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

## File filter

Press `/` to activate the filter input at the top of the sidebar. All files across every directory are searched regardless of expand state. The filter mode is inferred automatically from what you type:

| Query | Mode | Matches |
|-------|------|---------|
| `router` | fuzzy | any file whose name or path contains `router` |
| `*.test.ts` | glob | shell-style wildcards (`*` = any chars, `?` = one char) |
| `/\.test\./` | regex | Elixir `Regex` — case-insensitive, strip trailing `/` |
| `#test` | tag | predefined group: test files (`_test.`, `.spec.`, `test/`) |
| `#config` | tag | config files (`.env`, `config.`, `mix.exs`) |
| `#doc` | tag | docs (`.md`, `README`, `docs/`) |
| `#schema` | tag | schema / migration files |
| `#router` | tag | router / routes files |

Unknown `#tag` falls back to substring match on the tag word.

```
┌ #test  tag  #test #config #doc … ─────┐
│ ▶ test/router_test.ex                 │
│   test/helpers/auth_test.ex           │
└────────────────────────────────────────┘
```

| Key | Action |
|-----|--------|
| `/` | Activate filter |
| any printable key | Append to query |
| `Backspace` | Delete last character |
| `Esc` | Clear filter and return to normal tree view |

While a filter is active, `j`/`k`/`↑`/`↓` navigate the filtered list and `e` opens the selected file as normal. Expand/collapse (`→`/`←`/`Space`) are suspended during filtering.

## Syntax highlighting

The preview pane maps file extensions to syntect's built-in language set via `path_to_language/1`.

| Languages | Extensions |
|-----------|-----------|
| Elixir | `.ex` `.exs` |
| Erlang | `.erl` `.hrl` |
| JavaScript / TypeScript | `.js` `.jsx` `.ts` `.tsx` |
| Python | `.py` |
| Ruby | `.rb` |
| Rust | `.rs` |
| Go | `.go` |
| Java / Kotlin | `.java` `.kt` `.kts` |
| Scala | `.scala` |
| C# | `.cs` |
| C / C++ / Objective-C | `.c` `.h` `.cpp` `.cc` `.cxx` `.hpp` `.m` |
| Haskell | `.hs` |
| OCaml | `.ml` `.mli` |
| Lua | `.lua` |
| PHP | `.php` |
| Perl | `.pl` `.pm` |
| Lisp | `.lisp` `.el` |
| R | `.r` `.R` |
| Groovy | `.groovy` |
| D | `.d` |
| Bash | `.sh` `.bash` `.zsh` `.fish` |
| SQL | `.sql` |
| JSON | `.json` |
| YAML | `.yaml` `.yml` |
| XML | `.xml` |
| HTML | `.html` |
| CSS / SCSS | `.css` `.scss` |
| Markdown | `.md` |
| Diff | `.diff` `.patch` |

TypeScript and Kotlin use JavaScript/Java highlighting (closest built-in match). Files with unrecognised extensions render as plain text.
