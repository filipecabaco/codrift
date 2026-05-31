# Architecture

## Supervision tree

```
Codrift (Application)
  └── Codrift.Supervisor (:one_for_one)
      ├── {Registry, name: Codrift.AgentRegistry} — agent ID → pid lookup
      ├── Codrift.SessionStore       — GenServer, SQLite-backed Claude session IDs
      ├── Codrift.Initiative.Store   — GenServer, JSON-persisted initiative state
      ├── Codrift.OAuth.StateStore   — GenServer, in-memory PKCE state (10 min TTL)
      ├── Codrift.AgentSupervisor    — DynamicSupervisor, one child per running agent
      │   └── Codrift.AgentProcess   — GenServer + erlexec PTY → external CLI (Claude, Aider…)
      ├── {Task.Supervisor, name: Codrift.TaskSupervisor} — async agent start + OAuth polling
      └── Codrift (Francis)          — HTTP/SSE server on port 7437
          ├── GET  /                          — health
          ├── GET  /api/initiatives           — list initiatives (JSON)
          ├── GET  /api/diff/:id              — diff for initiative (JSON)
          ├── GET  /api/agent/:id             — agent status (JSON)
          ├── SSE  /events/initiative/:id     — live agent output stream
          ├── POST /mcp                       — MCP JSON-RPC (HTTP transport)
          ├── SSE  /mcp/sse                   — MCP server-sent events endpoint
          ├── GET  /oauth/start/:service      — begin OAuth2 flow
          ├── GET  /oauth/callback/:service   — OAuth2 redirect callback
          ├── GET  /oauth/status              — token status for all services
          └── Static /diff.html              — browser diff viewer
```

## Pure modules (no processes)

| Module | Role |
|--------|------|
| `Codrift.Initiative` | Struct + serialisation + status lifecycle |
| `Codrift.Initiative.DirEntry` | Per-dir struct: source path, worktree path, `effective_path/1` |
| `Codrift.Worktree` | Git worktree lifecycle: ensure, remove, branch naming |
| `Codrift.Memory` | Per-initiative FTS5 knowledge base (SQLite, opens own connection) |
| `Codrift.Diff` | Git diff generation + parser |
| `Codrift.Agent` | Behaviour for CLI adapters |
| `Codrift.Integration` | Behaviour for external service adapters (GitHub, Linear, etc.) |
| `Codrift.Integration.HTTP` | `:httpc` wrapper — GET/POST with JSON, no extra deps |
| `Codrift.Integration.Sync` | Re-fetch item and rewrite `integration.md` |
| `Codrift.OAuth` | Token acquisition: PKCE browser, device flow, guided token |
| `Codrift.OAuth.Config` | Per-service OAuth parameters, env var names, endpoints |
| `Codrift.MCP.Handler` | JSON-RPC dispatch |
| `Codrift.Config.Keybindings` | Loads `~/.codrift/keybindings.json`, merges over defaults |
| `Codrift.Config.Theme` | Loads `~/.codrift/theme.json`, resolves named themes |
| `Codrift.TUI.VT100` | Pure Elixir VT100/ANSI terminal emulator |
| `Codrift.TUI.Sidebar` | Sidebar entry builder + renderer (context and diff modes) |
| `Codrift.TUI.Modals` | Modal overlay renderer |
| `Codrift.TUI.DirPicker` | Directory autocomplete |
| `Codrift.TUI.Styles` | Shared style helpers |
| `Codrift.TUI.ANSI` | ANSI strip utilities |
| `Codrift.TUI.Layout` | Layout helpers |
