# Codrift

> Drive multiple AI coding agents across your projects from a single keyboard-driven terminal.

Codrift is a TUI for running Claude Code, Codex, Opencode, Gemini, Copilot, and shell agents side-by-side. You group directories into **initiatives**, launch agents against each one, watch their output live, review diffs, and let them share knowledge through a built-in memory store — all without leaving the terminal.

```
┌──────────────────────────────────────────────────────────────┐
│ ● 1: Context  ○ 2: Diff  ○ 3: Tree                          │
├─────────────────┬────────────────────────────────────────────┤
│ Initiatives     │                                            │
│  ● my-app       │  Initiative / dir / agent output           │
│   ◈ context     │  (updates as cursor moves)                 │
│   ▸ ~/repo [wt] │                                            │
│     ◦ claude    │                                            │
│     ◦ terminal  │                                            │
├─────────────────┴────────────────────────────────────────────┤
│ j/k:navigate  s:start  a:add-dir  d:delete  Ctrl+P:palette  │
└──────────────────────────────────────────────────────────────┘
```

---

## Features

- **Full terminal UI** — sidebar + agent panes, keyboard-driven, mouse support, no browser needed
- **Multiple agents per directory** — Claude Code, Codex, Opencode, Gemini, Copilot, and a raw terminal shell, all running simultaneously
- **Git worktrees** — each directory gets an isolated branch; agents never touch your main checkout
- **Live diff view** — colour-coded split/unified diff per initiative, updated as agents work
- **Tree view** — mode `3` shows a file-tree browser with syntax-highlighted previews; `e` opens any file in your `$EDITOR` inside the TUI
- **Shared memory** — FTS5 knowledge base per initiative; agents search it before starting, write to it when done
- **MCP server** — Claude Code and other tools connect to Codrift and call its tools over SSE
- **External integrations** — pull context from GitHub, Linear, GitLab, Jira, Notion, and more
- **Session persistence** — Claude sessions survive TUI restarts; agents resume where they left off
- **Context folders** — each initiative has `~/.codrift/initiatives/{id}/` picked up automatically by `--add-dir`
- **Quick-open** — `codrift <file…>` opens files in a temporary initiative; promote to a named one with `P`

---

## Quick start

```bash
# macOS / Linux — one-line install
curl -fsSL https://codrift.sh/install.sh | sh

# Or run from source
mix deps.get
mix codrift.tui
```

Then register the MCP server so Claude Code can talk to Codrift:

```bash
codrift mcp install
# runs: claude mcp add codrift --transport sse http://localhost:7437/mcp/sse
```

---

## Core concepts

### Initiatives

An initiative is a named unit of work — a feature, bug fix, or project milestone. Each initiative holds one or more project directories and tracks its own status (`planning → ongoing → done → archived`). Everything — agents, memory, worktrees, integrations — lives under an initiative.

```
codrift initiative create "auth redesign"
codrift initiative add-dir <id> ~/projects/backend
codrift initiative add-dir <id> ~/projects/frontend
```

### Git worktrees

When adding a directory, Codrift can create a git worktree on a dedicated branch (`codrift/{id}/{slug}`). Agents operate there and their changes stay isolated until you're ready to merge.

Enable when adding a dir (`w` to toggle in the modal), or later with `W` on any dir entry. See [docs/worktrees.md](docs/worktrees.md).

```
  ▸ ~/projects/realtime  [wt]   1   ← clean worktree, 1 agent running
  ▸ ~/projects/walrus    [wt*]  0   ← dirty (uncommitted changes)
  ▸ ~/projects/other               ← no worktree
```

### Shared memory

Each initiative has a searchable knowledge base (SQLite FTS5). Agents write decisions, summaries, and code snippets to it; new agents search it before starting work — saving tokens and keeping them aligned across sessions.

```bash
codrift memory search <id> "authentication"
codrift memory add    <id> decision "use JWT not sessions"
codrift memory recent <id>
```

Agents can also call these as MCP tools (`memory_search`, `memory_add`, …). See [docs/memory.md](docs/memory.md).

### MCP server

While the TUI is running, an MCP server listens at `http://localhost:7437/mcp/sse`. Any connected agent can call:

| Category | Tools |
|----------|-------|
| Initiatives | `list_initiatives`, `create_initiative`, `add_dir`, `delete_initiative`, `set_initiative_status`, `get_diff` |
| Agents | `list_agents`, `start_agent`, `send_to_agent`, `get_agent_output` |
| Memory | `memory_search`, `memory_add`, `memory_delete`, `memory_recent`, `memory_list` |
| Integrations | `start_oauth_flow`, `save_guided_token`, `get_oauth_status`, `list_integration_items`, `import_from_integration`, `sync_initiative_context` |

---

## Keyboard reference

### Global

| Key | Action |
|-----|--------|
| `j` / `k` / `↑` / `↓` | Navigate sidebar / scroll pane |
| `1` | Context view |
| `2` | Diff view |
| `3` | Tree view |
| `Ctrl+P` | Command palette |
| `Ctrl+B` | Toggle sidebar |
| `Ctrl+D` / `Ctrl+U` | Half-page scroll |
| `Ctrl+Q` | Quit |

### Initiatives & agents

| Key | Action |
|-----|--------|
| `n` | New initiative (or new file/dir in tree mode) |
| `a` | Add directory to initiative |
| `s` | Start agent (Claude / Codex / Opencode / Gemini / Copilot / Terminal) |
| `d` | Delete or stop (context-sensitive) |
| `W` | Toggle git worktree for current directory |
| `[` / `]` | Cycle initiative status |
| `P` | Promote temp initiative to named |

### Context & diff

| Key | Action |
|-----|--------|
| `c` | Create context file |
| `e` | Open context file / tree file in `$EDITOR` |
| `v` | Toggle unified ↔ split diff |
| `r` | Refresh diff |
| `*` | Reset diff to all files |

### Tree view

| Key | Action |
|-----|--------|
| `Enter` / `Space` | Expand / collapse directory |
| `→` / `←` | Expand / collapse directory |
| `e` | Open file at cursor in `$EDITOR` |
| `Tab` | Cycle focus between sidebar and preview pane |

### Input

| Key | Action |
|-----|--------|
| `Ctrl+V` | Paste mode toggle (fallback for terminals without bracketed paste) |
| `Shift+Enter` | Insert newline in input |
| `Tab` | Insert tab character |

All keys are configurable in `~/.codrift/keybindings.json`. See [docs/keyboard.md](docs/keyboard.md) for the full reference.

---

## External integrations

Pull issue context directly into an initiative from:

**GitHub Issues · GitHub Projects · Linear Issues · Linear Projects · GitLab · Jira · Notion · Shortcut · Asana**

```bash
codrift integration auth github       # OAuth2 browser flow
codrift integration list github       # list open issues
codrift integration import github 42  # seed an initiative from issue #42
```

Both OAuth (PKCE / device flow, fully TUI-driven) and personal API token fallbacks are supported. No secrets are stored in the binary. See [docs/integrations.md](docs/integrations.md).

---

## CLI reference

```
codrift tui
codrift mcp install

codrift initiative list
codrift initiative create <name>
codrift initiative add-dir <id> <path>
codrift initiative delete  <id>
codrift initiative worktree-status  <id>
codrift initiative worktree-enable  <id> <path>
codrift initiative worktree-disable <id> <path>

codrift memory search <id> <query>
codrift memory add    <id> <type> <content>
codrift memory recent <id>
codrift memory list   <id> <type>
codrift memory delete <id> <rowid>
codrift memory stats  <id>

codrift integration services
codrift integration auth   <service>
codrift integration list   <service>
codrift integration import <service> <item_id>
codrift integration revoke <service>
codrift integration tokens
```

---

## Documentation

[Architecture](docs/architecture.md) · [Keyboard reference](docs/keyboard.md) · [Tree view](docs/tree-view.md) · [Diff mode](docs/diff-mode.md) · [Worktrees](docs/worktrees.md) · [Memory](docs/memory.md) · [Integrations](docs/integrations.md) · [Modules](docs/modules.md) · [Decisions](docs/decisions.md)

---

## Architecture

```
Codrift (Application)
  └── Codrift.Supervisor (:one_for_one)
      ├── Registry (Codrift.AgentRegistry)    — agent ID → pid lookup
      ├── Codrift.Initiative.Store            — GenServer, JSON persistence
      ├── Codrift.SessionStore                — GenServer, SQLite session UUIDs
      ├── Codrift.OAuth.StateStore            — GenServer, in-memory PKCE state
      ├── Codrift.AgentSupervisor             — DynamicSupervisor, one child per agent
      │   └── Codrift.AgentProcess            — GenServer + erlexec PTY → Claude / Codex / Opencode / Gemini / shell
      ├── {Task.Supervisor, Codrift.TaskSupervisor}
      └── Codrift (Francis / Bandit)          — HTTP + SSE on port 7437
```

See [docs/architecture.md](docs/architecture.md) and [docs/modules.md](docs/modules.md).

---

## Development

```bash
mix deps.get
unbuffer mix test        # full test suite
mix credo --strict
mix dialyzer
```

**Stack:** Elixir · [Francis](https://github.com/nicholasgasior/francis) · [ex_ratatui](https://github.com/filipecabaco/ex_ratatui) · SQLite (Exqlite) · erlexec

### Supported platforms

| Platform | Target |
|----------|--------|
| macOS (Apple Silicon) | `aarch64-apple-darwin` |
| macOS (Intel) | `x86_64-apple-darwin` |
| Linux x86\_64 | `x86_64-linux-gnu` |
| Linux arm64 | `aarch64-linux-gnu` |

---

## License

MIT
