# Codrift — AI Coding Companion TUI

## Overview

Terminal UI application for driving AI coding agents across multiple working
directories grouped under a single "initiative". First-class diff viewing,
keyboard-driven actions, embedded web server for rich views, MCP server for
external tool integration. Full terminal emulator pane for arbitrary shell
access. SQLite + vector search for persistent project memory.

**Stack:** Elixir · Francis (web layer only) · TUI library TBD · Git (diffs) · SQLite + sqlite-vec

---

## Architecture

```
Codrift (Application)
  └── Codrift.Supervisor (:one_for_one)
      ├── {Registry, name: Codrift.AgentRegistry} — agent ID → pid lookup
      ├── Codrift.Initiative.Store  — GenServer, JSON-persisted initiative state
      ├── Codrift.AgentSupervisor   — DynamicSupervisor, one child per running agent
      │   └── Codrift.AgentProcess  — GenServer + Port → external CLI (Claude, Aider…)
      ├── Codrift.TerminalSupervisor — DynamicSupervisor for terminal pane PTY sessions
      │   └── Codrift.TerminalProcess — GenServer + PTY → user's preferred shell
      ├── Codrift.Memory.Repo       — Ecto repo (SQLite + sqlite-vec extension)
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
- `Codrift.Initiative` — struct + serialisation
- `Codrift.Diff` — git diff generation + parser
- `Codrift.Agent` — behaviour for CLI adapters
- `Codrift.MCP.Handler` — JSON-RPC dispatch
- `Codrift.Keymap` — keybinding lookup (load-time map)
- `Codrift.Action` — behaviour for command palette actions
- `Codrift.Pane` — pane tree data structure (split/focus/resize/terminal pane type)

**Open decision:** TUI rendering library (Ratatouille, raw ANSI, or other).
Steps 5–8 are blocked until this is resolved.

---

## Build Order

| # | Step | Status | Notes |
|---|------|--------|-------|
| 1 | Project skeleton | ✅ Done | Francis + supervision tree, port 7437 |
| 2 | Initiative model + persistence | ✅ Done | GenServer + JSON file |
| 3 | Agent process (Port → CLI) | ✅ Done | DynamicSupervisor + behaviour, Registry |
| 4 | Diff module | ✅ Done | `git diff` parser, pure functions |
| 9 | Web diff view | ✅ Done | `/diff.html` + SSE `/events/initiative/:id` |
| 10 | MCP server | ✅ Done | HTTP+SSE transport, `mix codrift.mcp.install` |
| 11 | Multi-agent per initiative | ✅ Done | Registry lookup + initiative filter |
| — | Code quality | ✅ Done | Credo clean, `@doc`/`@moduledoc` throughout |
| 6 | TUI — ex_ratatui shell | ✅ Done | `mix codrift.tui`, sidebar + output + diff panes |
| 7 | TUI — initiative management | ✅ Done | `n` new, `a` add-dir, `s` start-agent, `d` delete/stop (context), `Ctrl+P` palette |
| — | MCP initiative tools | ✅ Done | `create_initiative`, `add_dir`, `delete_initiative` |
| — | Multi-dir sidebar | ✅ Done | initiative → 📁 dir → agent hierarchy |
| — | Tab 3: Initiative info | ✅ Done | git branch, last commit, agents per dir |
| — | PTY agents + terminals | ✅ Done | `erlexec :pty`, direct keypress forwarding, `t` key opens `$SHELL` pane |
| — | Cursor-driven pane | ✅ Done | initiative → overview, dir → git log, agent/terminal → ANSI output |
| — | Graceful shutdown | ✅ Done | `terminate/2` kills all agents + terminals on TUI exit |
| 5 | Full VT100 emulation | ⬜ Next | Rustler NIF wrapping `vt100` crate (~100 lines Rust); replaces ANSI strip with proper cell-grid rendering. Architecture: `erlexec` bytes → `vt100::Parser::process()` → `vt100::Screen` → ex_ratatui cells. Based on `tui-term` design. |
| 16 | Multiple agents + terminals per dir | ⬜ Next | Sidebar: `📁 dir` → `◦ claude` + `◦ bash` + `◦ bash` (multiple entries); Tab cycles through them |
| 15 | Initiative root agents | ⬜ Next | Agents with no specific dir show under the initiative header |
| 8 | Keybinding config layer | ⬜ Next | Config-file override |
| 14 | Theme chooser | ⬜ Next | Named themes (Dracula, Nord, Solarized, Tokyo Night) set border colors, highlight colors, and CodeBlock syntax theme in one config entry |
| 13 | SQLite + vector memory | ⬜ Next | `ecto_sqlite3` + `sqlite-vec` for semantic search over project context |
| 17 | Git worktrees per initiative | ⬜ Next | For each git-enabled dir in an initiative, create a dedicated `git worktree` on an initiative-scoped branch. Agents operate inside their worktree — changes are isolated, concurrent, and mergeable. TUI gains worktree status (branch, dirty state) in sidebar. See *Upcoming: Git Worktrees* section. |

---

## Module Reference

### Codrift.Initiative
Struct: `%{id, name, dirs, created_at}`
API: `new/2`, `to_map/1`, `from_map/1`

### Codrift.Initiative.Store
GenServer. Persists to `~/.config/codrift/initiatives.json`.
Accepts `:path` and `:name` opts for test isolation.

API: `create/2`, `get/1`, `list/0`, `add_dir/2`, `remove_dir/2`, `delete/1`

### Codrift.AgentProcess
GenServer owning a Port to an external CLI.
State: `%{id, initiative_id, dir, adapter, port, status, buffer, subscribers}`
Status: `:starting | :idle | :running | :awaiting_input | :stopped`
Subscribers receive `{:agent_output, id, data}` and `{:agent_stopped, id, code}`.

API: `send_input/2`, `status/1`, `recent_output/2`, `subscribe/2`

### Codrift.AgentSupervisor
DynamicSupervisor. Accepts `:name`/`server` for test isolation.

API: `start_agent/4`, `stop_agent/2`, `list_agents/1`, `find_agent/2`, `list_agents_for_initiative/2`

### Codrift.Agent (behaviour)
Callbacks: `cmd/0`, `args/1`, `env/1`, `parse_status/1`
Adapters: `Codrift.Agent.Adapters.Claude`, `Codrift.Agent.Adapters.Aider`

### Codrift.Diff
Pure module. Shells `git diff` via `System.cmd/3`, parses unified diff format.

`generate(dir, opts)` → `{:ok, [%FileDiff{}]} | {:error, reason}`
`parse(patch)` → `[%FileDiff{}]`
`to_map(file_diff)` → JSON-serialisable map

Structs: `%FileDiff{path, old_path, hunks, additions, deletions}`
`%Hunk{old_start, old_count, new_start, new_count, header, lines}`
`%Line{type, content}` — type: `:add | :remove | :context`

### Codrift.MCP.Handler
Pure module. JSON-RPC 2.0 over HTTP+SSE transport.
Install: `mix codrift.mcp.install`
Tools: `list_initiatives`, `get_diff`, `list_agents`, `start_agent`, `send_to_agent`, `get_agent_output`

---

## Upcoming: Terminal Pane (Step 12)

A `:terminal` pane hosts a real PTY session (user's `$SHELL`). Unlike
`AgentProcess` which expects structured CLI output, `TerminalProcess` passes
raw bytes through unchanged — the TUI layer renders them via a VT100 parser.

Dependency: `ex_pty` (or `erlang-ptyterm`) for PTY allocation.

## Upcoming: SQLite Memory (Step 13)

Persistent project memory with semantic search:
- `ecto_sqlite3` for the Ecto adapter
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
| CLI agents | External OS processes via Port | CLIs are independent executables |
| Agent restart | `:temporary` | User-driven; automatic restart would re-run expensive inference |
| Persistence | JSON file (`~/.config/codrift/`) | Simple, human-readable, v1 scope |
| Git diffs | Shell to `git diff` | Zero deps, covers all needed formats |
| JSON codec | Elixir 1.18 built-in `JSON` | No extra dep needed |
| MCP transport | HTTP+SSE (`POST /mcp` + `GET /mcp/sse`) | Compatible with `claude mcp add --transport sse` |
| Test isolation | `:name` opt defaults to `__MODULE__`; `server` param on queries | Avoids conflicts with app-started named processes |
| Code style | Credo enforced; `@doc`/`@moduledoc` on all public modules | Consistency + discoverability |
