// One WebSocket for the whole workspace: every agent's output and status down,
// keystrokes and resizes up, keyed by agent id. Reconnects with backoff.

// Type-only, so this stays the leaf module it is at runtime.
import type { Initiative } from "$lib/api";

export type AgentStatus =
  | "starting"
  | "running"
  | "awaiting_input"
  | "idle"
  | "stopped"
  | "crashed";

/** Shape the backend sends for an agent (mirrors a `list_agents` entry). */
export type AgentInfo = {
  id: string;
  adapter: string;
  status: AgentStatus;
  dir: string;
  initiative_id: string;
  mode: string;
  profile?: string | null;
};

/**
 * An agent asking for the user's attention at a specific agent or terminal.
 *
 * Unlike every other frame here this one is a *request*, not a notification:
 * the backend has no way to open a pane, so a tool that needs a human at the
 * keyboard says so and the window acts on it.
 */
export type PaneRequest = {
  agentId: string;
  initiativeId: string;
  reason: string | null;
};

/**
 * An initiative appearing, changing, or going away somewhere other than here.
 *
 * The sidebar is not the only writer: `codrift initiative create` in a shell, an
 * MCP-connected agent, and a second window all mutate the list behind this
 * session's back, and until these frames existed none of it was visible without
 * a manual reload.
 *
 * `created` and `updated` carry the whole record, in the same shape
 * `list_initiatives` returns, so a handler can patch the one row it names —
 * re-running the workspace's `load()` instead would refetch every initiative's
 * agents on every rename.
 */
export type InitiativeChange =
  | { kind: "created" | "updated"; initiative: Initiative }
  | { kind: "deleted"; initiativeId: string };

const outputSubs = new Map<string, Set<(bytes: Uint8Array) => void>>();
const stoppedSubs = new Map<string, Set<(code: number) => void>>();
const statusSubs = new Set<(agentId: string, status: AgentStatus) => void>();
const agentSubs = new Set<(agent: AgentInfo) => void>();
const paneSubs = new Set<(req: PaneRequest) => void>();
const initiativeSubs = new Set<(change: InitiativeChange) => void>();
const memorySubs = new Set<(initiativeId: string) => void>();

let socket: WebSocket | null = null;
let retry: ReturnType<typeof setTimeout> | null = null;
let attempt = 0;
/** Frames written while the socket was down, replayed on open. */
let pending: string[] = [];

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function dispatch(frame: Record<string, unknown>) {
  const agentId = frame.agent_id as string;

  switch (frame.event) {
    // Join snapshot; also resyncs after a reconnect.
    case "connected":
      for (const agent of (frame.agents ?? []) as AgentInfo[]) agentSubs.forEach((fn) => fn(agent));
      break;
    case "agent_started":
      agentSubs.forEach((fn) => fn(frame.agent as AgentInfo));
      break;
    // Ordered after the `agent_started` for the same agent — both ride this one
    // socket — so a handler can rely on the workspace already knowing about it.
    case "pane_request":
      paneSubs.forEach((fn) =>
        fn({
          agentId,
          initiativeId: frame.initiative_id as string,
          reason: (frame.reason as string) ?? null,
        }),
      );
      break;
    case "initiative_created":
    case "initiative_updated":
      initiativeSubs.forEach((fn) =>
        fn({
          kind: frame.event === "initiative_created" ? "created" : "updated",
          initiative: frame.initiative as Initiative,
        }),
      );
      break;
    case "initiative_deleted":
      initiativeSubs.forEach((fn) =>
        fn({ kind: "deleted", initiativeId: frame.initiative_id as string }),
      );
      break;
    // Says only *that* the store moved. The memory view owns a query string no
    // frame could reproduce, so re-running that query is the only correct refresh.
    case "memory_changed":
      memorySubs.forEach((fn) => fn(frame.initiative_id as string));
      break;
    case "output": {
      const subs = outputSubs.get(agentId);
      if (subs?.size) {
        const bytes = b64ToBytes(frame.content as string);
        subs.forEach((fn) => fn(bytes));
      }
      break;
    }
    case "status":
      statusSubs.forEach((fn) => fn(agentId, frame.status as AgentStatus));
      break;
    case "stopped": {
      // The backend's own distinction: a clean exit is `stopped`, anything else
      // `crashed`. Reporting both as "stopped" hid crashes until the next
      // refresh — and the UI now treats the two differently.
      const code = (frame.exit_code as number) ?? 0;
      statusSubs.forEach((fn) => fn(agentId, code === 0 ? "stopped" : "crashed"));
      stoppedSubs.get(agentId)?.forEach((fn) => fn(code));
      break;
    }
  }
}

/** Opens the socket if it isn't already up. Safe to call repeatedly. */
export function connect() {
  if (socket) return;

  const proto = location.protocol === "https:" ? "wss" : "ws";
  const sock = new WebSocket(`${proto}://${location.host}/ws`);
  socket = sock;

  sock.onopen = () => {
    attempt = 0;
    pending.splice(0).forEach((frame) => sock.send(frame));
  };

  sock.onmessage = (e) => {
    try {
      dispatch(JSON.parse(e.data));
    } catch {
      /* ignore malformed frame */
    }
  };

  sock.onclose = () => {
    socket = null;
    if (retry) clearTimeout(retry);
    retry = setTimeout(connect, Math.min(500 * 2 ** attempt++, 5000));
  };
}

// Queued while the socket is down so a keystroke mid-reconnect isn't dropped.
function send(frame: Record<string, unknown>) {
  const payload = JSON.stringify(frame);
  if (socket?.readyState === WebSocket.OPEN) socket.send(payload);
  else if (pending.length < 100) pending.push(payload);
}

export function sendKeys(agentId: string, data: string) {
  send({ t: "d", agent_id: agentId, d: data });
}

export function sendResize(agentId: string, cols: number, rows: number) {
  send({ t: "r", agent_id: agentId, cols, rows });
}

/** Subscribe to one agent's live output (and exit). Returns an unsubscribe function. */
export function onAgentOutput(
  agentId: string,
  handlers: { output: (bytes: Uint8Array) => void; stopped?: (code: number) => void },
): () => void {
  connect();

  const outs = outputSubs.get(agentId) ?? new Set();
  outs.add(handlers.output);
  outputSubs.set(agentId, outs);

  const stops = stoppedSubs.get(agentId) ?? new Set();
  if (handlers.stopped) stops.add(handlers.stopped);
  stoppedSubs.set(agentId, stops);

  return () => {
    outs.delete(handlers.output);
    if (handlers.stopped) stops.delete(handlers.stopped);
    if (!outs.size) outputSubs.delete(agentId);
    if (!stops.size) stoppedSubs.delete(agentId);
  };
}

/** Subscribe to agents appearing (join snapshot and later starts). */
export function onAgent(fn: (agent: AgentInfo) => void): () => void {
  agentSubs.add(fn);
  return () => agentSubs.delete(fn);
}

/** Subscribe to agents asking to be put in front of the user. */
export function onPaneRequest(fn: (req: PaneRequest) => void): () => void {
  paneSubs.add(fn);
  return () => paneSubs.delete(fn);
}

/** Subscribe to initiatives created, changed, or deleted outside this session. */
export function onInitiativeChange(fn: (change: InitiativeChange) => void): () => void {
  initiativeSubs.add(fn);
  return () => initiativeSubs.delete(fn);
}

/** Subscribe to an initiative's memory store being written to. */
export function onMemoryChange(fn: (initiativeId: string) => void): () => void {
  memorySubs.add(fn);
  return () => memorySubs.delete(fn);
}

/** Subscribe to agent status transitions. */
export function onAgentStatus(fn: (agentId: string, status: AgentStatus) => void): () => void {
  statusSubs.add(fn);
  return () => statusSubs.delete(fn);
}

/** Buffered scrollback for an agent, decoded and oldest-first. */
export async function fetchReplay(agentId: string, n = 400): Promise<Uint8Array[]> {
  try {
    const res = await fetch(`/api/agent/${encodeURIComponent(agentId)}/output?n=${n}`);
    if (!res.ok) return [];
    const body = await res.json();
    return Array.isArray(body.output) ? body.output.map(b64ToBytes) : [];
  } catch {
    return [];
  }
}
