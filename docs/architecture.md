# Architecture

## Supervision tree

```
Codrift (Application)
  └── Codrift.Supervisor (:one_for_one)
      ├── {Registry, name: Codrift.AgentRegistry}
      │     Agent ID → pid lookup
      ├── Codrift.Initiative.Store
      │     GenServer — JSON-persisted initiative state at ~/.config/codrift/initiatives.json
      ├── Codrift.SessionStore
      │     GenServer — SQLite-backed Claude session UUIDs at ~/.codrift/codrift.db
      ├── Codrift.OAuth.StateStore
      │     GenServer — in-memory PKCE verifier state (10-minute TTL)
      ├── Codrift.AgentSupervisor
      │     DynamicSupervisor — one child per running agent
      │       └── Codrift.AgentProcess
      │             GenServer + erlexec PTY → external CLI (Claude, Codex, Opencode, Gemini, Copilot, shell)
      ├── {Task.Supervisor, name: Codrift.TaskSupervisor}
      │     Async agent start tasks and OAuth device-flow polling
      └── Codrift (Francis / Bandit)
            HTTP + SSE server on port 7437
```

## HTTP routes

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Health check |
| `GET` | `/api/initiatives` | List initiatives (JSON) |
| `GET` | `/api/diff/:id` | Diff for an initiative (JSON) |
| `GET` | `/api/agent/:id` | Agent status (JSON) |
| `SSE` | `/events/initiative/:id` | Live agent output stream |
| `POST` | `/mcp` | MCP JSON-RPC (HTTP transport) |
| `SSE` | `/mcp/sse` | MCP server-sent events endpoint |
| `GET` | `/oauth/start/:service` | Begin OAuth2 flow |
| `GET` | `/oauth/callback/:service` | OAuth2 redirect callback |
| `GET` | `/oauth/status` | Token status for all services |
| `Static` | `/diff.html` | Browser diff viewer |

## Pure modules (no processes)

| Module | Role |
|--------|------|
| `Codrift.Initiative` | Struct + serialisation + status lifecycle |
| `Codrift.Initiative.DirEntry` | Per-dir struct: source path, worktree path, `effective_path/1` |
| `Codrift.Worktree` | Git worktree lifecycle: ensure, remove, branch naming |
| `Codrift.Memory` | Per-initiative FTS5 knowledge base (SQLite, opens own connection per call) |
| `Codrift.Diff` | Git diff generation + parser |
| `Codrift.Agent` | Behaviour for CLI adapters; `available_adapters/0` detects installed CLIs; `tui?/0` callback for Ink/Bubble Tea adapters |
| `Codrift.Integration` | Behaviour for external service adapters |
| `Codrift.Integration.HTTP` | `:httpc` wrapper — GET/POST with JSON, no extra deps |
| `Codrift.Integration.Sync` | Re-fetch item and rewrite `integration.md` |
| `Codrift.OAuth` | Token acquisition: PKCE browser, device flow, guided token |
| `Codrift.OAuth.Config` | Per-service OAuth parameters, env var names, endpoints |
| `Codrift.MCP.Handler` | JSON-RPC 2.0 dispatch |
| `Codrift.Config.Keybindings` | Loads `~/.codrift/keybindings.json`, merges over defaults |
| `Codrift.Config.Theme` | Loads `~/.codrift/theme.json`, resolves named themes |
| `Codrift.Config.Settings` | Reads/writes `~/.codrift/settings.json`; tracks per-adapter start counts for agent picker sort order |
| `Codrift.TUI.VT100` | Pure Elixir VT100/ANSI terminal emulator |
| `Codrift.TUI.Sidebar` | Sidebar entry builder + renderer (context and diff modes) |
| `Codrift.TUI.Modals` | Modal overlay renderer |
| `Codrift.TUI.DirPicker` | Directory autocomplete |
| `Codrift.TUI.Styles` | Shared style helpers |
| `Codrift.TUI.ANSI` | ANSI strip utilities |
| `Codrift.TUI.Layout` | Layout helpers |

## Data flow

```
User keystroke
  → Codrift.TUI (ex_ratatui event loop)
    → handle_event/2
      → Codrift.AgentSupervisor.start_agent/4
        → Codrift.AgentProcess (GenServer)
          → erlexec PTY → claude / codex / opencode / gemini / $SHELL
            → {:agent_output, id, data}
              → TUI subscriber (live update)
              → MCP SSE subscribers (connected agents)
```

Agent output is buffered in `AgentProcess`, streamed to all subscribers, and emulated through `VT100` before rendering.
