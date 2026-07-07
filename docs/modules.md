# Module Reference

## Codrift.Initiative

Struct: `%{id, name, dirs, created_at, status, integration, worktree_default}`

- `dirs` is `[%DirEntry{}]` — see `Codrift.Initiative.DirEntry`
- `status`: `:planning | :ongoing | :done | :archived`

API: `new/2`, `to_map/1`, `from_map/1`, `next_status/1`, `prev_status/1`

## Codrift.Initiative.DirEntry

Struct representing one project directory within an initiative.

| Field | Type | Description |
|-------|------|-------------|
| `path` | `String.t()` | Source path — canonical identity, used for display |
| `worktree_enabled` | `boolean()` | Whether a worktree is active |
| `worktree_path` | `String.t() \| nil` | Absolute path to the worktree directory |

`effective_path/1` returns `worktree_path` when set, otherwise `path`.
`from_value/1` accepts legacy plain strings for transparent migration.

See [worktrees.md](worktrees.md).

## Codrift.Initiative.Store

GenServer. Persists to `~/.config/codrift/initiatives.json`. Context folders live at `~/.codrift/initiatives/{id}/`; a `CLAUDE.md` symlink is created automatically and backfilled for existing initiatives on startup.

Accepts `:path`, `:name`, `:context_dir_base` opts for test isolation.

API: `create/2`, `get/1`, `list/0`, `add_dir/2,3,4`, `remove_dir/2`, `delete/1`, `set_status/2`, `set_worktree_default/3`, `toggle_dir_worktree/3`, `context_path/1`

## Codrift.Worktree

Pure module. Git worktree lifecycle management. See [worktrees.md](worktrees.md).

API: `git_repo?/1`, `ensure/3`, `remove/2`, `status/1`, `worktree_path/2`, `branch_name/2`

## Codrift.Memory

Pure module. Per-initiative FTS5 full-text search over agent knowledge. See [memory.md](memory.md).

API: `search/2`, `add/4`, `delete/2`, `recent/2`, `list/2`, `stats/1`, `valid_types/0`

## Codrift.SessionStore

GenServer. SQLite-backed (Exqlite, `~/.codrift/codrift.db`). Persists session UUIDs per agent across restarts. Rows include adapter name; `adapter` column added via non-destructive `ALTER TABLE` migration.

API: `save/5` (agent_id, initiative_id, dir, session_id, adapter_name), `get_by_agent/1`, `list_all/0` → `[{agent_id, initiative_id, dir, session_id, adapter}]`, `list_by_dir/2`, `delete_by_agent/1`, `prune_deleted_initiatives/1`

## Codrift.AgentProcess

GenServer owning an erlexec PTY (`:pty` mode) or Port (`:interactive` / `:once`).

**State fields:** `id`, `initiative_id`, `dir`, `adapter`, `mode`, `exec_pid`, `exec_ospid`, `port`, `status`, `buffer`, `buffer_size`, `subscribers`, `conversation_started`, `raw_line_buf`, `session_uuid`

**Status:** `:starting | :idle | :running | :awaiting_input | :stopped`

Subscribers receive `{:agent_output, id, data}`, `{:agent_ready, id}`, and `{:agent_stopped, id, code}`.

For session-persistable adapters, a stable session UUID is generated (or reused
from `SessionStore`) **before** the process launches and passed to the CLI — so
the UUID is always known up front and never needs to be discovered from disk.

API: `send_input/2`, `send_raw/2`, `resize/3`, `status/1`, `recent_output/2`, `session_uuid/1`, `subscribe/2`

## Codrift.AgentSupervisor

DynamicSupervisor. Accepts `:name` / `server` for test isolation.

API: `start_agent/4`, `stop_agent/2`, `list_agents/1`, `find_agent/2`, `list_agents_for_initiative/2`

## Codrift.Conductor

GenServer. Orchestrates multiple `AgentProcess`es under a single initiative. Two modes:

- **Fan-out** (`start_conductor/3`) — starts one agent per directory and broadcasts prompts to all of them.
- **Orchestrator** (`start_orchestration/3`) — starts one Claude agent in the initiative's context dir with a planning prompt (from `orchestration.md`); that agent uses Codrift's MCP tools to spawn and direct sub-agents itself. Agents are tracked with a role of `:orchestrator` or `:worker`.

Subscribers receive `{:conductor_output, initiative_id, agent_id, chunk}`, `{:conductor_agent_ready, …}`, and `{:conductor_agent_stopped, …, exit_code}`.

API: `broadcast/2`, `send_to/3`, `results/1`, `agent_status/1`, `subscribe/2`

## Codrift.ConductorSupervisor

DynamicSupervisor. One `Conductor` per initiative, registered in `ConductorRegistry`.

API: `start_conductor/3`, `start_orchestration/4`, `find_conductor/2`, `stop_conductor/2`, `list_conductors/1`

## Codrift.Agent (behaviour)

Callbacks: `cmd/0`, `mode/0`, `args/2`, `args_continue/1`, `env/1`, `parse_status/1`, `session_persistable?/0`, `tui?/0`

**Adapters:**

| Adapter | Mode | Notes |
|---------|------|-------|
| `Codrift.Agent.Adapters.Claude` | `:pty` | Session persistence via `--resume`/`--session-id`; `--add-dir` for context folder |
| `Codrift.Agent.Adapters.Codex` | `:pty` | OpenAI Codex CLI interactive REPL |
| `Codrift.Agent.Adapters.Opencode` | `:pty` | Bubble Tea TUI; `\e[2J` signals ready |
| `Codrift.Agent.Adapters.Gemini` | `:pty` | Google Gemini CLI; Ink TUI |
| `Codrift.Agent.Adapters.Copilot` | `:interactive` | `gh copilot suggest` |
| `Codrift.Agent.Adapters.Terminal` | `:pty` | Opens `$SHELL`; any output → `:awaiting_input` |

`tui?/0` — returns `true` for Ink/Bubble Tea adapters (Claude, Codex, Opencode, Gemini); drives `chunks_from_last_clear` replay, two-step PTY resize, and re-subscription nudge. `parse_status/1` detects `\e[2J` as universal TUI-ready signal.

**Modes:**
- `:pty` — erlexec PTY, full terminal emulation
- `:interactive` — Port with pipes
- `:once` — new Port per message

## Codrift.Diff

Pure module. Shells `git diff` via `System.cmd/3`, parses unified diff format.

| Function | Returns |
|----------|---------|
| `generate(dir, opts)` | `{:ok, [%FileDiff{}]} \| {:error, reason}` |
| `parse(patch)` | `[%FileDiff{}]` |
| `to_map(file_diff)` | JSON-serialisable map |
| `to_unified(file_diff)` | Unified diff string (for unified view) |
| `to_split_rows(file_diff)` | `[{:header \| :context \| :change, old \| nil, new \| nil}]` |
| `to_split_lines(file_diff)` | `[{old_line \| nil, new_line \| nil}]` (compatibility) |

**Structs:**
- `%FileDiff{path, old_path, hunks, additions, deletions}`
- `%Hunk{old_start, old_count, new_start, new_count, header, lines}`
- `%Line{type, content}` — type: `:add | :remove | :context`

## Codrift.Config.Keybindings

Pure module. Loads `~/.codrift/keybindings.json`; merges user overrides over built-in defaults.

`load/0` returns a `%{action => key}` map. The desktop UI fetches it through the
`get_keybindings` RPC (see `Codrift.Core`) and drives its own key dispatch and
palette hints, so displayed labels always match the user's config.

## Codrift.Config.Settings

Pure module. Reads/writes `~/.codrift/settings.json` (Elixir 1.18+ JSON module).

Tracks per-adapter start counts for sorting the agent launcher (most-used first).

API: `adapter_start_counts/0`, `increment_adapter_start/1`

## Codrift.Integration (behaviour)

Behaviour for external service adapters.

Callbacks: `name/0`, `list_items/1`, `get_item/2`, `to_initiative_context/1`

`%Item{}` fields: `id`, `title`, `description`, `url`, `labels`, `status`, `assignee`, `linked_prs`

Adapters: `GitHub`, `GitHubProjects`, `Linear`, `LinearProjects`, `GitLab`

## Codrift.Integration.HTTP

Pure module. Thin [Req](https://hex.pm/packages/req) wrapper — GET/POST/GraphQL with JSON decode and Bearer auth; 15 s timeout, non-2xx → `{:error, "HTTP {status}: {body}"}`.

API: `get/2`, `post/3`, `graphql/4`

## Codrift.Integration.Sync

Pure module. Re-fetches an item from the linked integration and rewrites `integration.md` in the initiative's context folder.

API: `sync/1`

## Codrift.OAuth

Pure module. Manages OAuth2 token acquisition and storage for external integrations.

**Flow types:**

| Flow | Services | Description |
|------|----------|-------------|
| PKCE browser | Linear, LinearProjects, GitLab | RFC 7636; `start_flow/1` returns `auth_url`; `handle_callback/3` exchanges code + verifier |
| Device flow | GitHub, GitHubProjects | RFC 8628; `start_flow/1` returns `user_code` + `verification_uri`; `poll_device_auth/5` polls in a supervised Task |

Tokens stored at `~/.codrift/oauth_tokens.json` (mode 0600).

API: `start_flow/1`, `handle_callback/3`, `poll_device_auth/5`, `save_token/2`, `get_token/1`, `revoke/1`

## Codrift.OAuth.Config

Pure module. Declares OAuth parameters (flow type, scopes, endpoints, env var names) per service.

API: `for_service/1`, `services/0`, `client_id/1`, `token_from_env/1`

## Codrift.OAuth.StateStore

GenServer. Holds in-memory PKCE state (verifier + metadata) while a browser flow is in progress. Entries expire after 10 minutes.

API: `put/2`, `pop/1`

## Codrift.MCP.Handler

Pure module. JSON-RPC 2.0 dispatch over HTTP + SSE transport.

Install: `codrift mcp install` (or `mix codrift.mcp.install`)

| Category | Tools |
|----------|-------|
| Initiatives | `list_initiatives`, `get_diff`, `create_initiative`, `add_dir`, `delete_initiative`, `set_initiative_status` |
| Agents | `list_agents`, `start_agent`, `send_to_agent`, `get_agent_output`, `broadcast_to_initiative` |
| Orchestration | `start_conductor`, `start_orchestration`, `get_conductor_status`, `get_conductor_results` |
| Memory | `memory_search`, `memory_add`, `memory_delete`, `memory_recent`, `memory_list` |
| Integrations | `start_oauth_flow`, `get_oauth_status`, `list_integration_items`, `import_from_integration`, `sync_initiative_context` |
