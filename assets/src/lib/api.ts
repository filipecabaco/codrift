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

// ── Integrations / OAuth ────────────────────────────────────────────────────

export type OAuthFlow = "pkce_browser" | "device_flow" | "guided_token";

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
    }
  | { flow: "guided_token"; service: string; instructions: string; message: string };

export function oauthStatus(): Promise<OAuthStatus> {
  return rpc<OAuthStatus>("get_oauth_status");
}

export function startOAuthFlow(service: string): Promise<StartFlowResult> {
  return rpc<StartFlowResult>("start_oauth_flow", { service });
}

export function saveGuidedToken(service: string, token: string): Promise<unknown> {
  return rpc("save_guided_token", { service, token });
}

export function revokeOAuthToken(service: string): Promise<unknown> {
  return rpc("revoke_oauth_token", { service });
}

// The Tauri webview can't launch the system browser, so the backend (same
// machine) opens it for us. In a plain browser this is still harmless.
export function openUrl(url: string): Promise<unknown> {
  return rpc("open_url", { url });
}

// Friendly display metadata. Services not listed fall back to a title-cased key.
export const SERVICE_META: Record<string, { label: string; blurb: string }> = {
  linear: { label: "Linear", blurb: "Issues" },
  linear_projects: { label: "Linear Projects", blurb: "Projects & milestones" },
  github: { label: "GitHub", blurb: "Issues & pull requests" },
  github_projects: { label: "GitHub Projects", blurb: "Project boards" },
  gitlab: { label: "GitLab", blurb: "Issues & merge requests" },
  jira: { label: "Jira", blurb: "Issues" },
  notion: { label: "Notion", blurb: "Pages & databases" },
};
