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

GenServer. SQLite-backed (Exqlite, `~/.codrift/codrift.db`). Persists session UUIDs per agent across TUI restarts. Rows include adapter name; `adapter` column added via non-destructive `ALTER TABLE` migration.

API: `save/5` (agent_id, initiative_id, dir, session_id, adapter_name), `get_by_agent/1`, `list_all/0` → `[{agent_id, initiative_id, dir, session_id, adapter}]`, `list_by_dir/2`, `delete_by_agent/1`, `prune_deleted_initiatives/1`

## Codrift.AgentProcess

GenServer owning an erlexec PTY (`:pty` mode) or Port (`:interactive` / `:once`).

**State fields:** `id`, `initiative_id`, `dir`, `adapter`, `mode`, `exec_pid`, `exec_ospid`, `port`, `status`, `buffer`, `buffer_size`, `subscribers`, `conversation_started`, `raw_line_buf`, `session_uuid`

**Status:** `:starting | :idle | :running | :awaiting_input | :stopped`

Subscribers receive `{:agent_output, id, data}`, `{:agent_ready, id}`, and `{:agent_stopped, id, code}`.

Session UUID is auto-detected by polling `~/.claude/projects/<encoded-dir>/` for `.jsonl` files modified at or after agent start time (3 s delay, one retry at 8 s).

API: `send_input/2`, `send_raw/2`, `resize/3`, `status/1`, `recent_output/2`, `session_uuid/1`, `subscribe/2`

## Codrift.AgentSupervisor

DynamicSupervisor. Accepts `:name` / `server` for test isolation.

API: `start_agent/4`, `stop_agent/2`, `list_agents/1`, `find_agent/2`, `list_agents_for_initiative/2`

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

## Codrift.TUI.VT100

Pure Elixir VT100/ANSI terminal emulator. No Rustler NIF.

| Function | Description |
|----------|-------------|
| `new(width, height)` | Allocate virtual screen (cell grid) |
| `process(screen, data)` | Feed raw PTY bytes; updates cursor, cells, style, scroll region |
| `to_text(screen, show_cursor)` | Convert cell grid to `%ExRatatui.Text{}` for `Paragraph` |
| `resize(screen, width, height)` | Notify of dimension changes |

Supported sequences: SGR colors/modifiers + attribute-off (21–29), cursor movement (H/f/A/B/C/D/G/d), erase (J/K/X), insert/delete chars (@/P), IL/DL (L/M), SU/SD (S/T), scroll region (r), save/restore cursor (ESC 7/8, [s/u), alternate screen (?1049h/l), cursor visibility (?25h/l), OSC/DCS/PM/APC skip, incomplete-sequence carry buffer across PTY chunks.

## Codrift.TUI.Sidebar

Builds and renders sidebar entries for context mode and diff mode.

**Context mode** — `build_entries(initiatives, agents)` → flat list of:
- `{:initiative, id, name, dir_count, agent_count, status}`
- `{:context_dir, initiative_id, path, agent_count}`
- `{:context_file, initiative_id, full_path, filename}`
- `{:dir, initiative_id, path, agent_count}`
- `{:agent, id, adapter, status}`

**Diff mode** — `build_diff_entries([{dir, [%FileDiff{}]}])` → flat list of:
- `{:diff_all, total_adds, total_dels}`
- `{:diff_dir, dir, adds, dels}`
- `{:diff_file, dir, path, adds, dels}`

`render/3` — context sidebar widget
`render_diff/3` — diff sidebar widget

## Codrift.TUI.SidebarFilter

Pure module. Filter state and matching logic for the sidebar in tree and diff modes.

Holds `%{query: String.t(), active: boolean()}`. Mode is inferred from the query — no explicit switching:

| Query form | Mode | Behaviour |
|------------|------|-----------|
| plain text | `:fuzzy` | case-insensitive substring |
| starts with `/` | `:regex` | Elixir `Regex`, case-insensitive |
| starts with `#` | `:tag` | predefined groups: `#test` `#config` `#doc` `#schema` `#router` |
| contains `*` or `?` | `:glob` | shell wildcards |

| Function | Description |
|----------|-------------|
| `new/0` | Blank, inactive filter |
| `activate/1` | Marks filter as accepting input |
| `deactivate/1` | Clears query and deactivates |
| `put_char/2` | Appends a printable character |
| `backspace/1` | Removes the last character |
| `mode/1` | Returns `:fuzzy \| :glob \| :regex \| :tag` |
| `matches?/2` | Tests a string under the active mode |
| `apply_tree/3` | Filters `all_files` to matching `{:tree_file, …}` entries |
| `apply_diff/2` | Retains only matching `{:diff_file, …}` entries |

Extend via `@tag_patterns`, `mode/1`, or `do_match/3`.

## Codrift.TUI.Tree

Pure module. Builds and navigates the file tree sidebar for tree mode.

| Function | Description |
|----------|-------------|
| `build_visible/2` | Flat list of entries respecting the `expanded` MapSet |
| `all_files/1` | Flat list of all `{:tree_file, …}` entries across every directory, regardless of expand state — used by `SidebarFilter` |
| `toggle_expand/2` | Toggles a path in the expanded `MapSet` |

## Codrift.Config.Keybindings

Pure module. Loads `~/.codrift/keybindings.json` at TUI start; merges user overrides over built-in defaults.

`load/0` returns a forward map `%{action => key}` and reverse map `%{key => action}` for dispatch. Palette hints and the footer status bar read from the resolved map so displayed labels always match the user's config.

## Codrift.Config.Theme

Pure module. Loads `~/.codrift/theme.json` at TUI start; resolves to a `%Theme{}` struct used by `Codrift.TUI.Styles`.

Fields: `border`, `sidebar_highlight`, `diff_border`, `syntax_theme`

Named themes: `default`, `dracula`, `nord`, `solarized`, `tokyo_night`. Unknown names and missing files fall back to `default`.

## Codrift.Config.Settings

Pure module. Reads/writes `~/.codrift/settings.json` (Elixir 1.18+ JSON module).

Tracks per-adapter start counts for sorting the agent picker modal (most-used first).

API: `adapter_start_counts/0`, `increment_adapter_start/1`

## Codrift.Integration (behaviour)

Behaviour for external service adapters.

Callbacks: `name/0`, `list_items/1`, `get_item/2`, `to_initiative_context/1`

`%Item{}` fields: `id`, `title`, `description`, `url`, `labels`, `status`, `assignee`, `linked_prs`

Adapters: `GitHub`, `GitHubProjects`, `Linear`, `LinearProjects`, `GitLab`, `Jira`, `Notion`, `Shortcut`, `Asana`

## Codrift.Integration.HTTP

Pure module. Thin `:httpc` wrapper — GET/POST with JSON decode, Bearer auth, no extra deps.

API: `get/2`, `post/3`

## Codrift.Integration.Sync

Pure module. Re-fetches an item from the linked integration and rewrites `integration.md` in the initiative's context folder.

API: `sync/1`

## Codrift.OAuth

Pure module. Manages OAuth2 token acquisition and storage for external integrations.

**Flow types:**

| Flow | Services | Description |
|------|----------|-------------|
| PKCE browser | Linear, GitLab, Jira | RFC 7636; `start_flow/1` returns `auth_url`; `handle_callback/3` exchanges code + verifier |
| Device flow | GitHub | RFC 8628; `start_flow/1` returns `user_code` + `verification_uri`; `poll_device_auth/5` polls in a supervised Task |
| Guided token | Notion, Shortcut, Asana | TUI shows a URL + token input field |

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
| Initiatives | `list_initiatives`, `get_diff`, `create_initiative`, `add_dir`, `delete_initiative` |
| Agents | `list_agents`, `start_agent`, `send_to_agent`, `get_agent_output` |
| Memory | `memory_search`, `memory_add`, `memory_delete`, `memory_recent`, `memory_list` |
| Integrations | `start_oauth_flow`, `get_oauth_status`, `list_integration_items`, `import_from_integration`, `sync_initiative_context` |
