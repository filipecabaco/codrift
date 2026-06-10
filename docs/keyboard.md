# Keyboard Reference

All bindings are configurable in `~/.codrift/keybindings.json`. The `Ctrl+P` command palette shows the current binding next to every action.

## Global

| Key | Action |
|-----|--------|
| `j` / `k` | Move sidebar cursor down / up |
| `↑` / `↓` | Move sidebar cursor up / down |
| `1` | Switch to Context view |
| `2` | Switch to Diff view |
| `3` | Switch to Tree view |
| `Ctrl+P` | Open command palette |
| `Ctrl+B` | Toggle sidebar |
| `Ctrl+D` | Scroll down half-page |
| `Ctrl+U` | Scroll up half-page |
| `Ctrl+Q` | Quit |

## Initiatives & agents

| Key | Action |
|-----|--------|
| `n` | New initiative |
| `a` | Add directory to current initiative |
| `s` | Start agent picker (Claude / Codex / Opencode / Gemini / Copilot / Terminal) |
| `d` | Delete initiative / stop agent (context-sensitive) |
| `[` | Cycle initiative status backward (`archived → done → ongoing → planning`) |
| `]` | Cycle initiative status forward (`planning → ongoing → done → archived`) |
| `W` | Toggle git worktree for current directory entry |
| `P` | Promote temporary initiative to a named one |

## Context view

| Key | Action |
|-----|--------|
| `c` | Create a new context file in the initiative folder |
| `e` | Open context file in `$EDITOR` (embedded PTY) |

## Diff view

| Key | Action |
|-----|--------|
| `v` | Toggle unified ↔ split diff layout |
| `r` | Refresh diff |
| `*` | Reset to show all files |

## Tree view

| Key | Action |
|-----|--------|
| `Enter` / `Space` | Expand / collapse directory node |
| `→` | Expand directory node |
| `←` | Collapse directory node |
| `e` | Open file at cursor in `$EDITOR` (embedded PTY) |
| `n` | Create new file or directory (trailing `/` → directory) |
| `d` | Delete file or directory (confirmation prompt) |
| `Tab` | Cycle focus between tree sidebar and preview pane |

## PTY / agent pane

| Key | Action |
|-----|--------|
| `t` | Open a new `$SHELL` terminal pane |
| Any printable key | Forwarded raw to the active PTY |
| Paste | Forwarded via bracketed paste (atomically, no key-by-key simulation) |
| `Ctrl+V` | Paste mode toggle (fallback for terminals without bracketed paste support) |
| `Shift+Enter` | Insert newline (`\n`) in non-PTY text input |
| `Tab` | Insert tab character (`\t`) in non-PTY text input |

## Mouse

| Action | Effect |
|--------|--------|
| Scroll over sidebar | Move sidebar cursor |
| Scroll over PTY pane | Send arrow-key sequences to PTY |
| Scroll over main pane | Scroll content |
| Left-click | Switch focus to clicked pane |

## Configuring keybindings

Create `~/.codrift/keybindings.json` with any subset of the default map:

```json
{
  "quit":            "ctrl+q",
  "palette":         "ctrl+p",
  "toggle_sidebar":  "ctrl+b",
  "new":             "n",
  "add_dir":         "a",
  "start_agent":     "s",
  "delete":          "d",
  "toggle_worktree": "W",
  "status_prev":     "[",
  "status_next":     "]",
  "context_view":    "1",
  "diff_view":       "2",
  "tree_view":       "3",
  "toggle_diff":     "v",
  "refresh_diff":    "r",
  "diff_all":        "*",
  "edit_context":    "e",
  "create_context":  "c"
}
```

Unknown keys are ignored; missing keys fall back to defaults.
