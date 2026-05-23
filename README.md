# Codrift

> An AI coding companion for the terminal — drive multiple AI agents across
> your projects from a single keyboard-driven interface.

Codrift is an Elixir application that groups local directories into named
**initiatives** and runs AI coding agents (Claude Code, Aider, …) against
them. It exposes a live diff view, a streaming agent output feed, and an MCP
server so other tools can query and control it.

## Status

Early development. The supervision tree, agent management, diff engine, web
server, and MCP server are working. The TUI render layer is not built yet —
see [PLAN.md](PLAN.md) for the full roadmap.

## What it does today

| Capability | How |
|---|---|
| Run AI agents against any directory | `AgentSupervisor` → `AgentProcess` → Port → CLI |
| Group directories into initiatives | `Initiative.Store` → JSON persistence |
| Parse and serve git diffs | `Codrift.Diff` → `git diff` → structured output |
| Stream agent output live | SSE at `/events/initiative/:id` |
| Expose all state over MCP | `POST /mcp` + `GET /mcp/sse` |
| Browser diff viewer | `http://localhost:7437/diff.html` |

## Quick start

```bash
# Install deps
mix deps.get

# Start (with IEx for a live REPL)
iex -S mix

# Or just run the server
mix francis.server
```

The web server starts on **port 7437**.

### Register the MCP server with Claude Code

```bash
mix codrift.mcp.install
```

This runs `claude mcp add codrift --transport sse http://localhost:7437/mcp/sse`
(or prints the command if the Claude CLI is not in your PATH).

### Try it from IEx

```elixir
# Create an initiative
{:ok, init} = Codrift.Initiative.Store.create("my-project", ["/path/to/repo"])

# Start a Claude Code agent
{:ok, pid} = Codrift.AgentSupervisor.start_agent(
  init.id,
  "/path/to/repo",
  Codrift.Agent.Adapters.Claude
)

# Subscribe to live output
Codrift.AgentProcess.subscribe(pid)

# Send a prompt
Codrift.AgentProcess.send_input(pid, "explain this codebase")

# Read buffered output
Codrift.AgentProcess.recent_output(pid, 20)
```

### Browse the diff view

Open `http://localhost:7437/diff.html`, enter your initiative ID, and click
**Load diff**. Hit **Watch live** to stream agent output as it arrives.

## Architecture

```
Codrift.Supervisor (:one_for_one)
  ├── Registry (Codrift.AgentRegistry)   — agent ID → PID lookup
  ├── Codrift.Initiative.Store           — CRUD + JSON persistence
  ├── Codrift.AgentSupervisor            — one AgentProcess per running agent
  └── Codrift (Francis / Bandit)         — HTTP + SSE on port 7437
```

**Key modules:**

| Module | Role |
|---|---|
| `Codrift.Initiative` | Struct + serialisation for a named workspace |
| `Codrift.Initiative.Store` | GenServer: in-memory CRUD, JSON file persistence |
| `Codrift.AgentProcess` | GenServer: Port → external CLI, output buffer, subscriptions |
| `Codrift.AgentSupervisor` | DynamicSupervisor: spawn / stop / list agents |
| `Codrift.Agent` | Behaviour: `cmd/0`, `args/1`, `env/1`, `parse_status/1` |
| `Codrift.Diff` | Pure: `git diff` → `%FileDiff{}` structs |
| `Codrift.MCP.Handler` | Pure: JSON-RPC 2.0 dispatch over HTTP+SSE |

## HTTP API

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Health check |
| `GET` | `/api/initiatives` | List all initiatives |
| `GET` | `/api/diff/:id` | Current git diff for an initiative |
| `GET` | `/api/agent/:id` | Agent status |
| `SSE` | `/events/initiative/:id` | Live agent output stream |
| `POST` | `/mcp` | MCP JSON-RPC request |
| `SSE` | `/mcp/sse` | MCP server-initiated events |

## MCP tools

| Tool | Description |
|---|---|
| `list_initiatives` | All initiatives |
| `get_diff` | Git diff for an initiative |
| `list_agents` | Running agents |
| `start_agent` | Spawn an agent in a directory |
| `send_to_agent` | Send input to a running agent |
| `get_agent_output` | Recent stdout from an agent |

## Agent adapters

Codrift ships with adapters for **Claude Code** (`claude`) and **Aider**
(`aider`). Add your own by implementing `Codrift.Agent`:

```elixir
defmodule MyApp.Agent.Adapters.MyCLI do
  @behaviour Codrift.Agent

  @impl true
  def cmd, do: System.find_executable("mycli") || raise "mycli not found"

  @impl true
  def args(_dir), do: ["--flag"]

  @impl true
  def env(_dir), do: []

  @impl true
  def parse_status("prompt> " <> _), do: :awaiting_input
  def parse_status(_), do: nil
end
```

## Development

```bash
mix deps.get       # fetch dependencies
mix test           # run tests (60 tests)
mix credo --all    # lint (must be clean)
mix sobelow        # security audit
mix deps.audit     # dependency CVE check
```

## Roadmap

See [PLAN.md](PLAN.md) for the full build order. Next milestones:

- **Terminal pane** — PTY-backed shell sessions inside the TUI
- **SQLite memory** — `sqlite-vec` for semantic search over project context
- **TUI render layer** — blocked on TUI library choice
- **Command palette** — Raycast-style fuzzy action search
- **VS Code keybindings** — configurable keymap layer

## License

MIT
