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
| 5 | Pane data structure | ⬜ Pending TUI decision | Extend with `:terminal` pane type |
| 6 | TUI render loop | 🚫 Blocked | Needs TUI library choice |
| 7 | Command palette | 🚫 Blocked | Needs TUI layer |
| 8 | Keybinding layer | 🚫 Blocked | Needs TUI layer |
| 12 | Terminal pane (PTY) | ⬜ Next up | `ex_pty` + TerminalProcess GenServer |
| 13 | SQLite memory (vector search) | ⬜ Next up | `ecto_sqlite3` + `sqlite-vec` |

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
