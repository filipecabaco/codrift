// Mirrors Codrift.Config.Keybindings actions. Labels are used by the command
// palette; the actual key bindings come from the backend (get_keybindings), so
// the user's ~/.codrift/keybindings.json applies to the web UI too.
export type ActionId =
  | "navigate_down"
  | "navigate_up"
  | "new_initiative"
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
  | "palette"
  | "start_orchestration";

export const ACTION_LABELS: Record<ActionId, string> = {
  navigate_down: "Navigate down",
  navigate_up: "Navigate up",
  new_initiative: "New initiative",
  add_dir: "Add directory",
  start_agent: "Start agent",
  start_terminal: "Start terminal",
  delete: "Delete / stop selection",
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
  palette: "Command palette",
  start_orchestration: "Start orchestration",
};

export type Keymap = Partial<Record<ActionId, string>>;

// Fallback mirroring Codrift.Config.Keybindings defaults, used if the backend
// fetch fails. The live map (with user overrides) comes from get_keybindings.
export const DEFAULT_KEYMAP: Keymap = {
  navigate_down: "j",
  navigate_up: "k",
  new_initiative: "n",
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
  palette: "ctrl+p",
  start_orchestration: "o",
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
  else if (k === "Escape") key = "esc";
  else if (k.length === 1) key = k.toLowerCase();
  else key = k.toLowerCase();

  // One modifier max, mirroring the backend (ctrl wins; treat ⌘ as ctrl on mac).
  if (e.ctrlKey || e.metaKey) return `ctrl+${key}`;
  if (e.altKey) return `alt+${key}`;
  return key;
}

// Human-readable spec for hints, e.g. "ctrl+p" -> "⌃P", "j" -> "J".
export function formatSpec(spec: string | undefined): string {
  if (!spec) return "";
  if (spec.startsWith("ctrl+")) return "⌃" + spec.slice(5).toUpperCase();
  if (spec.startsWith("alt+")) return "⌥" + spec.slice(4).toUpperCase();
  return spec.length === 1 ? spec.toUpperCase() : spec;
}
