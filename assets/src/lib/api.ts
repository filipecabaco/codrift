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
  /** `git` is derived per request by the backend, not stored. */
  dirs: {
    path: string;
    worktree_enabled?: boolean;
    worktree_path?: string;
    /** Set when the directory is checked out on the initiative's branch. */
    branch?: string;
    git?: boolean;
  }[];
  created_at: string;
  context_path?: string;
  /** Set when the initiative was imported from an issue tracker. */
  integration?: { service: string; item_id: string; url: string | null };
};

export type Agent = {
  id: string;
  adapter: string;
  status: string;
  dir: string;
  initiative_id: string;
  mode: string;
  profile?: string | null;
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

// A launch profile: a named binding of a base adapter + env overrides (e.g.
// CLAUDE_CONFIG_DIR) so the same tool can run under different accounts/folders.
export type AgentProfile = { name: string; adapter: string | null };

export function listAgentProfiles(): Promise<AgentProfile[]> {
  return rpc<AgentProfile[]>("list_agent_profiles");
}

// The same profile with the env it sets — what the Profiles view edits.
export type AgentProfileConfig = {
  name: string;
  adapter: string;
  env: Record<string, string>;
};

export async function getAgentProfiles(): Promise<AgentProfileConfig[]> {
  const res = await rpc<{ profiles: AgentProfileConfig[] }>("get_agent_profiles");
  return res.profiles;
}

export function saveAgentProfile(
  profile: AgentProfileConfig & { previous_name?: string },
): Promise<AgentProfileConfig> {
  return rpc<AgentProfileConfig>("save_agent_profile", { ...profile });
}

export function deleteAgentProfile(name: string): Promise<unknown> {
  return rpc("delete_agent_profile", { name });
}

// The variable each tool reads for "which account/config folder am I?", used to
// prefill a new profile. Adapters without a documented one start with no rows.
export const PROFILE_CONFIG_VAR: Record<string, string> = {
  claude: "CLAUDE_CONFIG_DIR",
  codex: "CODEX_HOME",
};

// ── Integrations / OAuth ────────────────────────────────────────────────────

export type OAuthFlow = "pkce_browser" | "device_flow";

export type OAuthService = {
  connected: boolean;
  oauth_supported: boolean;
  flow: OAuthFlow;
};

export type OAuthStatus = { services: Record<string, OAuthService> };

// Result shapes returned by start_oauth_flow, discriminated by `flow`.
export type StartFlowResult =
  | { flow: "pkce_browser"; service: string; auth_url: string; message: string }
  | {
      flow: "device_flow";
      service: string;
      user_code: string;
      verification_uri: string;
      message: string;
    };

export function oauthStatus(): Promise<OAuthStatus> {
  return rpc<OAuthStatus>("get_oauth_status");
}

export function startOAuthFlow(service: string): Promise<StartFlowResult> {
  return rpc<StartFlowResult>("start_oauth_flow", { service });
}

export function revokeOAuthToken(service: string): Promise<unknown> {
  return rpc("revoke_oauth_token", { service });
}

// The Tauri webview can't launch the system browser, so the backend (same
// machine) opens it for us. In a plain browser this is still harmless.
export function openUrl(url: string): Promise<unknown> {
  return rpc("open_url", { url });
}

export type AssignedItem = {
  service: string;
  id: string;
  title: string;
  url: string;
  status: string | null;
  assignee: string | null;
  labels: string[];
  /** Why this item is in the user's queue: "assigned", "created", … */
  relation: string;
  imported: boolean;
  initiative_id: string | null;
};

export type AssignedWork = {
  items: AssignedItem[];
  errors: { service: string; reason: string }[];
};

export function listAssignedItems(): Promise<AssignedWork> {
  return rpc<AssignedWork>("list_assigned_items");
}

export function importFromIntegration(
  service: string,
  itemId: string,
): Promise<Initiative & { existing: boolean }> {
  return rpc<Initiative & { existing: boolean }>("import_from_integration", {
    service,
    item_id: itemId,
  });
}

// Friendly display metadata. Services not listed fall back to a title-cased key.
export const SERVICE_META: Record<string, { label: string; blurb: string }> = {
  linear: { label: "Linear", blurb: "Issues" },
  linear_projects: { label: "Linear Projects", blurb: "Projects & milestones" },
  github: { label: "GitHub", blurb: "Issues & pull requests" },
  github_projects: { label: "GitHub Projects", blurb: "Project boards" },
  gitlab: { label: "GitLab", blurb: "Issues & merge requests" },
};
