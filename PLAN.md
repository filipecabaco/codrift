# Codrift — AI Coding Companion TUI

## Overview

Terminal UI application for driving AI coding agents across multiple working
directories grouped under a single "initiative". First-class diff viewing,
keyboard-driven actions, embedded web server for rich views, MCP server for
external tool integration. Full terminal emulator pane for arbitrary shell
access. SQLite for session persistence; SQLite FTS5 for per-initiative memory.

**Stack:** Elixir · Francis (web layer only) · ex_ratatui · Git (diffs) · SQLite (Exqlite)

**Docs:** [Architecture](docs/architecture.md) · [Modules](docs/modules.md) · [Decisions](docs/decisions.md)

---

## Build Order

### ✅ Done — Backend foundation

| # | Step | Notes |
|---|------|-------|
| 1 | Project skeleton | Francis + supervision tree, port 7437 |
| 2 | Initiative model + persistence | GenServer + JSON file; status lifecycle (planning/ongoing/done/archived) |
| 3 | Agent process (Port → CLI) | DynamicSupervisor + behaviour, Registry |
| 4 | Diff module | `git diff` parser, pure functions |
| 5 | Code quality | Credo clean, `@doc`/`@moduledoc` throughout |

### ✅ Done — TUI core

| # | Step | Notes |
|---|------|-------|
| 6 | Full VT100 emulation | Pure Elixir `Codrift.TUI.VT100`: cell-grid rendering, SGR colors, cursor movement, erase, scroll regions, IL/DL, SU/SD, OSC/DCS/APC skip, incomplete-sequence carry buffer, `to_text/2` → `%ExRatatui.Text{}` |
| 7 | TUI shell | `mix codrift.tui`, sidebar + output + diff panes |
| 8 | PTY agents + terminals | `erlexec :pty`, direct keypress forwarding, `t` key opens `$SHELL` pane |
| 9 | Task.Supervisor for async starts | `Codrift.TaskSupervisor` wraps agent start to avoid blocking TUI loop |
| 10 | Graceful shutdown | `terminate/2` kills all agents + terminals on TUI exit |
| 11 | Mouse support | Scroll (sidebar navigation / PTY arrow keys / pane scroll) + left-click focus switch |

### ✅ Done — TUI navigation & context

| # | Step | Notes |
|---|------|-------|
| 12 | Multi-dir sidebar | initiative → dir → agent hierarchy |
| 13 | Cursor-driven pane | initiative → overview, dir → git log, agent/terminal → ANSI output |
| 14 | Initiative management | `n` new, `a` add-dir, `s` start-agent, `d` delete/stop (context), `Ctrl+P` palette |
| 15 | Multiple agents + terminals per dir | `dir_entries/3` maps all agents under each dir into `{:agent, ...}` sidebar rows |
| 16 | Initiative root agents | `context_dir_entries/3` catches agents whose dir is the initiative context path |
| 17 | Initiative status lifecycle | `:planning → :ongoing → :done → :archived`; cycle with `[`/`]` keys |
| 18 | Context folder + CLAUDE.md | Each initiative gets `~/.codrift/initiatives/{id}/`; CLAUDE.md symlink shared to all dirs |
| 19 | In-TUI context file editor | `c` to create, `e` to open textarea editor, autosave every 500 ms, Esc to save & close |

### ✅ Done — Diff

| # | Step | Notes |
|---|------|-------|
| 20 | Web diff view | `/diff.html` + SSE `/events/initiative/:id` |
| 21 | Diff viewer overhaul | Sidebar transforms in diff mode; cursor-driven content pane; unified + coloured split view; `v` toggle; `*` reset. See [Diff Mode](docs/diff-mode.md). |

### ✅ Done — Agents & sessions

| # | Step | Notes |
|---|------|-------|
| 22 | Multi-agent per initiative | Registry lookup + initiative filter |
| 23 | Session persistence | `Codrift.SessionStore` (SQLite via Exqlite) stores Claude session UUIDs per initiative+dir; agents auto-detect session file and `--resume` on next start |
| 24 | Session auto-restart | TUI re-launches Claude agents from saved sessions on boot (`:autostart_sessions`) |
| 31 | Session store: multi-agent per dir | Schema keyed by `agent_id TEXT PRIMARY KEY`; `save/4`, `get_by_agent/1`, `list_by_dir/2`; migration drops old `(initiative_id, dir)` PK on first boot |

### ✅ Done — Integrations

| # | Step | Notes |
|---|------|-------|
| 25 | MCP server | HTTP+SSE transport, `mix codrift.mcp.install` |
| 26 | MCP initiative tools | `create_initiative`, `add_dir`, `delete_initiative` |

### ✅ Done — Polish

| # | Step | Notes |
|---|------|-------|
| 27 | Remove emoji from TUI | Replaced `📁`/`📂` → `▸`, `✏` → `~`, `⚠` → `!`; all Unicode line-art kept |
| 28 | Mode bar labels | `1: Context │ 2: Diff` — symmetric ASCII, no Unicode ball |
| 29 | Sidebar collapse | `Ctrl+B` toggles sidebar; PTY screens resize immediately; focus shifts to main on collapse |
| 30 | Command palette expansion | Toggle Sidebar, Context/Diff View, Toggle Diff Unified/Split, Diff All Files, Edit Context File, Cycle Status — grouped with section comments |

### ✅ Done — Config layer

| # | Step | Notes |
|---|------|-------|
| 32 | Keybinding config layer | `Codrift.Config.Keybindings` — loads `~/.codrift/keybindings.json`, merges over defaults; TUI dispatch uses reverse map; palette hints and footer status bar reflect configured keys |
| 33 | Theme chooser | `Codrift.Config.Theme` — loads `~/.codrift/theme.json`; named themes: `default`, `dracula`, `nord`, `solarized`, `tokyo_night`; controls border colours, sidebar highlight, diff border, and CodeBlock syntax theme |

### ✅ Done — Memory store, CLI & distribution

| # | Step | Notes |
|---|------|-------|
| 34 | Per-initiative memory store + CLI | `Codrift.Memory` (FTS5, pure module); `Codrift.CLI.{TUI,MCP,Initiative,Session,Memory}`; `rel/commands/` shell scripts; `releases:` in `mix.exs`; Mix tasks delegate to CLI modules; 5 new MCP tools. See [Memory](docs/memory.md). |
| 35 | Distribution & installation | `install.sh` (curl-pipe-sh, 4-platform detection, `~/.local/share/codrift` + symlink); `.github/workflows/release.yml` (matrix: macOS ARM/Intel + Linux x86_64/ARM64 via `erlef/setup-beam`, `softprops/action-gh-release`) |
| 36 | GitHub Actions CI | `.github/workflows/ci.yml` — `mix deps.get` → `compile --warnings-as-errors` → `format --check-formatted` → `credo --strict` → `test`; deps + build cache keyed on `mix.lock` |

### ✅ Done — Safe paste + input hardening

| # | Step | Notes |
|---|------|-------|
| 41 | Safe paste + input hardening | Full 1:1 paste experience via bracketed paste mode. Forked `ex_ratatui` as `vendor/ex_ratatui` git submodule; NIF extended to deliver `Event::Paste(String)` → `%ExRatatui.Event.Paste{content}` atomically. `EnableBracketedPaste` in `init_terminal` (Rust), `DisableBracketedPaste` in `restore_terminal` and `Drop`. TUI: `handle_event(%Paste{})` appends whole string to buffer; PTY mode forwards as raw `\r`-normalised bytes. Additional fixes: Tab inserts `\t` in main non-PTY; Shift+Enter inserts `\n`; multi-byte Unicode input handled by `byte_size > 1 and <= 4` guard; quit key changed from `q` to `Ctrl+Q`; `paste_mode` (`Ctrl+V`) toggle preserved as fallback. |

### ✅ Done — Sidequests

| Sidequest | Notes |
|-----------|-------|
| Reduce TUI flickering | Five-layer fix: (1) `AgentProcess.resize` dedup via `last_size`; (2) resize only selected PTY; (3) `apply_resize` no-op guard + `render?: false`; (4) skip 600 ms nudge when agent has existing output; (5) cancel stale nudge/restore timers. NIF: `BeginSynchronizedUpdate`/`EndSynchronizedUpdate` wrap every draw. See [flickering](docs/flickering.md). |

### ✅ Done — External integrations

| # | Step | Notes |
|---|------|-------|
| 39 | External integrations | `Codrift.Integration` behaviour + 9 adapters (GitHub Issues/Projects, Linear Issues/Projects, GitLab, Jira, Notion, Shortcut, Asana); `Codrift.OAuth` (PKCE browser, device flow, guided token); `Codrift.OAuth.StateStore` GenServer; `Codrift.OAuth.Config`; 3 web routes (`/oauth/start/:service`, `/oauth/callback/:service`, `/oauth/status`); 5 new MCP tools; `Codrift.CLI.Integration`. See [Integrations](docs/integrations.md). |

### ✅ Done — Git Worktrees

| # | Step | Notes |
|---|------|-------|
| 37 | Git worktrees per initiative | Opt-in per-dir; `Codrift.Initiative.DirEntry` replaces plain strings in `dirs`; `Codrift.Worktree` (pure module); per-initiative `worktree_default` flag; `W` key + palette to toggle; initiative and dir panes show worktree status; 291 tests. See [Worktrees](docs/worktrees.md). |

---

### ✅ Done — Worktree UX improvements

| # | Step | Notes |
|---|------|-------|
| 42 | Worktree UX improvements | Sidebar `[wt]`/`[wt*]` label per dir (yellow when dirty); `Worktree.status/1` (branch, dirty?); `codrift initiative worktree-enable/disable/status` CLI commands; 296 tests. See [Worktrees](docs/worktrees.md). |

### ✅ Done — Tree view

| # | Step | Notes |
|---|------|-------|
| 44 | Tree view (mode 3) | Third mode (`3` key, `Ctrl+P` palette). **Sidebar** shows the file-tree of all dirs in the active initiative (WidgetList, sidebar border/highlight). **Main pane** shows a syntax-highlighted `CodeBlock` preview of the selected file; directory entries show a path hint; empty entries show a placeholder. `j`/`k`, arrows, and mouse wheel over the sidebar navigate the tree cursor and update the preview. `Enter`/`Space` toggle expand/collapse dirs; `→`/`←` expand/collapse; `e` opens the file in the embedded vim PTY. `n` new file/dir, `d` delete with confirmation. Entering tree mode sets sidebar focus automatically. `Tab` cycles focus to the main pane for preview scrolling. `path_to_language/1` maps 20+ extensions to syntax themes. Mode bar shows `1: Context │ 2: Diff │ 3: Tree`. 307 tests. |

### ✅ Done — Embedded editor

| # | Step | Notes |
|---|------|-------|
| 45 | Embedded `$EDITOR` in main pane | Dropped the custom textarea editor (step 19) and the suspend-TUI approach. `e` key spawns the editor as an erlexec PTY inside the main pane — identical to how Terminal agents work. `open_in_editor/2` calls `:exec.run([editor_bin, path], [:pty, {:winsz, {rows, cols}}, :stdin, {:stdout, self()}, :monitor, {:env, [...]}])`. Output streams as `{:stdout, ospid, data}` → `VT100.process` → re-render. All keypresses forwarded raw via `key_to_raw/1` + `:exec.send`. Resize events send `:exec.winsz` and resize the VT100 screen. On exit (`{:DOWN, ospid, ...}`), vim_editor cleared, sidebar reloaded. Key details: `{:winsz, {rows, cols}}` must be a startup option (not post-spawn) so vim sees correct dimensions on its first `ioctl`; `System.find_executable` used to resolve absolute editor path before passing to erlexec. Editor selection: reads `$EDITOR` env var, falls back to `vim`. `e` in tree mode opens any file at the tree cursor; same `open_in_editor/2` covers both context files and tree files. Future step adds `editor` key to `~/.codrift/settings.json`. |

### ⬜ Upcoming

| # | Step | Notes |
|---|------|-------|
| 43 | Additional CLI adapters | Codex CLI, Opencode, Cursor Agent, Gemini CLI, Copilot CLI, Amp, Goose, Aider (complete). See *Upcoming: Additional CLI Adapters* below. |
| 46 | Split panes | **Pane layout engine.** Any main-area pane can be split horizontally (`Ctrl+\`) or vertically (`Ctrl+-`). Each resulting pane is an independent *view slot* that can hold any of: a sidebar item (agent output, terminal, diff), a new spawned agent, or a new terminal (`$SHELL`). Pane focus cycles with `Ctrl+W` (forward) / `Ctrl+Shift+W` (backward); focused pane gets a highlighted border. Closing a pane (`Ctrl+X`) merges its space back into the neighbour. Layout is pure data (`%PaneNode{split: :h | :v, ratio: float, left: pane, right: pane}` / `%PaneLeaf{type, ref}`) — no processes, just a binary tree rendered recursively into a bounding box. Pane content is driven by the existing `render_*` helpers; resize broadcasts go only to PTY leaves within the visible tree. Palette entries: *Split Horizontal*, *Split Vertical*, *Close Pane*, *Focus Next Pane*. |
| 47 | Website | Landing page: hero + install one-liner, feature bullets, asciinema demo, GitHub link. Domain: `codrift.sh`. |
| 48 | Multi-buffer search in tree view | **Project-wide search and edit.** `/` in tree mode opens a search prompt; results render as a single virtual buffer of file excerpts — one block per match, separated by `── path/to/file:line ──` headers. Users edit results directly; on save (`Ctrl+S` or `Enter` confirmation), changes are batch-applied back to source files. Supports regex via `:re` flag. Implemented as `Codrift.TUI.MultiBuffer`: a list of `%{file, line, col_start, col_end, text}` fragments compiled into a renderable pane. Edits are tracked per-fragment; `MultiBuffer.apply/1` writes each diff back via `File.write/2`. Keyboard: `n`/`N` jump between match groups; `Ctrl+R` re-run search; `Esc` closes without applying. Closest Vim analogue is nvim-spectre / quickfix + `:cfdo %s///g`; Zed calls this a *multibuffer*. No external process needed — all in-process. |

---

## Upcoming: Additional CLI Adapters (Step 38)

The `Codrift.Agent` behaviour already abstracts all CLI differences. Adding a new
adapter is ~40 lines under `lib/codrift/agent/adapters/` plus registration in the TUI picker.

### Behaviour recap (no changes needed)

```elixir
@callback cmd() :: String.t()
@callback mode() :: :pty | :interactive | :once
@callback args(dir, context_opts) :: [String.t()]
@callback args_continue(dir) :: [String.t()]
@callback env(dir) :: [{String.t(), String.t()}]
@callback parse_status(data) :: agent_status | nil
```

### Adapters planned

| CLI | Mode | Notes |
|-----|------|-------|
| **OpenAI Codex CLI** (`codex`) | `:pty` | `codex` interactive REPL; pass `--cwd <dir>` |
| **Opencode** (`opencode`) | `:pty` | TUI-first agent; full PTY required |
| **Cursor Agent** (`cursor`) | `:pty` | Headless Cursor via `cursor --agent`; experimental |
| **Gemini CLI** (`gemini`) | `:pty` | Google's `gemini` CLI (OSS, released 2025); `--resume` flag TBD |
| **GitHub Copilot CLI** (`gh copilot`) | `:interactive` | Pipe-friendly; `gh copilot suggest` / `gh copilot explain` |
| **Amp** (`amp`) | `:pty` | Sourcegraph's Amp agent |
| **Goose** (`goose`) | `:pty` | Block's Goose agent; `goose run` |
| **Aider** | `:interactive` | Already partially implemented; complete `args_continue/1` |

### TUI changes

- Agent picker (`s` key modal) lists all registered adapters, not just Claude
- Each sidebar `:agent` row shows a short adapter tag (e.g. `claude`, `codex`)
- `save_all_sessions/1` guards with `adapter == Claude`; extend to any adapter returning a non-nil session UUID (add `supports_resume?/0` callback)

**No changes to `AgentProcess`, `AgentSupervisor`, `SessionStore`, or the supervision tree.**
