<script lang="ts">
  import { Terminal } from "@xterm/xterm";
  import { FitAddon } from "@xterm/addon-fit";
  import { WebglAddon } from "@xterm/addon-webgl";
  import { CanvasAddon } from "@xterm/addon-canvas";
  import "@xterm/xterm/css/xterm.css";
  import { fetchReplay, onAgentOutput, sendKeys, sendResize } from "$lib/stream";

  // WebKit (Tauri/WKWebView) doesn't reliably composite xterm's DOM renderer —
  // output stays invisible until a native repaint (e.g. selecting text). A GPU
  // renderer fixes it: prefer WebGL, fall back to Canvas, else the DOM renderer.
  function useGpuRenderer(t: Terminal) {
    try {
      const webgl = new WebglAddon();
      // On context loss, fall back to Canvas (not the DOM renderer, which WebKit
      // won't repaint) so the terminal keeps painting after switches.
      webgl.onContextLoss(() => {
        webgl.dispose();
        try {
          t.loadAddon(new CanvasAddon());
        } catch {
          /* DOM renderer */
        }
      });
      t.loadAddon(webgl);
    } catch {
      try {
        t.loadAddon(new CanvasAddon());
      } catch {
        /* DOM renderer */
      }
    }
  }

  // An agent is itself a PTY/TUI program, so its pane is a real terminal
  // emulator. Both directions ride the shared socket (lib/stream.ts).
  let { agentId, initiativeId }: { agentId: string; initiativeId: string } =
    $props();

  let el: HTMLDivElement;
  let term: Terminal | undefined;
  let fit: FitAddon | undefined;
  let unsubscribe: (() => void) | undefined;
  // Bumped on every (re)connect so a late replay fetch from a previous agent
  // can't write into the current agent's terminal.
  let gen = 0;

  function disconnect() {
    unsubscribe?.();
    unsubscribe = undefined;
  }

  // Resolve a CSS custom property to an rgb() string xterm can parse (the tokens
  // are OKLCH; the browser converts them for us). Keeps the terminal background
  // in sync with the app's canvas instead of a hard-coded hex.
  function cssColor(varName: string, fallback: string): string {
    try {
      const raw = getComputedStyle(document.documentElement).getPropertyValue(varName).trim();
      if (!raw) return fallback;
      const probe = document.createElement("span");
      probe.style.color = raw;
      probe.style.display = "none";
      document.body.appendChild(probe);
      const rgb = getComputedStyle(probe).color;
      probe.remove();
      return rgb || fallback;
    } catch {
      return fallback;
    }
  }

  function connect(agent: string, initiative: string) {
    disconnect();
    term?.reset();
    const myGen = ++gen;

    // Replay first; the gen guard stops a late resolution landing in a newer
    // agent's terminal.
    fetchReplay(agent).then((chunks) => {
      if (myGen === gen) chunks.forEach((bytes) => term?.write(bytes));
    });

    unsubscribe = onAgentOutput(agent, {
      output: (bytes) => {
        if (myGen === gen) term?.write(bytes);
      },
      stopped: (code) => {
        if (myGen === gen) term?.write(`\r\n\x1b[31m[agent stopped, exit ${code}]\x1b[0m\r\n`);
      },
    });

    if (term) sendResize(agent, term.cols, term.rows);
  }

  // Recreate the live connection whenever the selected agent changes.
  $effect(() => {
    const a = agentId;
    const i = initiativeId;
    if (!term) {
      term = new Terminal({
        fontFamily: 'ui-monospace, "Cascadia Code", Menlo, monospace',
        fontSize: 13,
        theme: {
          background: cssColor("--color-canvas", "#0b0e14"),
          foreground: cssColor("--color-fg", "#e8ebf1"),
          cursor: cssColor("--color-accent", "#e0922e"),
        },
        cursorBlink: true,
        scrollback: 5000,
      });
      fit = new FitAddon();
      term.loadAddon(fit);
      term.open(el);
      useGpuRenderer(term);
      term.onData((data) => sendKeys(agentId, data));
      term.onResize(({ cols, rows }) => sendResize(agentId, cols, rows));
    }
    fit?.fit();
    connect(a, i);
  });

  $effect(() => {
    // Guard the fit: a resize queued just before teardown would otherwise call
    // fit() on a disposed terminal and throw xterm's `_isDisposed` error.
    const ro = new ResizeObserver(() => {
      if (term) fit?.fit();
    });
    ro.observe(el);
    return () => {
      ro.disconnect();
      disconnect();
      // The WebGL addon can throw from a deferred render during dispose — the
      // terminal is going away regardless, so swallow it rather than surface an
      // uncaught error.
      try {
        term?.dispose();
      } catch {
        /* already torn down */
      }
      term = undefined;
      fit = undefined;
    };
  });
</script>

<div class="size-full overflow-hidden bg-canvas p-1.5" bind:this={el}></div>
