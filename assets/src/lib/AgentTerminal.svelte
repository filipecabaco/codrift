<script lang="ts">
  import { Terminal } from "@xterm/xterm";
  import { FitAddon } from "@xterm/addon-fit";
  import { WebglAddon } from "@xterm/addon-webgl";
  import { CanvasAddon } from "@xterm/addon-canvas";
  import { WebLinksAddon } from "@xterm/addon-web-links";
  import "@xterm/xterm/css/xterm.css";
  import { openUrl, REDRAW_TERMINALS } from "$lib/api";
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
        // A fresh renderer starts with an empty canvas: everything already on
        // the screen lives in xterm's buffer, not in the surface that just went
        // away. Without this the pane stays blank until something happens to
        // write to it — which, for an agent waiting on input, is never.
        t.refresh(0, t.rows - 1);
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

  /**
   * Fit, unless the box isn't real yet.
   *
   * FitAddon divides the parent's measured size by the cell size, and a box that
   * has not been laid out (a pane one frame old, one mid-teardown) measures
   * zero — which proposes a 1×1 grid. xterm then reflows the buffer to one
   * column, and nothing later puts it back: a refit to the true size only
   * restores the geometry, not the lines that were wrapped away inside it.
   */
  function fitSafe() {
    if (!term || !el) return;
    const box = el.getBoundingClientRect();
    if (box.width < 2 || box.height < 2) return;
    fit?.fit();
  }

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
   * Make the agent paint its screen again — but only where that is free.
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
   *
   * The alt-screen guard is the whole subtlety. On the alternate buffer this
   * costs nothing: there is no scrollback to disturb and the TUI answers by
   * redrawing every cell. On the NORMAL buffer the same trick is destructive —
   * losing a row scrolls the scrollback up under the cursor and the shell
   * redraws its prompt where it now stands, so every re-select of a plain
   * terminal left another blank line and another prompt behind, and they piled
   * up for as long as the session lived. And it buys nothing there: a
   * normal-buffer screen is exactly the bytes that built it, which is what the
   * replay just wrote.
   */
  function forceRepaint(agent: string) {
    if (!term || term.cols < 2 || term.rows < 3) return;
    if (term.buffer.active.type !== "alternate") return;
    sendResize(agent, term.cols, term.rows - 1);
    sendResize(agent, term.cols, term.rows);
    sentCols = term.cols;
    sentRows = term.rows;
  }

  /**
   * The manual "put this pane right again", behind the refresh action.
   *
   * Everything above that repaints does so on a trigger we can observe — coming
   * back into view, regaining focus, losing the GPU context. WKWebView also
   * drops a surface for reasons that raise no event at all, and then the only
   * thing that brings the pane back is dragging the window edge. This is that
   * drag, on demand, in the three steps a real resize performs:
   *
   *   1. re-measure the box, in case the grid is genuinely wrong;
   *   2. redraw every row from xterm's buffer — always safe, and enough on its
   *      own whenever the bytes are there and only the surface went away;
   *   3. nudge the agent with SIGWINCH so a TUI re-emits its screen, for when
   *      the buffer is the thing that is wrong. `forceRepaint` decides whether
   *      that is safe; on the normal buffer it declines.
   */
  export function redraw() {
    if (!term || !visible) return;
    fitSafe();
    term.refresh(0, term.rows - 1);
    forceRepaint(agentId);
  }

  $effect(() => {
    const onRedraw = () => redraw();
    window.addEventListener(REDRAW_TERMINALS, onRedraw);
    return () => window.removeEventListener(REDRAW_TERMINALS, onRedraw);
  });

  function connect(agent: string, initiative: string) {
    disconnect();
    term?.reset();
    // The new agent has never been told anything. Carrying the last one's
    // dimensions over would let pushResize decide a genuinely needed resize was
    // a duplicate and drop it, leaving the agent drawing to a grid it has the
    // wrong size for — which is what a scrambled pane is.
    sentCols = 0;
    sentRows = 0;
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
    //
    // Cancelling the debounce first is not tidiness. `fit()` runs just before
    // every connect(), which queues a resize carrying the size measured *then*;
    // 80ms later that timer fired and re-sized the agent we had already told the
    // truth to. A grid one size and a PTY another is what a scrambled pane looks
    // like from the inside.
    clearTimeout(resizeTimer);
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
    fitSafe();
    connect(a, i);
  });

  // Coming back into view. The box never collapsed (visibility:hidden keeps it)
  // so there is nothing to reconnect and nothing to replay — but xterm doesn't
  // paint a terminal it can't see, so whatever arrived while another tab was up
  // is sitting in the buffer undrawn. `refresh` draws it. This is the difference
  // between switching back to a live pane and switching back to a blank one.
  //
  // Twice, once now and once on the next frame. The immediate call is what makes
  // the switch feel instant; the deferred one is what makes it correct, because
  // this effect runs inside the same flush that removed the `invisible` class
  // and a renderer asked to draw before the browser has laid the box out drops
  // the frame — which is the "blank until you click it" case exactly.
  $effect(() => {
    if (!visible) return;
    const paint = () => {
      if (!term) return;
      fitSafe();
      term.refresh(0, term.rows - 1);
    };
    paint();
    const frame = requestAnimationFrame(paint);
    return () => cancelAnimationFrame(frame);
  });

  // WKWebView drops the contents of a GPU surface it decided was off-screen —
  // hiding the window, switching Spaces, the machine sleeping. Nothing writes to
  // the terminal afterwards, so an agent waiting on input comes back to a pane
  // that is blank until it is touched. Redraw from the buffer on the way back
  // in, which costs one frame and is the only way anything gets on screen.
  $effect(() => {
    const repaint = () => {
      if (visible && term) term.refresh(0, term.rows - 1);
    };
    window.addEventListener("focus", repaint);
    document.addEventListener("visibilitychange", repaint);
    return () => {
      window.removeEventListener("focus", repaint);
      document.removeEventListener("visibilitychange", repaint);
    };
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
    fitSafe();
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
    // fitSafe carries both guards this needs: a terminal already disposed (a
    // resize queued just before teardown would throw xterm's `_isDisposed`) and
    // a box that measures as nothing.
    const ro = new ResizeObserver(() => fitSafe());
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
     row and paint over themselves.

     Painted in the terminal's own background rather than the app canvas: a
     character grid almost never divides the pane exactly, so there is up to a
     cell of remainder down the right edge and along the bottom, plus this
     padding. In the canvas colour all of it reads as dead space stuck to the
     terminal; in the theme's terminal background it is simply where the
     terminal ends. -->
<div
  class="relative size-full overflow-hidden p-1.5"
  style="background: {themeState.palette.terminal.background}"
  bind:this={pane}
>
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
