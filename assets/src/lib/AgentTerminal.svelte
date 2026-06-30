<script lang="ts">
  import { Terminal } from "@xterm/xterm";
  import { FitAddon } from "@xterm/addon-fit";
  import { WebglAddon } from "@xterm/addon-webgl";
  import { CanvasAddon } from "@xterm/addon-canvas";
  import "@xterm/xterm/css/xterm.css";

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

  // An agent (Claude Code, Codex, shell, …) is itself a PTY/TUI program, so its
  // pane is a real terminal emulator. Output arrives over the initiative SSE
  // stream (demuxed by agent_id); input/resize go back over a per-agent WS.
  let { agentId, initiativeId }: { agentId: string; initiativeId: string } =
    $props();

  let el: HTMLDivElement;
  let term: Terminal | undefined;
  let fit: FitAddon | undefined;
  let sse: EventSource | undefined;
  let ws: WebSocket | undefined;
  let wsRetry: ReturnType<typeof setTimeout> | undefined;
  // Bumped on every (re)connect so a late replay fetch from a previous agent
  // can't write into the current agent's terminal.
  let gen = 0;

  function disconnect() {
    clearTimeout(wsRetry);
    sse?.close();
    if (ws) ws.onclose = null; // suppress the reconnect handler on intentional close
    ws?.close();
    sse = undefined;
    ws = undefined;
  }

  // The input channel (unlike the SSE output stream, which auto-reconnects)
  // won't come back on its own after a server drop, so reopen it quietly while
  // this agent stays selected. Displayed scrollback is left untouched.
  function openWs(agent: string, myGen: number): WebSocket {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const sock = new WebSocket(`${proto}://${location.host}/ws/agent/${encodeURIComponent(agent)}`);
    sock.onopen = () => {
      // Don't auto-grab focus — App owns focus (Tab cycles sidebar↔terminal), so
      // arrowing onto an agent doesn't trap the keyboard in the terminal.
      if (term && myGen === gen) ws?.send(JSON.stringify({ t: "r", cols: term.cols, rows: term.rows }));
    };
    sock.onclose = () => {
      if (myGen !== gen) return; // superseded by a switch — let it go
      clearTimeout(wsRetry);
      wsRetry = setTimeout(() => {
        if (myGen === gen) ws = openWs(agent, myGen);
      }, 1500);
    };
    return sock;
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

  // PTY output is base64 on the wire (binary-safe). Decode to bytes and let
  // xterm reassemble UTF-8 across writes.
  function b64ToBytes(b64: string): Uint8Array {
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  }

  function connect(agent: string, initiative: string) {
    disconnect();
    term?.reset();
    const myGen = ++gen;

    // 1. Replay buffered scrollback before live bytes arrive. Guard against a
    // stale resolution landing in a newer agent's terminal.
    fetch(`/api/agent/${encodeURIComponent(agent)}/output?n=400`)
      .then((r) => (r.ok ? r.json() : { output: [] }))
      .then((d) => {
        if (myGen !== gen) return;
        if (Array.isArray(d.output)) d.output.forEach((c: string) => term?.write(b64ToBytes(c)));
      })
      .catch(() => {});

    // 2. Live output over the initiative SSE stream, demuxed by agent_id.
    sse = new EventSource(`/events/initiative/${encodeURIComponent(initiative)}`);
    sse.addEventListener("output", (e) => {
      if (myGen !== gen) return;
      const d = JSON.parse((e as MessageEvent).data);
      if (d.agent_id === agent) term?.write(b64ToBytes(d.content));
    });
    sse.addEventListener("stopped", (e) => {
      if (myGen !== gen) return;
      const d = JSON.parse((e as MessageEvent).data);
      if (d.agent_id === agent)
        term?.write(`\r\n\x1b[31m[agent stopped, exit ${d.exit_code}]\x1b[0m\r\n`);
    });

    // 3. Input channel — keystrokes + resize. Reopens itself on an unexpected drop.
    ws = openWs(agent, myGen);
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
      term.onData((data) => {
        if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ t: "d", d: data }));
      });
      term.onResize(({ cols, rows }) => {
        if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ t: "r", cols, rows }));
      });
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
