import { markOnline, markOffline } from "./connection.svelte";

// Single entry point to the backend's shared operation layer (`Codrift.Core`),
// exposed at POST /api/rpc. Every product capability — initiatives, agents,
// memory, conductor, integrations — is reachable through this one call.
export async function rpc<T = unknown>(
  name: string,
  args: Record<string, unknown> = {},
): Promise<T> {
  let res: Response;
  try {
    res = await fetch("/api/rpc", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name, args }),
    });
  } catch {
    // Transport failure (server stopped, offline) — distinct from an API error
    // that came back with a status. Flag it so the UI can show a reconnect banner.
    markOffline();
    throw new Error("Can't reach the Codrift server — it may have stopped.");
  }
  markOnline();
  const body = await res.json();
  if (!res.ok) {
    throw new Error(body?.error ?? `rpc ${name} failed (${res.status})`);
  }
  return body.ok as T;
}

export type Initiative = {
  id: string;
  name: string;
  status: "planning" | "ongoing" | "done" | "archived";
  dirs: { path: string; worktree_enabled?: boolean }[];
  created_at: string;
  context_path?: string;
};

export type Agent = {
  id: string;
  adapter: string;
  status: string;
  dir: string;
  initiative_id: string;
  mode: string;
};

export type DiffLine = { type: "add" | "remove" | "context"; content: string };
export type DiffHunk = { header: string; lines: DiffLine[] };
export type DiffFile = {
  path: string;
  old_path: string | null;
  additions: number;
  deletions: number;
  hunks: DiffHunk[];
};

export type MemoryEntry = {
  id: number;
  chunk_type: string;
  content: string;
  source: string;
  rank?: number;
};

// Adapters that can be launched from the UI (terminal is started internally only).
export const ADAPTERS = ["claude", "codex", "opencode", "gemini", "copilot"] as const;
