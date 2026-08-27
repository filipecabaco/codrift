// Mirrors Codrift.Config.Keybindings actions. Labels are used by the command
// palette; the actual key bindings come from the backend (get_keybindings), so
// the user's ~/.codrift/keybindings.json applies to the web UI too.
export type ActionId =
  | "navigate_down"
  | "navigate_up"
  | "new_initiative"
  | "new_scratchpad"
  | "promote_initiative"
  | "add_dir"
  | "start_agent"
  | "start_terminal"
  | "delete"
  | "edit_context"
  | "new_context"
  | "refresh"
  | "status_prev"
  | "status_next"
  | "context_mode"
  | "diff_mode"
  | "tree_mode"
  | "toggle_diff_view"
  | "diff_all_files"
  | "quit"
  | "toggle_sidebar"
  | "sort_created"
  | "sort_recent"
  | "sort_name"
  | "sort_status"
  | "focus_left"
  | "focus_right"
  | "focus_up"
  | "focus_down"
  | "palette"
  | "start_orchestration"
  | "branch_initiative"
  | "initiative_agent"
  | "git_fetch"
  | "git_rebase"
  | "git_commit"
  | "git_push"
  | "settings"
  | "appearance"
  | "agent_profiles"
  | "setup"
  | "check_updates";

export const ACTION_LABELS: Record<ActionId, string> = {
  navigate_down: "Navigate down",
  navigate_up: "Navigate up",
  new_initiative: "New initiative",
  new_scratchpad: "New scratchpad",
  promote_initiative: "Rank scratchpad up to an initiative",
  add_dir: "Add directory",
  start_agent: "Start agent",
  start_terminal: "Start terminal",
  delete: "Delete / stop the highlighted row",
  edit_context: "Edit context",
  new_context: "New context file",
  refresh: "Refresh",
  status_prev: "Cycle status backward",
  status_next: "Cycle status forward",
  context_mode: "Context view",
  diff_mode: "Diff view",
  tree_mode: "Tree view",
  toggle_diff_view: "Toggle diff layout",
  diff_all_files: "Show all changed files",
  quit: "Quit",
  toggle_sidebar: "Toggle sidebar",
  // Phrased so every one of them matches a palette search for "sort".
  sort_created: "Sort initiatives by date created (oldest first)",
  sort_recent: "Sort initiatives by date created (newest first)",
  sort_name: "Sort initiatives by name",
  sort_status: "Sort initiatives by status (active work first)",
  focus_left: "Move focus left (pane → pane → sidebar)",
  focus_right: "Move focus right (sidebar → pane → pane)",
  focus_up: "Move focus up (stacked panes)",
  focus_down: "Move focus down (stacked panes)",
  palette: "Command palette",
  start_orchestration: "Start orchestration",
  branch_initiative: "Branch git directories for this initiative",
  initiative_agent: "Change this initiative's agent",
  git_fetch: "Git: fetch all remotes",
  git_rebase: "Git: rebase onto upstream",
  git_commit: "Git: commit everything",
  git_push: "Git: push and offer the PR link",
  settings: "Settings",
  appearance: "Settings › Appearance (theme & font)",
  agent_profiles: "Settings › Launch profiles (accounts & env)",
  setup: "Setup (register MCP server & install agent skills)",
  check_updates: "Check for updates",
};

// Actions the desktop UI actually performs. The keymap itself is wider — it is
// shared with the TUI and the backend owns it — but the palette must only offer
// commands that do something, so listing them here is the single gate.
export const PALETTE_ACTIONS: ActionId[] = [
  "navigate_down",
  "navigate_up",
  "new_initiative",
  "new_scratchpad",
  "promote_initiative",
  "add_dir",
  "start_agent",
  "start_terminal",
  "start_orchestration",
  "branch_initiative",
  "initiative_agent",
  "git_fetch",
  "git_rebase",
  "git_commit",
  "git_push",
  "delete",
  "edit_context",
  "refresh",
  "status_prev",
  "status_next",
  "context_mode",
  "diff_mode",
  "tree_mode",
  "diff_all_files",
  "toggle_sidebar",
  "sort_created",
  "sort_recent",
  "sort_name",
  "sort_status",
  "focus_left",
  "focus_right",
  "focus_up",
  "focus_down",
  "settings",
  "appearance",
  "agent_profiles",
  "setup",
  "check_updates",
  "palette",
  "quit",
];

export type Keymap = Partial<Record<ActionId, string>>;

// Fallback mirroring Codrift.Config.Keybindings defaults, used if the backend
// fetch fails. The live map (with user overrides) comes from get_keybindings.
export const DEFAULT_KEYMAP: Keymap = {
  navigate_down: "j",
  navigate_up: "k",
  new_initiative: "n",
  // A scratchpad is the thing you reach for *before* you know it is work, so it
  // carries a modifier and no cursor requirement — unlike `n`, which starts a
  // dialog. `promote_initiative` deliberately has no default binding: naming a
  // scratchpad happens once, and the palette is where once-per-session lives.
  new_scratchpad: "ctrl+n",
  add_dir: "a",
  start_agent: "s",
  start_terminal: "t",
  delete: "d",
  edit_context: "e",
  new_context: "c",
  refresh: "r",
  status_prev: "[",
  status_next: "]",
  context_mode: "1",
  diff_mode: "2",
  tree_mode: "3",
  toggle_diff_view: "v",
  diff_all_files: "*",
  quit: "ctrl+q",
  toggle_sidebar: "ctrl+b",
  // Directional focus across the whole window — and the only way out of a
  // focused terminal, so these have to carry a modifier: the pane hands ⇥ to the
  // PTY, and a bare arrow would just be typed at the agent. Never bind them to
  // esc — see Codrift.Config.Keybindings.
  focus_left: "ctrl+left",
  focus_right: "ctrl+right",
  focus_up: "ctrl+up",
  focus_down: "ctrl+down",
  palette: "ctrl+p",
  start_orchestration: "o",
  branch_initiative: "b",
  initiative_agent: "p",
  settings: "ctrl+,",
  // Git, as a row of bare keys. Bare because onCaptureKeydown eats modifier
  // combos before the PTY sees them, and taking ⌃R from a shell to mean "rebase"
  // would cost every user reverse-search. f/m/u are mnemonic; g is simply the
  // free key that keeps the four together.
  git_fetch: "f",
  git_rebase: "g",
  git_commit: "m",
  git_push: "u",
};

// spec -> action, e.g. { "j": "navigate_down", "ctrl+p": "palette" }
export function buildReverse(map: Keymap): Record<string, ActionId> {
  const out: Record<string, ActionId> = {};
  for (const [action, spec] of Object.entries(map)) {
    if (spec) out[spec] = action as ActionId;
  }
  return out;
}

// Translate a KeyboardEvent into a Codrift key spec ("ctrl+p", "j", "[", "1").
// Matches the backend's single-modifier format (parse_spec/1).
export function eventToSpec(e: KeyboardEvent): string | null {
  const k = e.key;
  if (k === "Control" || k === "Shift" || k === "Alt" || k === "Meta") return null;

  let key: string;
  if (k === "ArrowDown") key = "down";
  else if (k === "ArrowUp") key = "up";
  else if (k === "ArrowLeft") key = "left";
  else if (k === "ArrowRight") key = "right";
  else if (k === "Escape") key = "esc";
  else if (k.length === 1) key = k.toLowerCase();
  else key = k.toLowerCase();

  // One modifier max, mirroring the backend (ctrl wins; treat ⌘ as ctrl on mac).
  if (e.ctrlKey || e.metaKey) return `ctrl+${key}`;
  if (e.altKey) return `alt+${key}`;
  return key;
}

// The named keys eventToSpec emits, drawn as the glyph they carry on the key —
// "⌃←" reads as a shortcut, "⌃LEFT" reads as a variable name.
const KEY_GLYPHS: Record<string, string> = {
  left: "←",
  right: "→",
  up: "↑",
  down: "↓",
  esc: "⎋",
  enter: "⏎",
  tab: "⇥",
  space: "␣",
};

function formatKey(key: string): string {
  return KEY_GLYPHS[key] ?? (key.length === 1 ? key.toUpperCase() : key);
}

// Human-readable spec for hints, e.g. "ctrl+p" -> "⌃P", "ctrl+left" -> "⌃←".
export function formatSpec(spec: string | undefined): string {
  if (!spec) return "";
  if (spec.startsWith("ctrl+")) return "⌃" + formatKey(spec.slice(5));
  if (spec.startsWith("alt+")) return "⌥" + formatKey(spec.slice(4));
  return formatKey(spec);
}
