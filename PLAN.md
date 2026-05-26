# Codrift — AI Coding Companion TUI

## Overview

Terminal UI application for driving AI coding agents across multiple working
directories grouped under a single "initiative". First-class diff viewing,
keyboard-driven actions, embedded web server for rich views, MCP server for
external tool integration. Full terminal emulator pane for arbitrary shell
access. SQLite for session persistence; SQLite + vector search planned for
project memory.

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

### 🔬 Sidequests (future optimisations, not blocking)

| Sidequest | Notes |
|-----------|-------|
| Reduce TUI flickering | Render loop triggers frequent terminal resizes causing visible flicker. Correctness and features take priority. See [flickering sidequest](docs/flickering.md). |

---

### ⬜ Upcoming

| # | Step | Notes |
|---|------|-------|
| 31 | Session store: multi-agent per dir | Keys by `(initiative_id, dir)` — only one UUID per dir. Blocks multiple Claude agents in same dir from resuming independently. See *Upcoming: Multi-agent Session Store*. |
| 34 | SQLite + vector memory | `ecto_sqlite3` + `sqlite-vec` for semantic search over project context |
| 35 | Git worktrees per initiative | Per-initiative git worktree per dir; isolated branches; TUI shows worktree branch + dirty state |
| 36 | Additional CLI adapters | Codex CLI, Opencode, Cursor Agent, Gemini CLI, Copilot CLI, and others. See *Upcoming: Additional CLI Adapters*. |
| 37 | External integrations | Import initiatives + context from Linear, GitHub, Jira, Notion, GitLab, Shortcut, Asana. See *Upcoming: External Integrations*. |
| 38 | Distribution & installation | `mix release` + bundled ERTS → platform tarballs on GitHub Releases + curl-pipe-sh installer. See *Upcoming: Distribution & Installation*. |
| 39 | GitHub Actions CI | PR checks (tests, Credo, format), release workflow (tags → tarballs on GitHub Releases). See *Upcoming: GitHub Actions CI*. |
| 40 | Website | Landing page showcasing features, demo, install one-liner. See *Upcoming: Website*. |

---

## Upcoming: Additional CLI Adapters (Step 36)

The `Codrift.Agent` behaviour already abstracts all CLI differences. Adding a new
agent type is purely a matter of creating a new adapter module under
`lib/codrift/agent/adapters/` and registering it in the TUI picker.

### Behaviour recap (no changes needed)

```elixir
@callback cmd() :: String.t()           # executable name / path
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

### Session resume

Each adapter that supports session continuity implements `args_continue/1`
to emit the correct resume flag. `SessionStore` is adapter-agnostic — the
`agent_id` key works for any CLI. Adapters that have no resume concept simply
return `args/2` from `args_continue/1`.

### TUI changes

- Agent picker (the `s` key modal) lists all registered adapters, not just Claude
- Each sidebar `:agent` row shows a short adapter tag (e.g. `claude`, `codex`, `opencode`)
- `save_all_sessions/1` already guards with `adapter == Claude`; extend the guard
  to any adapter that returns a non-nil `session_uuid` (add `supports_resume?/0` callback)

**No changes to `AgentProcess`, `AgentSupervisor`, `SessionStore`, or the supervision tree** — the adapter pattern means all wiring is already in place. Each new CLI is ~40 lines of adapter code.

---

## Upcoming: External Integrations (Step 37)

Connect Codrift to external project management and collaboration tools so that initiatives can be seeded with real context (issue title, description, labels, linked PRs) and kept in sync as work progresses.

### Design principles

- **Read-first**: the primary flow is pulling context *into* Codrift, not pushing state back out.
- **One adapter per service**: each integration is a module implementing the `Codrift.Integration` behaviour.
- **Credentials in env**: API tokens read from environment variables; no secrets stored in the Codrift DB.
- **Context folder injection**: pulled content written into `~/.codrift/initiatives/{id}/` so every Claude agent picks it up via `--add-dir`.

### `Codrift.Integration` behaviour

```elixir
@callback name() :: String.t()
@callback list_items(opts :: keyword()) :: {:ok, [%Item{}]} | {:error, term()}
@callback get_item(id :: String.t(), opts :: keyword()) :: {:ok, %Item{}} | {:error, term()}
@callback to_initiative_context(%Item{}) :: String.t()
```

`%Item{}` carries: `id`, `title`, `description`, `url`, `labels`, `status`, `assignee`, `linked_prs`.

### Adapters planned

| Service | Notes |
|---------|-------|
| **Linear** | GraphQL API; create initiative per issue; sync status |
| **GitHub Issues** | REST + GraphQL; link PRs automatically; import milestone as initiative group |
| **GitHub Projects** | Import project board cards as initiatives |
| **GitLab Issues** | REST API |
| **Jira** | REST API v3; map Epic → initiative, Story → dir context |
| **Notion** | Blocks API; import a page or database row as initiative context |
| **Shortcut (Clubhouse)** | REST API; Story → initiative |
| **Asana** | REST API; Task or Project → initiative |
| **Linear Projects** | Import a Linear Project as a multi-dir initiative |

### MCP tools added

- `list_integration_items(service, filter?)` — list open issues/tasks from a connected service
- `import_from_integration(service, item_id, dir?)` — create an initiative from an external item
- `sync_initiative_context(initiative_id)` — re-fetch and overwrite the context file

---

## Upcoming: Multi-agent Session Store (Step 31)

`Codrift.SessionStore` currently keys sessions by `(initiative_id, dir)` — only **one** Claude session UUID per directory. When two Claude agents run in the same dir, the second session overwrites the first.

### Fix: key by agent ID

```sql
CREATE TABLE IF NOT EXISTS claude_sessions (
  agent_id      TEXT PRIMARY KEY,
  initiative_id TEXT NOT NULL,
  dir           TEXT NOT NULL,
  session_id    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
)
```

API changes:
- `save/3` → `save(agent_id, initiative_id, dir, session_id)`
- `get/2` → `get_by_agent(agent_id)`
- Keep `list_by_dir(initiative_id, dir)` for `:autostart_sessions` flow

### Migration

On `SessionStore.init/1`: if old schema detected (no `agent_id` column), drop and recreate the table.

---

## Upcoming: SQLite + Vector Memory (Step 34)

Extends `~/.codrift/codrift.db` (already used by `SessionStore`):
- `ecto_sqlite3` or raw Exqlite
- `sqlite-vec` extension for vector embeddings
- Stores: conversation summaries, code snippets, file context, agent outputs
- Retrieval: semantic similarity search on embeddings from a local/API model

---

## Upcoming: Git Worktrees per Initiative (Step 35)

**New module: `Codrift.Worktree`** (pure, no process)
- `ensure/2` — idempotently creates the worktree + branch, returns path
- `remove/1` — removes worktree and deletes branch
- `status/1` — returns `%{branch, dirty?, ahead, behind}`
- `list_for_initiative/1` — returns all worktree paths owned by an initiative

Worktree path: `~/.local/share/codrift/worktrees/<initiative-id>/<dir-slug>/`
Branch: `codrift/<initiative-slug>/<dir-slug>`

`AgentProcess` spawns with the worktree path as working dir. `Initiative.Store` persists `%{worktree_path, branch}` per dir entry. TUI sidebar shows branch + dirty indicator.

---

## Upcoming: Distribution & Installation (Step 38)

`curl -fsSL https://codrift.sh/install | sh` install experience. Uses `mix release` with bundled ERTS (not Burrito — see [decisions](docs/decisions.md)).

### Platform matrix

| Target | Runner |
|--------|--------|
| `aarch64-apple-darwin` | `macos-14` |
| `x86_64-apple-darwin` | `macos-13` |
| `x86_64-linux-gnu` | `ubuntu-latest` |
| `aarch64-linux-gnu` | `ubuntu-24.04-arm` |

### mix.exs release config

```elixir
releases: [
  codrift: [
    include_erts: true,
    strip_beams: true,
    steps: [:assemble, :tar]
  ]
]
```

---

## Upcoming: GitHub Actions CI (Step 39)

Two workflows: `ci.yml` (push/PR checks) and `release.yml` (tag → tarballs on GitHub Releases).

CI steps: `mix deps.get` → `mix format --check-formatted` → `mix credo --strict` → `mix test`

Release matrix: builds on `macos-14`, `macos-13`, `ubuntu-latest`, `ubuntu-24.04-arm`; uploads tarballs via `softprops/action-gh-release`.

---

## Upcoming: Website (Step 40)

Plain HTML + CSS deployed to GitHub Pages (`docs/` dir or `gh-pages` branch). Domain: `codrift.sh`.

Page structure: hero + one-liner install, 3–4 feature bullets, asciinema demo, GitHub link.
