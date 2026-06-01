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

### ⬜ Upcoming

| # | Step | Notes |
|---|------|-------|
| 38 | Additional CLI adapters | Codex CLI, Opencode, Cursor Agent, Gemini CLI, Copilot CLI, Amp, Goose, Aider (complete). See *Upcoming: Additional CLI Adapters* below. |
| 40 | Website | Landing page: hero + install one-liner, feature bullets, asciinema demo, GitHub link. Domain: `codrift.sh`. |
| 43 | Tree view (mode 3) | **Next up.** Third mode (`3` key, `Ctrl+P` palette) showing a file-tree of all dirs in the active initiative. Keyboard-driven: navigate with `j`/`k`, expand/collapse dirs with `Enter`/`Space`, open file in `$EDITOR` with `e`, create file/dir with `n`, delete with `d` (confirmation prompt). Mode bar becomes `1: Context │ 2: Diff │ 3: Tree`. Like diff view, tree view always reflects the currently focused initiative — switching sidebar focus updates the tree root. |
| 44 | Replace in-TUI editor with `$EDITOR` (vim) | Drop the custom textarea editor (step 19). `e` key suspends the TUI, opens the context file in `$EDITOR` (defaults to `vim`), then resumes the TUI on exit. Users get their own editor config, plugins, and keybindings for free — no custom editor to maintain. |

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
