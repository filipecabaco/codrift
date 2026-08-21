<script lang="ts">
  import { Terminal } from "@xterm/xterm";
  import { FitAddon } from "@xterm/addon-fit";
  import { WebglAddon } from "@xterm/addon-webgl";
  import { CanvasAddon } from "@xterm/addon-canvas";
  import { WebLinksAddon } from "@xterm/addon-web-links";
  import "@xterm/xterm/css/xterm.css";
  import { openUrl } from "$lib/api";
  import { fetchReplay, onAgentOutput, sendKeys, sendResize } from "$lib/stream";
  import { pathsToInput, registerDropZone, textToInput } from "$lib/dnd";
  import { themeState } from "$lib/theme.svelte";
  import { fontState } from "$lib/fonts.svelte";

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
  // `visible` is false while another tab is showing. The pane stays mounted
  // either way — see the persistent terminal layer in App.svelte — so this is
  // about painting, not about lifecycle.
  let {
    agentId,
    initiativeId,
    visible = true,
  }: { agentId: string; initiativeId: string; visible?: boolean } = $props();

  // ⇧⏎ (and ⌥⏎) insert a newline instead of submitting. Coding CLIs read the
  // ESC+CR pair as "newline, don't send" — the same sequence iTerm2 and VS Code
  // bind for it — while a plain shell treats it as a bare Return.
  const NEWLINE = "\x1b\r";

  function multilineEnter(t: Terminal) {
    t.attachCustomKeyEventHandler((e) => {
      if (e.type !== "keydown" || e.key !== "Enter") return true;
      if (e.ctrlKey || e.metaKey || !(e.shiftKey || e.altKey)) return true;
      e.preventDefault();
      // `agentId` is read at keypress time, so the handler survives the pane
      // switching agents — same reason onData reads it rather than closing over
      // a captured copy.
      sendKeys(agentId, NEWLINE);
      return false;
    });
  }

  // URLs in agent output are addresses worth following (a PR, a dev server, a
  // stack-trace doc). ⌘/⌃-click opens them in the real browser — via the
  // backend, since the Tauri webview has no window.open. A plain click is left
  // alone so it can still place the selection, matching every terminal app.
  function webLinks(t: Terminal) {
    t.loadAddon(
      new WebLinksAddon((e, uri) => {
        if (!(e.metaKey || e.ctrlKey)) return;
        void openUrl(uri).catch(() => {});
      }),
    );
  }

  let el: HTMLDivElement;
  let pane: HTMLDivElement;
  let dropping = $state(false);
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

  // The PTY hears about a resize at most once per idle moment, and only when the
  // grid actually changed. The ResizeObserver below fires on every frame of a
  // sidebar or split-divider drag, and every SIGWINCH makes a TUI repaint — a
  // burst of overlapping repaints is what garbled the pane. `agentId` is read at
  // fire time, like everywhere else here, so a switch mid-debounce can't resize
  // the agent we just left.
  let sentCols = 0;
  let sentRows = 0;
  let resizeTimer: ReturnType<typeof setTimeout> | undefined;

  function pushResize(cols: number, rows: number) {
    // A pane mid-teardown, or one that hasn't been laid out yet, measures as a
    // sliver. Forwarding that reflows the agent's UI to a size nobody chose, and
    // the damage outlives the resize that caused it.
    if (cols < 2 || rows < 2) return;
    if (cols === sentCols && rows === sentRows) return;
    sentCols = cols;
    sentRows = rows;
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => sendResize(agentId, cols, rows), 80);
  }

  // The terminal is themed from the same VS Code theme as the rest of the app —
  // including all 16 ANSI colours, so an agent's coloured output belongs to the
  // theme instead of fighting it.
  function xtermTheme() {
    const t = themeState.palette.terminal;
    return {
      background: t.background,
      foreground: t.foreground,
      cursor: t.cursor,
      cursorAccent: t.background,
      selectionBackground: t.selectionBackground,
      black: t.black,
      red: t.red,
      green: t.green,
      yellow: t.yellow,
      blue: t.blue,
      magenta: t.magenta,
      cyan: t.cyan,
      white: t.white,
      brightBlack: t.brightBlack,
      brightRed: t.brightRed,
      brightGreen: t.brightGreen,
      brightYellow: t.brightYellow,
      brightBlue: t.brightBlue,
      brightMagenta: t.brightMagenta,
      brightCyan: t.brightCyan,
      brightWhite: t.brightWhite,
    };
  }

  /**
   * Make the agent paint its screen again.
   *
   * Attaching to a *running* agent is the case that used to leave a blank pane.
   * The replay is a byte log, not a screen: if the tail of it happens to clear
   * the display — a full-screen TUI's repaint usually ends up doing exactly
   * that — we have nothing to show, and an agent sitting on `needs input` has no
   * reason to ever write again. So we ask it to.
   *
   * There is no "redraw" to ask for, so we do what dragging a window edge does:
   * change the size, then change it back. SIGWINCH is the one signal every TUI
   * and every readline prompt answers with a full repaint. It has to be a real
   * change in both directions — Darwin's TIOCSWINSZ only raises SIGWINCH when
   * the winsize differs, and Codrift.Agent.Process drops same-size resizes
   * before that anyway (see its `last_size` guard).
   */
  function forceRepaint(agent: string) {
    if (!term || term.cols < 2 || term.rows < 3) return;
    sendResize(agent, term.cols, term.rows - 1);
    sendResize(agent, term.cols, term.rows);
    sentCols = term.cols;
    sentRows = term.rows;
  }

  function connect(agent: string, initiative: string) {
    disconnect();
    term?.reset();
    const myGen = ++gen;

    /*
     * Everything below is about one ordering rule: the replay is the *past*, so
     * nothing newer may already be on the screen when it lands.
     *
     * Two things used to break it, and both show up as a scrambled or
     * near-empty pane after switching to a *busy* agent — the case where live
     * frames are arriving the whole time, e.g. a coding CLI redrawing its
     * spinner every few hundred milliseconds.
     *
     * 1. `fetchReplay` is an HTTP round trip. Frames that arrived while it was
     *    in flight were written straight through, and then the older replay was
     *    painted on top of them.
     * 2. `write()` is queued, not immediate. Calling `forceRepaint` right after
     *    the `forEach` only *looked* like "after the replay": the SIGWINCH
     *    repaint could be parsed before the replay bytes it was meant to land
     *    on top of, and get erased by them.
     *
     * So: subscribe first (no frame is missed), hold live frames in `pending`,
     * and release them from xterm's own parse callback — the one point where
     * the replay is not merely written but on the screen.
     */
    let pending: (() => void)[] | undefined = [];
    const afterReplay = (paint: () => void) => (pending ? pending.push(paint) : paint());

    unsubscribe = onAgentOutput(agent, {
      output: (bytes) => {
        if (myGen === gen) afterReplay(() => term?.write(bytes));
      },
      stopped: (code) => {
        if (myGen === gen) {
          afterReplay(() => term?.write(`\r\n\x1b[31m[agent stopped, exit ${code}]\x1b[0m\r\n`));
        }
      },
    });

    fetchReplay(agent).then((chunks) => {
      const flush = () => {
        if (myGen !== gen) return;
        const queued = pending ?? [];
        pending = undefined;
        queued.forEach((paint) => paint());
        forceRepaint(agent);
      };

      // A gen bump, or a terminal that went away mid-fetch, means no callback is
      // coming — drop the buffer rather than stranding live output in it.
      if (myGen !== gen || !term) {
        pending = undefined;
        return;
      }

      if (chunks.length === 0) return flush();
      chunks.forEach((bytes, i) => term?.write(bytes, i === chunks.length - 1 ? flush : undefined));
    });

    // Sent immediately rather than through pushResize: a freshly attached agent
    // has no idea how big our grid is, and it needs that before it first paints.
    if (term && term.cols >= 2 && term.rows >= 2) {
      sentCols = term.cols;
      sentRows = term.rows;
      sendResize(agent, term.cols, term.rows);
    }
  }

  // Recreate the live connection whenever the selected agent changes.
  $effect(() => {
    const a = agentId;
    const i = initiativeId;
    if (!term) {
      term = new Terminal({
        fontFamily: fontState.stack,
        fontSize: fontState.size,
        theme: xtermTheme(),
        cursorBlink: true,
        scrollback: 5000,
      });
      fit = new FitAddon();
      term.loadAddon(fit);
      term.open(el);
      useGpuRenderer(term);
      webLinks(term);
      multilineEnter(term);
      term.onData((data) => sendKeys(agentId, data));
      term.onResize(({ cols, rows }) => pushResize(cols, rows));
    }
    fit?.fit();
    connect(a, i);
  });

  // Coming back into view. The box never collapsed (visibility:hidden keeps it)
  // so there is nothing to reconnect and nothing to replay — but xterm doesn't
  // paint a terminal it can't see, so whatever arrived while another tab was up
  // is sitting in the buffer undrawn. `refresh` draws it. This is the difference
  // between switching back to a live pane and switching back to a blank one.
  $effect(() => {
    if (!visible || !term) return;
    fit?.fit();
    term.refresh(0, term.rows - 1);
  });

  // Re-skin a live terminal when the theme changes — no reconnect, no reload;
  // the scrollback keeps its content and just repaints in the new palette.
  $effect(() => {
    const theme = xtermTheme();
    if (term) term.options.theme = theme;
  });

  // Same for the typeface. A different cell size changes how many rows and
  // columns fit, so refit and tell the PTY its new dimensions.
  $effect(() => {
    const family = fontState.stack;
    const size = fontState.size;
    if (!term) return;
    term.options.fontFamily = family;
    term.options.fontSize = size;
    fit?.fit();
  });

  // Files dropped from Finder are typed in as absolute paths — the same thing a
  // terminal does — so the agent gets something it can actually open. `agentId`
  // is read at drop time, so the zone survives the pane switching agents.
  $effect(() =>
    registerDropZone(pane, {
      onHover: (over) => (dropping = over),
      onDrop: ({ paths, text }) => {
        const input = paths ? pathsToInput(paths) : textToInput(text ?? "");
        if (!input) return;
        sendKeys(agentId, input);
        // The drag stole focus from the terminal; typing should continue there.
        term?.focus();
      },
    }),
  );

  $effect(() => {
    // Guard the fit: a resize queued just before teardown would otherwise call
    // fit() on a disposed terminal and throw xterm's `_isDisposed` error. A
    // collapsed box is skipped too — `visibility:hidden` keeps the size, but a
    // pane being torn down (or laid out for the first time) reports 0×0, and
    // fitting to that proposes a one-column grid.
    const ro = new ResizeObserver((entries) => {
      const box = entries[0]?.contentRect;
      if (!term || !box || box.width < 2 || box.height < 2) return;
      fit?.fit();
    });
    ro.observe(el);
    return () => {
      ro.disconnect();
      clearTimeout(resizeTimer);
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

<!-- The padding lives on the wrapper, never on `el`. FitAddon sizes the grid from
     `getComputedStyle(el).height/width`, and under `box-sizing: border-box` — which
     Tailwind sets globally — that INCLUDES el's own padding, while it only ever
     subtracts the `.xterm` element's padding (0). With `p-1.5` on `el` it therefore
     fitted a grid to 12px more space than existed in both axes, overflowed the
     clipped pane by 9px, and told the PTY the terminal was a row and a column
     bigger than it is — which is what made full-screen redraws address a phantom
     row and paint over themselves. -->
<div class="relative size-full overflow-hidden bg-canvas p-1.5" bind:this={pane}>
  <div class="size-full" bind:this={el}></div>
  {#if dropping}
    <!-- pointer-events-none keeps this out of the hit test: the drop has to
         reach the pane underneath, not the hint drawn on top of it. -->
    <div
      class="pointer-events-none absolute inset-0 z-10 flex items-center justify-center border-2 border-dashed border-accent bg-canvas/60"
    >
      <span class="rounded-md border border-border bg-surface px-3 py-1.5 text-[12px] text-fg">
        Drop to insert into this agent
      </span>
    </div>
  {/if}
</div>
