# Tree View (Mode 3)

Press `3` (or select *Tree View* from `Ctrl+P`) to enter tree mode.

## Overview

Tree mode replaces the sidebar with a file-tree of all directories in the active initiative. The main pane shows a syntax-highlighted preview of the selected file.

```
┌──────────────────┬───────────────────────────────────────────┐
│ ▸ ~/projects/api │  1  defmodule MyApp.Router do              │
│   ├ router.ex    │  2    use Phoenix.Router                   │
│   ├ config/      │  3    ...                                  │
│   └ lib/         │                                            │
└──────────────────┴───────────────────────────────────────────┘
```

## Navigation

| Key | Action |
|-----|--------|
| `j` / `k` / `↑` / `↓` | Move cursor |
| `Enter` / `Space` | Expand / collapse directory |
| `→` | Expand directory |
| `←` | Collapse directory |
| `Tab` | Cycle focus between sidebar tree and preview pane |
| Mouse wheel | Scroll sidebar or preview (depending on focus) |

## File operations

| Key | Action |
|-----|--------|
| `e` | Open file at cursor in `$EDITOR` (embedded PTY in main pane) |
| `n` | New file or directory (prompt for name; trailing `/` creates a dir) |
| `d` | Delete file or directory (confirmation required) |

## Embedded editor

`e` spawns `$EDITOR` (falling back to `vim`) as a PTY inside the main pane. The editor session behaves identically to a Terminal agent: full VT100 emulation, live output, raw keypress forwarding, and correct dimensions on first `ioctl`.

On exit, the tree sidebar reloads automatically.

## Syntax highlighting

The preview pane maps file extensions to syntax themes via `path_to_language/1`. Supported extensions include:

`.ex` `.exs` `.erl` `.hrl` `.js` `.ts` `.jsx` `.tsx` `.py` `.rb` `.go` `.rs` `.c` `.cpp` `.h` `.java` `.json` `.yaml` `.yml` `.toml` `.html` `.css` `.sh` `.md`

Files with unrecognised extensions render as plain text.

## Project-wide search (upcoming)

`/` in tree mode will open a multi-buffer search prompt (step 48 in the plan). Results render as a single virtual buffer of file excerpts; edits are batch-applied back to source files on save.
