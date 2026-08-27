<script lang="ts">
  import { onMount, untrack } from "svelte";
  import { Icon } from "@steeze-ui/svelte-icon";
  import { ArrowPath, Cog6Tooth, CommandLine } from "@steeze-ui/heroicons";
  import {
    createScratchpad,
    openUrl,
    promoteInitiative,
    quitApp,
    rpc,
    MENU_EVENT,
    QUIT_REQUESTED,
    REDRAW_TERMINALS,
    type Agent,
    type DirInfo,
    type Initiative,
    type SidebarSort,
  } from "$lib/api";
  import { conn, health } from "$lib/connection.svelte";
  import { onPaneRequest, type PaneRequest } from "$lib/stream";
  import { workspace as ws, needsInput, type Row } from "$lib/workspace.svelte";
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
  import Sidebar, { type SidebarTarget } from "$lib/Sidebar.svelte";
  import ContextMenu, { type MenuEntry, type MenuRequest } from "$lib/ContextMenu.svelte";
  import CommandPalette from "$lib/CommandPalette.svelte";
  import Prompt from "$lib/Prompt.svelte";
  import DirPicker from "$lib/DirPicker.svelte";
  import Confirm from "$lib/Confirm.svelte";
  import Choice, { type ChoiceOption } from "$lib/Choice.svelte";
  import DirPreview from "$lib/DirPreview.svelte";
  import Editor from "$lib/Editor.svelte";
  import NewInitiative from "$lib/NewInitiative.svelte";
  import AgentPicker from "$lib/AgentPicker.svelte";
  import Settings, { type SettingsSection } from "$lib/Settings.svelte";
  import { initTheme } from "$lib/theme.svelte";
  import { initFonts } from "$lib/fonts.svelte";
  import { initTitlebar, overlayed, titlebar } from "$lib/titlebar.svelte";

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
    /**
     * The project directory the sidebar cursor is on, previewed in place of the
     * initiative overview. Set by walking onto a dir row and cleared by landing
     * on anything else, so it always describes the current selection.
     */
    dirPath: string | null;
    /**
     * A freshly split pane asks what it should hold rather than guessing. Any
     * selection — from the chooser or the sidebar — clears it.
     */
    chooser: boolean;
  };
  const newView = (): PaneView => ({
    initiativeId: null,
    agentId: null,
    tab: "context",
    wantFile: null,
    wantPanel: "file",
    treeSelectedPath: null,
    dirPath: null,
    chooser: false,
  });
  let panes = $state<PaneView[]>([newView()]);
  let activePane = $state(0);
  // Split divider: null = single pane; otherwise the orientation plus the first
  // pane's size as a fraction (0..1) of the content area.
  let split = $state<{ dir: "vertical" | "horizontal"; fraction: number } | null>(null);
  // The pane the sidebar and keyboard actions currently target.
  const active = $derived(panes[activePane] ?? panes[0]);

  /**
   * Panes belong to an initiative, not to the window.
   *
   * A split is a statement about one piece of work — "this agent beside that
   * terminal" — and it stopped making sense the moment the sidebar cursor moved
   * to unrelated work. So the whole layout is filed under the initiative it
   * describes: leave an initiative and its layout is put away intact; come back
   * and it is exactly as you left it. An initiative you never split opens as a
   * single pane, and stays that way no matter what the previous one looked like.
   *
   * `layoutInit` names the initiative the live `panes` / `activePane` / `split`
   * currently describe. `layouts` holds every *other* initiative's, so the live
   * three are always the authority for the one on screen — see `paneStrips`,
   * which has to overlay them onto the map to read the truth.
   */
  type Layout = { panes: PaneView[]; activePane: number; split: typeof split };
  let layouts = $state<Record<string, Layout>>({});
  let layoutInit = $state<string | null>(null);

  function useInitiative(id: string | null) {
    if (id === layoutInit) return;
    if (layoutInit) layouts[layoutInit] = { panes, activePane, split };
    layoutInit = id;

    const saved = id ? layouts[id] : null;
    if (saved) {
      panes = saved.panes;
      activePane = saved.activePane;
      split = saved.split;
    } else {
      panes = [{ ...newView(), initiativeId: id }];
      activePane = 0;
      split = null;
    }
  }

  // Every selection path funnels through here: switch to the target's layout
  // first, THEN take the active pane — otherwise the pane we hand back belongs
  // to the initiative we are leaving.
  function viewFor(initId: string): PaneView {
    useInitiative(initId);
    const v = activeView();
    v.initiativeId = initId;
    return v;
  }

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
  // The way out of a terminal, which keeps ⇥ for itself. A modifier combo, so it
  // can't collide with anything the agent or shell binds — and deliberately not
  // an esc combo: releasing the modifier a moment early sent a bare ⎋ straight to
  // the PTY, which coding CLIs read as "interrupt the running command". Comes
  // from the keymap (`focus_sidebar`), so it is overridable like every other key.
  const LEAVE_MAIN = $derived(formatSpec(keymap.focus_left));

  /**
   * One pane, named the way the sidebar names the same thing elsewhere.
   *
   * The strip is a map of the content area, so a chip reading "Pane 2" would
   * send the reader to the screen to find out what it meant — which is the work
   * the strip exists to save.
   */
  type PaneChip = {
    label: string;
    kind: "terminal" | "agent" | "view";
    active: boolean;
    role?: string | null;
  };

  function paneChip(p: PaneView): { label: string; kind: PaneChip["kind"]; role?: string | null } {
    const agent = p.agentId ? ws.agent(p.agentId) : null;
    if (agent) {
      // A terminal is named by where it is, an agent by what it is: two shells
      // in one initiative are told apart by their directory, two Claudes by
      // nothing else the chip has room for.
      if (agent.adapter !== "terminal")
        return { label: agent.adapter, kind: "agent", role: agent.role };
      // A folderless initiative's directory *is* its context folder, whose
      // basename is the 16-character id — a hex blob in the pane strip, where
      // the whole job of the label is to say which pane holds what. The sidebar
      // already calls that directory "scratch"; so does this.
      const init = ws.initiatives.find((i) => i.id === p.initiativeId);
      const label = agent.dir === init?.context_path ? "scratch" : base(agent.dir);
      return { label, kind: "terminal", role: agent.role };
    }
    if (p.chooser) return { label: "Empty", kind: "view" };
    return {
      label: p.tab === "diff" ? "Diff" : p.tab === "tree" ? "Files" : "Context",
      kind: "view",
    };
  }

  /**
   * The pane strip the sidebar draws under each initiative, keyed by id.
   *
   * Only split initiatives get one: with a single pane there is nothing to
   * choose between, and a one-chip strip would be chrome that says nothing. The
   * live `panes`/`activePane`/`split` are layered over `layouts` because the
   * map's entry for the current initiative is a snapshot from the last switch —
   * stale by construction, and the strip has to show what is on screen now.
   */
  const paneStrips = $derived.by<Record<string, PaneChip[]>>(() => {
    const all: Record<string, Layout> = { ...layouts };
    if (layoutInit) all[layoutInit] = { panes, activePane, split };

    const out: Record<string, PaneChip[]> = {};
    for (const [id, l] of Object.entries(all)) {
      if (!l.split || l.panes.length < 2) continue;
      out[id] = l.panes.map((p, i) => ({
        ...paneChip(p),
        active: id === layoutInit && i === l.activePane,
      }));
    }
    return out;
  });

  // Clicking a chip adopts that initiative's layout and lands in the pane. The
  // cursor follows what the pane holds, so the sidebar highlight and the content
  // never disagree — same invariant `reconcileCursor` keeps for the keyboard.
  function selectPane(initId: string, idx: number) {
    useInitiative(initId);
    ws.expand(initId);
    const held = panes[idx]?.agentId;
    if (held) ws.syncCursor((r) => r.kind === "agent" && r.agentId === held);
    else ws.syncCursor((r) => r.kind === "init" && r.initId === initId);
    enterPane(idx);
  }

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
    // A fresh split shows the chooser, and the chooser is the one thing in a new
    // pane you are certain to want next — so it takes the keyboard. Read
    // directly off `panes` rather than through activeView(), which answers the
    // chooser as a side effect of being read.
    const view = panes[activePane];
    if (view?.chooser && !view.agentId) {
      return document.querySelector(`#pane-${activePane} [data-chooser-option]`);
    }
    if (active.tab === "tree") {
      return document.querySelector(`#pane-${activePane} [data-tree-pane]`);
    }
    // A terminal stays mounted (hidden, inert) while another tab is showing, so
    // finding its textarea no longer means the terminal is on screen — the tab
    // decides that, not the query.
    return active.tab === "context" && active.agentId ? termTextarea() : null;
  }
  /**
   * Which panes can hold the keyboard, answered from the view rather than the
   * DOM.
   *
   * Every caller decides this *before* Svelte has re-rendered — a pane that was
   * just split off, or the survivor of a pane that was just closed — so asking
   * the document what `#pane-N` contains answers for whatever was there a
   * moment ago. The view is already correct; `mainFocusTarget` then has
   * `focusMain`'s retry loop to wait for the element to catch up.
   */
  function paneHasFocusable(v: PaneView | undefined): boolean {
    if (!v) return false;
    if (v.chooser && !v.agentId) return true;
    if (v.tab === "tree") return true;
    return v.tab === "context" && !!v.agentId;
  }

  // Retried across a few frames: the target can be one frame short of existing
  // when the pane was just created. Giving up silently is what left focus on
  // <body>, where the terminal's keystrokes ran as global shortcuts instead — so
  // exhausting the retries hands the keyboard back to the sidebar, which is
  // always there.
  function focusMain() {
    paneFocus = "main";
    let tries = 5;
    const attempt = () => {
      const target = mainFocusTarget();
      if (target) target.focus();
      else if (--tries > 0) requestAnimationFrame(attempt);
      else focusSidebar();
    };
    requestAnimationFrame(attempt);
  }
  function focusSidebar() {
    paneFocus = "sidebar";
    (document.activeElement as HTMLElement | null)?.blur?.();
  }

  /**
   * Make `idx` the active pane and put the keyboard in it.
   *
   * A pane showing the initiative overview has nothing to hold a caret. Landing
   * the keyboard on `<body>` there would be worse than not moving it: bare keys
   * would run as global shortcuts while the ring says a pane is active. So the
   * ring moves either way, and the keyboard falls back to the sidebar — always
   * somewhere the user can see it.
   */
  function enterPane(idx: number) {
    activePane = idx;
    if (paneHasFocusable(panes[idx])) focusMain();
    else focusSidebar();
  }

  // Focus has to land somewhere visible: a collapsed sidebar taking the keyboard
  // would hide the cursor behind a 6px strip.
  function leaveToSidebar() {
    sidebarCollapsed = false;
    focusSidebar();
  }

  /**
   * Directional focus across the whole window.
   *
   * The sidebar sits left of the content; a split adds a second pane either
   * beside pane 0 (`dir: "vertical"`, a vertical divider) or below it
   * (`dir: "horizontal"`). Moving past the last thing in a direction does
   * nothing rather than wrapping — in a two-item row a wrap is indistinguishable
   * from not moving, and it would make ⌘← unreliable as "get me out of here",
   * which is the job it inherited from ⌘⎋.
   */
  function moveFocus(dir: "left" | "right" | "up" | "down") {
    const sideBySide = split?.dir === "vertical";
    const stacked = split?.dir === "horizontal";

    if (dir === "left") {
      if (paneFocus !== "main") return;
      if (sideBySide && activePane === 1) enterPane(0);
      else leaveToSidebar();
      return;
    }

    if (dir === "right") {
      if (paneFocus === "sidebar") enterPane(activePane);
      else if (sideBySide && activePane === 0) enterPane(1);
      return;
    }

    // Up and down only mean something when the panes are stacked.
    if (!stacked || paneFocus !== "main") return;
    if (dir === "up" && activePane === 1) enterPane(0);
    if (dir === "down" && activePane === 0) enterPane(1);
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
    | { kind: "confirm"; message: string; confirmLabel?: string; onConfirm: () => void }
    | { kind: "choice"; title: string; description?: string; options: ChoiceOption[] }
    | { kind: "new_initiative" }
    | { kind: "agent_picker" }
    | { kind: "settings"; section: SettingsSection }
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
    // Only expand on the *first* selection: re-expanding on every refresh would
    // undo a collapse the user just made (r, status cycling, starting an agent…).
    // `ordered`, not `initiatives`: opening onto whatever happens to be oldest
    // would land on a scratchpad from last Tuesday as readily as on real work.
    if (!activeView().initiativeId && ws.ordered.length > 0) {
      const first = ws.ordered[0].id;
      viewFor(first);
      ws.expand(first);
    }
  }

  // Apply a row's selection WITHOUT touching the cursor — the cursor is owned by
  // workspace.moveCursor. (The mouse-facing select* helpers below also sync the
  // cursor; calling them here would snap it back and break arrow navigation.)
  // Nor does it expand: moving the cursor onto a collapsed node must leave it
  // collapsed, the way any tree behaves. → (expandOrChild) opens it.
  // The active pane, as every selection path sees it. Reading it answers the
  // chooser a fresh split left there — picking anything at all is an answer.
  function activeView(): PaneView {
    const v = panes[activePane];
    v.chooser = false;
    return v;
  }

  // One agent, one pane. Two panes bound to the same agent mount two xterms over
  // a single PTY — the same stream painted twice, which is what made a split look
  // broken. Whichever pane claims the agent wins; the other falls back to the
  // initiative overview, giving a split "move it here" semantics.
  function claimAgent(paneIndex: number, agentId: string) {
    panes.forEach((p, i) => {
      if (i !== paneIndex && p.agentId === agentId) p.agentId = null;
    });
    panes[paneIndex].agentId = agentId;
  }

  function applyRow(row: Row) {
    const v = viewFor(row.initId);
    v.dirPath = row.kind === "dir" ? row.path : null;
    switch (row.kind) {
      case "init":
      case "dir":
      case "folder":
        v.agentId = null;
        v.wantFile = null;
        break;
      case "file":
        v.agentId = null;
        v.wantFile = row.name;
        v.wantPanel = "file";
        v.tab = "context";
        break;
      case "memory":
        v.agentId = null;
        v.wantPanel = "memory";
        v.tab = "context";
        break;
      case "agent":
        claimAgent(activePane, row.agentId);
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
    const v = viewFor(id);
    v.agentId = null;
    v.wantFile = null;
    v.dirPath = null;
    paneFocus = "sidebar";
    ws.expand(id);
    ws.syncCursor((r) => r.kind === "init" && r.initId === id);
  }

  function openContextFile(initId: string, name: string) {
    const v = viewFor(initId);
    v.agentId = null;
    v.dirPath = null;
    v.wantFile = name;
    v.wantPanel = "file";
    v.tab = "context";
    paneFocus = "sidebar";
    ws.expand(initId);
    ws.syncCursor((r) => r.kind === "file" && r.initId === initId && r.name === name);
  }

  function openMemory(initId: string) {
    const v = viewFor(initId);
    v.agentId = null;
    v.dirPath = null;
    v.wantPanel = "memory";
    v.tab = "context";
    paneFocus = "sidebar";
    ws.expand(initId);
    ws.syncCursor((r) => r.kind === "memory" && r.initId === initId);
  }

  function toggleContextFolder(initId: string, path: string) {
    const v = viewFor(initId);
    v.agentId = null;
    v.dirPath = null;
    paneFocus = "sidebar";
    ws.toggleFolder(initId, path);
    ws.syncCursor((r) => r.kind === "folder" && r.initId === initId && r.path === path);
  }

  function selectAgent(initId: string, agentId: string) {
    const v = viewFor(initId);
    claimAgent(activePane, agentId);
    v.wantFile = null;
    v.dirPath = null;
    v.tab = "context";
    ws.syncCursor((r) => r.kind === "agent" && r.agentId === agentId);
    focusMain(); // explicit click on an agent → interact with its terminal
  }

  function selectDir(initId: string, path: string) {
    const v = viewFor(initId);
    v.agentId = null;
    v.wantFile = null;
    v.dirPath = path;
    paneFocus = "sidebar";
    ws.syncCursor((r) => r.kind === "dir" && r.initId === initId && r.path === path);
  }

  // Adds the directory and reports what actually happened. `add_dir` degrades
  // to a plain entry when the worktree cannot be created (a bare repo, a branch
  // git refuses), and a silent degrade is exactly the case where the user needs
  // telling — they asked for isolation and did not get it.
  async function addDir(initId: string, dir: string, worktree: boolean) {
    const res = await rpc<Initiative>("add_dir", { initiative_id: initId, dir, worktree });
    await load();
    const entry = res.dirs.find((d) => d.path === dir);
    if (worktree && entry && !entry.worktree_enabled) {
      toast("Added, but the worktree could not be created — using the directory itself.");
    } else {
      toast(worktree ? "Added as a worktree." : "Directory added.");
    }
  }

  // Refresh is the "make what I'm looking at correct again" action, so it has to
  // cover the terminals too. They can hold a stale surface that no amount of
  // reloading initiatives will repaint — see AgentTerminal.redraw.
  async function refreshAll() {
    window.dispatchEvent(new CustomEvent(REDRAW_TERMINALS));
    await load();
    toast("Refreshed");
  }

  function openSettings(section: SettingsSection) {
    modal = { kind: "settings", section };
  }

  // Which repository a git action runs in. The cursor's directory when it names
  // one (or the directory of the agent under it), otherwise nothing — the
  // backend then falls back to the initiative's only repo, and refuses to guess
  // when there are several. Always the SOURCE path: the backend resolves it to
  // the worktree, which is where the agent's work actually is.
  function gitTarget(): { initiative_id: string; dir?: string } | null {
    if (!selectedInitiative) {
      toast("Select an initiative first.");
      return null;
    }
    const dir = ws.cursorDir;
    return { initiative_id: selectedInitiative.id, ...(dir ? { dir } : {}) };
  }

  // Git operations are slow enough to look broken without a pending message, and
  // they fail for ordinary reasons (nothing to commit, a conflict) whose text is
  // the useful part — so surface git's own words rather than "failed".
  async function runGit(
    op: "git_fetch" | "git_rebase" | "git_push",
    pending: string,
    describe: ((r: any) => string) | null,
    extra: Record<string, unknown> = {},
  ) {
    const target = gitTarget();
    if (!target) return;
    toast(pending);
    try {
      const result = await rpc<any>(op, { ...target, ...extra });
      await load();
      // A push is the one operation with somewhere to go afterwards: offer the
      // link the forge printed (or one derived from the remote) instead of
      // making the user go find the branch in a browser.
      if (op === "git_push" && result.pr_url) {
        modal = {
          kind: "confirm",
          message: `Pushed ${result.branch}. Open the pull request page?`,
          confirmLabel: "Open PR",
          onConfirm: async () => {
            await rpc("open_url", { url: result.pr_url });
            modal = null;
          },
        };
        return;
      }
      toast(describe ? describe(result) : `Pushed ${result.branch}.`);
    } catch (e) {
      toast((e as Error).message);
    }
  }

  function promptCommit() {
    if (!gitTarget()) return;
    openPrompt("Commit message", async (message) => {
      modal = null;
      const target = gitTarget();
      if (!target) return;
      try {
        const r = await rpc<any>("git_commit", { ...target, message });
        await load();
        toast(`Committed ${r.sha} on ${r.branch}.`);
      } catch (e) {
        toast((e as Error).message);
      }
    });
  }

  function promptAddDir() {
    const init = selectedInitiative;
    if (!init) return;
    modal = {
      kind: "dirpicker",
      submit: async (dir) => {
        modal = null;
        let info: DirInfo;
        try {
          info = await rpc<DirInfo>("inspect_dir", { path: dir });
        } catch (e) {
          toast((e as Error).message);
          return;
        }

        // A plain folder has nothing to isolate, so there is nothing to ask.
        // Only a repo root gets the question — `Worktree.ensure` needs a `.git`
        // in the directory itself, so offering it deeper down would just fail.
        if (!info.git_root) {
          try {
            await addDir(init.id, info.path, false);
          } catch (e) {
            toast((e as Error).message);
          }
          return;
        }

        modal = {
          kind: "choice",
          title: `${base(info.path)} is a git repository`,
          description:
            "A worktree gives this initiative its own checkout on its own branch, so agents working here can't disturb whatever else you have going on in that repo.",
          options: [
            {
              label: "Add as a worktree",
              hint: "Separate checkout on a codrift/… branch. Your existing working tree is untouched.",
              run: async () => {
                await addDir(init.id, info.path, true);
                modal = null;
              },
            },
            {
              label: "Add the directory itself",
              hint: "Agents work in the repo as it stands, on whatever branch it is on.",
              run: async () => {
                await addDir(init.id, info.path, false);
                modal = null;
              },
            },
          ],
        };
      },
    };
  }

  // Returns the started agent so a caller can bind it to a specific pane (the
  // split chooser does); plain keyboard starts ignore it and just reload.
  async function startAgent(choice?: string): Promise<Agent | null> {
    if (!selectedInitiative) {
      toast("Select an initiative first.");
      return null;
    }
    const agent = choice ?? ws.agentChoiceFor(selectedInitiative);
    const profile = ws.profiles.find((p) => p.name === agent);
    const launch = profile
      ? { adapter: profile.adapter ?? "claude", profile: profile.name }
      : { adapter: agent };
    // Prefer the directory under the cursor (so you can start agents per dir).
    // With the cursor on the initiative itself — or one of its context files —
    // run at the initiative root (its context folder), so the agent can edit
    // initiative-wide files: orchestration.md, context docs, memory, etc.
    // Otherwise fall back to the first project directory; with no directory at
    // all, omit `dir` and the backend runs in the initiative's context folder.
    const row = ws.rows[ws.cursor];
    // "Cursor on the initiative row → run at its root" exists so an agent can
    // edit initiative-wide files. A scratchpad has none worth editing — its
    // paperwork is hidden and nobody adds to it — so when one was opened
    // against a directory, that directory wins even from the scratchpad's own
    // row. Otherwise seeding the directory would achieve nothing: every agent
    // would still start in the empty context folder.
    const atInitRoot =
      !selectedInitiative.scratch && (row?.kind === "init" || row?.kind === "file");
    const rootDir = selectedInitiative.context_path ?? null;
    const dir =
      ws.cursorDir ?? (atInitRoot ? rootDir : null) ?? selectedInitiative.dirs[0]?.path ?? null;
    try {
      const started = await rpc<Agent>("start_agent", {
        initiative_id: selectedInitiative.id,
        ...launch,
        ...(dir ? { dir } : {}),
      });
      const where =
        dir && dir === rootDir
          ? "at initiative root"
          : dir
            ? `in ${base(dir)}`
            : "in the initiative folder";
      toast(`Started ${agent} ${where}`);
      await load();
      return started;
    } catch (e) {
      toast((e as Error).message);
      return null;
    }
  }

  type ChooserKind = "agent" | "terminal" | "file";

  /**
   * What a fresh split can be filled with, in the order it renders.
   *
   * One list feeds both the buttons and the number keys, so the digit printed on
   * an option and the digit that presses it are the same index and cannot drift
   * apart when an option is added or reordered.
   */
  function chooserOptions(
    init: Initiative,
  ): { kind: ChooserKind; title: string; detail: string }[] {
    return [
      {
        kind: "agent",
        // Names the agent that will actually launch (the initiative's choice,
        // else default_agent, else claude) rather than a generic "Start an
        // agent" — a profile like claude-work reads here too.
        title: `Start ${ws.agentChoiceFor(init)}`,
        detail: `This initiative's agent, in ${init.dirs[0] ? base(init.dirs[0].path) : "its own folder"}`,
      },
      {
        kind: "terminal",
        title: "Open a terminal",
        detail: "A plain shell in the same directory",
      },
      {
        kind: "file",
        title: "Open a file",
        detail: "Browse this initiative's files",
      },
    ];
  }

  // True when the active pane is still asking what goes in it, so the number keys
  // should answer that question rather than switch a view mode.
  const choosing = $derived(active.chooser && !active.agentId && !!selectedInitiative);

  // ↑/↓ inside the chooser, kept off the window handlers that would otherwise
  // read them as sidebar navigation. Complements the number keys rather than
  // replacing them: the digits are the fast path once you know the list, the
  // arrows are what you reach for the first time. Enter and Space need no help
  // — these are buttons, and the browser already activates them.
  function chooserKeys(e: KeyboardEvent) {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    const options = [
      ...document.querySelectorAll<HTMLElement>(`#pane-${activePane} [data-chooser-option]`),
    ];
    if (options.length === 0) return;
    e.preventDefault();
    e.stopPropagation();
    const at = options.indexOf(document.activeElement as HTMLElement);
    const step = e.key === "ArrowDown" ? 1 : -1;
    // Clamped rather than wrapped: three options are few enough that a wrap
    // reads as "nothing happened" when you are already at the end.
    options[Math.min(options.length - 1, Math.max(0, at + step))]?.focus();
  }

  // Answers the chooser a fresh split put in pane `idx`.
  async function choosePaneContent(idx: number, kind: ChooserKind) {
    const view = panes[idx];
    view.chooser = false;
    if (kind === "file") {
      view.tab = "tree";
      focusMain();
      return;
    }
    const started = await startAgent(kind === "terminal" ? "terminal" : undefined);
    // A failed start already toasted; leave the pane on its overview rather than
    // binding it to nothing.
    if (started) {
      claimAgent(idx, started.id);
      focusMain();
    }
  }

  /**
   * Put `agentId` in a pane and hand it the keyboard, because an agent asked us
   * to — see `open_terminal` / `focus_agent` in the MCP server.
   *
   * This is the one place the UI moves focus on someone else's behalf, so it
   * tries hard not to destroy what the user was doing: it never displaces the
   * pane they are sitting in. With a single pane it splits and lands in the new
   * one; already split, it takes the pane the user isn't in. A pane that already
   * holds this agent is simply re-entered, so an agent that asks twice doesn't
   * accumulate splits.
   *
   * The reason is toasted rather than shown in a dialog on purpose: the point is
   * to arrive ready to type, and a dialog would just be one more thing to
   * dismiss before the keyboard is usable.
   */
  function openAgentPane({ agentId, initiativeId, reason }: PaneRequest) {
    // The agent's initiative owns the layout this pane goes into, so adopt it
    // before measuring: a split opened against the wrong layout would strand
    // the terminal behind whatever the user next selects.
    useInitiative(initiativeId);
    let idx = panes.findIndex((p) => p.agentId === agentId);

    // A pane holding nothing is not worth protecting. Without this, an
    // initiative the user has never opened acquires a split with a dead half the
    // first time one of its agents asks for them.
    const here = panes[activePane];
    if (idx === -1 && !split && !here.agentId && !here.wantFile && here.tab === "context") {
      idx = activePane;
    }

    if (idx === -1 && !split) {
      panes = [panes[activePane], { ...newView(), initiativeId }];
      split = { dir: "vertical", fraction: 0.5 };
      idx = 1;
    } else if (idx === -1) {
      idx = activePane === 0 ? 1 : 0;
    }

    const v = panes[idx];
    v.initiativeId = initiativeId;
    v.wantFile = null;
    v.wantPanel = "file";
    v.chooser = false;
    v.tab = "context";
    claimAgent(idx, agentId);

    // Expand first: syncCursor can only land on a row that exists, and the
    // agent's row is a child of its initiative.
    ws.expand(initiativeId);
    ws.syncCursor((r) => r.kind === "agent" && r.agentId === agentId);
    enterPane(idx);

    toast(reason ? `Agent needs you: ${reason}` : "An agent opened a terminal for you.");
  }

  // Opens a terminal in the initiative and types the setup commands into it.
  //
  // Deliberately a visible terminal rather than a silent shell-out: `npx skills
  // add` asks which agents to install for, and `codrift mcp install` reports
  // per-CLI results worth reading. Running it where the user can answer and see
  // the output is the point — they just don't have to leave the app to do it.
  const SETUP_COMMAND = "codrift mcp install && npx skills add filipecabaco/codrift";

  async function runSetup() {
    if (!selectedInitiative) return toast("Select an initiative first.");
    const dir =
      ws.cursorDir ?? selectedInitiative.context_path ?? selectedInitiative.dirs[0]?.path ?? null;
    try {
      const agent = await rpc<Agent>("start_agent", {
        initiative_id: selectedInitiative.id,
        adapter: "terminal",
        ...(dir ? { dir } : {}),
      });
      await load();
      claimAgent(activePane, agent.id);
      focusMain();
      await rpc("send_to_agent", { agent_id: agent.id, input: SETUP_COMMAND });
      toast("Running setup — answer the prompts in the terminal");
    } catch (e) {
      toast((e as Error).message);
    }
  }

  function confirmQuit() {
    const running = Object.values(ws.agentsByInit).reduce((n, list) => n + list.length, 0);
    modal = {
      kind: "confirm",
      message: running
        ? `Quit Codrift? ${running} agent${running === 1 ? "" : "s"} still running.`
        : "Quit Codrift?",
      confirmLabel: "Quit",
      // Not closed here on purpose: if quitting fails the app is still up, and
      // the dialog is the only place that failure can be reported.
      onConfirm: () => quitApp(),
    };
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

  /**
   * Open a scratchpad and land in it, ready to work.
   *
   * The whole value is that it costs one keystroke and no decisions — no name,
   * no directory, no dialog — so this deliberately does not stop to ask
   * anything. The pane it lands on is the chooser, and the chooser already has
   * the keyboard — so "scratchpad running an agent" is the shortcut and ⏎.
   */
  async function newScratchpad() {
    try {
      // Read the cursor's directory BEFORE anything moves: creating the
      // scratchpad reloads the workspace and selecting it moves the cursor into
      // it, so by the time the response lands there is no "where I was" left to
      // ask about.
      const created = await createScratchpad(ws.cursorDir ?? undefined);
      await load();
      selectInitiative(created.id);
      // Set on `panes` directly: every select* helper routes through
      // activeView(), which answers the chooser as a side effect of reading it.
      const v = panes[activePane];
      v.agentId = null;
      v.wantFile = null;
      v.tab = "context";
      v.chooser = true;
      focusMain();
      toast(`Opened ${created.name}`);
    } catch (e) {
      toast((e as Error).message);
    }
  }

  /**
   * Rank a scratchpad up into a real initiative.
   *
   * A rename and a flag, nothing more: the context folder, the memory store and
   * every running agent stay exactly where they are. That is the point — you
   * find out a scratch session was real work halfway through it, and the
   * promotion must not be a reason to start over.
   */
  function promoteScratchpad(id?: string) {
    const init = id ? ws.initiatives.find((i) => i.id === id) : selectedInitiative;
    if (!init) return toast("Select a scratchpad first.");
    if (!init.scratch) return toast(`"${init.name}" is already an initiative.`);
    openPrompt(
      "Name this initiative",
      async (name) => {
        modal = null;
        try {
          await promoteInitiative(init.id, name);
          await load();
          selectInitiative(init.id);
          toast(`Ranked up to "${name}"`);
        } catch (e) {
          toast((e as Error).message);
        }
      },
      "e.g. Parser rewrite",
    );
  }

  async function createInitiative(name: string, agent: string) {
    try {
      const created = await rpc<{ id: string }>("create_initiative", { name, agent });
      await ws.refreshSettings();
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
        await refreshAll();
        break;
      case "toggle_sidebar":
        sidebarCollapsed = !sidebarCollapsed;
        break;
      case "sort_created":
      case "sort_recent":
      case "sort_name":
      case "sort_status":
        // The action id carries the ordering, so there is no table to keep in
        // step with the ids — `sort_name` can only ever mean "name".
        await ws.setSort(id.slice("sort_".length) as SidebarSort);
        toast(`Initiatives sorted by ${id.slice("sort_".length)}`);
        break;
      case "focus_left":
        moveFocus("left");
        break;
      case "focus_right":
        moveFocus("right");
        break;
      case "focus_up":
        moveFocus("up");
        break;
      case "focus_down":
        moveFocus("down");
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
        await startAgent();
        break;
      case "start_terminal":
        await startAgent("terminal");
        break;
      case "setup":
        await runSetup();
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
      case "new_scratchpad":
        await newScratchpad();
        break;
      case "promote_initiative":
        promoteScratchpad();
        break;
      case "branch_initiative":
        await branchInitiative();
        break;
      case "add_dir":
        if (!selectedInitiative) return toast("Select an initiative first.");
        promptAddDir();
        break;
      case "git_fetch":
        await runGit("git_fetch", "Fetching…", (r) =>
          r.changed ? "Fetched." : "Already up to date.",
        );
        break;
      case "git_rebase":
        await runGit("git_rebase", "Rebasing…", (r) => `Rebased onto ${r.onto}.`);
        break;
      case "git_commit":
        promptCommit();
        break;
      case "git_push":
        await runGit("git_push", "Pushing…", null);
        break;
      case "delete":
        deleteSelection();
        break;
      case "edit_context":
        if (active.treeSelectedPath) editing = { path: active.treeSelectedPath };
        else toast("Open a file in the Tree view to edit it.");
        break;
      case "settings":
        openSettings("general");
        break;
      case "appearance":
        openSettings("appearance");
        break;
      case "agent_profiles":
        openSettings("profiles");
        break;
      case "initiative_agent":
        if (!selectedInitiative) return toast("Select an initiative first.");
        modal = { kind: "agent_picker" };
        break;
      case "quit":
        confirmQuit();
        break;
    }
  }

  // ── Right-click menus ──────────────────────────────────────────────────────

  let contextMenu = $state<MenuRequest | null>(null);

  const separator = { kind: "separator" } as const;

  // Right-click *selects* first. Every command below reads the selection (which
  // directory an agent starts in, which initiative gets the status change), so a
  // menu that left the cursor where it was would quietly act on the wrong row.
  function openSidebarMenu(event: MouseEvent, target: SidebarTarget) {
    event.preventDefault();
    selectForMenu(target);

    const entries = menuFor(target);
    if (!entries.length) return;

    contextMenu = { x: event.clientX, y: event.clientY, label: menuLabel(target), entries };
  }

  function selectForMenu(target: SidebarTarget) {
    switch (target.kind) {
      case "initiative":
        selectInitiative(target.initId);
        break;
      case "dir":
        selectDir(target.initId, target.path);
        break;
      case "agent":
        selectAgent(target.initId, target.agentId);
        break;
      case "file":
        if (target.isFile) openContextFile(target.initId, target.path);
        else selectInitiative(target.initId);
        break;
      case "memory":
        openMemory(target.initId);
        break;
    }
  }

  function menuLabel(target: SidebarTarget): string {
    switch (target.kind) {
      case "initiative":
        return "Initiative actions";
      case "dir":
        return "Directory actions";
      case "agent":
        return "Agent actions";
      case "file":
        return "File actions";
      case "memory":
        return "Memory actions";
    }
  }

  function menuFor(target: SidebarTarget): MenuEntry[] {
    switch (target.kind) {
      case "initiative":
        return initiativeMenu(target.initId);
      case "dir":
        return dirMenu(target.initId, target.path);
      case "agent":
        return agentMenu(target.agentId);
      case "file":
        return fileMenu(target.path, target.isFile);
      case "memory":
        return [{ label: "Open Memory", run: () => openMemory(target.initId) }];
    }
  }

  const k = (action: ActionId) => formatSpec(keymap[action]);

  function initiativeMenu(initId: string): MenuEntry[] {
    // `ws.ordered` spans both lists; `ws.initiatives` alone would return nothing
    // for a scratchpad row, which renders through the same snippet.
    const init = ws.ordered.find((i) => i.id === initId);
    if (!init) return [];

    const imported = !!init.integration;
    const nextStatus = STATUS_ORDER[(STATUS_ORDER.indexOf(init.status) + 1) % STATUS_ORDER.length];

    return [
      { label: "Start Agent", hint: k("start_agent"), run: () => void startAgent() },
      { label: "Open Terminal", hint: k("start_terminal"), run: () => void startAgent("terminal") },
      {
        label: "Start Orchestration…",
        hint: k("start_orchestration"),
        run: () => void runAction("start_orchestration"),
      },
      separator,
      { label: "Add Directory…", hint: k("add_dir"), run: promptAddDir },
      {
        label: "Branch Git Directories",
        hint: k("branch_initiative"),
        disabled: !init.dirs.length,
        run: () => void branchInitiative(),
      },
      {
        // Only imports have a remote to re-read; offering it on a hand-made
        // initiative would be a button whose only outcome is an error toast.
        label: "Sync Imported Context",
        disabled: !imported,
        run: () => void syncImportedContext(),
      },
      separator,
      { label: `Mark as ${nextStatus}`, hint: k("status_next"), run: () => void cycleStatus(1) },
      { label: "Roll Back Status", hint: k("status_prev"), run: () => void cycleStatus(-1) },
      separator,
      // A scratchpad is the one row where the destructive command is not a
      // deletion of anything the user named, so it is worded — and paired —
      // differently: promoting is the other way out of a scratchpad.
      ...(init.scratch
        ? [
            {
              label: "Promote to Initiative…",
              hint: k("promote_initiative"),
              run: () => promoteScratchpad(init.id),
            },
            separator,
          ]
        : []),
      {
        label: init.scratch ? "Discard Scratchpad…" : "Delete Initiative…",
        danger: true,
        run: () => confirmDeleteInitiative(init),
      },
    ];
  }

  function dirMenu(initId: string, path: string): MenuEntry[] {
    const dir = ws.ordered.find((i) => i.id === initId)?.dirs.find((d) => d.path === path);
    if (!dir) return [];

    return [
      { label: "Start Agent Here", hint: k("start_agent"), run: () => void startAgent() },
      {
        label: "Open Terminal Here",
        hint: k("start_terminal"),
        run: () => void startAgent("terminal"),
      },
      separator,
      {
        // A worktree only makes sense for a repo, and the label has to say which
        // way the toggle goes — "Worktree" alone reads as a state, not a command.
        label: dir.worktree_enabled ? "Stop Using Worktree" : "Work in a Git Worktree",
        disabled: !dir.git,
        hint: dir.git ? undefined : "not a repo",
        run: () => void toggleWorktree(initId, path),
      },
      separator,
      { label: "Copy Path", run: () => void copyText(path) },
    ];
  }

  function agentMenu(agentId: string): MenuEntry[] {
    const agent = ws.agent(agentId);
    if (!agent) return [];
    const isTerminal = agent.adapter === "terminal";

    return [
      {
        label: "Open in Pane",
        run: () => void rpc("focus_agent", { agent_id: agentId }).catch(() => {}),
      },
      separator,
      { label: "Copy Working Directory", disabled: !agent.dir, run: () => void copyText(agent.dir) },
      separator,
      {
        label: isTerminal ? "Close Terminal…" : "Stop Agent…",
        danger: true,
        run: () => confirmStopAgent(agentId),
      },
    ];
  }

  function fileMenu(path: string, isFile: boolean): MenuEntry[] {
    if (!isFile) return [{ label: "Copy Path", run: () => void copyText(path) }];

    return [
      { label: "Edit", hint: k("edit_context"), run: () => (editing = { path }) },
      separator,
      { label: "Copy Path", run: () => void copyText(path) },
    ];
  }

  function openTreeMenu(event: MouseEvent, path: string, isFile: boolean) {
    event.preventDefault();
    contextMenu = {
      x: event.clientX,
      y: event.clientY,
      label: isFile ? "File actions" : "Folder actions",
      entries: fileMenu(path, isFile),
    };
  }

  async function toggleWorktree(initId: string, dir: string) {
    try {
      await rpc("toggle_dir_branch", { initiative_id: initId, dir });
      await load();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  // The Tauri webview only grants clipboard writes from a user gesture, which a
  // menu click is — but it can still be refused, and a Copy that silently does
  // nothing is worse than one that says it failed.
  async function copyText(text: string) {
    try {
      await navigator.clipboard.writeText(text);
      toast("Copied");
    } catch {
      toast("Couldn't copy to the clipboard.");
    }
  }

  // ── Native menu ────────────────────────────────────────────────────────────

  const DOCS_URL = "https://codrift.app";
  const ISSUES_URL = "https://github.com/filipecabaco/codrift/issues/new";

  // Commands the menu offers that are not keymap actions: window management and
  // the two panels that have never had a binding. Keeping them out of ActionId
  // is deliberate — that type mirrors `Codrift.Config.Keybindings`, and inventing
  // ids there would put the desktop menu and the TUI's keymap out of sync.
  const MENU_ONLY: Record<string, () => void | Promise<void>> = {
    integrations: () => openSettings("integrations"),
    sync_context: () => syncImportedContext(),
    focus_next_waiting: () => focusNextWaiting(),
    split_vertical: () => toggleSplit("vertical"),
    split_horizontal: () => toggleSplit("horizontal"),
    balance_split: () => balanceSplit(),
    close_pane: () => closePane(activePane),
    help_docs: () => void openUrl(DOCS_URL),
    help_keys: () => void (modal = { kind: "palette" }),
    help_issue: () => void openUrl(ISSUES_URL),
  };

  function runMenuCommand(id: string) {
    const menuOnly = MENU_ONLY[id];
    // Anything not listed above is a keymap action of the same name, so the menu
    // item and the key binding run literally the same code.
    if (menuOnly) void menuOnly();
    else void runAction(id as ActionId);
  }

  // Re-pulls the initiative's imported issue/PR body from the service it came
  // from. Only initiatives created by an import have anything to sync, and the
  // backend says so rather than failing silently.
  async function syncImportedContext() {
    if (!selectedInitiative) return toast("Select an initiative first.");
    try {
      const res = await rpc<{ service: string }>("sync_initiative_context", {
        initiative_id: selectedInitiative.id,
      });
      toast(`Synced from ${res.service}`);
      await load();
    } catch (e) {
      toast((e as Error).message);
    }
  }

  // Jump to the next agent that is blocked on a human, wrapping around from the
  // one in view. With several initiatives running, finding the one that stopped
  // to ask a question is otherwise a manual scan of the whole sidebar.
  function focusNextWaiting() {
    const waiting = ws.initiatives.flatMap((init) =>
      ws.agentsFor(init.id).filter((a) => needsInput(a.status)).map((a) => ({ init, agent: a })),
    );

    if (!waiting.length) return toast("No agent is waiting on you.");

    const current = waiting.findIndex(({ agent }) => agent.id === active.agentId);
    const next = waiting[(current + 1) % waiting.length];

    ws.expanded.add(next.init.id);
    selectInitiative(next.init.id);
    selectAgent(next.init.id, next.agent.id);
  }

  // What `d` acts on is the row under the sidebar cursor, NOT whatever the pane
  // happens to be showing. The cursor is what the user is pointing at, and one
  // key that always meant "delete initiative" made every other row look as if it
  // had no delete at all — worse, it offered to delete the whole initiative when
  // the user was pointing at a single directory.
  //
  // Cursor and pane can never disagree about which initiative is in play
  // (applyRow/select* route every move through viewFor), so reading the row is
  // enough to know both the target and the initiative it belongs to.
  //
  // Native confirm() is a no-op in Tauri's WebKit webview, so the handlers below
  // use the in-app confirm modal. They deliberately do NOT catch: Confirm keeps
  // itself open and shows the error. Closing the dialog is the *success* path,
  // so a failed delete can never look like it silently worked.
  function deleteSelection() {
    const row = ws.cursorRow;
    switch (row?.kind) {
      case "agent":
        return confirmStopAgent(row.agentId);
      case "dir":
        return confirmRemoveDir(row.initId, row.path);
      case "init": {
        const init = ws.initiatives.find((i) => i.id === row.initId);
        return init ? confirmDeleteInitiative(init) : undefined;
      }
      case "file":
      case "folder":
        // Context documents are edited in place; there is no delete endpoint for
        // them, and silently deleting the initiative instead is how this key
        // earned its reputation.
        return toast("Context files can't be deleted from here.");
      case "memory":
        return toast("Delete memory entries from the memory view.");
      default:
        // Nothing selected: say so rather than swallowing the keypress, which
        // read as "delete is broken".
        toast("Select an initiative, directory or agent first.");
    }
  }

  function confirmRemoveDir(initId: string, path: string) {
    const init = ws.initiatives.find((i) => i.id === initId);
    const entry = init?.dirs.find((d) => d.path === path);
    if (!init || !entry) return;
    // Un-linking a directory leaves the user's repository exactly where it is —
    // except for a worktree, which is Codrift's own checkout and goes with it.
    // `git worktree remove --force` takes uncommitted work in it too, so that
    // has to be said before the key is pressed, not discovered afterwards.
    const consequence = entry.worktree_path
      ? "Its worktree is deleted, including any uncommitted changes in it. The original repository is untouched."
      : "The folder itself is left on disk.";
    // Agents launched in it keep running; they just lose the row they nested
    // under and move up to the initiative.
    const running = ws.agentsForDir(initId, path).length;
    const agents = running
      ? ` ${running} agent${running > 1 ? "s" : ""} running in it will keep running.`
      : "";
    modal = {
      kind: "confirm",
      message: `Remove "${path}" from "${init.name}"? ${consequence}${agents}`,
      confirmLabel: "Remove directory",
      onConfirm: async () => {
        await rpc("remove_dir", { initiative_id: initId, dir: path });
        await load();
        modal = null;
        // Its row is gone; land on the initiative that held it rather than
        // leaving the cursor to be re-anchored from nowhere.
        ws.syncCursor((r) => r.kind === "init" && r.initId === initId);
      },
    };
  }

  function confirmStopAgent(id: string) {
    // The terminal adapter is a raw shell, not an agent — calling it one in
    // the one dialog that closes it reads as if it were killing a coding run.
    const isTerminal = ws.agent(id)?.adapter === "terminal";
    modal = {
      kind: "confirm",
      message: isTerminal ? "Close this terminal?" : "Stop this agent?",
      confirmLabel: isTerminal ? "Close terminal" : "Stop agent",
      onConfirm: async () => {
        await rpc("stop_agent", { agent_id: id });
        // Guarded because the menu — and now the sidebar cursor — can stop an
        // agent that is not the one in the active pane, and clearing that pane
        // would blank an unrelated terminal. Clear whichever pane holds it.
        for (const p of panes) if (p.agentId === id) p.agentId = null;
        await load();
        modal = null;
      },
    };
  }

  function confirmDeleteInitiative(init: Initiative) {
    const agents = ws.agentsFor(init.id).length;
    // Remember the neighbour now: after the delete it is what the pane should
    // land on, rather than an empty "Select an initiative" screen.
    const others = ws.ordered.filter((i) => i.id !== init.id);
    const at = ws.ordered.findIndex((i) => i.id === init.id);
    const next = others[Math.min(at, others.length - 1)] ?? null;

    const drop = async () => {
      await rpc("delete_initiative", { initiative_id: init.id });
      active.initiativeId = null;
      active.agentId = null;
      await load();
      modal = null;
      if (next) selectInitiative(next.id);
    };

    // An idle scratchpad goes without asking. The dialog exists to protect
    // work, and there is none here: nothing running, and a name the user
    // never chose. Being asked "Delete initiative "scratch 22:35"?" about
    // something opened by accident is the wrong noun and the wrong ceremony.
    // A scratchpad with agents in it is not idle, and still asks.
    if (init.scratch && agents === 0) {
      drop().catch((e) => toast((e as Error).message));
      return;
    }

    modal = {
      kind: "confirm",
      message: init.scratch
        ? `Discard scratchpad "${init.name}"? ${agents} agent${agents === 1 ? "" : "s"} still running.`
        : `Delete initiative "${init.name}"?`,
      confirmLabel: init.scratch ? "Discard" : "Delete",
      onConfirm: drop,
    };
  }

  // ── Panes: split / balance / collapse ─────────────────────────────────────────

  // Toggle a split in the given orientation. With no split, open a second pane
  // onto the same initiative. Splitting again in the SAME orientation collapses
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
    // The new pane inherits the initiative but NOT the agent. Copying agentId
    // pointed both panes at one session — two terminals rendering the same
    // stream, which is never what a split is for. Instead it asks what it should
    // hold, so a split lands on something useful in one step.
    const source = panes[activePane];
    panes = [source, { ...newView(), initiativeId: source.initiativeId, chooser: true }];
    activePane = 1;
    split = { dir, fraction: 0.5 };
    // Not just `paneFocus = "main"`: that flipped the label without moving the
    // caret, so the keyboard stayed on <body> and the chooser — the whole
    // content of the pane that was just opened — could only be answered with the
    // mouse. focusMain() retries across frames, which is what this needs: the
    // pane does not exist in the DOM yet.
    focusMain();
  }

  function balanceSplit() {
    if (split) split = { ...split, fraction: 0.5 };
  }

  /**
   * Close one pane and keep the other; the survivor becomes the single view.
   *
   * The agent in the closed pane is left running — closing a pane is a layout
   * decision, and the sidebar still lists the agent for whenever it is wanted
   * back. Stopping one is `delete`, and it asks first.
   */
  function closePane(idx: number) {
    if (!split) return;
    panes = [panes[idx === 0 ? 1 : 0]];
    activePane = 0;
    split = null;
    // The keyboard was in the pane that just went away, so put it somewhere
    // visible rather than leaving it on <body>, where bare keys run as global
    // shortcuts with nothing on screen saying so.
    enterPane(0);
  }

  // ⌘W on the focused pane. With nothing split there is no pane to close, and
  // silently closing the window instead — the other thing ⌘W means — would be a
  // destructive answer to a layout keystroke.
  function closeActivePane() {
    if (!split) return toast(`Only one pane — ${PRIMARY_MOD}D splits it.`);
    closePane(activePane);
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
    // The one combo here that insists on the *platform's* modifier rather than
    // either. ⌃W is delete-word-backwards in every readline and half the TUIs an
    // agent runs; on a Mac there is no reason to take it, since ⌘W is what the
    // hand reaches for anyway. Elsewhere ⌃W is the only close-this there is, and
    // the collision comes with the platform.
    if (key === "w" && (IS_MAC ? e.metaKey : e.ctrlKey)) return closeActivePane;
    // ⌘1…⌘9 jump straight to a pane, the way every tiling terminal numbers its
    // panes. The bare digits are the tab bindings (1 Context, 2 Diff, 3 Tree),
    // so a digit only means "pane" with the modifier down. Out-of-range digits
    // fall through rather than being swallowed as a no-op.
    if (/^[1-9]$/.test(key)) {
      const idx = Number(key) - 1;
      return idx < panes.length ? () => enterPane(idx) : null;
    }
    return null;
  }

  function actionFor(spec: string): ActionId | undefined {
    return (
      reverse[spec] ??
      (spec === "down" ? "navigate_down" : spec === "up" ? "navigate_up" : undefined)
    );
  }

  // Anything that swallows keys for itself: a form field, or xterm's hidden
  // textarea — the terminal is a text surface like any other, and every key it
  // can use has to reach it.
  function typingTarget(): boolean {
    const ae = document.activeElement as HTMLElement | null;
    if (!ae) return false;
    return (
      ae.tagName === "INPUT" ||
      ae.tagName === "TEXTAREA" ||
      ae.tagName === "SELECT" ||
      ae.isContentEditable
    );
  }

  const FOCUS_ACTIONS = new Set<ActionId>(["focus_left", "focus_right", "focus_up", "focus_down"]);

  // eventToSpec folds ⌘ into ctrl, so the app's combos answer to either — but
  // only one of them is what someone on this platform reaches for, and a hint
  // naming the other one is just noise to read past.
  const IS_MAC = /Mac/i.test(navigator.userAgent);
  const PRIMARY_MOD = IS_MAC ? "⌘" : "⌃";

  // A real text field, as opposed to xterm's hidden textarea — which is a text
  // surface for key routing only: it holds no caret the user can move, so the
  // editing combos a field would want mean nothing there.
  function editableTarget(): boolean {
    const ae = document.activeElement as HTMLElement | null;
    if (!ae || ae.classList.contains("xterm-helper-textarea")) return false;
    return typingTarget();
  }

  // Bare keys, bubble phase: they must reach an input or the PTY first.
  function onWindowKeydown(e: KeyboardEvent) {
    if (modal || editing) return; // overlays and the editor own their keys

    const spec = eventToSpec(e);
    if (!spec || spec.includes("+")) return; // modifier combos: see onCaptureKeydown

    if (typingTarget()) return;

    // A pane still showing the chooser has no view mode to switch — the chooser
    // branch renders ahead of `view.tab`, so 1/2/3 are inert there today. Point
    // them at the options actually on screen instead: same digits the mode
    // switcher already teaches, applied to what the pane is currently asking.
    if (choosing) {
      const picked = ["1", "2", "3"].indexOf(spec);
      if (picked >= 0) {
        e.preventDefault();
        const options = chooserOptions(selectedInitiative!);
        if (options[picked]) choosePaneContent(activePane, options[picked].kind);
        return;
      }
    }

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

    // The way back to the sidebar (⌃← / ⌘←) is no longer special-cased here: it
    // is the `focus_sidebar` action, so it runs down the generic keymap path
    // below like every other combo and the user can rebind it.
    if (e.key === "Tab" && !typingTarget()) {
      e.preventDefault();
      e.stopPropagation();
      if (paneFocus === "main") focusSidebar();
      else if (paneHasFocusable(panes[activePane])) focusMain();
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
    // Moving focus between panes means nothing while a text field has the caret,
    // and the default bindings (⌘←→↑↓) are line- and document-motion there. Let
    // the field keep them. Modals and the editor already returned above.
    if (FOCUS_ACTIONS.has(action) && editableTarget()) return;
    e.preventDefault();
    e.stopPropagation();
    runAction(action);
  }

  const paletteItems = $derived(
    PALETTE_ACTIONS.map((id) => ({ id, label: ACTION_LABELS[id], spec: formatSpec(keymap[id]) })),
  );

  // Contextual shortcut hints for the footer — a quiet, always-on cheat row that
  // doubles as onboarding. Specs come from the live keymap so user overrides show.
  // `d` means several different things depending on the row under the cursor, so
  // the footer names the one it means right now — a shortcut that changes shape
  // is only an improvement if you can see which shape it is in.
  const deleteHint = $derived.by<string | null>(() => {
    const row = ws.cursorRow;
    switch (row?.kind) {
      case "agent":
        return ws.agent(row.agentId)?.adapter === "terminal" ? "Close terminal" : "Stop agent";
      case "dir":
        return "Remove dir";
      case "init":
        return "Delete initiative";
      default:
        return null;
    }
  });

  // The git row is only worth naming when the cursor is actually on a repository
  // — offering "Commit" while pointing at a context file is noise, and the
  // footer is a cheat row, not a menu of everything that exists.
  const onGitDir = $derived.by<boolean>(() => {
    const row = ws.cursorRow;
    if (row?.kind !== "dir") return false;
    const init = ws.initiatives.find((i) => i.id === row.initId);
    return init?.dirs.find((d) => d.path === row.path)?.git === true;
  });

  const keyHints = $derived.by<{ spec: string; label: string }[]>(() => {
    const k = (a: ActionId) => formatSpec(keymap[a]);
    const palette = { spec: k("palette"), label: "Commands" };
    // The terminal has the keyboard — including ⇥ — so the only ways out are
    // ⌘⎋ and the palette.
    if (paneFocus === "main" && active.agentId) {
      return [{ spec: LEAVE_MAIN, label: "Sidebar" }, { spec: "⇧⏎", label: "Newline" }, palette];
    }
    // While a pane is still asking, the numbers are the only thing worth saying:
    // every other hint here acts on content this pane does not have yet.
    if (choosing) return [{ spec: "1–3", label: "Fill this pane" }, palette];
    const hints = [{ spec: "↑↓", label: "Move" }];
    if (active.tab === "tree") hints.push({ spec: "⇥", label: "Sidebar" }, { spec: "/", label: "Filter files" });
    else if (active.agentId && active.tab === "context") hints.push({ spec: "⇥", label: "Terminal" });
    if (ws.initiatives.length === 0) hints.push({ spec: k("new_initiative"), label: "New initiative" });
    else hints.push({ spec: k("start_agent"), label: "Start agent" }, { spec: k("add_dir"), label: "Add dir" });
    hints.push({ spec: k("new_scratchpad"), label: "Scratchpad" });
    if (selectedInitiative?.dirs.some((d) => d.git && !d.branch)) {
      hints.push({ spec: k("branch_initiative"), label: "Branch" });
    }
    if (onGitDir) {
      hints.push({ spec: k("git_commit"), label: "Commit" }, { spec: k("git_push"), label: "Push" });
    }
    if (deleteHint) hints.push({ spec: k("delete"), label: deleteHint });
    if (selectedInitiative) hints.push({ spec: `${PRIMARY_MOD}D`, label: "Split" });
    if (split) hints.push({ spec: `${PRIMARY_MOD}W`, label: "Close pane" }, { spec: "⌘⌃=", label: "Balance" });
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

  // A deleted initiative takes its layout with it. Skipped while the workspace
  // is empty or loading — an in-flight refresh briefly looks like "everything
  // was deleted", and acting on that would drop every stored split.
  $effect(() => {
    if (ws.loading || !ws.initiatives.length) return;
    const live = new Set(ws.initiatives.map((i) => i.id));
    // Untracked: this effect depends on the initiative list, never on the map it
    // is pruning, or its own delete would schedule it again.
    untrack(() => {
      for (const id of Object.keys(layouts)) if (!live.has(id)) delete layouts[id];
    });
  });

  // An agent that closed — a clean exit, a stop from another window, a server
  // restart — leaves its pane holding a terminal for something that no longer
  // exists. Fall the pane back to the initiative overview, and hand the
  // keyboard back to the sidebar if that terminal was what had it.
  $effect(() => {
    panes.forEach((p, i) => {
      if (!p.agentId || ws.agent(p.agentId)) return;
      p.agentId = null;
      if (i === activePane && paneFocus === "main" && p.tab !== "tree") focusSidebar();
    });
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
    initTitlebar();
    try {
      keymap = await rpc<Keymap>("get_keybindings");
    } catch {
      keymap = DEFAULT_KEYMAP;
    }
    await load();
  });

  $effect(() => {
    window.addEventListener(QUIT_REQUESTED, confirmQuit);
    return () => window.removeEventListener(QUIT_REQUESTED, confirmQuit);
  });

  // The native menu bar is a thin shell over these same handlers — see
  // `build_menu` in src-tauri/src/main.rs for why none of it lives in Rust.
  $effect(() => {
    const onMenu = (e: Event) => {
      const id = (e as CustomEvent<string>).detail;
      if (typeof id === "string") runMenuCommand(id);
    };
    window.addEventListener(MENU_EVENT, onMenu);
    return () => window.removeEventListener(MENU_EVENT, onMenu);
  });

  /**
   * Moving the sidebar changes every terminal's width, and re-measuring is not
   * repainting. `AgentTerminal`'s ResizeObserver refits the grid, but WKWebView
   * keeps presenting the old surface until something forces it — which is why
   * dragging the window edge "fixed" the garbled pane and nothing else did.
   * So perform that drag ourselves, through the same path the refresh action
   * uses (`redraw`: refit, repaint every row, then SIGWINCH the agent).
   *
   * Deferred rather than immediate: the effect runs before the browser has laid
   * the new width out, so measuring now would measure the old box. Debounced by
   * the cleanup, because a width drag emits a change per pointer move and each
   * one would otherwise cost a SIGWINCH.
   */
  $effect(() => {
    sidebarCollapsed;
    sidebarWidth;
    const t = setTimeout(() => window.dispatchEvent(new CustomEvent(REDRAW_TERMINALS)), 10);
    return () => clearTimeout(t);
  });

  // Agents asking for a human. The frame arrives after the `agent_started` that
  // created the terminal, so `ws` already knows the agent by the time we look.
  $effect(() => onPaneRequest((req) => openAgentPane(req)));
</script>

<svelte:window onkeydown={onWindowKeydown} />

<div class="flex h-screen flex-col">
  <!-- The whole window chrome, in one 36px row. There is no native title bar
       above this on macOS: the shell runs `titleBarStyle: "Overlay"`, so the
       traffic lights are drawn straight onto this bar's left end and the gutter
       they need is measured at runtime (lib/titlebar.svelte.ts) — it collapses
       in fullscreen, where the buttons don't exist.

       `data-tauri-drag-region` moves the window. Tauri honours it only on the
       exact element under the pointer, so putting it on the bar and on its inert
       labels makes the empty space draggable while every button below stays
       clickable — and macOS still gets double-click-to-zoom for free. -->
  <header
    data-tauri-drag-region={overlayed ? "" : undefined}
    class="flex h-9 shrink-0 select-none items-center gap-3 border-b border-border bg-surface pr-1.5"
    style="padding-left: {titlebar.inset || 12}px"
  >
    <h1
      data-tauri-drag-region={overlayed ? "" : undefined}
      class="text-[13px] font-semibold tracking-tight text-accent"
    >
      Codrift
    </h1>
    <!-- Segmented control: one recessed track, the active tab raised out of it.
         Reads as a single object at this height, where three separate outlined
         buttons read as clutter. -->
    <nav class="flex items-center gap-0.5 rounded-lg bg-canvas/70 p-0.5 ring-1 ring-border/60">
      {#each tabs as t (t.id)}
        <button
          class={[
            "rounded-[6px] px-2.5 py-1 text-[11px] leading-none transition-colors",
            active.tab === t.id
              ? "bg-surface text-fg ring-1 ring-border"
              : "text-muted hover:text-fg",
          ]}
          aria-current={active.tab === t.id ? "page" : undefined}
          onclick={() => setTab(t.id)}
        >
          {t.label}
        </button>
      {/each}
    </nav>
    <!-- Announced, so feedback isn't purely visual. -->
    <span
      data-tauri-drag-region={overlayed ? "" : undefined}
      class="text-[11px] text-fg/70"
      role="status"
      aria-live="polite">{status ?? ""}</span
    >
    {#if active.tab === "tree" || (active.agentId && active.tab === "context")}
      <span data-tauri-drag-region={overlayed ? "" : undefined} class="text-[11px] text-fg/70">
        ⇥ focus: {paneFocus === "sidebar" ? "sidebar" : active.tab === "tree" ? "files" : "terminal"}
      </span>
    {/if}
    <!-- Grouped rather than five `ml-auto`-chained buttons, so the gap between
         the status text and the controls is one draggable run of bar. -->
    <div class="ml-auto flex items-center gap-0.5">
      <!-- One door, not three: theme, profiles and integrations were separate
           icons whose contents you had to already know to find. -->
      <button
        class="rounded-md p-1 text-muted hover:bg-canvas hover:text-fg"
        title="Settings — workspace folder, appearance, profiles, integrations ({formatSpec(
          keymap.settings,
        )})"
        onclick={() => openSettings("general")}
        aria-label="Settings"
      >
        <Icon src={Cog6Tooth} class="size-4" />
      </button>
      <button
        class="rounded-md p-1 text-muted hover:bg-canvas hover:text-fg"
        title="Command palette ({formatSpec(keymap.palette)})"
        onclick={() => (modal = { kind: "palette" })}
        aria-label="Command palette"
      >
        <Icon src={CommandLine} class="size-4" />
      </button>
      <button
        class="rounded-md p-1 text-muted hover:bg-canvas hover:text-fg"
        onclick={refreshAll}
        title="Refresh — reload initiatives and repaint the terminals ({formatSpec(keymap.refresh)})"
        aria-label="Refresh"
      >
        <Icon src={ArrowPath} class="size-4" />
      </button>
    </div>
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
        {paneStrips}
        onSelectPane={selectPane}
        width={sidebarWidth}
        newInitiativeKey={formatSpec(keymap.new_initiative)}
        newScratchpadKey={formatSpec(keymap.new_scratchpad)}
        collapseKey={formatSpec(keymap.toggle_sidebar)}
        onSelectInitiative={selectInitiative}
        onPromote={promoteScratchpad}
        onSelectDir={selectDir}
        onSelectAgent={selectAgent}
        onOpenContextFile={openContextFile}
        onOpenMemory={openMemory}
        onToggleContextFolder={toggleContextFolder}
    onContextMenu={openSidebarMenu}
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
      {#if panes.length > 1}
        <!-- Pane number, so ⌘1/⌘2 have something to aim at. Drawn only when
             there is more than one pane — a lone pane needs no label — and it
             names its own shortcut rather than just counting, which is the
             difference between a label and a hint. Click-through, so it can sit
             over a terminal without stealing the corner. -->
        <div
          class={[
            "pointer-events-none absolute left-1 top-1 z-10 rounded px-1.5 py-0.5 text-[10px] leading-none tabular-nums",
            activePane === idx
              ? "bg-accent/20 text-accent ring-1 ring-accent/40"
              : "bg-surface/80 text-muted",
          ]}
        >
          {PRIMARY_MOD}{idx + 1}
        </div>
      {/if}
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
              <p class="mt-3 flex flex-wrap items-center gap-x-1.5 gap-y-2 text-[13px] text-fg/70">
                <span>Not sure yet?</span>
                <kbd class="rounded border border-border bg-surface px-1.5 py-px text-[11px] text-fg/80">{formatSpec(keymap.new_scratchpad)}</kbd>
                <span>opens a scratchpad — no name, no directory. Rank it up if it turns into work.</span>
              </p>
            </div>
          </div>
        {:else}
          <div class="p-6 text-[13px] text-fg/70">Select an initiative.</div>
        {/if}
      {:else if view.chooser && !view.agentId}
        <!-- A fresh split asks rather than guessing. Cloning the source pane's
             agent used to put one PTY behind two terminals; an empty pane was
             correct but inert. -->
        <div class="flex h-full items-center justify-center p-8">
          <!-- The options are real focusable buttons and the first one is given
               the keyboard as soon as the split opens, so a new pane can be
               answered without reaching for the mouse. ↑/↓ walk the list and
               stop there: letting them through would move the sidebar cursor,
               which answers the chooser with whatever it lands on. -->
          <div class="w-full max-w-sm" role="group" aria-label="What goes in this pane?">
            <h2 class="text-base font-semibold text-fg">What goes in this pane?</h2>
            <p class="mt-1 text-[13px] text-fg/70">{init.name}</p>
            <!-- Rendered from chooserOptions so the badge on a row is the same
                 index the key handler uses. The digit is shown rather than
                 documented: a shortcut nobody can see is a shortcut nobody uses,
                 and this screen is where a new user first meets the split. -->
            <div class="mt-5 flex flex-col gap-2">
              {#each chooserOptions(init) as option, n (option.kind)}
                <button
                  data-chooser-option
                  onkeydown={chooserKeys}
                  class="flex items-start gap-3 rounded-lg border border-border bg-surface px-4 py-3 text-left text-[13px] text-fg hover:border-accent focus:border-accent focus:outline-none focus:ring-1 focus:ring-accent"
                  onclick={() => choosePaneContent(idx, option.kind)}
                >
                  <kbd
                    class="mt-px rounded border border-border bg-canvas px-1.5 py-px text-[11px] text-fg/80"
                    aria-hidden="true">{n + 1}</kbd
                  >
                  <span class="min-w-0">
                    <span class="font-semibold">{option.title}</span>
                    <span class="mt-0.5 block text-[12px] text-fg/60">{option.detail}</span>
                  </span>
                </button>
              {/each}
            </div>
            <p class="mt-4 text-[12px] text-fg/50">
              Press a number, or ↑↓ and ⏎. {PRIMARY_MOD}W closes this pane — or pick anything in
              the sidebar.
            </p>
          </div>
        </div>
      {:else if view.tab === "context"}
        <!-- The agent case is handled by the persistent terminal layer below. -->
        {#if !view.agentId}
          {#if view.dirPath && init.dirs.some((d) => d.path === view.dirPath)}
            <!-- Cursor is on a project directory: preview it in place of the
                 overview. Keyed on the path so moving between two dirs remounts
                 rather than showing the previous README while the next loads. -->
            {#key view.dirPath}
              <DirPreview
                initiativeId={init.id}
                dir={init.dirs.find((d) => d.path === view.dirPath)!}
                onOpenTree={() => setTab("tree")}
              />
            {/key}
          {:else}
            <ContextOverview
              initiative={init}
              agents={ws.agentsFor(init.id)}
              wantFile={view.wantFile}
              wantPanel={view.wantPanel}
              onChanged={load}
              onManageProfiles={() => openSettings("profiles")}
            />
          {/if}
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
            onContextMenu={(e, path, isFile) => {
              activePane = idx;
              openTreeMenu(e, path, isFile);
            }}
          />
        {/key}
      {/if}

      <!-- Persistent terminal layer.
           It lives outside the tab branch on purpose: rendering it under
           `tab === "context"` destroyed the xterm on every switch to Diff or
           Tree, and rebuilding it cannot restore a TUI. While unmounted the
           agent has no subscriber, so lib/stream.ts drops its output on the
           floor; on return all we could do was replay a raw byte log recorded at
           the *old* cols/rows — absolute cursor moves and alt-screen switches
           included — into a fresh terminal, which is what produced the garbling.

           `invisible` rather than `hidden`/`{#if}`: visibility:hidden keeps the
           box, so the element never reports 0×0, the fit stays put and the PTY
           is never resized behind the agent's back. `inert` keeps the hidden
           textarea out of the focus order.

           No {#key} either: a terminal persists and reconnects when the agent
           changes, avoiding WebGL-context churn that broke the UI. -->
      {#if init && view.agentId}
        <div
          class={["absolute inset-0", view.tab === "context" ? "" : "invisible"]}
          inert={view.tab !== "context"}
          aria-hidden={view.tab !== "context"}
        >
          <AgentTerminal
            agentId={view.agentId}
            initiativeId={init.id}
            visible={view.tab === "context"}
          />
        </div>
      {/if}
    </main>
  {/snippet}

  <!-- Always-on contextual cheat row: keyboard-first discoverability without ceremony. -->
  <!-- Scrolls rather than wraps: a second row would change the footer's height,
       and everything above it is a terminal that gets resized when that happens. -->
  <footer class="flex shrink-0 items-center gap-4 overflow-x-auto border-t border-border bg-surface px-4 py-1 text-[11px] text-fg/70">
    {#each keyHints as h (h.label)}
      <span class="flex shrink-0 items-center gap-1.5">
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

{#if modal?.kind === "settings"}
  <Settings
    section={modal.section}
    {keymap}
    onChanged={() => ws.refreshSettings()}
    onClose={() => (modal = null)}
  />
{:else if modal?.kind === "agent_picker" && selectedInitiative}
  <AgentPicker
    initiative={selectedInitiative}
    onDone={async (choice, scope) => {
      modal = null;
      await load();
      toast(
        scope === "default"
          ? `New initiatives start ${choice}`
          : `${selectedInitiative!.name} starts ${choice}`,
      );
    }}
    onClose={() => (modal = null)}
  />
{:else if modal?.kind === "new_initiative"}
  <NewInitiative
    onCreate={createInitiative}
    onOpen={revealInitiative}
    onManageProfiles={() => openSettings("profiles")}
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
  <DirPicker start={ws.workspaceDir} onSubmit={modal.submit} onClose={() => (modal = null)} />
{:else if modal?.kind === "confirm"}
  <Confirm
    message={modal.message}
    confirmLabel={modal.confirmLabel ?? "Confirm"}
    onConfirm={modal.onConfirm}
    onClose={() => (modal = null)}
  />
{:else if modal?.kind === "choice"}
  <Choice
    title={modal.title}
    description={modal.description}
    options={modal.options}
    onClose={() => (modal = null)}
  />
{/if}

{#if contextMenu}
  <ContextMenu request={contextMenu} onClose={() => (contextMenu = null)} />
{/if}
