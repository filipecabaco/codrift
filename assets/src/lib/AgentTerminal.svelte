<script lang="ts">
  import { Terminal } from "@xterm/xterm";
  import { FitAddon } from "@xterm/addon-fit";
  import { WebglAddon } from "@xterm/addon-webgl";
  import { CanvasAddon } from "@xterm/addon-canvas";
  import { WebLinksAddon } from "@xterm/addon-web-links";
  import "@xterm/xterm/css/xterm.css";
  import { untrack } from "svelte";
  import {
    type AgentTarget,
    CLEAR_TERMINAL,
    openUrl,
    PASTE_INTO_AGENT,
    REDRAW_TERMINALS,
    type PasteRequest,
  } from "$lib/api";
  import { fetchReplay, onAgentOutput, sendKeys, sendResize } from "$lib/stream";
  import { pathsToInput, registerDropZone, textToInput } from "$lib/dnd";
  import { themeState } from "$lib/theme.svelte";
  import { fontState } from "$lib/fonts.svelte";

  // An agent is itself a PTY program, so its pane is a real terminal emulator;
  // both directions ride the shared socket (lib/stream.ts). `visible` is false
  // while another tab shows. The pane stays mounted either way — see the
  // persistent terminal layer in App.svelte — so this is about painting only.
  let {
    agentId,
    initiativeId,
    visible = true,
  }: { agentId: string; initiativeId: string; visible?: boolean } = $props();

  let pane: HTMLDivElement;
  let el: HTMLDivElement;
  let dropping = $state(false);

  let term: Terminal | undefined;
  let fit: FitAddon | undefined;
  let unsubscribe: (() => void) | undefined;
  // Bumped on every reconnect, so a replay still in flight for the agent we just
  // left is dropped rather than painted into this one.
  let gen = 0;
  /**
   * True while the replay is being parsed, which mutes xterm's replies to it.
   *
   * A terminal answers questions: DSR (`\x1b[6n`) with a cursor position, OSC 11
   * with the background colour. xterm answers them the moment it PARSES them —
   * it cannot know it is reading a log rather than a live stream. So every
   * reconnect re-asked and re-answered every question in the replay, and the
   * program that asked had finished reading long ago, leaving its own replies
   * typed into the prompt: `11;rgb:2e2e/3434/4040;1R`, once per reattach.
   *
   * Nothing may be reported about a screen that has already been drawn, so the
   * replies are dropped rather than sent. Live output is unaffected: it is held
   * in `pending` and released only after this clears, so a real question asked
   * while the replay was in flight is still answered.
   */
  let replaying = false;
  let sentCols = 0;
  let sentRows = 0;
  let resizeTimer: ReturnType<typeof setTimeout> | undefined;

  // ── Renderer ───────────────────────────────────────────────────────────────

  // WKWebView won't composite xterm's DOM renderer — output stays invisible
  // until something forces a native repaint. A GPU renderer is the fix.
  function loadRenderer(t: Terminal) {
    try {
      const webgl = new WebglAddon();
      webgl.onContextLoss(() => recoverRenderer(t, webgl));
      t.loadAddon(webgl);
    } catch {
      loadCanvas(t);
    }
  }

  function loadCanvas(t: Terminal) {
    try {
      t.loadAddon(new CanvasAddon());
    } catch {
      /* xterm's DOM renderer: worse, but not nothing */
    }
  }

  // WKWebView throws the GPU surface away whenever it decides the window is off
  // screen. Dispose on the NEXT tick — `dispose()` from inside `onContextLoss`
  // throws, and that throw used to skip the fallback, leaving no renderer at all
  // — then repaint, since a new renderer starts empty. Canvas for good: a fresh
  // WebglAddon would lose its context the same way on the next window switch.
  function recoverRenderer(t: Terminal, webgl: WebglAddon) {
    setTimeout(() => {
      try {
        webgl.dispose();
      } catch {
        /* must not cost us the fallback */
      }
      loadCanvas(t);
      try {
        t.refresh(0, t.rows - 1);
      } catch {
        /* torn down mid-recovery */
      }
    }, 0);
  }

  // ── Input ──────────────────────────────────────────────────────────────────

  // ⇧⏎ / ⌥⏎ insert a newline instead of submitting: coding CLIs read ESC+CR as
  // "newline, don't send", the same pair iTerm2 and VS Code bind for it.
  function multilineEnter(t: Terminal) {
    t.attachCustomKeyEventHandler((e) => {
      if (e.type !== "keydown" || e.key !== "Enter") return true;
      if (e.ctrlKey || e.metaKey || !(e.shiftKey || e.altKey)) return true;
      e.preventDefault();
      sendKeys(agentId, "\x1b\r");
      return false;
    });
  }

  // ⌘/⌃-click opens a URL in the real browser — via the backend, since the Tauri
  // webview has no window.open. A plain click still places the selection.
  function linkOpener(t: Terminal) {
    t.loadAddon(
      new WebLinksAddon((e, uri) => {
        if (e.metaKey || e.ctrlKey) void openUrl(uri).catch(() => {});
      }),
    );
  }

  // ── Sizing ─────────────────────────────────────────────────────────────────

  // FitAddon divides the measured box by the cell size, so a box that has not
  // been laid out yet proposes a 1×1 grid — which reflows the buffer to one
  // column, and no later refit puts the wrapped lines back.
  function fitSafe() {
    if (!term || !el) return;
    const box = el.getBoundingClientRect();
    if (box.width >= 2 && box.height >= 2) fit?.fit();
  }

  // Debounced and deduped: the ResizeObserver fires on every frame of a divider
  // drag and every SIGWINCH makes a TUI repaint, so a burst garbles the pane.
  function pushResize(cols: number, rows: number) {
    if (cols < 2 || rows < 2) return;
    if (cols === sentCols && rows === sentRows) return;
    sentCols = cols;
    sentRows = rows;
    clearTimeout(resizeTimer);
    // `agentId` at fire time, so a switch mid-debounce can't resize the agent we
    // just left.
    resizeTimer = setTimeout(() => sendResize(agentId, cols, rows), 80);
  }

  // No "redraw" exists to request, so do what dragging a window edge does:
  // resize by a row and back. SIGWINCH is the one signal every TUI repaints for,
  // and Darwin only raises it when the winsize really differs — hence both ways.
  //
  // Alt-screen only. On the normal buffer losing a row scrolls the scrollback
  // under the cursor and the shell redraws its prompt where it now stands,
  // leaving a duplicate behind on every refresh — and it buys nothing there,
  // since that screen is exactly the bytes that built it.
  function forceRepaint(agent: string) {
    if (!term || term.cols < 2 || term.rows < 3) return;
    if (term.buffer.active.type !== "alternate") return;
    sendResize(agent, term.cols, term.rows - 1);
    sendResize(agent, term.cols, term.rows);
    sentCols = term.cols;
    sentRows = term.rows;
  }

  // ── Painting ───────────────────────────────────────────────────────────────

  function paint() {
    if (!term) return;
    fitSafe();
    term.refresh(0, term.rows - 1);
  }

  /** Nothing on screen: every row in the buffer is blank. */
  function isBlank(t: Terminal): boolean {
    const buf = t.buffer.active;
    for (let i = 0; i < buf.length; i++) {
      if (buf.getLine(i)?.translateToString(true).trim()) return false;
    }
    return true;
  }

  // The refresh action: WKWebView drops surfaces for reasons that raise no
  // event, and then only dragging the window edge brings the pane back.
  //
  // Unless the BUFFER is what is empty — every step here draws from it, so
  // repainting nothing faithfully paints nothing. That is a replay that never
  // landed, and only refetching helps. Guarded on blankness because a reconnect
  // resets the terminal, and the replay holds less than the scrollback does.
  export function redraw() {
    if (!term || !visible) return;
    paint();
    if (isBlank(term)) connect(agentId);
    else forceRepaint(agentId);
  }

  // ── Connection ─────────────────────────────────────────────────────────────

  function disconnect() {
    unsubscribe?.();
    unsubscribe = undefined;
  }

  /**
   * Attach to `agent`, replay what it has printed, then go live.
   *
   * The replay is the PAST, so nothing newer may be on screen when it lands. The
   * HTTP round trip lets live frames arrive first, and `write()` is queued, so
   * "after the forEach" can still be parsed before the replay. Hence: subscribe
   * first so no frame is missed, hold live frames in `pending`, and release them
   * from xterm's parse callback — the one point where the replay is on screen.
   */
  function connect(agent: string) {
    disconnect();
    term?.reset();
    // A new agent has never been told our size; carrying the last one's over
    // would let pushResize drop a genuinely needed resize as a duplicate.
    sentCols = 0;
    sentRows = 0;
    const myGen = ++gen;

    let pending: (() => void)[] | undefined = [];
    const afterReplay = (draw: () => void) => (pending ? pending.push(draw) : draw());

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
        // Only ever cleared by the connect that set it: a newer one may already
        // be replaying, and stealing its mute would let its replies through.
        if (myGen !== gen) return;
        replaying = false;
        const queued = pending ?? [];
        pending = undefined;
        queued.forEach((draw) => draw());
        forceRepaint(agent);
      };

      // A gen bump, or a terminal that went away mid-fetch, means no callback is
      // coming — drop the buffer rather than stranding live output in it.
      if (myGen !== gen || !term) {
        pending = undefined;
        return;
      }
      if (chunks.length === 0) return flush();
      // Muted from just before the first byte is written until the last is
      // parsed — never across the fetch, so a request that never answers cannot
      // leave the pane swallowing keystrokes.
      replaying = true;
      chunks.forEach((bytes, i) => term?.write(bytes, i === chunks.length - 1 ? flush : undefined));
    });

    // Immediate rather than through pushResize: a freshly attached agent needs
    // our size before it first paints. Cancelling the debounce first is not
    // tidiness — the fit above queues a resize that would otherwise fire 80ms
    // later and re-size the agent we have already told the truth to.
    clearTimeout(resizeTimer);
    if (term && term.cols >= 2 && term.rows >= 2) {
      sentCols = term.cols;
      sentRows = term.rows;
      sendResize(agent, term.cols, term.rows);
    }
  }

  // The terminal is themed from the same VS Code theme as the rest of the app,
  // all 16 ANSI colours included, so agent output belongs to the theme rather
  // than fighting it. `terminal` carries exactly xterm's own colour names.
  function xtermTheme() {
    const t = themeState.palette.terminal;
    return { ...t, cursorAccent: t.background };
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  // Built once, disposed once. Theme and font are read untracked because they
  // are only the *initial* options — tracked, a theme change would land in this
  // effect's dependencies and tear the terminal down to restyle it.
  $effect(() => {
    const t = new Terminal(
      untrack(() => ({
        fontFamily: fontState.stack,
        fontSize: fontState.size,
        theme: xtermTheme(),
        cursorBlink: true,
        scrollback: 5000,
      })),
    );
    fit = new FitAddon();
    t.loadAddon(fit);
    t.open(el);
    loadRenderer(t);
    linkOpener(t);
    multilineEnter(t);
    // Both read `agentId` at fire time, so they survive the pane changing agent.
    t.onData((data) => {
      if (!replaying) sendKeys(agentId, data);
    });
    t.onResize(({ cols, rows }) => pushResize(cols, rows));
    term = t;

    const ro = new ResizeObserver(() => fitSafe());
    ro.observe(el);

    return () => {
      ro.disconnect();
      clearTimeout(resizeTimer);
      disconnect();
      try {
        t.dispose();
      } catch {
        /* the WebGL addon can throw from a deferred render while disposing */
      }
      term = undefined;
      fit = undefined;
    };
  });

  // Reattach whenever the pane changes agent. Never a remount: rebuilding the
  // terminal costs a GPU context and a fresh unlaid-out fit, which is what left
  // panes blank or clipped.
  $effect(() => {
    const agent = agentId;
    initiativeId; // an agent belongs to one initiative; reattach if either moves
    if (!term) return;
    fitSafe();
    connect(agent);
  });

  // Restyle in place: no reconnect, no reload, scrollback intact. A different
  // cell size changes how many rows and columns fit, so refit and let onResize
  // tell the PTY.
  $effect(() => {
    const theme = xtermTheme();
    const family = fontState.stack;
    const size = fontState.size;
    if (!term) return;
    term.options.theme = theme;
    term.options.fontFamily = family;
    term.options.fontSize = size;
    fitSafe();
  });

  // Coming back into view: the box never collapsed, so nothing to reconnect, but
  // xterm doesn't paint a terminal it can't see. Twice, because this runs in the
  // same flush that removed the `invisible` class and a renderer asked to draw
  // before layout drops the frame — the "blank until you click it" case.
  $effect(() => {
    if (!visible) return;
    paint();
    const frame = requestAnimationFrame(paint);
    return () => cancelAnimationFrame(frame);
  });

  // focus/visibilitychange: WKWebView drops the contents of an off-screen
  // surface, and nothing writes afterwards, so an idle agent comes back blank.
  // The custom events are broadcasts because App.svelte renders terminals inside
  // a snippet and holds no reference to them — see lib/api.ts.
  $effect(() => {
    const repaint = () => {
      if (visible && term) term.refresh(0, term.rows - 1);
    };
    const onPaste = (e: Event) => {
      const req = (e as CustomEvent<PasteRequest>).detail;
      if (!term || req.agentId !== agentId || !req.text) return;
      term.paste(req.text);
      term.focus();
    };
    const onClear = (e: Event) => {
      const req = (e as CustomEvent<AgentTarget>).detail;
      if (!term || req.agentId !== agentId) return;
      term.clear();
      term.focus();
    };
    window.addEventListener("focus", repaint);
    document.addEventListener("visibilitychange", repaint);
    window.addEventListener(REDRAW_TERMINALS, redraw);
    window.addEventListener(PASTE_INTO_AGENT, onPaste);
    window.addEventListener(CLEAR_TERMINAL, onClear);
    return () => {
      window.removeEventListener("focus", repaint);
      document.removeEventListener("visibilitychange", repaint);
      window.removeEventListener(REDRAW_TERMINALS, redraw);
      window.removeEventListener(PASTE_INTO_AGENT, onPaste);
      window.removeEventListener(CLEAR_TERMINAL, onClear);
    };
  });

  /**
   * A drop is a paste, not typing — which is what makes an image an image.
   *
   * `term.paste` adds the `\x1b[200~`…`\x1b[201~` envelope when the program turned
   * bracketed-paste mode on, and that envelope is the entire signal a CLI has to
   * tell a pasted path from a typed one: Claude Code shows a dropped image as
   * `[Image #1]`, where the same bytes through `sendKeys` land as the literal
   * path. xterm has to do it — a shell that never asked for bracketed paste must
   * not be handed a literal `[200~`, and only xterm knows which it is.
   */
  $effect(() =>
    registerDropZone(pane, {
      onHover: (over) => (dropping = over),
      onDrop: ({ paths, text }) => {
        const input = paths ? pathsToInput(paths) : textToInput(text ?? "");
        if (!input) return;
        term?.paste(input);
        // The drag stole focus from the terminal; typing should continue there.
        term?.focus();
      },
    }),
  );
</script>

<!-- Padding on the wrapper, never on `el`: FitAddon measures el under
     `box-sizing: border-box`, which INCLUDES its padding while only subtracting
     `.xterm`'s (0), so `p-1.5` there fitted a grid to 12px that did not exist.
     Terminal background rather than canvas, because a character grid rarely
     divides the pane exactly and the remainder should read as where the terminal
     ends, not as dead space stuck to it. -->
<div
  class="relative size-full overflow-hidden p-1.5"
  style="background: {themeState.palette.terminal.background}"
  bind:this={pane}
>
  <div class="size-full" bind:this={el}></div>
  {#if dropping}
    <!-- pointer-events-none keeps this out of the hit test: the drop has to reach
         the pane underneath, not the hint drawn on top of it. -->
    <div
      class="pointer-events-none absolute inset-0 z-10 flex items-center justify-center border-2 border-dashed border-accent bg-canvas/60"
    >
      <span class="rounded-md border border-border bg-surface px-3 py-1.5 text-[12px] text-fg">
        Drop to insert into this agent
      </span>
    </div>
  {/if}
</div>
