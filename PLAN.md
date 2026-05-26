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

### ⬜ Upcoming

| # | Step | Notes |
|---|------|-------|
| 31 | Session store: multi-agent per dir | Keys by `(initiative_id, dir)` — only one UUID per dir. Blocks multiple Claude agents in same dir from resuming independently. See *Upcoming: Multi-agent Session Store*. |
| 32 | Keybinding config layer | Config-file override for all key bindings |
| 33 | Theme chooser | Named themes (Dracula, Nord, Solarized, Tokyo Night) set border colors, highlight colors, and CodeBlock syntax theme in one config entry |
| 34 | SQLite + vector memory | `ecto_sqlite3` + `sqlite-vec` for semantic search over project context |
| 35 | Git worktrees per initiative | Per-initiative git worktree per dir; isolated branches; TUI shows worktree branch + dirty state |

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
| Async agent starts | `Task.Supervisor` (`Codrift.TaskSupervisor`) | Non-blocking TUI loop; failures are isolated |
| Diff sidebar | Sidebar transforms in diff mode | Cleaner than a separate file-list panel; sidebar is always visible and drives content |
| Split diff colours | Explicit `%Span{}` rendering via `to_split_rows/1` | Syntect `language: "diff"` doesn't colour stripped-prefix content; span rendering gives full control |
| Diff content border | Always cyan in diff mode | Content pane is always the reading surface in diff mode — grey "inactive" border was misleading |
