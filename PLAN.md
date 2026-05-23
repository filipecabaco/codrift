# Codrift — AI Coding Companion TUI

## Overview

Terminal UI application for driving AI coding agents across multiple working
directories grouped under a single "initiative". First-class diff viewing,
keyboard-driven actions, embedded web server for rich views, MCP server for
external tool integration.

**Stack:** Elixir · Francis (web layer only) · TUI library TBD · Git (diffs)

---

## Architecture

```
Codrift (Application)
  └── Codrift.Supervisor (:one_for_one)
      ├── Codrift.Initiative.Store      — GenServer, JSON-persisted initiative state
      ├── Codrift.AgentSupervisor       — DynamicSupervisor, one child per running agent
      │   └── Codrift.AgentProcess      — GenServer + Port → external CLI process
      └── Codrift.Web                   — Francis HTTP/WS/SSE server
          ├── GET  /diff/:initiative_id — rich diff HTML view
          ├── SSE  /events/:agent_id    — live agent output stream
          └── WS   /mcp                — MCP server endpoint
```

**Pure modules (no processes):**
- `Codrift.Initiative` — struct + validation
- `Codrift.Diff` / `Codrift.Diff.Parser` — git diff generation and parsing
- `Codrift.Agent` — behaviour for CLI adapters
- `Codrift.Keymap` — keybinding lookup (load-time map)
- `Codrift.Action` — behaviour for command palette actions
- `Codrift.Pane` — pane tree data structure (split/focus/resize operations)

**Open decision:** TUI rendering library (Ratatouille, raw ANSI, or other).
Steps 5–7 are blocked until this is resolved.

---

## Build Order

| # | Step | Status | Notes |
|---|------|--------|-------|
| 1 | Project skeleton | ✅ Done | Francis + supervision tree |
| 2 | Initiative model + persistence | ✅ Done | GenServer + JSON file |
| 3 | Agent process (Port → CLI) | ✅ Done | DynamicSupervisor + behaviour |
| 4 | Diff module | ✅ Done | `git diff` parser, pure functions |
| 5 | Pane data structure | ⬜ Pending TUI decision | Pure tree: split/focus/resize |
| 6 | TUI render loop | 🚫 Blocked | Needs TUI library |
| 7 | Command palette | 🚫 Blocked | Needs TUI layer |
| 8 | Keybinding layer | 🚫 Blocked | Needs TUI layer |
| 9 | Web diff view | ⬜ Next up | Francis SSE + static HTML |
| 10 | MCP server | ⬜ Next up | WS endpoint in Francis |
| 11 | Multi-agent per initiative | ⬜ Next up | Supervisor already supports it |

---

## Module Reference

### Codrift.Initiative
Struct: `%{id, name, dirs, created_at}`

### Codrift.Initiative.Store
GenServer. Persists to `~/.config/codrift/initiatives.json` (configurable via
`:path` opt for tests). Accepts `:name` opt for test isolation.

API: `create/2`, `get/1`, `list/0`, `add_dir/2`, `remove_dir/2`, `delete/1`

### Codrift.AgentProcess
GenServer wrapping a Port to an external CLI process.
State: `%{id, initiative_id, dir, adapter, port, status, buffer, subscribers}`
Status values: `:starting | :idle | :running | :awaiting_input | :stopped`

API: `send_input/2`, `status/1`, `recent_output/2`, `subscribe/2`

### Codrift.AgentSupervisor
DynamicSupervisor. Accepts `:name` opt and `server` param for test isolation.

API: `start_agent/4`, `stop_agent/2`, `list_agents/1`

### Codrift.Agent (behaviour)
Callbacks: `cmd/0`, `args/1`, `env/1`, `parse_status/1`
Adapters: `Codrift.Agent.Adapters.Claude`, `Codrift.Agent.Adapters.Aider`

### Codrift.Diff
Pure module. Shells out to `git diff` via `System.cmd/3`.

`generate(dir, opts)` → `{:ok, [%FileDiff{}]} | {:error, reason}`
`parse(patch)` → `[%FileDiff{}]`

Structs: `%FileDiff{path, old_path, hunks, additions, deletions}`
         `%Hunk{old_start, old_count, new_start, new_count, header, lines}`
         `%Line{type, content}` — type: `:add | :remove | :context`

---

## Key Decisions Made

| Decision | Choice | Reason |
|----------|--------|--------|
| Francis role | Web server only | No TUI capabilities in Francis |
| CLI agents | External OS processes via Port | CLIs are independent executables |
| Persistence | JSON file (~/.config/codrift/) | Simple, human-readable, v1 scope |
| Git diffs | Shell to `git diff` | Zero deps, covers all needed formats |
| JSON codec | Elixir 1.18 built-in `JSON` | No extra dep needed |
| Restart policy for agents | `:temporary` | User-driven restart, not automatic |
| Test isolation (named procs) | Accept `:name` opt, default `__MODULE__` | Avoids conflict with app-started procs |
