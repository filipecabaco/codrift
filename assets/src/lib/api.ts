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

// Extensions the backend will serve raw over `GET /api/file`; keep in step with
// `@image_mimes` in lib/codrift/files.ex — a mismatch shows the pane an <img>
// the server then refuses.
const IMAGE_EXTENSIONS = /\.(apng|avif|bmp|gif|ico|jpe?g|png|svg|webp)$/i;

/** True for a path the preview should render as a picture rather than as text. */
export function isImagePath(path: string): boolean {
  return IMAGE_EXTENSIONS.test(path);
}

/**
 * Source URL for an image inside one of the initiative's directories.
 *
 * The one thing that does not go through `rpc()`: `<img src>` is a GET, and a
 * multi-megabyte screenshot base64'd into a JSON envelope would cost a third
 * more bytes and bypass the browser's image cache. See the `/api/file` route.
 */
export function fileUrl(initiativeId: string, path: string): string {
  const q = new URLSearchParams({ initiative_id: initiativeId, path });
  return `/api/file?${q}`;
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
  /** Launch choice for this initiative — a base adapter or a profile name. */
  agent?: string | null;
  /**
   * A scratchpad: an initiative opened before there was anything to name. Same
   * machinery as any other (context folder, memory, agents) — the flag only
   * decides where the sidebar files it, and that it can be ranked up.
   */
  scratch?: boolean;
};

/** `inspect_dir`: what the "add directory" flow needs to know before committing. */
export type DirInfo = {
  path: string;
  exists: boolean;
  dir: boolean;
  /** True anywhere inside a working tree — matches how the sidebar tags a dir. */
  git: boolean;
  /** True only when `.git` sits in this directory: what a worktree needs. */
  git_root: boolean;
};

/** `dir_preview`: a README when the directory has one, otherwise a shallow tree. */
export type DirPreview =
  | { kind: "readme"; dir: string; name: string; content: string }
  | {
      kind: "tree";
      dir: string;
      entries: { name: string; path: string; dir: boolean; depth: number }[];
      truncated: boolean;
    }
  | { kind: "empty"; dir: string };

export type Agent = {
  id: string;
  adapter: string;
  status: string;
  dir: string;
  initiative_id: string;
  mode: string;
  profile?: string | null;
  /** Who started it: "user", "orchestrator", or "directed". See AgentProcess. */
  role?: string | null;
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
export const ADAPTERS = ["claude", "codex", "opencode", "gemini", "copilot", "cursor"] as const;

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
  /** Executable to run instead of the adapter's own — a wrapper script or a second install. */
  command?: string | null;
  /** Arguments appended to the adapter's own, one entry per argument. */
  args?: string[];
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

export async function getDefaultAgent(): Promise<string> {
  const res = await rpc<{ agent: string }>("get_default_agent");
  return res.agent;
}

export function setDefaultAgent(agent: string): Promise<unknown> {
  return rpc("set_default_agent", { agent });
}

/**
 * How the sidebar orders initiatives. Mirrors `Codrift.Config.Settings`.
 *
 * `created` oldest first (the default), `recent` newest first, `name` A→Z,
 * `status` active work first.
 */
export type SidebarSort = "created" | "recent" | "name" | "status";

/** The cycle order of the sidebar's sort control, and the palette's listing. */
export const SIDEBAR_SORTS: { id: SidebarSort; label: string }[] = [
  { id: "created", label: "created" },
  { id: "recent", label: "recent" },
  { id: "name", label: "name" },
  { id: "status", label: "status" },
];

export async function getSidebarSort(): Promise<SidebarSort> {
  const res = await rpc<{ sort: SidebarSort }>("get_sidebar_sort");
  return res.sort;
}

export function setSidebarSort(sort: SidebarSort): Promise<unknown> {
  return rpc("set_sidebar_sort", { sort });
}

/**
 * Opens an unnamed scratchpad, optionally against `dir`.
 *
 * The backend names it — where it was opened, and when — so the caller never
 * has to invent one. Pass the directory the user was looking at and the
 * scratchpad has something to explore; omit it and it runs folderless in its
 * own context folder.
 */
export function createScratchpad(dir?: string): Promise<Initiative> {
  return rpc<Initiative>("create_scratchpad", dir ? { dirs: [dir] } : {});
}

/**
 * Ranks a scratchpad up into a real initiative. Nothing moves — the same
 * context folder, memory store and running agents carry over.
 */
export function promoteInitiative(initiativeId: string, name: string): Promise<Initiative> {
  return rpc<Initiative>("promote_initiative", { initiative_id: initiativeId, name });
}

export function setInitiativeAgent(initiativeId: string, agent: string): Promise<Initiative> {
  return rpc<Initiative>("set_initiative_agent", { initiative_id: initiativeId, agent });
}

// The folder the directory picker starts browsing from. `null` until the user
// sets one, at which point the picker still falls back to `~`.
export async function getWorkspaceDir(): Promise<string | null> {
  const res = await rpc<{ path: string | null }>("get_workspace_dir");
  return res.path;
}

/** Passing an empty path clears the preference. */
export async function setWorkspaceDir(path: string): Promise<string | null> {
  const res = await rpc<{ path: string | null }>("set_workspace_dir", { path });
  return res.path;
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
  /** Unix seconds the access token dies at. Absent for tokens that never expire. */
  expires_at?: number | null;
  /**
   * Connected, but the grant is spent and no refresh token can renew it — the
   * user has to run the flow again. Distinct from `!connected`: the row still
   * shows as a configured service, it just can't be used until reconnected.
   */
  needs_reauth?: boolean;
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

type TauriGlobal = { core?: { invoke: (cmd: string, args?: unknown) => Promise<unknown> } };

export async function quitApp(): Promise<void> {
  const tauri = (window as unknown as { __TAURI__?: TauriGlobal }).__TAURI__;
  if (tauri?.core?.invoke) {
    try {
      await tauri.core.invoke("quit_app");
    } catch (e) {
      // `quit_app` has to be registered in the Rust shell's invoke_handler. When
      // it isn't, the invoke rejects and Quit does nothing at all — report it
      // instead of leaving the user pressing a dead button.
      throw new Error(`Couldn't quit: ${(e as Error)?.message ?? e}`);
    }
    return;
  }
  window.close();
}

/** The native menu's Quit item asks the page first — see src-tauri/src/main.rs. */
export const QUIT_REQUESTED = "codrift:quit-requested";

/**
 * Every other native menu item arrives here, with the command id in `detail`.
 *
 * The shell implements none of them: it names the commands, gives them
 * accelerators, and hands them straight back to the page that already knows how
 * to run them. See `runMenuCommand` in App.svelte.
 */
export const MENU_EVENT = "codrift:menu";

/**
 * Asks every mounted agent terminal to repaint itself.
 *
 * A window event rather than a prop or an imperative handle: the terminals are
 * rendered per pane inside a snippet, and a split has two of them. Broadcasting
 * reaches whichever exist without App.svelte having to hold a reference to each.
 */
export const REDRAW_TERMINALS = "codrift:redraw-terminals";

/**
 * Asks the terminal showing `agentId` to paste `text` into it.
 *
 * Broadcast for the same reason as `REDRAW_TERMINALS`, plus one of its own: a
 * paste has to go through xterm rather than straight down the socket, because
 * only xterm knows whether the program on the other end turned bracketed-paste
 * mode on. See the drop handler in AgentTerminal.
 */
export const PASTE_INTO_AGENT = "codrift:paste-into-agent";
export type PasteRequest = { agentId: string; text: string };

/** Asks the terminal showing `agentId` to clear its buffer — ⌘K. */
export const CLEAR_TERMINAL = "codrift:clear-terminal";
export type AgentTarget = { agentId: string };

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

/** Mirrors `Codrift.Integration.Error.kind/0`. */
export type IntegrationErrorKind =
  | "auth"
  | "forbidden"
  | "not_found"
  | "rate_limited"
  | "http"
  | "network";

export type IntegrationError = {
  service: string;
  reason: string;
  /** `"auth"` is the only kind the user can fix — it earns a Reconnect button. */
  kind: IntegrationErrorKind;
};

export type AssignedWork = {
  items: AssignedItem[];
  errors: IntegrationError[];
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

/** `update_status`: whether a newer release exists, and who is allowed to install it. */
export type UpdateStatus = {
  current: string;
  latest: string | null;
  /** False whenever there is nothing to offer — no newer release, or no way to install one. */
  available: boolean;
  /**
   * Who owns the installed app. `unknown` means the desktop shell never told the
   * backend where the app lives (a dev build), so no update is offered at all.
   */
  manager: "homebrew" | "self" | "unknown";
  cli_manager: "homebrew" | "self" | "missing" | "unknown";
  brew_command: string;
  /** Set when the version probe failed; the UI stays silent rather than complaining. */
  error: string | null;
};

/** `update_progress`: one running update, as the runner sees it. */
export type UpdateProgress = {
  stage: "idle" | "running" | "done" | "failed";
  mode: "homebrew" | "self" | null;
  version: string | null;
  log: string[];
  error: string | null;
  /** `done` never means "installed" — the app has to quit for the handoff to run. */
  quit_required: boolean;
  log_path: string;
};

export function updateStatus(): Promise<UpdateStatus> {
  return rpc<UpdateStatus>("update_status");
}

export function startUpdate(): Promise<UpdateProgress> {
  return rpc<UpdateProgress>("start_update");
}

export function updateProgress(): Promise<UpdateProgress> {
  return rpc<UpdateProgress>("update_progress");
}
