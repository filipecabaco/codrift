<script lang="ts">
  import { onMount } from "svelte";
  import { Icon } from "@steeze-ui/svelte-icon";
  import { ArrowPath, CommandLine, Link } from "@steeze-ui/heroicons";
  import { rpc, type Initiative, type Agent } from "$lib/api";
  import { conn, health } from "$lib/connection.svelte";
  import {
    ACTION_LABELS,
    DEFAULT_KEYMAP,
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
  import CommandPalette from "$lib/CommandPalette.svelte";
  import Prompt from "$lib/Prompt.svelte";
  import DirPicker from "$lib/DirPicker.svelte";
  import Editor from "$lib/Editor.svelte";
  import Integrations from "$lib/Integrations.svelte";

  let initiatives = $state<Initiative[]>([]);
  let agentsByInit = $state<Record<string, Agent[]>>({});

  // Each pane is an independent viewport onto an initiative — its own agent,
  // tab, open context file and tree selection. The sidebar drives whichever
  // pane is active. Max two panes (a single split, one level deep).
  type PaneView = {
    initiativeId: string | null;
    agentId: string | null;
    tab: "context" | "diff" | "tree";
    wantFile: string | null;
    treeSelectedPath: string | null;
  };
  const newView = (): PaneView => ({
    initiativeId: null,
    agentId: null,
    tab: "context",
    wantFile: null,
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
  let cursor = $state(0);
  let error = $state<string | null>(null);
  let loading = $state(true);
  let status = $state<string | null>(null);
  let keymap = $state<Keymap>(DEFAULT_KEYMAP);
  let editing = $state<{ path: string } | null>(null);
  // Sidebar: which initiatives are expanded and their lazily-loaded context files.
  let expanded = $state<Set<string>>(new Set());
  let contextFilesByInit = $state<Record<string, string[]>>({});
  // Which pane has keyboard focus. Tab cycles; the terminal only receives keys
  // when "main" so sidebar nav (j/k/arrows) keeps working otherwise.
  let paneFocus = $state<"sidebar" | "main">("sidebar");

  // Element refs for pointer-drag resizing (sidebar width and the split divider).
  let bodyEl = $state<HTMLElement | null>(null);
  let contentEl = $state<HTMLElement | null>(null);

  const base = (p: string) => p.split("/").filter(Boolean).pop() ?? p;
  // Backend agent statuses are snake_case ("awaiting_input"); show them spaced.
  const humanStatus = (s: string) => s.replace(/_/g, " ");

  function termTextarea(): HTMLElement | null {
    // Scope to the active pane so focus lands on the right terminal when split.
    return document.querySelector(`#pane-${activePane} .xterm-helper-textarea`);
  }
  function focusMain() {
    paneFocus = "main";
    requestAnimationFrame(() => termTextarea()?.focus());
  }
  function focusSidebar() {
    paneFocus = "sidebar";
    (document.activeElement as HTMLElement | null)?.blur?.();
  }

  type Modal =
    | { kind: "palette" }
    | { kind: "prompt"; title: string; placeholder?: string; submit: (v: string) => void }
    | { kind: "dirpicker"; submit: (v: string) => void }
    | { kind: "confirm"; message: string; onConfirm: () => void }
    | { kind: "integrations" }
    | null;
  let modal = $state<Modal>(null);

  const tabs = [
    { id: "context", label: "1 Context" },
    { id: "diff", label: "2 Diff" },
    { id: "tree", label: "3 Tree" },
  ] as const;

  // Status hues are deliberately off the amber accent (accent = focus/selection,
  // not state): green = running, sky = planning, violet = done, muted = archived.
  const statusDot: Record<string, string> = {
    ongoing: "bg-green-500",
    planning: "bg-sky-500",
    done: "bg-violet-500",
    archived: "bg-muted",
  };
  const STATUS_ORDER = ["planning", "ongoing", "done", "archived"];

  const reverse = $derived(buildReverse(keymap));
  const selectedInitiative = $derived(initiatives.find((i) => i.id === active.initiativeId) ?? null);

  // Flat list of the currently-visible selectable sidebar rows, mirroring the
  // rendered tree, so j/k navigation matches what's on screen.
  type Row =
    | { kind: "init"; initId: string }
    | { kind: "file"; initId: string; name: string }
    | { kind: "dir"; initId: string; path: string }
    | { kind: "agent"; initId: string; agentId: string };

  function agentsForDir(initId: string, path: string): Agent[] {
    return (agentsByInit[initId] ?? []).filter((a) => a.dir === path);
  }

  // Agents whose dir isn't one of the initiative's project dirs (e.g. started in
  // the context folder) — shown directly under the initiative.
  function looseAgents(init: Initiative): Agent[] {
    const dirs = new Set(init.dirs.map((d) => d.path));
    return (agentsByInit[init.id] ?? []).filter((a) => !dirs.has(a.dir));
  }

  const rows = $derived.by<Row[]>(() => {
    const out: Row[] = [];
    for (const i of initiatives) {
      out.push({ kind: "init", initId: i.id });
      if (!expanded.has(i.id)) continue;
      for (const f of contextFilesByInit[i.id] ?? []) out.push({ kind: "file", initId: i.id, name: f });
      for (const d of i.dirs) {
        out.push({ kind: "dir", initId: i.id, path: d.path });
        for (const a of agentsForDir(i.id, d.path)) out.push({ kind: "agent", initId: i.id, agentId: a.id });
      }
      for (const a of looseAgents(i)) out.push({ kind: "agent", initId: i.id, agentId: a.id });
    }
    return out;
  });

  // Stable key per row so the keyboard cursor can be highlighted on ANY row
  // type (init / file / dir / agent), not just the ones with a semantic state.
  function rowKey(r: Row): string {
    switch (r.kind) {
      case "init":
        return `i:${r.initId}`;
      case "file":
        return `f:${r.initId}:${r.name}`;
      case "dir":
        return `d:${r.initId}:${r.path}`;
      case "agent":
        return `a:${r.agentId}`;
    }
  }

  const cursorKey = $derived(rows[cursor] ? rowKey(rows[cursor]) : null);

  // The directory the cursor is "in" — a dir row, or the dir of an agent row —
  // so `s`/`t` start an agent in the highlighted directory.
  const cursorDir = $derived.by<string | null>(() => {
    const r = rows[cursor];
    if (!r) return null;
    if (r.kind === "dir") return r.path;
    if (r.kind === "agent")
      return (agentsByInit[r.initId] ?? []).find((a) => a.id === r.agentId)?.dir ?? null;
    return null;
  });

  let statusTimer: ReturnType<typeof setTimeout> | undefined;
  function toast(msg: string) {
    status = msg;
    clearTimeout(statusTimer);
    statusTimer = setTimeout(() => (status = null), 4000);
  }

  async function load() {
    loading = true;
    error = null;
    try {
      initiatives = await rpc<Initiative[]>("list_initiatives");
      const entries = await Promise.all(
        initiatives.map(
          async (i) =>
            [i.id, await rpc<Agent[]>("get_initiative_agents", { initiative_id: i.id })] as const,
        ),
      );
      agentsByInit = Object.fromEntries(entries);
      const v = panes[activePane];
      if (!v.initiativeId && initiatives.length > 0) v.initiativeId = initiatives[0].id;
      if (v.initiativeId) expand(v.initiativeId);
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  async function ensureContextFiles(id: string) {
    if (contextFilesByInit[id]) return;
    try {
      const res = await rpc<{ files: string[] }>("list_context_files", { initiative_id: id });
      contextFilesByInit = { ...contextFilesByInit, [id]: res.files };
    } catch {
      contextFilesByInit = { ...contextFilesByInit, [id]: [] };
    }
  }

  function expand(id: string) {
    if (!expanded.has(id)) {
      expanded = new Set(expanded).add(id);
      void ensureContextFiles(id);
    }
  }

  function toggleExpand(id: string) {
    if (expanded.has(id)) {
      const next = new Set(expanded);
      next.delete(id);
      expanded = next;
    } else {
      expand(id);
    }
  }

  // Apply a row's selection WITHOUT touching the cursor — moveCursor owns the
  // cursor. (The mouse-facing select* helpers below also syncCursor; calling
  // them here would snap the cursor back and break arrow navigation.)
  function applyRow(row: Row) {
    const v = panes[activePane];
    switch (row.kind) {
      case "init":
      case "dir":
        v.initiativeId = row.initId;
        v.agentId = null;
        v.wantFile = null;
        expand(row.initId);
        break;
      case "file":
        v.initiativeId = row.initId;
        v.agentId = null;
        v.wantFile = row.name;
        v.tab = "context";
        expand(row.initId);
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
    if (rows.length === 0) return;
    cursor = Math.max(0, Math.min(cursor + delta, rows.length - 1));
    applyRow(rows[cursor]);
  }

  function syncCursor(pred: (r: Row) => boolean) {
    const i = rows.findIndex(pred);
    if (i >= 0) cursor = i;
  }

  function selectInitiative(id: string) {
    const v = panes[activePane];
    v.initiativeId = id;
    v.agentId = null;
    v.wantFile = null;
    paneFocus = "sidebar";
    expand(id);
    syncCursor((r) => r.kind === "init" && r.initId === id);
  }

  function openContextFile(initId: string, name: string) {
    const v = panes[activePane];
    v.initiativeId = initId;
    v.agentId = null;
    v.wantFile = name;
    v.tab = "context";
    paneFocus = "sidebar";
    expand(initId);
    syncCursor((r) => r.kind === "file" && r.initId === initId && r.name === name);
  }

  function selectAgent(initId: string, agentId: string) {
    const v = panes[activePane];
    v.initiativeId = initId;
    v.agentId = agentId;
    v.wantFile = null;
    v.tab = "context";
    syncCursor((r) => r.kind === "agent" && r.agentId === agentId);
    focusMain(); // explicit click on an agent → interact with its terminal
  }

  function selectDir(initId: string, path: string) {
    const v = panes[activePane];
    v.initiativeId = initId;
    v.agentId = null;
    v.wantFile = null;
    paneFocus = "sidebar";
    syncCursor((r) => r.kind === "dir" && r.initId === initId && r.path === path);
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
    const row = rows[cursor];
    const atInitRoot = row?.kind === "init" || row?.kind === "file";
    const rootDir = selectedInitiative.context_path ?? null;
    const dir = cursorDir ?? (atInitRoot ? rootDir : null) ?? selectedInitiative.dirs[0]?.path ?? null;
    try {
      await rpc("start_agent", {
        initiative_id: selectedInitiative.id,
        adapter,
        ...(dir ? { dir } : {}),
      });
      const where =
        dir && dir === rootDir
          ? "at initiative root"
          : dir
            ? `in ${base(dir)}`
            : "in scratchpad";
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

  async function runAction(id: ActionId) {
    if (modal) modal = null;
    switch (id) {
      case "context_mode":
        active.tab = "context";
        break;
      case "diff_mode":
        active.tab = "diff";
        break;
      case "tree_mode":
        active.tab = "tree";
        break;
      case "diff_all_files":
        active.tab = "diff";
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
        openPrompt("New initiative name", async (name) => {
          modal = null;
          try {
            await rpc("create_initiative", { name });
            await load();
          } catch (e) {
            toast((e as Error).message);
          }
        });
        break;
      case "add_dir":
        if (!selectedInitiative) return toast("Select an initiative first.");
        promptAddDir();
        break;
      case "delete":
        await deleteSelection();
        break;
      case "quit":
        toast("Quit is handled by the window — nothing to do here.");
        break;
      case "edit_context":
        if (active.treeSelectedPath) editing = { path: active.treeSelectedPath };
        else toast("Open a file in the Tree view to edit it.");
        break;
      case "new_context":
        toast("Context-file management is coming soon.");
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
      modal = {
        kind: "confirm",
        message: `Delete initiative "${init.name}"?`,
        onConfirm: async () => {
          modal = null;
          try {
            await rpc("delete_initiative", { initiative_id: init.id });
            active.initiativeId = null;
            await load();
          } catch (e) {
            toast((e as Error).message);
          }
        },
      };
    }
  }

  // ── Panes: split / balance / collapse ─────────────────────────────────────────

  function focusPane(idx: number) {
    activePane = Math.max(0, Math.min(idx, panes.length - 1));
  }

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
    const keep = panes[idx === 0 ? 1 : 0];
    panes = [keep];
    activePane = 0;
    split = null;
  }

  // Drag the divider between the two panes to resize them (fraction of content).
  function startSplitDrag(e: PointerEvent) {
    if (!split || !contentEl) return;
    e.preventDefault();
    const el = contentEl;
    const move = (ev: PointerEvent) => {
      const r = el.getBoundingClientRect();
      const f =
        split!.dir === "vertical"
          ? (ev.clientX - r.left) / r.width
          : (ev.clientY - r.top) / r.height;
      split = { ...split!, fraction: Math.min(0.85, Math.max(0.15, f)) };
    };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  }

  // Drag the divider between the sidebar and the content to resize the sidebar.
  function startSidebarDrag(e: PointerEvent) {
    if (!bodyEl) return;
    e.preventDefault();
    const el = bodyEl;
    const move = (ev: PointerEvent) => {
      const r = el.getBoundingClientRect();
      sidebarWidth = Math.min(520, Math.max(200, ev.clientX - r.left));
    };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  }

  // Window-management shortcuts, handled as raw events (like Tab focus cycling)
  // rather than through the remappable keymap: ⌘D / ⌘⇧D split, ⌘⌃= balances.
  function paneShortcut(e: KeyboardEvent): (() => void) | null {
    const primary = e.metaKey || e.ctrlKey;
    if (!primary) return null;
    const key = e.key.toLowerCase();
    if (e.metaKey && e.ctrlKey && (key === "=" || key === "+")) return balanceSplit;
    if (key === "d" && !(e.metaKey && e.ctrlKey))
      return () => toggleSplit(e.shiftKey ? "horizontal" : "vertical");
    return null;
  }

  function onWindowKeydown(e: KeyboardEvent) {
    // Confirm modals are handled in the capture phase (onCaptureKeydown) so the
    // agent terminal can't swallow Enter before we see it.
    if (modal?.kind === "confirm") return;
    if (modal || editing) return; // modals / editor handle their own keys

    // Pane shortcuts fire even when the terminal has focus (they're modifier
    // combos), so check them before the keymap path bails on editable targets.
    const pane = paneShortcut(e);
    if (pane) {
      e.preventDefault();
      pane();
      return;
    }

    const spec = eventToSpec(e);
    if (!spec) return;

    // When focus is in the terminal or a form field, only intercept modifier
    // combos so bare keystrokes still reach the PTY / inputs.
    const ae = document.activeElement as HTMLElement | null;
    const editable =
      !!ae &&
      (ae.tagName === "INPUT" ||
        ae.tagName === "TEXTAREA" ||
        ae.tagName === "SELECT" ||
        ae.isContentEditable);

    const action =
      reverse[spec] ??
      (spec === "down" ? "navigate_down" : spec === "up" ? "navigate_up" : undefined);
    if (!action) return;
    if (editable && !spec.includes("+")) return;

    e.preventDefault();
    runAction(action);
  }

  // Capture-phase key handling so xterm can't swallow keys before we act on them.
  // Handles: confirm-modal Enter/Esc, and Tab focus cycling between sidebar/terminal.
  function onCaptureKeydown(e: KeyboardEvent) {
    // Confirm modals: Enter accepts, Esc cancels. Runs ahead of xterm, which
    // otherwise routes Enter (\r) to the PTY and stops propagation.
    if (modal?.kind === "confirm") {
      if (e.key === "Enter") {
        e.preventDefault();
        e.stopPropagation();
        modal.onConfirm();
      } else if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        modal = null;
      }
      return;
    }
    // Tab / Shift+Tab cycle focus between the sidebar and the agent terminal.
    // (Esc is left for the agent — Claude/vim need it.)
    if (e.key !== "Tab" || modal || editing) return;
    e.preventDefault();
    e.stopPropagation();
    if (paneFocus === "main") focusSidebar();
    else if (active.agentId && active.tab === "context") focusMain();
  }

  const paletteItems = $derived(
    (Object.keys(ACTION_LABELS) as ActionId[]).map((id) => ({
      id,
      label: ACTION_LABELS[id],
      spec: formatSpec(keymap[id]),
    })),
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
    if (active.agentId && active.tab === "context") hints.push({ spec: "⇥", label: "Terminal" });
    if (initiatives.length === 0) hints.push({ spec: k("new_initiative"), label: "New initiative" });
    else hints.push({ spec: k("start_agent"), label: "Start agent" }, { spec: k("add_dir"), label: "Add dir" });
    if (selectedInitiative) hints.push({ spec: "⌘D", label: "Split" });
    if (split) hints.push({ spec: "⌘⌃=", label: "Balance" });
    hints.push(palette);
    return hints;
  });

  $effect(() => {
    window.addEventListener("keydown", onCaptureKeydown, true);
    return () => window.removeEventListener("keydown", onCaptureKeydown, true);
  });

  // When the server drops (conn.online flipped false by a failed rpc), poll the
  // cheap health endpoint until it answers, then reload everything. The effect
  // re-runs when conn.online flips back true, which tears the interval down.
  $effect(() => {
    if (conn.online) return;
    const timer = setInterval(async () => {
      if (await health()) await load();
    }, 2000);
    return () => clearInterval(timer);
  });

  onMount(async () => {
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
          onclick={() => (active.tab = t.id)}
        >
          {t.label}
        </button>
      {/each}
    </nav>
    {#if status}
      <span class="text-[11px] text-muted">{status}</span>
    {/if}
    {#if active.agentId && active.tab === "context"}
      <span class="text-[11px] text-muted">⇥ focus: {paneFocus === "main" ? "terminal" : "sidebar"}</span>
    {/if}
    <button
      class="ml-auto rounded-md p-1 text-muted hover:text-fg"
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
      <aside
        class={[
          "shrink-0 overflow-y-auto border-r bg-canvas p-2",
          paneFocus === "sidebar" ? "border-accent/50" : "border-border",
        ]}
        style="width: {sidebarWidth}px"
      >
        <div class="mb-1 flex items-center justify-between pl-1">
          <span class="text-[10px] font-semibold uppercase tracking-wide text-muted">Initiatives</span>
          <button
            class="rounded p-0.5 text-muted hover:text-fg"
            title="Collapse sidebar ({formatSpec(keymap.toggle_sidebar)})"
            aria-label="Collapse sidebar"
            onclick={() => (sidebarCollapsed = true)}
          >‹</button>
        </div>
        {#if loading}
          <p class="p-1.5 text-xs text-muted">Loading…</p>
        {:else if error}
          <p class="p-1.5 text-xs text-red-400">{error}</p>
        {:else if initiatives.length === 0}
          <p class="p-1.5 text-xs text-muted">No initiatives yet. Press {formatSpec(keymap.new_initiative)} to create one.</p>
        {:else}
          {#each initiatives as init (init.id)}
            {@const isOpen = expanded.has(init.id)}
            <div class="mb-1">
              <div class="flex items-center">
                <button
                  class="px-1 text-[10px] text-muted hover:text-fg"
                  onclick={() => toggleExpand(init.id)}
                  aria-label={isOpen ? "Collapse" : "Expand"}
                >
                  {isOpen ? "▾" : "▸"}
                </button>
                <button
                  class={[
                    "flex flex-1 items-center gap-1.5 rounded-md px-1 py-1 text-left text-xs font-semibold",
                    cursorKey === `i:${init.id}` ? "bg-accent/20 text-white" : "text-fg hover:bg-surface",
                  ]}
                  onclick={() => selectInitiative(init.id)}
                >
                  <span class={["size-2 rounded-full", statusDot[init.status] ?? "bg-muted"]}></span>
                  <span class="truncate">{init.name}</span>
                  {#if (agentsByInit[init.id] ?? []).length}
                    <span class="ml-auto text-[11px] text-muted">{(agentsByInit[init.id] ?? []).length}</span>
                  {/if}
                </button>
              </div>

              {#if isOpen}
                <!-- context files -->
                {#each contextFilesByInit[init.id] ?? [] as f (f)}
                  <button
                    class={[
                      "flex w-full items-center gap-1.5 rounded-md py-0.5 pr-1.5 pl-6 text-left text-xs",
                      cursorKey === `f:${init.id}:${f}`
                        ? "bg-accent/20 text-white"
                        : "text-fg/70 hover:bg-surface",
                    ]}
                    onclick={() => openContextFile(init.id, f)}
                  >
                    <span class="text-muted">◈</span>{f}
                  </button>
                {/each}

                <!-- directories, each with its agents -->
                {#each init.dirs as dir (dir.path)}
                  <button
                    class={[
                      "flex w-full items-center gap-1.5 rounded-md py-0.5 pr-1.5 pl-6 text-left text-xs",
                      cursorKey === `d:${init.id}:${dir.path}`
                        ? "bg-accent/20 text-white"
                        : "text-fg/80 hover:bg-surface",
                    ]}
                    onclick={() => selectDir(init.id, dir.path)}
                    title={dir.path}
                  >
                    <span class="text-muted">▸</span><span class="truncate"
                      >{dir.path === init.context_path ? "scratch" : base(dir.path)}</span
                    >
                    {#if dir.worktree_enabled}<span class="rounded border border-border px-1 text-[10px] text-muted">wt</span>{/if}
                  </button>
                  {#each agentsForDir(init.id, dir.path) as agent (agent.id)}
                    <button
                      class={[
                        "flex w-full items-center gap-2 rounded-md py-0.5 pr-1.5 pl-10 text-left text-xs",
                        cursorKey === `a:${agent.id}` ? "bg-accent/20 text-white" : "text-fg/70 hover:bg-surface",
                      ]}
                      onclick={() => selectAgent(init.id, agent.id)}
                    >
                      ◦ {agent.adapter}
                      {#if agent.profile}<span class="rounded border border-accent/40 px-1 text-[10px] text-accent/90">{agent.profile}</span>{/if}
                      <span class="ml-auto text-[11px] text-muted">{humanStatus(agent.status)}</span>
                    </button>
                  {/each}
                {/each}

                <!-- agents not tied to a project dir -->
                {#each looseAgents(init) as agent (agent.id)}
                  <button
                    class={[
                      "flex w-full items-center gap-2 rounded-md py-0.5 pr-1.5 pl-6 text-left text-xs",
                      cursorKey === `a:${agent.id}` ? "bg-accent/20 text-white" : "text-fg/70 hover:bg-surface",
                    ]}
                    onclick={() => selectAgent(init.id, agent.id)}
                  >
                    ◦ {agent.adapter}
                    {#if agent.profile}<span class="rounded border border-accent/40 px-1 text-[10px] text-accent/90">{agent.profile}</span>{/if}
                    <span class="ml-auto text-[11px] text-muted">{agent.status}</span>
                  </button>
                {/each}
              {/if}
            </div>
          {/each}
        {/if}
      </aside>
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
    {@const init = initiatives.find((i) => i.id === view.initiativeId) ?? null}
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
        {#if !loading && initiatives.length === 0}
          <div class="flex h-full items-center justify-center p-8">
            <div class="max-w-md">
              <h2 class="text-base font-semibold text-fg">Start your first initiative</h2>
              <p class="mt-2 text-[13px] leading-6 text-muted">
                An initiative groups the project directories you work across. Codrift runs an AI
                coding agent in each one and streams its terminal live, so you can supervise
                several at once.
              </p>
              <p class="mt-4 flex flex-wrap items-center gap-x-1.5 gap-y-2 text-[13px] text-muted">
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
          <div class="p-6 text-[13px] text-muted">Select an initiative.</div>
        {/if}
      {:else if view.tab === "context"}
        {#if view.agentId}
          <!-- No {#key} here: a terminal persists and reconnects when the agent
               changes, avoiding WebGL-context churn that broke the UI. -->
          <AgentTerminal agentId={view.agentId} initiativeId={init.id} />
        {:else}
          <ContextOverview
            initiative={init}
            agents={agentsByInit[init.id] ?? []}
            wantFile={view.wantFile}
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
            bind:selectedPath={view.treeSelectedPath}
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
  <footer class="flex items-center gap-4 border-t border-border bg-surface px-4 py-1 text-[11px] text-muted">
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
    onClose={() => (editing = null)}
  />
{/if}

{#if modal?.kind === "integrations"}
  <Integrations onClose={() => (modal = null)} />
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
  <div
    class="fixed inset-0 z-50 flex items-start justify-center bg-black/50 pt-[18vh]"
    onclick={() => (modal = null)}
    role="presentation"
  >
    <div
      class="w-[420px] max-w-[90vw] rounded-lg border border-border bg-surface p-4 shadow-2xl"
      onclick={(e) => e.stopPropagation()}
      role="presentation"
    >
      <p class="mb-1 text-[13px] text-fg">{modal.message}</p>
      <p class="mb-4 text-[11px] text-muted">Enter to confirm · Esc to cancel</p>
      <div class="flex justify-end gap-2">
        <button
          class="rounded-md px-3 py-1.5 text-xs text-muted hover:text-fg"
          onclick={() => (modal = null)}
        >
          Cancel
        </button>
        <button
          class="rounded-md bg-red-500/20 px-3 py-1.5 text-xs text-red-300 hover:bg-red-500/30"
          onclick={modal.onConfirm}
        >
          Confirm
        </button>
      </div>
    </div>
  </div>
{/if}
