# Architecture

## Supervision tree

```
Codrift (Application)
  └── Codrift.Supervisor (:one_for_one)
      ├── {Registry, name: Codrift.AgentRegistry}
      │     Agent ID → pid lookup (+ initiative_id metadata)
      ├── {Registry, name: Codrift.ConductorRegistry}
      │     Initiative ID → conductor pid lookup
      ├── Codrift.SessionStore
      │     GenServer — SQLite-backed agent session UUIDs at ~/.codrift/codrift.db
      ├── Codrift.Initiative.Store
      │     GenServer — JSON-persisted initiative state at ~/.config/codrift/initiatives.json
      ├── Codrift.AgentSupervisor
      │     DynamicSupervisor — one child per running agent
      │       └── Codrift.AgentProcess
      │             GenServer + erlexec PTY → external CLI (Claude, Codex, Opencode, Gemini, Copilot, shell)
      ├── Codrift.ConductorSupervisor
      │     DynamicSupervisor — one Codrift.Conductor per orchestrated initiative
      ├── {Task.Supervisor, name: Codrift.TaskSupervisor}
      │     Async agent start tasks and OAuth device-flow polling
      ├── Codrift.OAuth.StateStore
      │     GenServer — in-memory PKCE verifier state (10-minute TTL)
      ├── Codrift.Scheduler
      │     Quantum — runs Codrift.Integration.Sync every 5 minutes
      ├── Codrift (Francis / Bandit)
      │     HTTP + SSE + WebSocket server on port 7437
      └── Codrift.ShutdownManager        (desktop release only)
            Unix-socket heartbeat from the Tauri shell; stops the backend when the app closes
```

## HTTP routes

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Returns `"ok"` |
| `GET` | `/api/health` | `%{ok: true}` liveness probe the UI polls to detect a dropped server |
| `POST` | `/api/rpc` | **Generic op endpoint** — `{name, args}` → `Codrift.Core.call/2`; backs the whole UI |
| `GET` | `/api/initiatives` | List initiatives (JSON) |
| `GET` | `/api/diff/:id` | Diff for an initiative (JSON) |
| `GET` | `/api/agent/:id` | Agent status (JSON) |
| `GET` | `/api/agent/:id/output` | Recent PTY output, Base64, oldest-first (`?n=`, ≤1000) — terminal scrollback replay |
| `WS` | `/ws/agent/:agent_id` | Bidirectional PTY input: `{t:"d",d}` keystrokes, `{t:"r",cols,rows}` resize |
| `SSE` | `/events/initiative/:id` | Live output stream (`output`, `stopped`, `conductor_*` events, Base64) |
| `POST` | `/mcp` | MCP JSON-RPC (HTTP transport) |
| `SSE` | `/mcp/sse` | MCP server-sent events endpoint |
| `GET` | `/oauth/start/:service` | Begin OAuth2 flow |
| `GET` | `/oauth/callback/:service` | OAuth2 redirect callback |
| `GET` | `/oauth/status` | Token status for all services |
| `Static` | `/` | The Vite-built Svelte SPA from `priv/static` (`index.html`, `assets/…`) |

> Agent **output** flows to the UI over SSE; agent **input** flows back over the
> WebSocket. `POST /api/rpc` handles everything else. `priv/static` also carries
> two standalone HTML prototypes (`diff.html`, `term.html`) kept for local
> experimentation; they are not part of the app shell.

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
| `Codrift.Integration.HTTP` | Req wrapper — GET/POST/GraphQL with JSON, 15s timeout |
| `Codrift.Integration.Sync` | Re-fetch item and rewrite `integration.md` |
| `Codrift.OAuth` | Token acquisition: PKCE browser, device flow |
| `Codrift.OAuth.Config` | Per-service OAuth parameters, env var names, endpoints |
| `Codrift.MCP.Handler` | JSON-RPC 2.0 dispatch |
| `Codrift.Config.Keybindings` | Loads `~/.codrift/keybindings.json`, merges over defaults; served to the UI via the `get_keybindings` RPC |
| `Codrift.Config.Settings` | Reads/writes `~/.codrift/settings.json`; tracks per-adapter start counts for agent picker sort order |

## Frontend

The desktop shell is a Tauri (Rust) window that spawns the Elixir `desktop`
release as a sidecar and points its webview at the Francis server on `:7437`.
The UI is a **Svelte 5** app (`assets/`, built with Vite) that renders agent
output in embedded **xterm.js** terminals (WebGL renderer, Canvas/DOM fallback),
highlights code with **Shiki**, and edits files in a **CodeMirror 6** pane with
Vim mode.

It talks to the backend through three channels: `POST /api/rpc` for all
request/response operations (`assets/src/lib/api.ts`), SSE for live agent output,
and a per-agent WebSocket for terminal input. See `src-tauri/` (Rust shell) and
`assets/src/` (Svelte UI).

![Context view — initiative sidebar, directories, and rendered context](images/context-overview.png)

The three main-pane tabs — **Context**, **Diff**, and **Tree** — are documented
in [diff-mode.md](diff-mode.md) and [tree-view.md](tree-view.md).

## Data flow

```
User action (Svelte UI)
  → POST /api/rpc  (Codrift.Core.call/2)
    → Codrift.AgentSupervisor.start_agent/4
      → Codrift.AgentProcess (GenServer)
        → erlexec PTY → claude / codex / opencode / gemini / $SHELL
          → {:agent_output, id, data}
            → SSE /events/initiative/:id  → xterm.js (live update)
            → MCP SSE subscribers (connected agents)

Keystrokes / resize (xterm.js)
  → WS /ws/agent/:agent_id
    → AgentProcess.send_raw / .resize → PTY
```

Agent output is buffered in `AgentProcess` (newest-first, cap 1000) and streamed
to all subscribers; the Svelte UI replays scrollback from
`GET /api/agent/:id/output` on connect, then feeds live PTY bytes straight into
xterm.js. `Codrift.Core` is the single shared operation layer — the HTTP `/api/rpc`
endpoint, the MCP handler, and the CLI all route through `Core.call/2`.
