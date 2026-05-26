# Architecture

## Supervision tree

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

## Pure modules (no processes)

| Module | Role |
|--------|------|
| `Codrift.Initiative` | Struct + serialisation + status lifecycle |
| `Codrift.Diff` | Git diff generation + parser |
| `Codrift.Agent` | Behaviour for CLI adapters |
| `Codrift.MCP.Handler` | JSON-RPC dispatch |
| `Codrift.Config.Keybindings` | Loads `~/.codrift/keybindings.json`, merges over defaults, exposes reverse-lookup map |
| `Codrift.Config.Theme` | Loads `~/.codrift/theme.json`, resolves named themes to style structs |
| `Codrift.TUI.VT100` | Pure Elixir VT100/ANSI terminal emulator |
| `Codrift.TUI.Sidebar` | Sidebar entry builder + renderer (context and diff modes) |
| `Codrift.TUI.Modals` | Modal overlay renderer |
| `Codrift.TUI.DirPicker` | Directory autocomplete |
| `Codrift.TUI.Styles` | Shared style helpers |
| `Codrift.TUI.ANSI` | ANSI strip utilities |
| `Codrift.TUI.Layout` | Layout helpers |
