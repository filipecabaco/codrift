# Codrift

> Drive multiple AI coding agents across your projects from a single keyboard-driven terminal interface.

Codrift groups local directories into named **initiatives** and runs AI coding agents (Claude Code, Aider, shell) against them — each in its own PTY, with full terminal emulation, live diff viewing, shared memory, and an MCP server so agents can coordinate with each other.

---

## Features

| | |
|--|--|
| **Full TUI** | Sidebar + agent panes, keyboard-driven, mouse support, no browser needed |
| **Multiple agents per dir** | Claude Code, Aider, Terminal — all running simultaneously |
| **Git worktrees** | Each dir gets an isolated branch; agents never touch your main checkout |
| **Live diff view** | Coloured split/unified diff per initiative, updated as agents work |
| **Shared memory** | FTS5 knowledge base per initiative — agents search it before starting, write to it when done |
| **MCP server** | Claude Code and other tools connect to Codrift and call its tools directly |
| **External integrations** | Pull context from GitHub Issues, Linear, Jira, Notion, and more |
| **Session persistence** | Claude sessions survive TUI restarts — agents resume where they left off |
| **Context folders** | Each initiative has `~/.codrift/initiatives/{id}/` picked up automatically by `--add-dir` |

---

## Quick start

```bash
# Install (macOS / Linux)
curl -fsSL https://codrift.sh/install.sh | sh

# Or run from source
mix deps.get
mix codrift.tui
```

### Register the MCP server

```bash
mix codrift.mcp.install
# or: codrift mcp install
```

This runs `claude mcp add codrift --transport sse http://localhost:7437/mcp/sse`.

---

## TUI overview

```
┌──────────────────────────────────────────────────────────┐
│ ● Context  ○ 2: Diff                                     │
├─────────────────┬────────────────────────────────────────┤
│ Initiatives     │                                        │
│  ● my-project   │  Initiative / dir / agent output       │
│   ◈ context     │  (updates as cursor moves)             │
│   ▸ ~/repo   ─── ──────────────────────────────────────  │
│     ◦ claude    │                                        │
│     ◦ terminal  │                                        │
├─────────────────┴────────────────────────────────────────┤
│ j/k:navigate  s:start  a:add-dir  d:delete  Ctrl+P:palette│
└──────────────────────────────────────────────────────────┘
```

### Key bindings (defaults)

| Key | Action |
|-----|--------|
| `j` / `k` / `↑` / `↓` | Navigate sidebar / scroll pane |
| `n` | New initiative |
| `a` | Add directory to initiative |
| `s` | Start Claude agent |
| `d` | Delete / stop (context-sensitive) |
| `W` | Toggle git worktree for current dir |
| `[` / `]` | Cycle initiative status |
| `1` / `2` | Context view / Diff view |
| `v` | Toggle unified ↔ split diff |
| `Ctrl+P` | Command palette |
| `Ctrl+B` | Toggle sidebar |
| `Ctrl+Q` | Quit |

All keys are configurable via `~/.codrift/keybindings.json`.

---

## Git worktrees

When adding a directory that has git, Codrift offers to create a worktree:

```
[x] Use git worktree  (w to toggle)
```

Agents run in the worktree — a full checkout on a dedicated `codrift/{id}/{slug}` branch — so your main working tree is never disturbed. Press `W` on any dir entry to enable/disable later. See [docs/worktrees.md](docs/worktrees.md).

---

## Shared memory

Each initiative has a searchable knowledge base. Agents write decisions, summaries, and snippets to it; new agents search it before starting work.

```bash
codrift memory search <initiative_id> "authentication"
codrift memory add    <initiative_id> decision "use JWT not sessions"
codrift memory recent <initiative_id>
```

MCP tools (`memory_search`, `memory_add`, `memory_delete`, …) are available to any connected agent. See [docs/memory.md](docs/memory.md).

---

## MCP tools

When the TUI is running, any MCP client on `http://localhost:7437/mcp/sse` can call:

| Category | Tools |
|----------|-------|
| Initiatives | `list_initiatives`, `create_initiative`, `add_dir`, `delete_initiative` |
| Agents | `list_agents`, `start_agent`, `send_to_agent`, `get_agent_output`, `get_diff` |
| Memory | `memory_search`, `memory_add`, `memory_delete`, `memory_recent`, `memory_list` |
| Integrations | `list_integration_items`, `import_from_integration`, `sync_initiative_context` |

---

## External integrations

Pull issue context directly into an initiative from:

GitHub Issues · GitHub Projects · Linear Issues · Linear Projects · GitLab · Jira · Notion · Shortcut · Asana

```bash
codrift integration auth github       # OAuth2 browser flow
codrift integration list github       # list open issues
codrift integration import github 42  # seed an initiative from issue #42
```

See [docs/integrations.md](docs/integrations.md).

---

## CLI reference

```
codrift tui
codrift mcp install

codrift initiative list
codrift initiative create <name>
codrift initiative add-dir <id> <path>
codrift initiative delete  <id>

codrift memory search <id> <query>
codrift memory add    <id> <type> <content>
codrift memory recent <id>
codrift memory stats  <id>

codrift integration services
codrift integration auth   <service>
codrift integration list   <service>
codrift integration import <service> <item_id>
```

---

## Architecture

```
Codrift.Supervisor (:one_for_one)
  ├── Registry (Codrift.AgentRegistry)
  ├── Codrift.Initiative.Store     — GenServer, JSON persistence
  ├── Codrift.SessionStore         — GenServer, SQLite session UUIDs
  ├── Codrift.AgentSupervisor      — DynamicSupervisor, one AgentProcess per agent
  │   └── Codrift.AgentProcess     — GenServer + erlexec PTY → Claude / Aider / shell
  ├── Codrift.TaskSupervisor       — async agent start tasks
  └── Codrift (Francis / Bandit)   — HTTP + SSE on port 7437
```

See [docs/architecture.md](docs/architecture.md) and [docs/modules.md](docs/modules.md).

---

## Development

```bash
mix deps.get
unbuffer mix test        # 291 tests
mix credo --strict
```

**Stack:** Elixir · [Francis](https://github.com/nicholasgasior/francis) · [ex_ratatui](https://github.com/filipecabaco/ex_ratatui) (forked) · SQLite (Exqlite) · erlexec

---

## License

MIT
