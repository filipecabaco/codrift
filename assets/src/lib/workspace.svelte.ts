// The sidebar's data model: initiatives, their agents, expansion state, and the
// flat cursor-navigable row list derived from them. App.svelte owns interaction.

import {
  ADAPTERS,
  rpc,
  listAgentProfiles,
  type Agent,
  type AgentProfile,
  type Initiative,
} from "$lib/api";
import { connect, onAgent, onAgentStatus, type AgentInfo, type AgentStatus } from "$lib/stream";

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
  awaiting_input: "needs input",
  idle: "idle",
  stopped: "stopped",
  crashed: "crashed",
};

export function statusLabel(status: string): string {
  return STATUS_LABELS[status] ?? status.replace(/_/g, " ");
}

/** An agent blocked on the user is the one signal worth interrupting for. */
export function needsInput(status: string): boolean {
  return status === "awaiting_input";
}

export function isDead(status: string): boolean {
  return status === "stopped" || status === "crashed";
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
  // The launch adapter/profile the user picked. Shared across panes on purpose:
  // it is a property of the person, not of a viewport, so cloning a pane (⌘D)
  // or switching initiative must not silently drop it back to "claude".
  launchChoice = $state<string>("claude");
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
    connect();
  }

  agentsFor(initId: string): Agent[] {
    return this.agentsByInit[initId] ?? [];
  }

  agentsForDir(initId: string, path: string): Agent[] {
    return this.agentsFor(initId).filter((a) => a.dir === path);
  }

  /** Agents whose dir isn't one of the initiative's project dirs (e.g. scratch). */
  looseAgents(init: Initiative): Agent[] {
    const dirs = new Set(init.dirs.map((d) => d.path));
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

  // Mirrors the rendered tree exactly, so j/k moves through what's on screen.
  rows = $derived.by<Row[]>(() => {
    const out: Row[] = [];
    for (const i of this.initiatives) {
      out.push({ kind: "init", initId: i.id });
      if (!this.expanded.has(i.id)) continue;
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
        this.initiatives.map(
          async (i) =>
            [i.id, await rpc<Agent[]>("get_initiative_agents", { initiative_id: i.id })] as const,
        ),
      );
      this.agentsByInit = Object.fromEntries(entries);
      await this.refreshProfiles();
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  // Profiles live in settings.json, editable in the Profiles view or by hand —
  // so a refresh has to re-read them. A failure here must not fail the whole
  // load: the initiative list is what the sidebar needs.
  async refreshProfiles() {
    try {
      this.profiles = await listAgentProfiles();
    } catch {
      this.profiles = [];
    }
    // A profile can be renamed or deleted out from under the launch picker.
    // Leaving the choice dangling would silently start nothing (unknown
    // profile) on the next `s`, so fall back to the plain adapter.
    const known =
      (ADAPTERS as readonly string[]).includes(this.launchChoice) ||
      this.profiles.some((p) => p.name === this.launchChoice);
    if (!known) this.launchChoice = "claude";
  }

  async #ensureContextFiles(id: string) {
    if (this.contextFiles[id]) return;
    try {
      const res = await rpc<{ files: string[] }>("list_context_files", { initiative_id: id });
      this.contextFiles = { ...this.contextFiles, [id]: res.files };
    } catch {
      this.contextFiles = { ...this.contextFiles, [id]: [] };
    }
  }

  #upsertAgent(agent: AgentInfo) {
    const list = this.agentsByInit[agent.initiative_id] ?? [];
    const i = list.findIndex((a) => a.id === agent.id);
    let next: Agent[];
    if (i < 0) {
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
      const next = list.slice();
      next[i] = { ...next[i], status };
      this.agentsByInit = { ...this.agentsByInit, [initId]: next };
      return;
    }
  }
}

export const workspace = new Workspace();
