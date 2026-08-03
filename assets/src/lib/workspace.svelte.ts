// The sidebar's data model: initiatives, their agents, expansion state, and the
// flat cursor-navigable row list derived from them. App.svelte owns interaction.

import { rpc, type Agent, type Initiative } from "$lib/api";
import { connect, onAgent, onAgentStatus, type AgentInfo, type AgentStatus } from "$lib/stream";

export type Row =
  | { kind: "init"; initId: string }
  | { kind: "file"; initId: string; name: string }
  | { kind: "dir"; initId: string; path: string }
  | { kind: "agent"; initId: string; agentId: string };

/** Stable identity for a row, so the cursor can highlight any row type. */
export function rowKey(r: Row): string {
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

class Workspace {
  initiatives = $state<Initiative[]>([]);
  agentsByInit = $state<Record<string, Agent[]>>({});
  contextFiles = $state<Record<string, string[]>>({});
  expanded = $state<Set<string>>(new Set());
  cursor = $state(0);
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

  // Mirrors the rendered tree exactly, so j/k moves through what's on screen.
  rows = $derived.by<Row[]>(() => {
    const out: Row[] = [];
    for (const i of this.initiatives) {
      out.push({ kind: "init", initId: i.id });
      if (!this.expanded.has(i.id)) continue;
      for (const f of this.contextFiles[i.id] ?? []) out.push({ kind: "file", initId: i.id, name: f });
      for (const d of i.dirs) {
        out.push({ kind: "dir", initId: i.id, path: d.path });
        for (const a of this.agentsForDir(i.id, d.path))
          out.push({ kind: "agent", initId: i.id, agentId: a.id });
      }
      for (const a of this.looseAgents(i)) out.push({ kind: "agent", initId: i.id, agentId: a.id });
    }
    return out;
  });

  cursorKey = $derived(this.rows[this.cursor] ? rowKey(this.rows[this.cursor]) : null);

  /** The directory the cursor is "in", so `s`/`t` start an agent in the right place. */
  cursorDir = $derived.by<string | null>(() => {
    const r = this.rows[this.cursor];
    if (!r) return null;
    if (r.kind === "dir") return r.path;
    if (r.kind === "agent") return this.agent(r.agentId)?.dir ?? null;
    return null;
  });

  moveCursor(delta: number): Row | null {
    if (this.rows.length === 0) return null;
    this.cursor = Math.max(0, Math.min(this.cursor + delta, this.rows.length - 1));
    return this.rows[this.cursor] ?? null;
  }

  moveTo(index: number): Row | null {
    if (index < 0 || index >= this.rows.length) return null;
    this.cursor = index;
    return this.rows[index];
  }

  /**
   * ← in a tree: close the open node, otherwise step out to its parent.
   * Returns the row to apply, or null when nothing moved.
   */
  collapseOrParent(): Row | null {
    const row = this.rows[this.cursor];
    if (!row) return null;

    if (row.kind === "init") {
      if (this.expanded.has(row.initId)) this.toggleExpand(row.initId);
      return null;
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
    const row = this.rows[this.cursor];
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

    // A directory's children are its agents, which sit directly after it.
    if (row.kind === "dir") {
      const next = this.rows[this.cursor + 1];
      return next?.kind === "agent" ? this.moveTo(this.cursor + 1) : null;
    }

    return null; // files and agents are leaves
  }

  syncCursor(pred: (r: Row) => boolean) {
    const i = this.rows.findIndex(pred);
    if (i >= 0) this.cursor = i;
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
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
    }
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
