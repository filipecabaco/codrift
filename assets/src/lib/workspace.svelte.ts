// The sidebar's data model: initiatives, their agents, expansion state, and the
// flat cursor-navigable row list derived from them. App.svelte owns interaction.

import {
  ADAPTERS,
  rpc,
  getDefaultAgent,
  getSidebarSort,
  getWorkspaceDir,
  listAgentProfiles,
  setSidebarSort,
  type Agent,
  type AgentProfile,
  type Initiative,
  type SidebarSort,
} from "$lib/api";
import {
  connect,
  onAgent,
  onAgentStatus,
  onInitiativeChange,
  type AgentInfo,
  type AgentStatus,
  type InitiativeChange,
} from "$lib/stream";

export type Row =
  | { kind: "init"; initId: string }
  | { kind: "memory"; initId: string }
  | { kind: "folder"; initId: string; path: string }
  | { kind: "file"; initId: string; name: string }
  | { kind: "dir"; initId: string; path: string }
  | { kind: "agent"; initId: string; agentId: string };

/** Stable identity for a row, so the cursor can highlight any row type. */
export function rowKey(r: Row): string {
  switch (r.kind) {
    case "init":
      return `i:${r.initId}`;
    case "memory":
      return `m:${r.initId}`;
    case "folder":
      return `x:${r.initId}:${r.path}`;
    case "file":
      return `f:${r.initId}:${r.name}`;
    case "dir":
      return `d:${r.initId}:${r.path}`;
    case "agent":
      return `a:${r.agentId}`;
  }
}

/**
 * Every path a directory entry answers to.
 *
 * A worktree-backed directory has two: the source repository the user added,
 * and the isolated checkout agents actually run in. An agent started there
 * reports the *worktree* path, so anything matching agents to directories has
 * to accept both — otherwise enabling a worktree silently unparents every agent
 * under it, and they all reappear at the bottom of the tree as loose ones.
 */
function dirPaths(entry: Initiative["dirs"][number]): string[] {
  return entry.worktree_path ? [entry.path, entry.worktree_path] : [entry.path];
}

/** A file or folder inside an initiative's context folder. */
export type ContextNode = {
  name: string;
  /** Path relative to the context folder, e.g. `scripts/deploy.sh`. */
  path: string;
  isFile: boolean;
  children: ContextNode[];
};

// Backend statuses are snake_case atoms; unmapped ones fall back to de-underscored.
const STATUS_LABELS: Record<string, string> = {
  starting: "starting",
  running: "running",
  // Text is in its box but the Enter keystroke has not gone out yet — not the
  // same thing as an agent that is free, which is what this used to be told.
  input_pending: "sending",
  awaiting_input: "needs input",
  idle: "idle",
  stopped: "stopped",
  crashed: "crashed",
};

export function statusLabel(status: string): string {
  return STATUS_LABELS[status] ?? status.replace(/_/g, " ");
}

/** An agent that is part of an orchestration, not one the user started. */
export function isOrchestrated(role?: string | null): boolean {
  return role === "orchestrator" || role === "directed";
}

/**
 * What an agent's icon means, spelled out. The row has no space for the word,
 * so this is the tooltip and the accessible name — the glyph carries it on
 * screen, this carries it everywhere else.
 */
export function agentIconLabel(adapter: string, role?: string | null): string {
  if (role === "orchestrator") return "Orchestrator — directing the other agents";
  if (role === "directed") return "Started and directed by the orchestrator";
  return adapter === "terminal" ? "Terminal" : "Agent";
}

/** An agent blocked on the user is the one signal worth interrupting for. */
export function needsInput(status: string): boolean {
  return status === "awaiting_input";
}

export function isDead(status: string): boolean {
  return status === "stopped" || status === "crashed";
}

/**
 * An agent whose session simply ended is done: its row closes and its pane falls
 * back to the initiative overview, the way closing a terminal tab works. A crash
 * stays visible — the exit code and whatever the agent printed on its way out
 * are the whole reason to look — until it is dismissed with the delete key.
 *
 * Which of the two an exit was is the backend's call, not this one's: a shell
 * exits with whatever its last command returned, and a CLI that took SIGINT was
 * asked to quit. Both arrive here as `stopped`.
 */
function closesOnExit(agent: { status: string; mode?: string }): boolean {
  // `once` agents (orchestration turns) go back to :idle after each run and are
  // reused, so their exit is not the end of the agent.
  return agent.status === "stopped" && agent.mode !== "once";
}

/** The context subfolder a row lives in, or null when it sits at the root. */
function parentFolder(row: Row): string | null {
  const path = row.kind === "file" ? row.name : row.kind === "folder" ? row.path : null;
  if (!path?.includes("/")) return null;
  return path.slice(0, path.lastIndexOf("/"));
}

/** Folders before files, each alphabetical — the order every file tree uses. */
function sortNodes(nodes: ContextNode[]): ContextNode[] {
  nodes.sort((a, b) =>
    a.isFile === b.isFile ? a.name.localeCompare(b.name) : a.isFile ? 1 : -1,
  );
  nodes.forEach((n) => sortNodes(n.children));
  return nodes;
}

/**
 * Where each status sits when sorting by it.
 *
 * Active work first, finished work sinking — deliberately NOT the lifecycle
 * order that `[` / `]` cycle through (`planning → ongoing → done → archived`).
 * Cycling is about moving one initiative along its life; sorting is about what
 * the sidebar should put in front of you, and nobody opens Codrift to look at
 * what is archived.
 */
const STATUS_RANK: Record<string, number> = { ongoing: 0, planning: 1, done: 2, archived: 3 };

// Sorted lists must be *total*: two initiatives that tie on the chosen key have
// to keep a stable order between renders, or rows swap places for no reason the
// user can see. Every comparator below therefore ends on a unique-ish key.
const byName = (a: Initiative, b: Initiative) =>
  a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
// created_at is ISO-8601, so lexicographic order is chronological order.
const byCreated = (a: Initiative, b: Initiative) => a.created_at.localeCompare(b.created_at);
const rank = (i: Initiative) => STATUS_RANK[i.status] ?? 99;

function compareBy(sort: SidebarSort, a: Initiative, b: Initiative): number {
  switch (sort) {
    case "name":
      return byName(a, b) || byCreated(a, b);
    case "recent":
      return byCreated(b, a);
    case "status":
      return rank(a) - rank(b) || byName(a, b) || byCreated(a, b);
    default:
      return byCreated(a, b);
  }
}

class Workspace {
  initiatives = $state<Initiative[]>([]);
  agentsByInit = $state<Record<string, Agent[]>>({});
  contextFiles = $state<Record<string, string[]>>({});
  expanded = $state<Set<string>>(new Set());
  // Open subfolders inside context folders, keyed `${initId}:${relativePath}`.
  expandedFolders = $state<Set<string>>(new Set());
  // Launch profiles from settings.json, refreshed by every load() so a profile
  // added on disk shows up on the next refresh instead of only on a reload.
  profiles = $state<AgentProfile[]>([]);
  defaultAgent = $state<string>("claude");
  // Where the "add directory" picker starts browsing. null = no preference, so
  // the picker falls back to `~` the way it always did.
  workspaceDir = $state<string | null>(null);
  // The cursor is identified by ROW KEY, not by index: rows appear and vanish
  // under it (an agent stops, an initiative is deleted, another pane's agent
  // starts) and an index would then point at an unrelated row — highlighting
  // one initiative while the content pane still shows another.
  cursorKey = $state<string | null>(null);
  loading = $state(true);
  error = $state<string | null>(null);

  constructor() {
    onAgentStatus((agentId, status) => this.#applyStatus(agentId, status));
    onAgent((agent) => this.#upsertAgent(agent));
    onInitiativeChange((change) => this.#applyInitiativeChange(change));
    connect();
  }

  agentsFor(initId: string): Agent[] {
    return this.agentsByInit[initId] ?? [];
  }

  agentsForDir(initId: string, path: string): Agent[] {
    const entry = this.initiatives.find((i) => i.id === initId)?.dirs.find((d) => d.path === path);
    const paths = entry ? dirPaths(entry) : [path];
    return this.agentsFor(initId).filter((a) => paths.includes(a.dir));
  }

  /** Agents whose dir isn't one of the initiative's project dirs (e.g. scratch). */
  looseAgents(init: Initiative): Agent[] {
    const dirs = new Set(init.dirs.flatMap(dirPaths));
    return this.agentsFor(init.id).filter((a) => !dirs.has(a.dir));
  }

  /** How many of an initiative's agents are blocked waiting on the user. */
  waitingCount(initId: string): number {
    return this.agentsFor(initId).filter((a) => needsInput(a.status)).length;
  }

  agent(agentId: string): Agent | null {
    for (const list of Object.values(this.agentsByInit)) {
      const found = list.find((a) => a.id === agentId);
      if (found) return found;
    }
    return null;
  }

  /**
   * The context folder as a tree. An initiative folder is a real workspace —
   * people keep `scripts/` and `docs/` in it — so nested paths become nested
   * nodes rather than one flat list of slash-y names.
   */
  contextTree(initId: string): ContextNode[] {
    const roots: ContextNode[] = [];
    for (const rel of this.contextFiles[initId] ?? []) {
      const segments = rel.split("/").filter(Boolean);
      let level = roots;
      let path = "";
      segments.forEach((segment, i) => {
        path = path ? `${path}/${segment}` : segment;
        const isFile = i === segments.length - 1;
        let node = level.find((n) => n.name === segment && n.isFile === isFile);
        if (!node) {
          node = { name: segment, path, isFile, children: [] };
          level.push(node);
        }
        level = node.children;
      });
    }
    return sortNodes(roots);
  }

  /** Flattened context tree honouring folder expansion — what actually renders. */
  contextRows(initId: string): { node: ContextNode; depth: number }[] {
    const out: { node: ContextNode; depth: number }[] = [];
    const walk = (nodes: ContextNode[], depth: number) => {
      for (const node of nodes) {
        out.push({ node, depth });
        if (!node.isFile && this.folderOpen(initId, node.path)) walk(node.children, depth + 1);
      }
    };
    walk(this.contextTree(initId), 0);
    return out;
  }

  folderOpen(initId: string, path: string): boolean {
    return this.expandedFolders.has(`${initId}:${path}`);
  }

  toggleFolder(initId: string, path: string) {
    const key = `${initId}:${path}`;
    const next = new Set(this.expandedFolders);
    next.has(key) ? next.delete(key) : next.add(key);
    this.expandedFolders = next;
  }

  /**
   * Real initiatives, then scratchpads — the order the sidebar draws them in,
   * and therefore the order `rows` has to walk.
   *
   * Scratchpads sit at the bottom because they are the noisy end of the list:
   * one gets opened for every stray question, most are never named, and none of
   * them should push the work you actually filed off the top of the sidebar.
   */
  /**
   * How the initiative list is ordered. Persisted, so it survives a restart.
   *
   * Every ordering offered here is *stable* — it changes only when the user does
   * something (creates, renames, promotes, cycles a status), never on its own.
   * Sorting by "needs input" was the obvious candidate and is the one to avoid:
   * rows would rearrange themselves under the cursor every time an agent
   * changed state. The "N waiting" badge already says who is blocked without
   * moving anything.
   */
  sort = $state<SidebarSort>("created");

  projects = $derived(
    // filter() already copied, so sorting in place is not mutating `initiatives`.
    this.initiatives.filter((i) => !i.scratch).sort((a, b) => compareBy(this.sort, a, b)),
  );
  // Newest first, against the oldest-first order the store returns, and NOT
  // subject to `sort`. That order is right for filed work — long-lived things
  // should sit still — and exactly wrong here: the scratchpad you opened a
  // second ago would land at the bottom while last Tuesday's dead ones held the
  // top. A scratchpad stack is a recency stack, the way shell history is; that
  // is what the thing *is*, not a preference about it.
  scratchpads = $derived(this.initiatives.filter((i) => i.scratch).reverse());
  ordered = $derived([...this.projects, ...this.scratchpads]);

  // Mirrors the rendered tree exactly, so j/k moves through what's on screen.
  rows = $derived.by<Row[]>(() => {
    const out: Row[] = [];
    for (const i of this.ordered) {
      out.push({ kind: "init", initId: i.id });
      if (!this.expanded.has(i.id)) continue;
      // A scratchpad hides its paperwork. It has an initiative.md, an
      // orchestration.md and a memory store like anything else — but nobody
      // opens a scratchpad to read them, and three rows of ceremony under every
      // throwaway session turns the sidebar into filing. They are still on
      // disk, and ranking one up brings them straight back.
      if (!i.scratch) {
        for (const { node } of this.contextRows(i.id)) {
          out.push(
            node.isFile
              ? { kind: "file", initId: i.id, name: node.path }
              : { kind: "folder", initId: i.id, path: node.path },
          );
        }
        // Memory is context too — reachable from the tree, not only from a tab
        // buried in the overview.
        out.push({ kind: "memory", initId: i.id });
      }
      for (const d of i.dirs) {
        out.push({ kind: "dir", initId: i.id, path: d.path });
        for (const a of this.agentsForDir(i.id, d.path))
          out.push({ kind: "agent", initId: i.id, agentId: a.id });
      }
      for (const a of this.looseAgents(i)) out.push({ kind: "agent", initId: i.id, agentId: a.id });
    }
    return out;
  });

  /** Where the cursor sits in `rows`, or -1 once its row is gone. */
  cursorIndex = $derived(this.rows.findIndex((r) => rowKey(r) === this.cursorKey));

  /** Same, clamped for callers that just want a row to read. */
  cursor = $derived(Math.max(0, this.cursorIndex));

  /** The row under the cursor, or null when it no longer exists. */
  cursorRow = $derived(this.cursorIndex >= 0 ? this.rows[this.cursorIndex] : null);

  /** How many agents are alive across every initiative. */
  totalAgents = $derived(Object.values(this.agentsByInit).reduce((n, l) => n + l.length, 0));

  /** The directory the cursor is "in", so `s`/`t` start an agent in the right place. */
  cursorDir = $derived.by<string | null>(() => {
    const r = this.cursorRow;
    if (!r) return null;
    if (r.kind === "dir") return r.path;
    if (r.kind === "agent") return this.agent(r.agentId)?.dir ?? null;
    return null;
  });

  moveCursor(delta: number): Row | null {
    if (this.rows.length === 0) return null;
    return this.moveTo(Math.max(0, Math.min(this.cursor + delta, this.rows.length - 1)));
  }

  moveTo(index: number): Row | null {
    const row = this.rows[index];
    if (!row) return null;
    this.cursorKey = rowKey(row);
    return row;
  }

  /**
   * Re-anchor the cursor after its row disappeared — an agent was stopped, an
   * initiative deleted. Anchors inside `initId` (the initiative the pane is
   * showing) so the highlight can never contradict the content pane.
   */
  reconcileCursor(initId: string | null): void {
    if (this.cursorIndex >= 0) return;
    const row =
      (initId ? this.rows.find((r) => r.kind === "init" && r.initId === initId) : undefined) ??
      this.rows[0];
    this.cursorKey = row ? rowKey(row) : null;
  }

  /**
   * ← in a tree: close the open node, otherwise step out to its parent.
   * Returns the row to apply, or null when nothing moved.
   */
  collapseOrParent(): Row | null {
    const row = this.cursorRow;
    if (!row) return null;

    if (row.kind === "init") {
      if (this.expanded.has(row.initId)) this.toggleExpand(row.initId);
      return null;
    }

    if (row.kind === "folder" && this.folderOpen(row.initId, row.path)) {
      this.toggleFolder(row.initId, row.path);
      return null;
    }

    // Inside a context subfolder: step out to the folder that holds it.
    const parent = parentFolder(row);
    if (parent) {
      const i = this.rows.findIndex(
        (r) => r.kind === "folder" && r.initId === row.initId && r.path === parent,
      );
      if (i >= 0) return this.moveTo(i);
    }

    // Agents nest under a directory; everything else hangs off the initiative.
    if (row.kind === "agent") {
      const dir = this.agent(row.agentId)?.dir;
      const dirIndex = this.rows.findIndex(
        (r) => r.kind === "dir" && r.initId === row.initId && r.path === dir,
      );
      if (dirIndex >= 0) return this.moveTo(dirIndex);
    }

    return this.moveTo(this.rows.findIndex((r) => r.kind === "init" && r.initId === row.initId));
  }

  /**
   * → in a tree: open the closed node, otherwise step into its first child.
   * Returns the row to apply, or null when nothing moved.
   */
  expandOrChild(): Row | null {
    const row = this.cursorRow;
    if (!row) return null;

    if (row.kind === "init") {
      if (!this.expanded.has(row.initId)) {
        this.expand(row.initId);
        return null;
      }
      // Already open: descend to the first child, if it has one.
      const next = this.rows[this.cursor + 1];
      return next && next.kind !== "init" ? this.moveTo(this.cursor + 1) : null;
    }

    if (row.kind === "folder") {
      if (!this.folderOpen(row.initId, row.path)) {
        this.toggleFolder(row.initId, row.path);
        return null;
      }
      const next = this.rows[this.cursor + 1];
      return next ? this.moveTo(this.cursor + 1) : null;
    }

    // A directory's children are its agents, which sit directly after it.
    if (row.kind === "dir") {
      const next = this.rows[this.cursor + 1];
      return next?.kind === "agent" ? this.moveTo(this.cursor + 1) : null;
    }

    return null; // files, memory and agents are leaves
  }

  syncCursor(pred: (r: Row) => boolean) {
    const row = this.rows.find(pred);
    if (row) this.cursorKey = rowKey(row);
  }

  expand(id: string) {
    if (this.expanded.has(id)) return;
    this.expanded = new Set(this.expanded).add(id);
    void this.#ensureContextFiles(id);
  }

  toggleExpand(id: string) {
    if (!this.expanded.has(id)) return this.expand(id);
    const next = new Set(this.expanded);
    next.delete(id);
    this.expanded = next;
  }

  async load() {
    this.loading = true;
    this.error = null;
    try {
      this.initiatives = await rpc<Initiative[]>("list_initiatives");
      const entries = await Promise.all(
        this.initiatives.map(async (i) => {
          const agents = await rpc<Agent[]>("get_initiative_agents", { initiative_id: i.id });
          // The backend keeps finished agents queryable on purpose; the sidebar
          // shows only what is still worth looking at.
          return [i.id, agents.filter((a) => !closesOnExit(a))] as const;
        }),
      );
      this.agentsByInit = Object.fromEntries(entries);
      await this.refreshSettings();
      await this.refreshSort();
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  // Everything that lives in settings.json — profiles, the default agent, the
  // workspace folder — is editable in Settings or by hand, so a refresh has to
  // re-read it. A failure here must not fail the whole load: the initiative
  // list is what the sidebar needs.
  async refreshSettings() {
    try {
      this.profiles = await listAgentProfiles();
    } catch {
      this.profiles = [];
    }
    try {
      this.defaultAgent = await getDefaultAgent();
    } catch {
      this.defaultAgent = "claude";
    }
    if (!this.knownAgent(this.defaultAgent)) this.defaultAgent = "claude";
    try {
      this.workspaceDir = await getWorkspaceDir();
    } catch {
      this.workspaceDir = null;
    }
  }

  async refreshSort() {
    try {
      this.sort = await getSidebarSort();
    } catch {
      /* an unsorted-as-stored list still beats failing the whole load */
    }
  }

  /** Reorders now, remembers after — the list must not wait on a round trip. */
  async setSort(next: SidebarSort) {
    this.sort = next;
    try {
      await setSidebarSort(next);
    } catch {
      /* a re-sorted sidebar that cannot persist still beats an error toast */
    }
  }

  knownAgent(choice: string | null | undefined): boolean {
    if (!choice) return false;
    return (
      (ADAPTERS as readonly string[]).includes(choice) ||
      this.profiles.some((p) => p.name === choice)
    );
  }

  /** The agent an initiative launches: its own choice, else the global default. */
  agentChoiceFor(init: Initiative | null | undefined): string {
    if (init && this.knownAgent(init.agent)) return init.agent as string;
    return this.knownAgent(this.defaultAgent) ? this.defaultAgent : "claude";
  }

  async #ensureContextFiles(id: string) {
    if (this.contextFiles[id]) return;
    await this.refreshContextFiles(id);
  }

  /**
   * Re-read one initiative's context files, cache or no cache.
   *
   * `#ensureContextFiles` reads once and keeps the answer — the list only
   * changes when something writes to the folder, which is rare enough that
   * re-listing on every sidebar render would be waste. But `open_file` *is*
   * something writing to the folder, and without this the pin it just made was
   * missing from the sidebar until the next reload.
   */
  async refreshContextFiles(id: string) {
    try {
      const res = await rpc<{ files: string[] }>("list_context_files", { initiative_id: id });
      this.contextFiles = { ...this.contextFiles, [id]: res.files };
    } catch {
      this.contextFiles = { ...this.contextFiles, [id]: [] };
    }
  }

  /**
   * Fold in an initiative created, changed, or deleted outside this session —
   * a shell running `codrift initiative create`, an MCP agent, a second window.
   *
   * Patches the one row the frame names rather than calling `load()`. `load()`
   * fans out `get_initiative_agents` per initiative, so making it the refresh
   * primitive would turn every rename into O(initiatives) round trips; it also
   * flips `loading`, which would blank the sidebar on someone else's edit.
   */
  #applyInitiativeChange(change: InitiativeChange) {
    if (change.kind === "deleted") return this.#removeInitiative(change.initiativeId);

    const next = change.initiative;
    const i = this.initiatives.findIndex((init) => init.id === next.id);
    if (i >= 0) {
      const updated = this.initiatives.slice();
      updated[i] = next;
      this.initiatives = updated;
      return;
    }

    // Sorted by creation time, matching list_initiatives, so a new initiative
    // lands where a reload would have put it rather than at the end.
    this.initiatives = [...this.initiatives, next].sort((a, b) =>
      a.created_at.localeCompare(b.created_at),
    );
    // Nothing can have started in it yet, but the key has to exist so the row
    // renders as "no agents" instead of waiting on a fetch that never happens.
    if (!this.agentsByInit[next.id]) {
      this.agentsByInit = { ...this.agentsByInit, [next.id]: [] };
    }
  }

  #removeInitiative(id: string) {
    this.initiatives = this.initiatives.filter((init) => init.id !== id);

    const agents = { ...this.agentsByInit };
    delete agents[id];
    this.agentsByInit = agents;

    const files = { ...this.contextFiles };
    delete files[id];
    this.contextFiles = files;

    if (this.expanded.has(id)) {
      const next = new Set(this.expanded);
      next.delete(id);
      this.expanded = next;
    }
    // Folder expansion is keyed `${initId}:${path}`, so it needs pruning too or
    // the set grows a stale entry for every initiative ever deleted.
    const folders = new Set([...this.expandedFolders].filter((k) => !k.startsWith(`${id}:`)));
    if (folders.size !== this.expandedFolders.size) this.expandedFolders = folders;
  }

  #upsertAgent(agent: AgentInfo) {
    const list = this.agentsByInit[agent.initiative_id] ?? [];
    const i = list.findIndex((a) => a.id === agent.id);
    let next: Agent[];
    // The join snapshot replays every agent the backend still holds, finished
    // ones included; a clean exit must not come back on a reconnect.
    if (closesOnExit(agent)) {
      if (i < 0) return;
      next = list.filter((a) => a.id !== agent.id);
    } else if (i < 0) {
      next = [...list, agent];
    } else {
      next = list.slice();
      next[i] = { ...next[i], ...agent };
    }
    this.agentsByInit = { ...this.agentsByInit, [agent.initiative_id]: next };
  }

  #applyStatus(agentId: string, status: AgentStatus) {
    for (const [initId, list] of Object.entries(this.agentsByInit)) {
      const i = list.findIndex((a) => a.id === agentId);
      if (i < 0) continue;
      if (list[i].status === status) return;
      const updated = { ...list[i], status };
      let next: Agent[];
      if (closesOnExit(updated)) {
        next = list.filter((a) => a.id !== agentId);
      } else {
        next = list.slice();
        next[i] = updated;
      }
      this.agentsByInit = { ...this.agentsByInit, [initId]: next };
      return;
    }
  }
}

export const workspace = new Workspace();
