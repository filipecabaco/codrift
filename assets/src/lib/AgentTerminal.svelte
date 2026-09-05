<script module lang="ts">
  import { Ghostty } from "ghostty-web";
  import wasmUrl from "ghostty-web/ghostty-vt.wasm?url";
  import { routeWindowOpenToBrowser } from "$lib/api";

  /**
   * A private VT core per terminal. Deliberately not shared.
   *
   * `init()` fetches the core from a base64 `data:` URL inlined in the bundle,
   * which our CSP blocks (`connect-src 'self'`) and which it offers no way to
   * point elsewhere. `Ghostty.load` takes a path, so it gets the copy Vite emits
   * as an ordinary same-origin asset. The inlined one still rides along in the
   * bundle, unreachable behind the path check inside `load`.
   *
   * Sharing one core between panes looks free — it holds no per-terminal state —
   * and it is not. Two terminals freed and rebuilt against one WASM heap wedge
   * the tab: 100% of a core, forever, in a loop no JS frame appears in, which is
   * what a theme change does to a split. Closing a pane is fine, and one pane
   * rebuilding alone is fine; it takes the second allocation after the second
   * free. An instance apiece costs a compile per terminal and cannot corrupt a
   * sibling. See coder/ghostty-web#141 for the shape of it.
   */
  const ghosttyCore = () => Ghostty.load(wasmUrl);

  // ghostty-web detects URLs itself and opens them with `window.open`, which this
  // webview does not implement — and it registers those providers from `open()`,
  // ahead of anything we could add. So the redirect has to happen on window.open.
  routeWindowOpenToBrowser();
</script>

<script lang="ts">
  import { FitAddon, Terminal } from "ghostty-web";
  import { untrack } from "svelte";
  import {
    type AgentTarget,
    CLEAR_TERMINAL,
    PASTE_INTO_AGENT,
    REDRAW_TERMINALS,
    TERMINAL_INPUT_CLASS,
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
  let loadError = $state<string | undefined>(undefined);

  let term: Terminal | undefined;
  let fit: FitAddon | undefined;
  let unsubscribe: (() => void) | undefined;
  // Bumped on every reconnect, so a replay still in flight for the agent we just
  // left is dropped rather than painted into this one.
  let gen = 0;
  /**
   * True while the replay is being parsed, which mutes the terminal's replies.
   *
   * A terminal answers questions: DSR (`\x1b[6n`) with a cursor position, OSC 11
   * with the background colour. It answers them the moment it PARSES them — it
   * cannot know it is reading a log rather than a live stream. So every reconnect
   * re-asked and re-answered every question in the replay, and the program that
   * asked had finished reading long ago, leaving its own replies typed into the
   * prompt: `11;rgb:2e2e/3434/4040;1R`, once per reattach.
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

  /**
   * Draw every cell again, onto a backing store built from scratch.
   *
   * This is the answer to two problems that happen to share a cure.
   *
   * WKWebView drops the contents of a surface it has decided is off screen, and
   * raises no event doing it. ghostty-web's render loop cannot recover from that
   * on its own: it runs every frame, but asks for the DIRTY rows, and a screen
   * nobody has written to has none — so the loop faithfully paints nothing and
   * the pane stays blank until something forces a full redraw. Reassigning
   * `canvas.width` (which `renderer.resize` does) is what makes WebKit allocate a
   * new surface, and `forceAll` is what fills it.
   *
   * It also puts the canvas back on the device pixel grid. ghostty-web sizes the
   * backing store twice whenever the grid or the font changes: the renderer sets
   * it in device pixels and scales the context to match, then the terminal
   * overwrites `canvas.width` in CSS pixels — which also resets the transform. On
   * a Retina display that leaves every cell drawn at half resolution, so the text
   * comes back blurry after the first divider drag.
   */
  function repaint() {
    const t = term;
    const renderer = t?.renderer;
    if (!t || !renderer || !t.wasmTerm) return;
    renderer.resize(t.cols, t.rows);
    renderer.render(t.wasmTerm, true, t.getViewportY(), t);
  }

  // ── Input ──────────────────────────────────────────────────────────────────

  // ⇧⏎ / ⌥⏎ insert a newline instead of submitting: coding CLIs read ESC+CR as
  // "newline, don't send", the same pair iTerm2 and VS Code bind for it.
  //
  // The return value is INVERTED from xterm.js: here `true` means "handled, stop"
  // where xterm.js reads it as "carry on" (coder/ghostty-web#192). Returning
  // xterm's values would swallow every keystroke in the pane.
  function multilineEnter(t: Terminal) {
    t.attachCustomKeyEventHandler((e) => {
      if (e.key !== "Enter") return false;
      if (e.ctrlKey || e.metaKey || !(e.shiftKey || e.altKey)) return false;
      sendKeys(agentId, "\x1b\r");
      return true;
    });
  }

  // ── Sizing ─────────────────────────────────────────────────────────────────

  // FitAddon divides the measured box by the cell size, so a box that has not
  // been laid out yet proposes a 2×1 grid — which reflows the buffer to two
  // columns, and no later refit puts the wrapped lines back.
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

  /** Nothing on screen: every row in the buffer is blank. */
  function isBlank(t: Terminal): boolean {
    const buf = t.buffer.active;
    for (let i = 0; i < buf.length; i++) {
      if (buf.getLine(i)?.translateToString(true).trim()) return false;
    }
    return true;
  }

  /**
   * The refresh action: WKWebView drops surfaces for reasons that raise no
   * event, and then only dragging the window edge brings the pane back.
   *
   * Unless the BUFFER is what is empty — every step here draws from it, so
   * repainting nothing faithfully paints nothing. That is a replay that never
   * landed, and only refetching helps. Guarded on blankness because a reconnect
   * resets the terminal, and the replay holds less than the scrollback does.
   */
  export function redraw() {
    if (!term || !visible) return;
    fitSafe();
    repaint();
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
   * HTTP round trip lets live frames arrive first, and the write callback is
   * deferred a frame, so "after the forEach" can still land before the replay is
   * on screen. Hence: subscribe first so no frame is missed, hold live frames in
   * `pending`, and release them from the write callback.
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
        repaint();
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
  // than fighting it. `terminal` carries exactly the theme's own colour names.
  function terminalTheme() {
    const t = themeState.palette.terminal;
    return { ...t, cursorAccent: t.background };
  }

  /**
   * The theme the terminal was BUILT with, which is the only one it can wear.
   *
   * ghostty-web resolves colours when it constructs the WASM terminal: every
   * cell then carries its own RGB, so `renderer.setTheme` afterwards only
   * repaints the ground between cells and the text stays in the old palette
   * (coder/ghostty-web#125, #121). Re-theming means a new terminal — affordable
   * here, since a pane already knows how to rebuild itself from the replay, and
   * the cost is the scrollback older than the replay window.
   *
   * Debounced, because the theme picker previews on every arrow key and each
   * preview would otherwise cost a WASM terminal and a replay fetch.
   */
  let themeKey = $state(untrack(() => JSON.stringify(themeState.palette.terminal)));

  $effect(() => {
    const key = JSON.stringify(themeState.palette.terminal);
    if (key === untrack(() => themeKey)) return;
    const timer = setTimeout(() => (themeKey = key), 250);
    return () => clearTimeout(timer);
  });

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  // Built once per theme, disposed once. Font is read untracked because it is
  // only the *initial* size — it can be changed in place, and tracked here a
  // font tweak would tear the terminal down to restyle it.
  $effect(() => {
    themeKey; // a new palette needs a new terminal — see above
    let cancelled = false;
    let built: Terminal | undefined;
    let ro: ResizeObserver | undefined;

    // `.catch` rather than a second `.then` argument: an onRejected handler does
    // not see what the onFulfilled beside it threw, and `open()` throws — that
    // would have gone out as an unhandled rejection, leaving a blank pane and no
    // way to tell it from one that simply painted nothing.
    ghosttyCore()
      .then((ghostty) => {
        if (cancelled) return;
        const t = new Terminal({
          ghostty,
          ...untrack(() => ({
            fontFamily: fontState.stack,
            fontSize: fontState.size,
            theme: terminalTheme(),
            cursorBlink: true,
            // Ghostty budgets scrollback in BYTES, not lines, however the option
            // is named on this side (coder/ghostty-web#140) — the old 5000 would
            // have bought about a screenful. 4MB is a few tens of thousands of
            // lines, and well under Ghostty's own 10MB default per surface.
            scrollback: 4_000_000,
          })),
        });

        // `open()` focuses, which is wrong for a pane mounting behind another tab
        // or while a form field has the caret — put focus back where it was.
        const previous = document.activeElement as HTMLElement | null;
        t.open(el);
        if (previous && previous !== document.body) previous.focus?.();
        else if (!untrack(() => visible)) t.blur();

        fit = new FitAddon();
        t.loadAddon(fit);
        multilineEnter(t);
        // Both read `agentId` at fire time, so they survive the pane changing agent.
        t.onData((data) => {
          if (!replaying) sendKeys(agentId, data);
        });
        t.onResize(({ cols, rows }) => {
          repaint();
          pushResize(cols, rows);
        });
        built = t;
        term = t;

        ro = new ResizeObserver(() => fitSafe());
        ro.observe(el);

        // The reattach effect below has already run and found no terminal, so
        // this first connection is ours to make. The deferred repaint is for the
        // first frame: `open()` drew once already, but into a surface the webview
        // had not laid out yet.
        fitSafe();
        connect(agentId);
        requestAnimationFrame(() => {
          if (!cancelled) repaint();
        });
      })
      .catch((e: unknown) => {
        if (!cancelled) loadError = e instanceof Error ? e.message : String(e);
      });

    return () => {
      cancelled = true;
      ro?.disconnect();
      clearTimeout(resizeTimer);
      disconnect();
      built?.dispose();
      term = undefined;
      fit = undefined;
    };
  });

  // Reattach whenever the pane changes agent. Never a remount: rebuilding the
  // terminal costs a WASM terminal and a fresh unlaid-out fit, which is what left
  // panes blank or clipped.
  $effect(() => {
    const agent = agentId;
    initiativeId; // an agent belongs to one initiative; reattach if either moves
    if (!term) return;
    fitSafe();
    connect(agent);
  });

  // The font restyles in place: no reconnect, no reload, scrollback intact. A
  // different cell size changes how many rows and columns fit, so refit and let
  // onResize tell the PTY. (The theme cannot go this way — see `themeKey`.)
  $effect(() => {
    const family = fontState.stack;
    const size = fontState.size;
    if (!term) return;
    term.options.fontFamily = family;
    term.options.fontSize = size;
    fitSafe();
    repaint();
  });

  // Coming back into view: the box never collapsed, so nothing to reconnect, but
  // the surface it was drawn on may not have survived being hidden. Twice,
  // because this runs in the same flush that removed the `invisible` class and a
  // renderer asked to draw before layout drops the frame — the "blank until you
  // click it" case.
  $effect(() => {
    if (!visible) return;
    fitSafe();
    repaint();
    const frame = requestAnimationFrame(() => {
      fitSafe();
      repaint();
    });
    return () => cancelAnimationFrame(frame);
  });

  // focus/visibilitychange: WKWebView drops the contents of an off-screen
  // surface, and nothing writes afterwards, so an idle agent comes back blank.
  $effect(() => {
    const onFocus = () => {
      if (visible) repaint();
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
    // A broadcast because App.svelte renders terminals inside a snippet and holds
    // no reference to them — see lib/api.ts.
    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onFocus);
    window.addEventListener(REDRAW_TERMINALS, redraw);
    window.addEventListener(PASTE_INTO_AGENT, onPaste);
    window.addEventListener(CLEAR_TERMINAL, onClear);
    return () => {
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onFocus);
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
   * path. The terminal has to do it — a shell that never asked for bracketed
   * paste must not be handed a literal `[200~`, and only it knows which it is.
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

<!-- Padding on the wrapper, never on `el`: FitAddon measures el's clientWidth and
     subtracts el's own padding, so padding here is already outside the measured
     box while padding there would be counted twice. Terminal background rather
     than canvas, because a character grid rarely divides the pane exactly and the
     remainder should read as where the terminal ends, not as dead space stuck to
     it. -->
<div
  class="relative size-full overflow-hidden p-1.5"
  style="background: {themeState.palette.terminal.background}"
  bind:this={pane}
>
  <!-- ghostty-web makes this element the terminal: it sets `contenteditable` and
       `tabindex` here and hangs keydown, paste and composition off it, so THIS is
       what `document.activeElement` becomes — not the textarea it also creates.
       Hence the marker class here, which is how App.svelte tells a terminal from
       a real text field. `caret-transparent` because contenteditable draws a
       blinking DOM caret in the corner, and the only cursor that means anything
       is the one the renderer paints on the canvas. -->
  <div class="size-full caret-transparent {TERMINAL_INPUT_CLASS}" bind:this={el}></div>
  {#if loadError}
    <div class="absolute inset-0 z-10 flex items-center justify-center p-4">
      <span class="rounded-md border border-border bg-surface px-3 py-1.5 text-[12px] text-fg">
        Terminal engine failed to load: {loadError}
      </span>
    </div>
  {/if}
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
