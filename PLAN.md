# Codrift — AI Coding Companion TUI

## Overview

Terminal UI application for driving AI coding agents across multiple working
directories grouped under a single "initiative". First-class diff viewing,
keyboard-driven actions, embedded web server for rich views, MCP server for
external tool integration. Full terminal emulator pane for arbitrary shell
access. SQLite for session persistence; SQLite + vector search planned for
project memory.

**Stack:** Elixir · Francis (web layer only) · ex_ratatui · Git (diffs) · SQLite (Exqlite)

---

## Architecture

```
Codrift (Application)
  └── Codrift.Supervisor (:one_for_one)
      ├── {Registry, name: Codrift.AgentRegistry} — agent ID → pid lookup
      ├── Codrift.SessionStore    — GenServer, SQLite-backed Claude session IDs
      ├── Codrift.Initiative.Store  — GenServer, JSON-persisted initiative state
      ├── Codrift.AgentSupervisor   — DynamicSupervisor, one child per running agent
      │   └── Codrift.AgentProcess  — GenServer + erlexec PTY → external CLI (Claude, Aider…)
      ├── {Task.Supervisor, name: Codrift.TaskSupervisor} — async agent start tasks
      └── Codrift (Francis)         — HTTP/SSE server on port 7437
          ├── GET  /                     — health
          ├── GET  /api/initiatives      — list initiatives (JSON)
          ├── GET  /api/diff/:id         — diff for initiative (JSON)
          ├── GET  /api/agent/:id        — agent status (JSON)
          ├── SSE  /events/initiative/:id — live agent output stream
          ├── POST /mcp                  — MCP JSON-RPC (HTTP transport)
          ├── SSE  /mcp/sse              — MCP server-sent events endpoint
          └── Static /diff.html          — browser diff viewer
```

**Pure modules (no processes):**
- `Codrift.Initiative` — struct + serialisation + status lifecycle
- `Codrift.Diff` — git diff generation + parser
- `Codrift.Agent` — behaviour for CLI adapters
- `Codrift.MCP.Handler` — JSON-RPC dispatch
- `Codrift.TUI.VT100` — pure Elixir VT100/ANSI terminal emulator
- `Codrift.TUI.Sidebar` — sidebar entry builder + renderer (context and diff modes)
- `Codrift.TUI.Modals` — modal overlay renderer
- `Codrift.TUI.DirPicker` — directory autocomplete
- `Codrift.TUI.Styles` — shared style helpers
- `Codrift.TUI.ANSI` — ANSI strip utilities
- `Codrift.TUI.Layout` — layout helpers

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
| 21 | Diff viewer overhaul | Sidebar transforms in diff mode; cursor-driven content pane; unified + coloured split view; `v` toggle; `*` reset. See *Diff Mode* section. |

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

### 🔬 Sidequests (future optimisations, not blocking)

| Sidequest | Notes |
|-----------|-------|
| Reduce TUI flickering | The current render loop triggers frequent terminal resizes to keep panes correctly sized, which causes visible flicker. Correctness and features take priority; this is a polish pass for later. See *Sidequest: Reduce TUI Flickering*. |

---

### ✅ Done — Config layer

| # | Step | Notes |
|---|------|-------|
| 32 | Keybinding config layer | `Codrift.Config.Keybindings` — loads `~/.codrift/keybindings.json`, merges over defaults; TUI dispatch uses reverse map; palette hints and footer status bar reflect configured keys |
| 33 | Theme chooser | `Codrift.Config.Theme` — loads `~/.codrift/theme.json`; named themes: `default`, `dracula`, `nord`, `solarized`, `tokyo_night`; controls border colours, sidebar highlight, diff border, and CodeBlock syntax theme |

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

### Key decision

**No changes to `AgentProcess`, `AgentSupervisor`, `SessionStore`, or the supervision tree** — the adapter pattern means all wiring is already in place. Each new CLI is ~40 lines of adapter code.

---

## Upcoming: External Integrations (Step 37)

Connect Codrift to external project management and collaboration tools so that initiatives can be seeded with real context (issue title, description, labels, linked PRs) and kept in sync as work progresses.

### Design principles

- **Read-first**: the primary flow is pulling context *into* Codrift, not pushing state back out. Write-back (e.g. closing a Linear issue when an initiative is done) is optional and opt-in.
- **One adapter per service**: each integration is a module implementing the `Codrift.Integration` behaviour; the TUI + MCP surface treats them uniformly.
- **Credentials in env**: API tokens are read from environment variables (e.g. `LINEAR_API_KEY`, `GITHUB_TOKEN`); no secrets stored in the Codrift DB.
- **Context folder injection**: pulled content is written into the initiative's `~/.codrift/initiatives/{id}/` folder so every Claude agent picks it up via `--add-dir`.

### `Codrift.Integration` behaviour

```elixir
@callback name() :: String.t()
@callback list_items(opts :: keyword()) :: {:ok, [%Item{}]} | {:error, term()}
@callback get_item(id :: String.t(), opts :: keyword()) :: {:ok, %Item{}} | {:error, term()}
@callback to_initiative_context(%Item{}) :: String.t()   # markdown snippet written to context folder
```

`%Item{}` carries: `id`, `title`, `description`, `url`, `labels`, `status`, `assignee`, `linked_prs`.

### Adapters planned

| Service | Notes |
|---------|-------|
| **Linear** | GraphQL API; create initiative per issue; sync status (`planning ↔ In Progress`, `done ↔ Done`) |
| **GitHub Issues** | REST + GraphQL; link PRs automatically; import milestone as initiative group |
| **GitHub Projects** | Import project board cards as initiatives |
| **GitLab Issues** | REST API; similar to GitHub flow |
| **Jira** | REST API v3; map Epic → initiative, Story → dir context |
| **Notion** | Blocks API; import a page or database row as initiative context |
| **Shortcut (Clubhouse)** | REST API; Story → initiative |
| **Asana** | REST API; Task or Project → initiative |
| **Linear Projects** | Import a Linear Project (not just single issues) as a multi-dir initiative |

### TUI flow

1. `Ctrl+P` → "Import from Integration…" → service picker (only shows adapters with env token present)
2. Fuzzy-search list of open items fetched from the chosen service
3. Select one → Codrift creates an initiative with the item title, writes a `context.md` into the initiative folder with description + labels + linked URLs
4. Optionally auto-add the repo dir if a linked PR/repo is detected
5. `Ctrl+P` → "Sync Context from Integration" refreshes the context file for the current initiative

### MCP tools added

- `list_integration_items(service, filter?)` — list open issues/tasks from a connected service
- `import_from_integration(service, item_id, dir?)` — create an initiative from an external item
- `sync_initiative_context(initiative_id)` — re-fetch and overwrite the context file

### Context file format

Each integration writes a `<service>_context.md` inside the initiative folder:

```markdown
# [LINEAR-123] Fix auth token expiry

**Source:** Linear · https://linear.app/team/issue/LIN-123
**Status:** In Progress
**Labels:** bug, auth
**Assignee:** filipe

## Description
Users report that session tokens expire after 1 hour even when "Remember me" is checked…

## Linked PRs
- #456 — fix: extend token TTL for remembered sessions (open)
```

---

## Diff Mode

Pressing `2` enters diff mode. The sidebar transforms to show changed files grouped
by directory; the main pane shows the diff content driven by the sidebar cursor.
Pressing `1` returns to context mode.

### Sidebar entries (diff mode)

```
  * all files              +42 -17
    ▸ ~/work/project        +30 -10
      ○ lib/foo.ex          +20  -5
      ○ lib/bar.ex          +10  -5
    ▸ ~/work/other          +12  -7
      ○ test/foo_test.ex    +12  -7
```

Entry types in `Codrift.TUI.Sidebar`:
- `{:diff_all, total_adds, total_dels}` — always first; shows combined totals
- `{:diff_dir, dir, adds, dels}` — one per directory that has changes
- `{:diff_file, dir, path, adds, dels}` — one per changed file

Directories with no changes are excluded. Moving the cursor updates the content
pane instantly — no Enter needed.

### Content pane (diff mode)

- Cursor on `{:diff_all}` → all changed files combined
- Cursor on `{:diff_dir}` → all files in that directory
- Cursor on `{:diff_file}` → single file

The content pane always has a cyan border in diff mode (always "active" — it is
the primary reading surface regardless of which pane has keyboard focus).

### View modes (toggle with `v`)

**Unified** (default) — single `CodeBlock` with `language: "diff"` syntax highlighting:
```
--- a/lib/foo.ex
+++ b/lib/foo.ex
@@ -1,5 +1,6 @@
-old line
+new line
 context
```

**Split** — two `Paragraph` panels with explicit span colouring:
```
┌─ - removed ──────┬─ + added ────────┐
│ old line  (red)  │ new line  (green) │
│ context          │ context           │
│ ~  (padding)     │ extra add (green) │
└──────────────────┴───────────────────┘
```
- Removed lines: red foreground (left pane, red border)
- Added lines: green foreground (right pane, green border)
- Context lines: default white
- Padding rows (`~`): dark-gray
- Hunk headers: dark-gray

Both modes share `diff_scroll`; `Ctrl+D`/`Ctrl+U` do half-page jumps.

### Diff keyboard shortcuts

| Key | Action |
|-----|--------|
| `j` / `↓` | Move diff sidebar cursor down (or scroll content when main focused) |
| `k` / `↑` | Move diff sidebar cursor up (or scroll content when main focused) |
| `v` | Toggle unified / split view |
| `*` | Jump diff sidebar cursor to "all files" (entry 0) |
| `Ctrl+D` / `Ctrl+U` | Half-page scroll in diff content |
| `r` | Refresh diff for current initiative |
| `Ctrl+P` | Open palette → "Toggle Diff: Unified / Split" etc. |

---

## Module Reference

### Codrift.Initiative
Struct: `%{id, name, dirs, created_at, status}`
Status: `:planning | :ongoing | :done | :archived`
API: `new/2`, `to_map/1`, `from_map/1`, `next_status/1`, `prev_status/1`

### Codrift.Initiative.Store
GenServer. Persists to `~/.config/codrift/initiatives.json`.
Accepts `:path` and `:name` opts for test isolation.
Context folders live at `~/.codrift/initiatives/{id}/`; CLAUDE.md symlink is
created automatically and backfilled for existing initiatives on startup.

API: `create/2`, `get/1`, `list/0`, `add_dir/2`, `remove_dir/2`, `delete/1`, `set_status/2`, `context_path/1`

### Codrift.SessionStore
GenServer. SQLite-backed (via Exqlite, at `~/.codrift/codrift.db`).
Persists Claude Code session UUIDs per `(initiative_id, dir)` pair so agents
can be resumed via `claude --resume <uuid>` across TUI restarts.

API: `save/3`, `get/2`, `list_all/0`

### Codrift.AgentProcess
GenServer owning an erlexec PTY (`:pty` mode) or Port (`:interactive` / `:once`).
State: `%{id, initiative_id, dir, adapter, mode, exec_pid, exec_ospid, port, status, buffer, buffer_size, subscribers, conversation_started, raw_line_buf, session_uuid}`
Status: `:starting | :idle | :running | :awaiting_input | :stopped`

Subscribers receive `{:agent_output, id, data}`, `{:agent_ready, id}`, and `{:agent_stopped, id, code}`.

Session UUID is auto-detected by polling `~/.claude/projects/<encoded-dir>/` for
`.jsonl` files modified at or after agent start time (3 s delay, one retry at 8 s).

API: `send_input/2`, `send_raw/2`, `resize/3`, `status/1`, `recent_output/2`, `session_uuid/1`, `subscribe/2`

### Codrift.AgentSupervisor
DynamicSupervisor. Accepts `:name`/`server` for test isolation.

API: `start_agent/4`, `stop_agent/2`, `list_agents/1`, `find_agent/2`, `list_agents_for_initiative/2`

### Codrift.Agent (behaviour)
Callbacks: `cmd/0`, `mode/0`, `args/2`, `args_continue/1`, `env/1`, `parse_status/1`
Adapters: `Codrift.Agent.Adapters.Claude`, `Codrift.Agent.Adapters.Aider`, `Codrift.Agent.Adapters.Terminal`

**Modes:** `:pty` (erlexec PTY, full terminal), `:interactive` (Port with pipes), `:once` (new Port per message)

Claude adapter: `:pty`, passes `--resume <uuid>` or `--continue` from SessionStore, `--add-dir` for context folder.
Terminal adapter: `:pty`, opens `$SHELL` (falls back to `bash`), any output → `:awaiting_input`.
Aider adapter: `:interactive`, plain pipes.

### Codrift.Diff
Pure module. Shells `git diff` via `System.cmd/3`, parses unified diff format.

`generate(dir, opts)` → `{:ok, [%FileDiff{}]} | {:error, reason}`
`parse(patch)` → `[%FileDiff{}]`
`to_map(file_diff)` → JSON-serialisable map
`to_unified(file_diff)` → unified diff string (for unified view)
`to_split_rows(file_diff)` → `[{:header | :context | :change, old | nil, new | nil}]` — typed rows for coloured split view
`to_split_lines(file_diff)` → `[{old_line | nil, new_line | nil}]` — untyped pairs (kept for compatibility)

Structs: `%FileDiff{path, old_path, hunks, additions, deletions}`
`%Hunk{old_start, old_count, new_start, new_count, header, lines}`
`%Line{type, content}` — type: `:add | :remove | :context`

### Codrift.TUI.Sidebar
Builds and renders sidebar entries for both context mode and diff mode.

**Context mode** — `build_entries(initiatives, agents)` → flat list of:
`{:initiative, id, name, dir_count, agent_count, status}`
`{:context_dir, initiative_id, path, agent_count}`
`{:context_file, initiative_id, full_path, filename}`
`{:dir, initiative_id, path, agent_count}`
`{:agent, id, adapter, status}`

**Diff mode** — `build_diff_entries([{dir, [%FileDiff{}]}])` → flat list of:
`{:diff_all, total_adds, total_dels}`
`{:diff_dir, dir, adds, dels}`
`{:diff_file, dir, path, adds, dels}`

`render/3` — context sidebar widget
`render_diff/3` — diff sidebar widget (title: "Changed Files")

### Codrift.TUI.VT100
Pure Elixir VT100/ANSI terminal emulator. No Rustler NIF needed.

Architecture:
1. `new(width, height)` — allocate virtual screen (cell grid)
2. `process(screen, data)` — feed raw PTY bytes; updates cursor, cells, style, scroll region
3. `to_text(screen, show_cursor)` — convert cell grid to `%ExRatatui.Text{}` for `Paragraph`
4. `resize(screen, width, height)` — notify of dimension changes

Supported: SGR colors/modifiers + attribute-off (21–29), cursor movement (H/f/A/B/C/D/G/d),
erase (J/K/X), insert/delete chars (@/P), IL/DL (L/M), SU/SD (S/T), scroll region (r),
save/restore cursor (ESC 7/8, [s/u), alternate screen (?1049h/l), cursor visibility (?25h/l),
OSC/DCS/PM/APC skip, incomplete-sequence carry buffer across PTY chunks.

### Codrift.MCP.Handler
Pure module. JSON-RPC 2.0 over HTTP+SSE transport.
Install: `mix codrift.mcp.install`
Tools: `list_initiatives`, `get_diff`, `list_agents`, `start_agent`, `send_to_agent`, `get_agent_output`,
`create_initiative`, `add_dir`, `delete_initiative`

---

## Upcoming: Multi-agent Session Store (Step 20)

`Codrift.SessionStore` currently keys sessions by `(initiative_id, dir)` with a
`PRIMARY KEY (initiative_id, dir)` constraint, meaning only **one** Claude
session UUID is remembered per directory. When two Claude agents run in the same
dir under the same initiative, the second agent's session overwrites the first on
quit, so only one can be resumed next time.

### Root cause

`save/3` does `INSERT OR REPLACE` keyed on `(initiative_id, dir)`. Detection
(`detect_claude_session/2` in `AgentProcess`) finds the newest `.jsonl` file in
`~/.claude/projects/<encoded-dir>/` modified after start time, which is correct
per-agent — the problem is only in the *storage* side.

### Fix: key by agent ID instead of (initiative_id, dir)

Change the primary key from `(initiative_id, dir)` to `agent_id`:

```sql
CREATE TABLE IF NOT EXISTS claude_sessions (
  agent_id     TEXT PRIMARY KEY,
  initiative_id TEXT NOT NULL,
  dir          TEXT NOT NULL,
  session_id   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
)
```

API changes:
- `save/3` → `save(agent_id, initiative_id, dir, session_id)` — upsert by agent ID
- `get/2` (by initiative+dir) → `get_by_agent(agent_id)` — fetch by agent ID
- `list_all/0` → returns `[{agent_id, initiative_id, dir, session_id}]`
- Keep a `list_by_dir(initiative_id, dir)` for the `:autostart_sessions` flow (returns all sessions for a dir so all agents can be resumed)

### Impact on AgentProcess

`initiative_context_opts/2` currently calls `Codrift.SessionStore.get(initiative_id, dir)` to fetch the resume UUID. It needs the agent's own ID to fetch correctly. Pass `agent_id` as an additional option to `initiative_context_opts/3`.

### Impact on TUI autostart

`handle_info(:autostart_sessions)` currently does one agent per session row. With the new schema, `list_all/0` returns one row per agent — it can start each one independently, allowing multiple agents per dir to all resume.

### Migration

On `init/1` in `SessionStore`, run a safe migration: if the old schema is detected (no `agent_id` column), drop and recreate the table (sessions are ephemeral enough that losing them once is acceptable).

---

## Upcoming: SQLite + Vector Memory (Step 13)

Persistent project memory with semantic search. The SQLite database already exists
at `~/.codrift/codrift.db` (used by `Codrift.SessionStore`). Step 13 extends it:
- `ecto_sqlite3` for the Ecto adapter (or continue with raw Exqlite)
- `sqlite-vec` extension for vector embeddings
- Stores: conversation summaries, code snippets, file context, agent outputs
- Retrieval: semantic similarity search on embeddings from a local/API model

---

## Upcoming: Git Worktrees per Initiative (Step 17)

Each initiative can span multiple git-enabled dirs. Today all agents work on the
same branch, so concurrent agent edits in the same repo can conflict. Worktrees
solve this cleanly.

**Flow:**
1. When a dir is added to an initiative (or on first agent start), Codrift checks
   `git -C <dir> rev-parse --is-inside-work-tree`.
2. If it is a git repo, create (or reuse) a worktree:
   ```
   git -C <repo-root> worktree add <worktree-path> -b codrift/<initiative-slug>/<dir-slug>
   ```
   `<worktree-path>` lives under `~/.local/share/codrift/worktrees/<initiative-id>/<dir-slug>/`.
3. `AgentProcess` is spawned with the worktree path as its working dir instead of
   the original dir — agents see a full repo checkout on an isolated branch.
4. `Codrift.Diff` reads diffs from the worktree path (already works; no change needed).
5. TUI sidebar shows the worktree branch name + dirty indicator next to each dir entry.
6. On initiative delete (or explicit "close worktree" action), Codrift runs
   `git worktree remove --force <worktree-path>`.

**New module: `Codrift.Worktree`** (pure, no process)
- `ensure/2` — idempotently creates the worktree + branch, returns path
- `remove/1` — removes worktree and deletes branch
- `status/1` — returns `%{branch, dirty?, ahead, behind}` (shells `git status --short` + `git rev-list`)
- `list_for_initiative/1` — returns all worktree paths owned by an initiative

**Initiative.Store changes:** persist `%{worktree_path, branch}` per dir entry.

**Concurrency benefit:** multiple agents on the same underlying repo each get their
own branch + working tree → no checkout conflicts, diffs are clean per-initiative,
and the user can PR/merge/discard each branch independently after a session.

---

## Upcoming: GitHub Actions CI (Step 39)

Two workflows: one for PR checks, one for releases. The release workflow is already sketched in step 38 — this step wires up the full CI surface.

### PR / push checks (`.github/workflows/ci.yml`)

Runs on every push and pull request to `main`.

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.18'
          otp-version: '27'
      - uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}
      - run: mix deps.get
      - run: mix format --check-formatted
      - run: mix credo --strict
      - run: mix test
```

### Release workflow (`.github/workflows/release.yml`)

Already described in step 38 — triggers on `v*` tags, builds a tarball per platform, uploads to GitHub Releases. Repeated here for completeness; the actual YAML lives in one file, not two.

### Status badge

Add to `README.md`:

```markdown
[![CI](https://github.com/OWNER/codrift/actions/workflows/ci.yml/badge.svg)](https://github.com/OWNER/codrift/actions/workflows/ci.yml)
```

---

## Upcoming: Website (Step 40)

A static landing page — the last step because the product needs to be shippable (step 38 distribution) and CI-green (step 39) before advertising it.

### Goals

- Communicate what Codrift is in one sentence
- Show the TUI in action (terminal recording or screenshot)
- Surface the one-liner install command prominently
- Link to GitHub repo and docs

### Stack

**Plain HTML + CSS, deployed to GitHub Pages** — zero build tooling, no framework, no npm. The site lives in `docs/` (GitHub Pages convention) or a dedicated `gh-pages` branch. A GitHub Actions workflow (part of step 39's release.yml or a dedicated `site.yml`) deploys it on every push to `main`.

Alternatives considered and rejected:
- Next.js / Astro: overkill for a single landing page; introduces a JS build pipeline
- Vercel / Netlify: free tier works, but GitHub Pages keeps everything in one repo with no external account

### Page structure

```
Hero
  Codrift — multi-agent AI coding companion for your terminal
  [one-liner install]  [GitHub]

What it does  (3-4 short bullets)
  • Run Claude Code, Opencode, Aider across multiple repos — one TUI
  • Full PTY emulation — interact just like a normal terminal
  • Diff viewer, session persistence, MCP server built in
  • Zero config — works with your existing Claude setup

Demo
  Terminal recording (asciinema embed or animated SVG)

Install
  curl -fsSL https://codrift.sh/install | sh
  — or —  brew install codrift/tap/codrift

Links
  GitHub  ·  Changelog  ·  Issues
```

### Domain

`codrift.sh` — short, memorable, matches the install URL from step 38. Register before step 40 begins.

### Deploy workflow (`.github/workflows/site.yml`)

```yaml
on:
  push:
    branches: [main]
    paths: ['docs/**']

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      pages: write
      id-token: write
    environment:
      name: github-pages
      url: ${{ steps.deploy.outputs.page_url }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/upload-pages-artifact@v3
        with:
          path: docs/
      - id: deploy
        uses: actions/deploy-pages@v4
```

### Terminal demo

Use `asciinema` to record a short session (creating an initiative, starting a Claude agent, viewing diffs). Embed via `<script src="https://asciinema.org/a/{id}.js">` or self-host the cast file + `asciinema-player` for zero third-party dependency.

---

## Upcoming: Distribution & Installation (Step 38)

Zero-dependency install experience identical to opencode / mise: `curl -fsSL https://codrift.sh/install | sh`.

### Why `mix release`, not Burrito

`mix release` is the OTP-native release mechanism — it bundles ERTS (the Erlang runtime) directly into the tarball using the exact toolchain already present during the build. No Zig cross-compilation, no NIF wrapper, no third-party packaging layer. Burrito's macOS Tahoe breakage stems from its reliance on Zig to repack the BEAM VM into a single-file binary; `mix release` avoids that entirely by producing a conventional directory release that is then tarballed.

The trade-off is tarball size: a release with bundled ERTS is ~30–40 MB vs a Go/Rust single binary. This is acceptable — the install is a one-time operation and the experience is identical from the user's perspective.

### Release structure

`mix release` produces:

```
codrift-{version}/
├── bin/
│   └── codrift          # POSIX startup script (generated by mix release)
├── erts-{version}/      # bundled ERTS — no Erlang/Elixir required on target
├── lib/                 # app + all deps (beam files)
└── releases/
    └── {version}/
        └── codrift.tar.gz   # inner tarball (used by release tooling)
```

This directory is tarballed as `codrift-{version}-{os}-{arch}.tar.gz` and uploaded to GitHub Releases.

### Platform matrix

| Target | GitHub Actions runner | Notes |
|--------|-----------------------|-------|
| `aarch64-apple-darwin` | `macos-14` | Apple Silicon (M1+) |
| `x86_64-apple-darwin` | `macos-13` | Intel Mac |
| `x86_64-linux-gnu` | `ubuntu-latest` | Linux x86_64 |
| `aarch64-linux-gnu` | `ubuntu-24.04-arm` | Linux ARM64 |

### GitHub Actions workflow

```yaml
# .github/workflows/release.yml
on:
  push:
    tags: ['v*']

jobs:
  build:
    strategy:
      matrix:
        include:
          - os: macos-14
            target: aarch64-apple-darwin
          - os: macos-13
            target: x86_64-apple-darwin
          - os: ubuntu-latest
            target: x86_64-linux-gnu
          - os: ubuntu-24.04-arm
            target: aarch64-linux-gnu
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.18'
          otp-version: '27'
      - run: mix deps.get --only prod
      - run: MIX_ENV=prod mix release
      - name: Package
        run: |
          VERSION=${GITHUB_REF_NAME#v}
          TARBALL="codrift-${VERSION}-${{ matrix.target }}.tar.gz"
          tar -czf "$TARBALL" -C _build/prod/rel codrift
          echo "TARBALL=$TARBALL" >> $GITHUB_ENV
      - uses: softprops/action-gh-release@v2
        with:
          files: ${{ env.TARBALL }}
```

### Install script (`install.sh`)

```sh
#!/bin/sh
set -eu

VERSION="${CODRIFT_VERSION:-latest}"
INSTALL_DIR="${CODRIFT_INSTALL_DIR:-$HOME/.local}"

# Detect OS
case "$(uname -s)" in
  Darwin) OS=apple-darwin ;;
  Linux)  OS=linux-gnu ;;
  *)      echo "Unsupported OS: $(uname -s)"; exit 1 ;;
esac

# Detect arch
case "$(uname -m)" in
  arm64|aarch64) ARCH=aarch64 ;;
  x86_64)        ARCH=x86_64 ;;
  *)             echo "Unsupported arch: $(uname -m)"; exit 1 ;;
esac

TARGET="${ARCH}-${OS}"

# Resolve latest version tag from GitHub
if [ "$VERSION" = "latest" ]; then
  VERSION=$(curl -fsSL "https://api.github.com/repos/OWNER/codrift/releases/latest" \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
fi

URL="https://github.com/OWNER/codrift/releases/download/v${VERSION}/codrift-${VERSION}-${TARGET}.tar.gz"

TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT

echo "Downloading codrift ${VERSION} for ${TARGET}..."
curl -fsSL "$URL" | tar -xz -C "$TMP"

mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/lib/codrift"
cp -r "$TMP/codrift/." "$INSTALL_DIR/lib/codrift/"
ln -sf "$INSTALL_DIR/lib/codrift/bin/codrift" "$INSTALL_DIR/bin/codrift"

echo "codrift installed to $INSTALL_DIR/bin/codrift"
echo "Make sure $INSTALL_DIR/bin is in your PATH."
```

Hosted at `https://codrift.sh/install` (or GitHub raw); invoked with:

```sh
curl -fsSL https://codrift.sh/install | sh
```

### mix.exs release config

```elixir
def project do
  [
    releases: [
      codrift: [
        include_erts: true,          # bundle ERTS — no Erlang needed on target
        strip_beams: true,           # strip debug info → ~30% smaller beams
        steps: [:assemble, :tar]     # produce .tar.gz alongside the release dir
      ]
    ]
  ]
end
```

`steps: [:assemble, :tar]` makes `mix release` emit `codrift-{version}.tar.gz` directly in `_build/prod/rel/` — the CI workflow picks that up instead of tarballing the directory manually.

### Homebrew tap (optional, later)

A `homebrew-tap` repo with a formula that points to the GitHub Release tarball. Allows `brew install codrift/tap/codrift` as an alternative install path for users who prefer Homebrew.

---

## Sidequest: Reduce TUI Flickering

**Priority: low — correctness and features first.**

### Root cause

The render loop triggers resizes on panes (PTY, content pane, sidebar) to keep them correctly sized after layout changes. Each resize round-trips through the terminal: the BEAM emits escape sequences, the terminal redraws, and if multiple resizes fire in quick succession the user sees a flash between intermediate states.

### Code review findings

Five concrete sources were identified by reading `lib/codrift/tui.ex` and `lib/codrift/agent/process.ex`.

---

**1. `AgentProcess.resize/3` has no deduplication — every call sends a SIGWINCH**

`process.ex:170-176` — `handle_cast({:resize, cols, rows}, ...)` calls `:exec.winsz/3` unconditionally. There is no guard for "same size as last time". Every `resize/3` call on a PTY unconditionally signals the child process regardless of whether dimensions changed.

*Fix:* Add `last_size: nil` to `AgentProcess` state. In the `handle_cast({:resize, cols, rows}, ...)` clause, compare `{cols, rows}` to `state.last_size`; only call `:exec.winsz` and update `last_size` when they differ. This deduplicates at the source, making all higher-level fixes cheaper.

```elixir
def handle_cast({:resize, cols, rows}, %{mode: :pty, exec_ospid: ospid} = state)
    when not is_nil(ospid) and {cols, rows} != state.last_size do
  :exec.winsz(ospid, rows, cols)
  {:noreply, %{state | last_size: {cols, rows}}}
rescue
  _ -> {:noreply, state}
end

def handle_cast({:resize, _cols, _rows}, state), do: {:noreply, state}
```

---

**2. `resize_all_ptys/2` resizes every agent on every terminal resize event**

`tui.ex:1774-1778` — called from both `handle_info({:apply_resize, ...})` (line 603) and `toggle_sidebar/1` (line 2138). It signals every agent including hidden ones.

Hidden agents repainting in the background produce output that is then buffered and replayed on selection, but the SIGWINCH itself still causes the child process to redraw and can perturb its internal state (scroll regions, cursor position).

*Fix:* Resize only the selected agent immediately. Resize all others lazily — `subscribe_to_agent/2` already calls `resize/3` on subscription, so non-selected agents pick up the correct dimensions when they become visible. Replace `resize_all_ptys/2` with a targeted call:

```elixir
# in handle_info({:apply_resize, w, h}, state)
if state.selected_agent_id do
  case AgentSupervisor.find_agent(state.selected_agent_id) do
    {:ok, pid} -> AgentProcess.resize(pid, pane_w, pane_h)
    _ -> :ok
  end
end
```

---

**3. `handle_info({:apply_resize, ...})` does not guard against no-op resizes**

`tui.ex:595-620` — after debouncing at 50 ms, the handler always calls `resize_all_ptys/2` and rebuilds all VT100 screens, even when `{pane_w, pane_h}` equals the current `state.pane_size`. This can fire during redraws triggered by agent output (ExRatatui fires synthetic resize events on some terminals).

*Fix:* Early-return when the computed pane size matches what is already stored:

```elixir
def handle_info({:apply_resize, w, h}, state) do
  {pane_w, pane_h} = calc_pane_size(w, h, state.sidebar_collapsed)

  if {pane_w, pane_h} == state.pane_size do
    {:noreply, %{state | resize_ref: nil}}
  else
    # ... existing resize logic ...
  end
end
```

---

**4. Each agent subscription fires 3–4 resize calls in 600 ms**

`tui.ex:1275-1278` — `subscribe_to_agent/2` immediately sends `w-1` (to force Ink to repaint), then schedules `{:restore_agent_size, ...}` at +150 ms (which sends `w`, then +60 ms sends `\r` via `{:input_nudge, ...}`), then schedules another `{:nudge_agent, ...}` at +600 ms which repeats the full `w-1 → w` cycle. Total: up to 4 SIGWINCH signals + 1 `\r` in 660 ms per subscription. Each SIGWINCH causes Claude Code / Ink to do a `\e[2J` full repaint, which is the most visible form of flicker.

The 600 ms second nudge (`tui.ex:1278`) is described as "catches slow-starting agents" — but it fires unconditionally even when the agent has already painted correctly.

*Fix (conservative):* Make the 600 ms nudge conditional — only schedule it if `has_output` was false at subscription time, and add a guard in `handle_info({:nudge_agent, ...})` that skips the cycle when the VT100 screen already has content:

```elixir
# In subscribe_to_agent, only schedule the 600ms nudge if there is no output yet
if Enum.empty?(replay) do
  Process.send_after(self(), {:nudge_agent, agent_id, w, h}, 600)
end
```

*Fix (aggressive):* Track `nudge_ref` and `restore_ref` alongside the existing `resize_ref` in TUI state. Cancel stale timers before scheduling new ones, so rapid agent navigation doesn't accumulate a queue of nudge cycles waiting to fire.

---

**5. Stale nudge/restore timers accumulate during rapid navigation**

`tui.ex:1246` — `maybe_subscribe_agent/2` calls `Process.send_after(self(), {:nudge_agent, ...}, 80)` with no cancellation of any previous pending nudge. When the user navigates between agents faster than 80 ms, the old timer still fires but is guarded by `agent_id == state.selected_agent_id` (line 654), so it harmlessly no-ops for the wrong agent. However `subscribe_to_agent` (line 1277) schedules `{:restore_agent_size, ...}` with no ref tracking, so those can pile up across agent switches.

*Fix:* Add `nudge_ref: nil` and `restore_ref: nil` to the `defstruct` and cancel-before-schedule them in the same pattern as `resize_ref`:

```elixir
# In maybe_subscribe_agent
if state.nudge_ref, do: Process.cancel_timer(state.nudge_ref)
ref = Process.send_after(self(), {:nudge_agent, agent_id, w, h}, 80)
%{state | nudge_ref: ref}
```

---

### Suggested approach order

These five fixes are independent and ordered cheapest-to-most-invasive:

1. **Fix 1** (guard in `AgentProcess.resize`) — ~5 lines, zero risk, deduplicates at the root
2. **Fix 3** (no-op guard in `apply_resize`) — ~5 lines, eliminates spurious full repaints
3. **Fix 5** (cancel stale nudge refs) — ~10 lines, prevents timer pile-up during navigation
4. **Fix 4** (conditional 600 ms nudge) — ~5 lines, halves the repaint count on subscription
5. **Fix 2** (lazy background resizes) — bigger change, highest payoff when many agents are running

---

## Key Decisions Made

| Decision | Choice | Reason |
|----------|--------|--------|
| Francis role | Web server only | No TUI capabilities in Francis |
| HTTP port | 7437 | Rarely used; avoids clashes with Phoenix (4000), Angular (4200), etc. |
| CLI agents | erlexec PTY (`:pty` mode primary) | Claude Code requires a real TTY for interactive mode; PTY via erlexec gives full terminal support |
| Agent restart | `:temporary` | User-driven; automatic restart would re-run expensive inference |
| Persistence | JSON file (`~/.config/codrift/`) | Simple, human-readable, v1 scope |
| Session storage | SQLite via Exqlite (`~/.codrift/codrift.db`) | Structured, reliable upsert; shares DB with future vector memory |
| Git diffs | Shell to `git diff` | Zero deps, covers all needed formats |
| JSON codec | Elixir 1.18 built-in `JSON` | No extra dep needed |
| MCP transport | HTTP+SSE (`POST /mcp` + `GET /mcp/sse`) | Compatible with `claude mcp add --transport sse` |
| Test isolation | `:name` opt defaults to `__MODULE__`; `server` param on queries | Avoids conflicts with app-started named processes |
| Code style | Credo enforced; `@doc`/`@moduledoc` on all public modules | Consistency + discoverability |
| VT100 emulation | Pure Elixir (`Codrift.TUI.VT100`) | No Rustler/NIF needed; full correctness achievable in Elixir; supports all required sequences including IL/DL and SU/SD |
| Distribution | `mix release` + bundled ERTS, not Burrito | Burrito breaks on macOS Tahoe (relies on Zig to repack BEAM VM); `mix release` is OTP-native, produces a conventional tarball with ERTS included, no third-party toolchain involved |
| Async agent starts | `Task.Supervisor` (`Codrift.TaskSupervisor`) | Non-blocking TUI loop; failures are isolated |
| Diff sidebar | Sidebar transforms in diff mode | Cleaner than a separate file-list panel; sidebar is always visible and drives content |
| Split diff colours | Explicit `%Span{}` rendering via `to_split_rows/1` | Syntect `language: "diff"` doesn't colour stripped-prefix content; span rendering gives full control |
| Diff content border | Always cyan in diff mode | Content pane is always the reading surface in diff mode — grey "inactive" border was misleading |
