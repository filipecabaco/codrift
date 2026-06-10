# Codrift — AI Coding Companion TUI

## Overview

Terminal UI application for driving AI coding agents across multiple working
directories grouped under a single "initiative". First-class diff viewing,
keyboard-driven actions, embedded web server for rich views, MCP server for
external tool integration. Full terminal emulator pane for arbitrary shell
access. SQLite for session persistence; SQLite FTS5 for per-initiative memory.

**Stack:** Elixir · Francis (web layer only) · ex_ratatui · Git (diffs) · SQLite (Exqlite)

**Docs:** [Architecture](docs/architecture.md) · [Modules](docs/modules.md) · [Decisions](docs/decisions.md) · [Keyboard](docs/keyboard.md) · [Tree View](docs/tree-view.md) · [Diff Mode](docs/diff-mode.md) · [Worktrees](docs/worktrees.md) · [Memory](docs/memory.md) · [Integrations](docs/integrations.md)

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
| 6 | Full VT100 emulation | Pure Elixir cell-grid renderer with SGR, cursor, scroll regions, and incomplete-sequence buffering. |
| 7 | TUI shell | `mix codrift.tui`, sidebar + output + diff panes |
| 8 | PTY agents + terminals | `erlexec :pty` with keypress forwarding; `t` opens a `$SHELL` pane. |
| 9 | Task.Supervisor for async starts | Wraps agent start to avoid blocking the TUI loop. |
| 10 | Graceful shutdown | `terminate/2` kills all agents + terminals on exit. |
| 11 | Mouse support | Scroll (sidebar / PTY / pane) + left-click focus switch. |

### ✅ Done — TUI navigation & context

| # | Step | Notes |
|---|------|-------|
| 12 | Multi-dir sidebar | initiative → dir → agent hierarchy |
| 13 | Cursor-driven pane | Content switches by cursor type: initiative overview, dir git log, agent/terminal ANSI output. |
| 14 | Initiative management | `n` new, `a` add-dir, `s` start-agent, `d` delete/stop, `Ctrl+P` palette. |
| 15 | Multiple agents + terminals per dir | All agents under a dir mapped into `{:agent, ...}` sidebar rows. |
| 16 | Initiative root agents | Catches agents whose dir matches the initiative context path. |
| 17 | Initiative status lifecycle | `:planning → :ongoing → :done → :archived`; cycle with `[`/`]`. |
| 18 | Context folder + CLAUDE.md | Each initiative gets `~/.codrift/initiatives/{id}/`; CLAUDE.md symlinked to all dirs. |
| 19 | In-TUI context file editor | `c` creates, `e` opens textarea editor, autosave every 500 ms, Esc to close. |

### ✅ Done — Diff

| # | Step | Notes |
|---|------|-------|
| 20 | Web diff view | `/diff.html` + SSE `/events/initiative/:id` |
| 21 | Diff viewer overhaul | Cursor-driven pane with unified/split view toggle (`v`) and reset (`*`). See [Diff Mode](docs/diff-mode.md). |

### ✅ Done — Agents & sessions

| # | Step | Notes |
|---|------|-------|
| 22 | Multi-agent per initiative | Registry lookup filtered by initiative. |
| 23 | Session persistence | SQLite stores session UUIDs; agents auto-resume on next start. |
| 24 | Session auto-restart | TUI re-launches agents from saved sessions on boot. |
| 31 | Session store: multi-agent per dir | Schema keyed by `agent_id`; migration drops old `(initiative_id, dir)` PK on first boot. |

### ✅ Done — Integrations

| # | Step | Notes |
|---|------|-------|
| 25 | MCP server | HTTP+SSE transport, `mix codrift.mcp.install` |
| 26 | MCP initiative tools | `create_initiative`, `add_dir`, `delete_initiative` |

### ✅ Done — Polish

| # | Step | Notes |
|---|------|-------|
| 27 | Remove emoji from TUI | Replaced emoji with ASCII/line-art equivalents. |
| 28 | Mode bar labels | `1: Context │ 2: Diff` — symmetric ASCII. |
| 29 | Sidebar collapse | `Ctrl+B` toggles sidebar; PTY and focus update immediately. |
| 30 | Command palette expansion | Added Sidebar, Diff, Context, Status, and Editor commands, grouped with section comments. |

### ✅ Done — Config layer

| # | Step | Notes |
|---|------|-------|
| 32 | Keybinding config layer | Loads `~/.codrift/keybindings.json`, merges over defaults; palette hints and footer reflect configured keys. |
| 33 | Theme chooser | Loads `~/.codrift/theme.json`; named themes: `default`, `dracula`, `nord`, `solarized`, `tokyo_night`. |

### ✅ Done — Memory store, CLI & distribution

| # | Step | Notes |
|---|------|-------|
| 34 | Per-initiative memory store + CLI | SQLite FTS5 memory module; unified CLI entry points; Mix tasks delegate to CLI modules. See [Memory](docs/memory.md). |
| 35 | Distribution & installation | `install.sh` with 4-platform detection; GitHub Actions release matrix (macOS + Linux, ARM + x86). |
| 36 | GitHub Actions CI | `deps.get → compile → format → credo → test`; cache keyed on `mix.lock`. |

### ✅ Done — Safe paste + input hardening

| # | Step | Notes |
|---|------|-------|
| 41 | Safe paste + input hardening | Bracketed paste via forked `ex_ratatui` NIF delivering `%Paste{content}` atomically. Also fixes Tab, Shift+Enter, multi-byte Unicode, and changes quit key to `Ctrl+Q`. |

### ✅ Done — Sidequests

| Sidequest | Notes |
|-----------|-------|
| Reduce TUI flickering | Five-layer fix (resize dedup, selective PTY resize, no-op guards, nudge skip, stale timer cancel) plus `BeginSynchronizedUpdate`/`EndSynchronizedUpdate` wrapping every draw. |

### ✅ Done — External integrations

| # | Step | Notes |
|---|------|-------|
| 39 | External integrations | `Codrift.Integration` behaviour + 9 adapters (GitHub, Linear, GitLab, Jira, Notion, Shortcut, Asana); OAuth PKCE/device/token flows; 5 MCP tools. See [Integrations](docs/integrations.md). |

### ✅ Done — Git Worktrees

| # | Step | Notes |
|---|------|-------|
| 37 | Git worktrees per initiative | Opt-in per-dir via `DirEntry`; `Codrift.Worktree` pure module; `W` key + palette to toggle. See [Worktrees](docs/worktrees.md). |

### ✅ Done — Worktree UX improvements

| # | Step | Notes |
|---|------|-------|
| 42 | Worktree UX improvements | Sidebar `[wt]`/`[wt*]` label (yellow when dirty); CLI `worktree-enable/disable/status` commands. See [Worktrees](docs/worktrees.md). |

### ✅ Done — Tree view

| # | Step | Notes |
|---|------|-------|
| 44 | Tree view (mode 3) | `3` key shows file-tree sidebar with syntax-highlighted preview; `e` opens file in embedded editor. `n`/`d` create/delete; `Enter`/`Space` expand/collapse. |

### ✅ Done — Embedded editor & quick-open

| # | Step | Notes |
|---|------|-------|
| 45 | Embedded `$EDITOR` in main pane | `e` spawns editor as an erlexec PTY in the main pane, streaming output through VT100. Falls back to `vim`; works from context and tree mode. |
| 49 | `codrift <file…>` quick-open | Creates a temp initiative for file args; `P` promotes it to a named initiative. |

### ✅ Done — Modal text-input focus audit

| # | Step | Notes |
|---|------|-------|
| 50 | Modal text-input focus audit | Audited all modal types against text-input routing guards; fixed `@type modal` missing 7 types; added developer checklist comment above guards. |

### ✅ Done — Additional CLI adapters

| # | Step | Notes |
|---|------|-------|
| 43 | Additional CLI adapters | Claude, Codex, Opencode, Gemini, Copilot; auto-detected via `System.find_executable`; `:agent_picker` modal when multiple found, sorted by most-used. `tui?/0` callback drives TUI-ready detection uniformly across Ink/Bubble Tea adapters. |

### ⬜ Upcoming
| 48 | Multi-buffer search in tree view | `/` in tree mode opens project-wide search; results render as a virtual buffer of excerpts editable in-place and batch-applied back to source files. |
| 47 | Website | Landing page at `codrift.sh`: hero, install one-liner, asciinema demo. |
| 51 | OAuth app credentials | Bundle `client_id` into release binary; users no longer need their own app registrations. |
