<script lang="ts">
  import { onMount, untrack } from "svelte";
  import { Icon } from "@steeze-ui/svelte-icon";
  import { ArrowPath, CommandLine, Link, Swatch } from "@steeze-ui/heroicons";
  import { rpc } from "$lib/api";
  import { conn, health } from "$lib/connection.svelte";
  import { workspace as ws, type Row } from "$lib/workspace.svelte";
  import {
    ACTION_LABELS,
    DEFAULT_KEYMAP,
    PALETTE_ACTIONS,
    buildReverse,
    eventToSpec,
    formatSpec,
    type ActionId,
    type Keymap,
  } from "$lib/keys";
  import AgentTerminal from "$lib/AgentTerminal.svelte";
  import DiffView from "$lib/DiffView.svelte";
  import ContextOverview from "$lib/ContextOverview.svelte";
  import TreeView from "$lib/TreeView.svelte";
  import Sidebar from "$lib/Sidebar.svelte";
  import CommandPalette from "$lib/CommandPalette.svelte";
  import Prompt from "$lib/Prompt.svelte";
  import DirPicker from "$lib/DirPicker.svelte";
  import Confirm from "$lib/Confirm.svelte";
  import Editor from "$lib/Editor.svelte";
  import Integrations from "$lib/Integrations.svelte";
  import NewInitiative from "$lib/NewInitiative.svelte";
  import Appearance from "$lib/Appearance.svelte";
  import { initTheme, themeState } from "$lib/theme.svelte";
  import { initFonts } from "$lib/fonts.svelte";

  // Each pane is an independent viewport onto an initiative — its own agent,
  // tab, open context file and tree selection. The sidebar drives whichever
  // pane is active. Max two panes (a single split, one level deep).
  type PaneView = {
    initiativeId: string | null;
    agentId: string | null;
    tab: "context" | "diff" | "tree";
    wantFile: string | null;
    /** Which half of the context view is showing: a document or the memory store. */
    wantPanel: "file" | "memory";
    treeSelectedPath: string | null;
  };
  const newView = (): PaneView => ({
    initiativeId: null,
    agentId: null,
    tab: "context",
    wantFile: null,
    wantPanel: "file",
    treeSelectedPath: null,
  });
  let panes = $state<PaneView[]>([newView()]);
  let activePane = $state(0);
  // Split divider: null = single pane; otherwise the orientation plus the first
  // pane's size as a fraction (0..1) of the content area.
  let split = $state<{ dir: "vertical" | "horizontal"; fraction: number } | null>(null);
  // The pane the sidebar and keyboard actions currently target.
  const active = $derived(panes[activePane] ?? panes[0]);

  let sidebarCollapsed = $state(false);
  let sidebarWidth = $state(300);
  let status = $state<string | null>(null);
  let keymap = $state<Keymap>(DEFAULT_KEYMAP);
  let editing = $state<{ path: string } | null>(null);
  // Bumped whenever the editor writes a file, so views showing that file's
  // contents (the tree's preview) re-read it instead of showing the old text.
  let fileRevision = $state(0);
  // Which pane has keyboard focus. Tab cycles; the terminal only receives keys
  // when "main" so sidebar nav (j/k/arrows) keeps working otherwise.
  let paneFocus = $state<"sidebar" | "main">("sidebar");

  // Element refs for pointer-drag resizing (sidebar width and the split divider).
  let bodyEl = $state<HTMLElement | null>(null);
  let contentEl = $state<HTMLElement | null>(null);

  const base = (p: string) => p.split("/").filter(Boolean).pop() ?? p;

  function termTextarea(): HTMLElement | null {
    // Scope to the active pane so focus lands on the right terminal when split.
    return document.querySelector(`#pane-${activePane} .xterm-helper-textarea`);
  }
  // Null means the view has nothing focusable, so ⇥ stays on the sidebar.
  function mainFocusTarget(): HTMLElement | null {
    if (active.tab === "tree") {
      return document.querySelector(`#pane-${activePane} [data-tree-pane]`);
    }
    return active.agentId ? termTextarea() : null;
  }
  function focusMain() {
    paneFocus = "main";
    requestAnimationFrame(() => mainFocusTarget()?.focus());
  }
  function focusSidebar() {
    paneFocus = "sidebar";
    (document.activeElement as HTMLElement | null)?.blur?.();
  }
  function setTab(tab: PaneView["tab"]) {
    active.tab = tab;
    if (tab === "tree") focusMain();
    else focusSidebar();
  }

  type Modal =
    | { kind: "palette" }
    | { kind: "prompt"; title: string; placeholder?: string; submit: (v: string) => void }
    | { kind: "dirpicker"; submit: (v: string) => void }
    | { kind: "confirm"; message: string; onConfirm: () => void }
    | { kind: "integrations" }
    | { kind: "new_initiative" }
    | { kind: "appearance" }
    | null;
  let modal = $state<Modal>(null);

  const tabs = [
    { id: "context", label: "1 Context" },
    { id: "diff", label: "2 Diff" },
    { id: "tree", label: "3 Tree" },
  ] as const;

  const STATUS_ORDER = ["planning", "ongoing", "done", "archived"];

  const reverse = $derived(buildReverse(keymap));
  const selectedInitiative = $derived(ws.initiatives.find((i) => i.id === active.initiativeId) ?? null);

  let statusTimer: ReturnType<typeof setTimeout> | undefined;
  function toast(msg: string) {
    status = msg;
    clearTimeout(statusTimer);
    statusTimer = setTimeout(() => (status = null), 4000);
  }

  async function load() {
    await ws.load();
    const v = panes[activePane];
    // Only expand on the *first* selection: re-expanding on every refresh would
    // undo a collapse the user just made (r, status cycling, starting an agent…).
    if (!v.initiativeId && ws.initiatives.length > 0) {
      v.initiativeId = ws.initiatives[0].id;
      ws.expand(v.initiativeId);
    }
  }

  // Apply a row's selection WITHOUT touching the cursor — the cursor is owned by
  // workspace.moveCursor. (The mouse-facing select* helpers below also sync the
  // cursor; calling them here would snap it back and break arrow navigation.)
  // Nor does it expand: moving the cursor onto a collapsed node must leave it
  // collapsed, the way any tree behaves. → (expandOrChild) opens it.
  function applyRow(row: Row) {
    const v = panes[activePane];
    switch (row.kind) {
      case "init":
      case "dir":
      case "folder":
        v.initiativeId = row.initId;
        v.agentId = null;
        v.wantFile = null;
        break;
      case "file":
        v.initiativeId = row.initId;
        v.agentId = null;
        v.wantFile = row.name;
        v.wantPanel = "file";
        v.tab = "context";
        break;
      case "memory":
        v.initiativeId = row.initId;
        v.agentId = null;
        v.wantPanel = "memory";
        v.tab = "context";
        break;
      case "agent":
        v.initiativeId = row.initId;
        v.agentId = row.agentId;
        v.wantFile = null;
        v.tab = "context";
        break;
    }
  }

  function moveCursor(delta: number) {
    const row = ws.moveCursor(delta);
    if (row) applyRow(row);
  }

  // Tree convention: close/open the node, else step out to the parent or into
  // the first child. Structural navigation, so not part of the remappable keymap.
  function treeHorizontal(dir: "left" | "right") {
    const row = dir === "left" ? ws.collapseOrParent() : ws.expandOrChild();
    if (row) applyRow(row);
  }

  function selectInitiative(id: string) {
    const v = panes[activePane];
    v.initiativeId = id;
    v.agentId = null;
    v.wantFile = null;
    paneFocus = "sidebar";
    ws.expand(id);
    ws.syncCursor((r) => r.kind === "init" && r.initId === id);
  }

  function openContextFile(initId: string, name: string) {
    const v = panes[activePane];
    v.initiativeId = initId;
    v.agentId = null;
    v.wantFile = name;
    v.wantPanel = "file";
    v.tab = "context";
    paneFocus = "sidebar";
    ws.expand(initId);
    ws.syncCursor((r) => r.kind === "file" && r.initId === initId && r.name === name);
  }

  function openMemory(initId: string) {
    const v = panes[activePane];
    v.initiativeId = initId;
    v.agentId = null;
    v.wantPanel = "memory";
    v.tab = "context";
    paneFocus = "sidebar";
    ws.expand(initId);
    ws.syncCursor((r) => r.kind === "memory" && r.initId === initId);
  }

  function toggleContextFolder(initId: string, path: string) {
    const v = panes[activePane];
    v.initiativeId = initId;
    v.agentId = null;
    paneFocus = "sidebar";
    ws.toggleFolder(initId, path);
    ws.syncCursor((r) => r.kind === "folder" && r.initId === initId && r.path === path);
  }

  function selectAgent(initId: string, agentId: string) {
    const v = panes[activePane];
    v.initiativeId = initId;
    v.agentId = agentId;
    v.wantFile = null;
    v.tab = "context";
    ws.syncCursor((r) => r.kind === "agent" && r.agentId === agentId);
    focusMain(); // explicit click on an agent → interact with its terminal
  }

  function selectDir(initId: string, path: string) {
    const v = panes[activePane];
    v.initiativeId = initId;
    v.agentId = null;
    v.wantFile = null;
    paneFocus = "sidebar";
    ws.syncCursor((r) => r.kind === "dir" && r.initId === initId && r.path === path);
  }

  function promptAddDir() {
    const init = selectedInitiative;
    if (!init) return;
    modal = {
      kind: "dirpicker",
      submit: async (dir) => {
        modal = null;
        try {
          await rpc("add_dir", { initiative_id: init.id, dir });
          await load();
        } catch (e) {
          toast((e as Error).message);
        }
      },
    };
  }

  async function startAgent(adapter: string) {
    if (!selectedInitiative) return toast("Select an initiative first.");
    // Prefer the directory under the cursor (so you can start agents per dir).
    // With the cursor on the initiative itself — or one of its context files —
    // run at the initiative root (its context folder), so the agent can edit
    // initiative-wide files: orchestration.md, context docs, memory, etc.
    // Otherwise fall back to the first project directory; with no directory at
    // all, omit `dir` and the backend runs in the initiative's context folder.
    const row = ws.rows[ws.cursor];
    const atInitRoot = row?.kind === "init" || row?.kind === "file";
    const rootDir = selectedInitiative.context_path ?? null;
    const dir =
      ws.cursorDir ?? (atInitRoot ? rootDir : null) ?? selectedInitiative.dirs[0]?.path ?? null;
    try {
      await rpc("start_agent", {
        initiative_id: selectedInitiative.id,
        adapter,
        ...(dir ? { dir } : {}),
      });
      const where =
        dir && dir === rootDir ? "at initiative root" : dir ? `in ${base(dir)}` : "in scratchpad";
      toast(`Started ${adapter} ${where}`);
      await load();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  async function cycleStatus(delta: number) {
    if (!selectedInitiative) return;
    const i = STATUS_ORDER.indexOf(selectedInitiative.status);
    const next = STATUS_ORDER[(i + delta + STATUS_ORDER.length) % STATUS_ORDER.length];
    try {
      await rpc("set_initiative_status", { initiative_id: selectedInitiative.id, status: next });
      await load();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  function openPrompt(title: string, submit: (v: string) => void, placeholder = "") {
    modal = { kind: "prompt", title, placeholder, submit };
  }

  // Select what was just created or imported: otherwise it lands at the bottom
  // of the sidebar unselected and the natural next key (`a`) would add a
  // directory to whatever was selected before.
  async function revealInitiative(id: string) {
    modal = null;
    await load();
    selectInitiative(id);
  }

  // Skips are the interesting half (a dirty tree, a plain folder), so the toast
  // names the first one rather than just counting successes.
  async function branchInitiative() {
    if (!selectedInitiative) return toast("Select an initiative first.");
    try {
      const res = await rpc<{
        branch: string;
        switched: string[];
        skipped: { dir: string; reason: string }[];
      }>("branch_initiative", { initiative_id: selectedInitiative.id });

      if (!res.switched.length && !res.skipped.length) {
        toast("No directories to branch — add one first.");
      } else if (res.skipped.length) {
        toast(`${res.switched.length} on ${res.branch} · skipped: ${res.skipped[0].reason}`);
      } else {
        toast(`${res.switched.length} director${res.switched.length === 1 ? "y" : "ies"} on ${res.branch}`);
      }
      await load();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  async function createInitiative(name: string) {
    try {
      const created = await rpc<{ id: string }>("create_initiative", { name });
      await revealInitiative(created.id);
    } catch (e) {
      modal = null;
      toast((e as Error).message);
    }
  }

  async function runAction(id: ActionId) {
    if (modal) modal = null;
    switch (id) {
      case "context_mode":
        setTab("context");
        break;
      case "diff_mode":
      case "diff_all_files":
        setTab("diff");
        break;
      case "tree_mode":
        setTab("tree");
        break;
      case "navigate_down":
        moveCursor(1);
        break;
      case "navigate_up":
        moveCursor(-1);
        break;
      case "refresh":
        await load();
        toast("Refreshed");
        break;
      case "toggle_sidebar":
        sidebarCollapsed = !sidebarCollapsed;
        break;
      case "palette":
        modal = { kind: "palette" };
        break;
      case "status_prev":
        await cycleStatus(-1);
        break;
      case "status_next":
        await cycleStatus(1);
        break;
      case "start_agent":
        await startAgent("claude");
        break;
      case "start_terminal":
        await startAgent("terminal");
        break;
      case "start_orchestration":
        if (!selectedInitiative) return toast("Select an initiative first.");
        openPrompt("Orchestration task", async (task) => {
          modal = null;
          try {
            await rpc("start_orchestration", { initiative_id: selectedInitiative!.id, task });
            toast("Orchestration started");
            await load();
          } catch (e) {
            toast((e as Error).message);
          }
        });
        break;
      case "new_initiative":
        modal = { kind: "new_initiative" };
        break;
      case "branch_initiative":
        await branchInitiative();
        break;
      case "add_dir":
        if (!selectedInitiative) return toast("Select an initiative first.");
        promptAddDir();
        break;
      case "delete":
        deleteSelection();
        break;
      case "edit_context":
        if (active.treeSelectedPath) editing = { path: active.treeSelectedPath };
        else toast("Open a file in the Tree view to edit it.");
        break;
      case "appearance":
        modal = { kind: "appearance" };
        break;
      case "quit":
        toast("Quit is handled by the window — nothing to do here.");
        break;
    }
  }

  function deleteSelection() {
    // Native confirm() is a no-op in Tauri's WebKit webview, so use an in-app
    // confirm modal instead.
    if (active.agentId) {
      const id = active.agentId;
      modal = {
        kind: "confirm",
        message: "Stop this agent?",
        onConfirm: async () => {
          modal = null;
          try {
            await rpc("stop_agent", { agent_id: id });
            active.agentId = null;
            await load();
          } catch (e) {
            toast((e as Error).message);
          }
        },
      };
    } else if (selectedInitiative) {
      const init = selectedInitiative;
      // Remember the neighbour now: after the delete it is what the pane should
      // land on, rather than an empty "Select an initiative" screen.
      const others = ws.initiatives.filter((i) => i.id !== init.id);
      const at = ws.initiatives.findIndex((i) => i.id === init.id);
      const next = others[Math.min(at, others.length - 1)] ?? null;
      modal = {
        kind: "confirm",
        message: `Delete initiative "${init.name}"?`,
        onConfirm: async () => {
          modal = null;
          try {
            await rpc("delete_initiative", { initiative_id: init.id });
            active.initiativeId = null;
            active.agentId = null;
            await load();
            if (next) selectInitiative(next.id);
          } catch (e) {
            toast((e as Error).message);
          }
        },
      };
    }
  }

  // ── Panes: split / balance / collapse ─────────────────────────────────────────

  // Toggle a split in the given orientation. With no split, clone the active
  // pane into a second one. Splitting again in the SAME orientation collapses
  // back to the active pane; splitting in the other just re-orients.
  function toggleSplit(dir: "vertical" | "horizontal") {
    if (split) {
      if (split.dir === dir) {
        const keep = panes[activePane] ?? panes[0];
        panes = [keep];
        activePane = 0;
        split = null;
      } else {
        split = { ...split, dir };
      }
      return;
    }
    panes = [panes[activePane], { ...panes[activePane] }];
    activePane = 0;
    split = { dir, fraction: 0.5 };
  }

  function balanceSplit() {
    if (split) split = { ...split, fraction: 0.5 };
  }

  // Close one pane and keep the other; the survivor becomes the single view.
  function closePane(idx: number) {
    if (!split) return;
    panes = [panes[idx === 0 ? 1 : 0]];
    activePane = 0;
    split = null;
  }

  // Shared drag handler for both dividers: the sidebar's (width in px) and the
  // split's (fraction of the content box).
  function startDrag(onMove: (e: PointerEvent) => void) {
    return (e: PointerEvent) => {
      e.preventDefault();
      const up = () => {
        window.removeEventListener("pointermove", onMove);
        window.removeEventListener("pointerup", up);
      };
      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", up);
    };
  }

  const startSplitDrag = startDrag((ev) => {
    if (!split || !contentEl) return;
    const r = contentEl.getBoundingClientRect();
    const f =
      split.dir === "vertical" ? (ev.clientX - r.left) / r.width : (ev.clientY - r.top) / r.height;
    split = { ...split, fraction: Math.min(0.85, Math.max(0.15, f)) };
  });

  const startSidebarDrag = startDrag((ev) => {
    if (!bodyEl) return;
    const r = bodyEl.getBoundingClientRect();
    sidebarWidth = Math.min(520, Math.max(200, ev.clientX - r.left));
  });

  // Window-management shortcuts, handled as raw events rather than through the
  // remappable keymap: ⌘D / ⌘⇧D split, ⌘⌃= balances.
  function paneShortcut(e: KeyboardEvent): (() => void) | null {
    const primary = e.metaKey || e.ctrlKey;
    if (!primary) return null;
    const key = e.key.toLowerCase();
    if (e.metaKey && e.ctrlKey && (key === "=" || key === "+")) return balanceSplit;
    if (key === "d" && !(e.metaKey && e.ctrlKey))
      return () => toggleSplit(e.shiftKey ? "horizontal" : "vertical");
    return null;
  }

  function actionFor(spec: string): ActionId | undefined {
    return (
      reverse[spec] ??
      (spec === "down" ? "navigate_down" : spec === "up" ? "navigate_up" : undefined)
    );
  }

  // Bare keys, bubble phase: they must reach an input or the PTY first.
  function onWindowKeydown(e: KeyboardEvent) {
    if (modal || editing) return; // overlays and the editor own their keys

    const spec = eventToSpec(e);
    if (!spec || spec.includes("+")) return; // modifier combos: see onCaptureKeydown

    const ae = document.activeElement as HTMLElement | null;
    const editable =
      !!ae &&
      (ae.tagName === "INPUT" ||
        ae.tagName === "TEXTAREA" ||
        ae.tagName === "SELECT" ||
        ae.isContentEditable);
    if (editable) return;

    if (spec === "left" || spec === "right") {
      e.preventDefault();
      treeHorizontal(spec);
      return;
    }

    const action = actionFor(spec);
    if (!action) return;
    e.preventDefault();
    runAction(action);
  }

  // Capture phase so xterm can't swallow them: Tab, pane shortcuts, and every
  // modifier combo (⌃P, ⌃B…), which the terminal would otherwise eat.
  function onCaptureKeydown(e: KeyboardEvent) {
    if (modal || editing) return; // overlays install their own capture handlers

    if (e.key === "Tab") {
      e.preventDefault();
      e.stopPropagation();
      if (paneFocus === "main") focusSidebar();
      else if (mainFocusTarget()) focusMain();
      return;
    }

    const pane = paneShortcut(e);
    if (pane) {
      e.preventDefault();
      e.stopPropagation();
      pane();
      return;
    }

    const spec = eventToSpec(e);
    if (!spec || !spec.includes("+")) return;
    const action = actionFor(spec);
    if (!action) return;
    e.preventDefault();
    e.stopPropagation();
    runAction(action);
  }

  const paletteItems = $derived(
    PALETTE_ACTIONS.map((id) => ({ id, label: ACTION_LABELS[id], spec: formatSpec(keymap[id]) })),
  );

  // Contextual shortcut hints for the footer — a quiet, always-on cheat row that
  // doubles as onboarding. Specs come from the live keymap so user overrides show.
  const keyHints = $derived.by<{ spec: string; label: string }[]>(() => {
    const k = (a: ActionId) => formatSpec(keymap[a]);
    const palette = { spec: k("palette"), label: "Commands" };
    // Terminal has the keyboard: only Tab (back) and the palette do anything here.
    if (paneFocus === "main" && active.agentId) {
      return [{ spec: "⇥", label: "Sidebar" }, palette];
    }
    const hints = [{ spec: "↑↓", label: "Move" }];
    if (active.tab === "tree") hints.push({ spec: "⇥", label: "Sidebar" }, { spec: "/", label: "Filter files" });
    else if (active.agentId && active.tab === "context") hints.push({ spec: "⇥", label: "Terminal" });
    if (ws.initiatives.length === 0) hints.push({ spec: k("new_initiative"), label: "New initiative" });
    else hints.push({ spec: k("start_agent"), label: "Start agent" }, { spec: k("add_dir"), label: "Add dir" });
    if (selectedInitiative?.dirs.some((d) => d.git && !d.branch)) {
      hints.push({ spec: k("branch_initiative"), label: "Branch" });
    }
    if (selectedInitiative) hints.push({ spec: "⌘D", label: "Split" });
    if (split) hints.push({ spec: "⌘⌃=", label: "Balance" });
    hints.push(palette);
    return hints;
  });

  $effect(() => {
    window.addEventListener("keydown", onCaptureKeydown, true);
    return () => window.removeEventListener("keydown", onCaptureKeydown, true);
  });

  // Rows come and go under the cursor (an agent stops, an initiative is
  // deleted, another pane starts one). Whenever that leaves the cursor pointing
  // at nothing, re-anchor it inside the initiative this pane is showing, so the
  // sidebar highlight can never disagree with the content — the one thing a
  // multi-agent operator has to be able to trust.
  $effect(() => {
    ws.rows;
    ws.reconcileCursor(active.initiativeId);
  });

  // When the server drops (conn.online flipped false by a failed rpc), poll the
  // cheap health endpoint until it answers, then reload everything. The effect
  // re-runs when conn.online flips back true, which tears the interval down.
  $effect(() => {
    if (conn.online) return;
    // Read once, untracked: this effect must depend on `conn.online` alone, or
    // every agent update would tear the poll down and restart it.
    const before = untrack(() => ws.totalAgents);
    const timer = setInterval(async () => {
      if (!(await health())) return;
      await load();
      // Agents are children of the server process, so a restart kills them.
      // Say so — silently emptying the sidebar looks like nothing happened.
      const lost = before - ws.totalAgents;
      if (lost > 0) toast(`Reconnected — ${lost} running agent${lost === 1 ? "" : "s"} was lost.`);
      else toast("Reconnected to the Codrift server.");
    }, 2000);
    return () => clearInterval(timer);
  });

  onMount(async () => {
    // Appearance first: it decides what everything below renders as.
    void initTheme();
    void initFonts();
    try {
      keymap = await rpc<Keymap>("get_keybindings");
    } catch {
      keymap = DEFAULT_KEYMAP;
    }
    await load();
  });
</script>

<svelte:window onkeydown={onWindowKeydown} />

<div class="flex h-screen flex-col">
  <header class="flex items-center gap-4 border-b border-border bg-surface px-4 py-2">
    <h1 class="text-[13px] font-semibold text-accent">Codrift</h1>
    <nav class="flex gap-1">
      {#each tabs as t (t.id)}
        <button
          class={[
            "rounded-md border px-2.5 py-1 text-xs",
            active.tab === t.id ? "border-border bg-canvas text-fg" : "border-transparent text-muted hover:text-fg",
          ]}
          aria-current={active.tab === t.id ? "page" : undefined}
          onclick={() => setTab(t.id)}
        >
          {t.label}
        </button>
      {/each}
    </nav>
    <!-- Announced, so feedback isn't purely visual. -->
    <span class="text-[11px] text-fg/70" role="status" aria-live="polite">{status ?? ""}</span>
    {#if active.tab === "tree" || (active.agentId && active.tab === "context")}
      <span class="text-[11px] text-fg/70">
        ⇥ focus: {paneFocus === "sidebar" ? "sidebar" : active.tab === "tree" ? "files" : "terminal"}
      </span>
    {/if}
    <button
      class="ml-auto rounded-md p-1 text-muted hover:text-fg"
      title="Appearance — theme &amp; font ({themeState.label})"
      onclick={() => (modal = { kind: "appearance" })}
      aria-label="Appearance"
    >
      <Icon src={Swatch} class="size-4" />
    </button>
    <button
      class="rounded-md p-1 text-muted hover:text-fg"
      title="Integrations"
      onclick={() => (modal = { kind: "integrations" })}
      aria-label="Integrations"
    >
      <Icon src={Link} class="size-4" />
    </button>
    <button
      class="rounded-md p-1 text-muted hover:text-fg"
      title="Command palette ({formatSpec(keymap.palette)})"
      onclick={() => (modal = { kind: "palette" })}
      aria-label="Command palette"
    >
      <Icon src={CommandLine} class="size-4" />
    </button>
    <button class="rounded-md p-1 text-muted hover:text-fg" onclick={load} aria-label="Refresh">
      <Icon src={ArrowPath} class="size-4" />
    </button>
  </header>

  {#if !conn.online}
    <div
      class="flex items-center gap-2 border-b border-red-500/40 bg-red-500/10 px-4 py-1.5 text-[11px] text-red-300"
      role="status"
      aria-live="polite"
    >
      <span class="size-1.5 rounded-full bg-red-400 motion-safe:animate-pulse"></span>
      Lost connection to the Codrift server. Reconnecting…
    </div>
  {/if}

  <div class="flex min-h-0 flex-1" bind:this={bodyEl}>
    {#if sidebarCollapsed}
      <button
        class="flex w-6 shrink-0 items-center justify-center border-r border-border bg-canvas text-muted hover:text-fg"
        title="Expand sidebar ({formatSpec(keymap.toggle_sidebar)})"
        aria-label="Expand sidebar"
        onclick={() => (sidebarCollapsed = false)}
      >›</button>
    {:else}
      <Sidebar
        focused={paneFocus === "sidebar"}
        width={sidebarWidth}
        newInitiativeKey={formatSpec(keymap.new_initiative)}
        collapseKey={formatSpec(keymap.toggle_sidebar)}
        onSelectInitiative={selectInitiative}
        onSelectDir={selectDir}
        onSelectAgent={selectAgent}
        onOpenContextFile={openContextFile}
        onOpenMemory={openMemory}
        onToggleContextFolder={toggleContextFolder}
        onCollapse={() => (sidebarCollapsed = true)}
      />
      <!-- Drag to resize the sidebar. -->
      <div
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize sidebar"
        class="w-1 shrink-0 cursor-col-resize bg-transparent hover:bg-accent/50"
        onpointerdown={startSidebarDrag}
      ></div>
    {/if}

    <!-- Content area: one pane, or two split by a draggable divider. -->
    <div
      bind:this={contentEl}
      class={["flex min-h-0 min-w-0 flex-1", split?.dir === "horizontal" ? "flex-col" : "flex-row"]}
    >
      {@render pane(panes[0], 0)}
      {#if split}
        <div
          role="separator"
          aria-orientation={split.dir === "vertical" ? "vertical" : "horizontal"}
          aria-label="Resize split"
          class={[
            "shrink-0 bg-border hover:bg-accent/60",
            split.dir === "vertical" ? "w-1 cursor-col-resize" : "h-1 cursor-row-resize",
          ]}
          onpointerdown={startSplitDrag}
        ></div>
        {@render pane(panes[1], 1)}
      {/if}
    </div>
  </div>

  {#snippet pane(view: PaneView, idx: number)}
    {@const init = ws.initiatives.find((i) => i.id === view.initiativeId) ?? null}
    <main
      id={"pane-" + idx}
      class={[
        "relative min-h-0 min-w-0 overflow-hidden bg-canvas",
        split && activePane === idx ? "ring-1 ring-inset ring-accent/30" : "",
        view.agentId && view.tab === "context" && paneFocus === "main" && activePane === idx
          ? "ring-1 ring-inset ring-accent/60"
          : "",
      ]}
      style={split ? (idx === 0 ? `flex: 0 0 ${split.fraction * 100}%` : "flex: 1 1 0%") : "flex: 1 1 0%"}
      onpointerdowncapture={() => (activePane = idx)}
    >
      {#if split}
        <button
          class="absolute right-1 top-1 z-10 rounded bg-surface/80 px-1 text-[11px] text-muted hover:text-fg"
          title="Close pane"
          aria-label="Close pane"
          onclick={() => closePane(idx)}
        >✕</button>
      {/if}
      {#if !init}
        {#if !ws.loading && ws.initiatives.length === 0}
          <div class="flex h-full items-center justify-center p-8">
            <div class="max-w-md">
              <h2 class="text-base font-semibold text-fg">Start your first initiative</h2>
              <p class="mt-2 text-[13px] leading-6 text-fg/70">
                An initiative groups the project directories you work across. Codrift runs an AI
                coding agent in each one and streams its terminal live, so you can supervise
                several at once.
              </p>
              <p class="mt-4 flex flex-wrap items-center gap-x-1.5 gap-y-2 text-[13px] text-fg/70">
                <kbd class="rounded border border-border bg-surface px-1.5 py-px text-[11px] text-fg/80">{formatSpec(keymap.new_initiative)}</kbd>
                <span>create one,</span>
                <kbd class="rounded border border-border bg-surface px-1.5 py-px text-[11px] text-fg/80">{formatSpec(keymap.add_dir)}</kbd>
                <span>add a project directory, then</span>
                <kbd class="rounded border border-border bg-surface px-1.5 py-px text-[11px] text-fg/80">{formatSpec(keymap.start_agent)}</kbd>
                <span>to launch an agent.</span>
              </p>
            </div>
          </div>
        {:else}
          <div class="p-6 text-[13px] text-fg/70">Select an initiative.</div>
        {/if}
      {:else if view.tab === "context"}
        {#if view.agentId}
          <!-- No {#key} here: a terminal persists and reconnects when the agent
               changes, avoiding WebGL-context churn that broke the UI. -->
          <AgentTerminal agentId={view.agentId} initiativeId={init.id} />
        {:else}
          <ContextOverview
            initiative={init}
            agents={ws.agentsFor(init.id)}
            wantFile={view.wantFile}
            wantPanel={view.wantPanel}
            onChanged={load}
          />
        {/if}
      {:else if view.tab === "diff"}
        {#key init.id}
          <DiffView initiativeId={init.id} />
        {/key}
      {:else}
        {#key init.id}
          <TreeView
            initiativeId={init.id}
            revision={fileRevision}
            bind:selectedPath={view.treeSelectedPath}
            onLeave={focusSidebar}
            onEdit={(p) => {
              activePane = idx;
              editing = { path: p };
            }}
          />
        {/key}
      {/if}
    </main>
  {/snippet}

  <!-- Always-on contextual cheat row: keyboard-first discoverability without ceremony. -->
  <footer class="flex items-center gap-4 border-t border-border bg-surface px-4 py-1 text-[11px] text-fg/70">
    {#each keyHints as h (h.label)}
      <span class="flex items-center gap-1.5">
        <kbd class="rounded border border-border bg-canvas px-1.5 py-px text-[10px] text-fg/80">{h.spec}</kbd>
        {h.label}
      </span>
    {/each}
  </footer>
</div>

{#if editing && selectedInitiative}
  <Editor
    initiativeId={selectedInitiative.id}
    path={editing.path}
    onSaved={() => fileRevision++}
    onClose={() => (editing = null)}
  />
{/if}

{#if modal?.kind === "appearance"}
  <Appearance onClose={() => (modal = null)} />
{:else if modal?.kind === "integrations"}
  <Integrations onClose={() => (modal = null)} />
{:else if modal?.kind === "new_initiative"}
  <NewInitiative
    onCreate={createInitiative}
    onOpen={revealInitiative}
    onClose={() => (modal = null)}
  />
{:else if modal?.kind === "palette"}
  <CommandPalette items={paletteItems} onRun={runAction} onClose={() => (modal = null)} />
{:else if modal?.kind === "prompt"}
  <Prompt
    title={modal.title}
    placeholder={modal.placeholder}
    onSubmit={modal.submit}
    onClose={() => (modal = null)}
  />
{:else if modal?.kind === "dirpicker"}
  <DirPicker onSubmit={modal.submit} onClose={() => (modal = null)} />
{:else if modal?.kind === "confirm"}
  <Confirm message={modal.message} onConfirm={modal.onConfirm} onClose={() => (modal = null)} />
{/if}
