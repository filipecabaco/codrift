# Module Reference

## Codrift.Initiative

Struct: `%{id, name, dirs, created_at, status}`
Status: `:planning | :ongoing | :done | :archived`
API: `new/2`, `to_map/1`, `from_map/1`, `next_status/1`, `prev_status/1`

## Codrift.Initiative.Store

GenServer. Persists to `~/.config/codrift/initiatives.json`.
Accepts `:path` and `:name` opts for test isolation.
Context folders live at `~/.codrift/initiatives/{id}/`; CLAUDE.md symlink is created automatically and backfilled for existing initiatives on startup.

API: `create/2`, `get/1`, `list/0`, `add_dir/2`, `remove_dir/2`, `delete/1`, `set_status/2`, `context_path/1`

## Codrift.SessionStore

GenServer. SQLite-backed (via Exqlite, at `~/.codrift/codrift.db`).
Persists Claude Code session UUIDs per `(initiative_id, dir)` pair so agents can be resumed via `claude --resume <uuid>` across TUI restarts.

API: `save/3`, `get/2`, `list_all/0`

## Codrift.AgentProcess

GenServer owning an erlexec PTY (`:pty` mode) or Port (`:interactive` / `:once`).

State: `%{id, initiative_id, dir, adapter, mode, exec_pid, exec_ospid, port, status, buffer, buffer_size, subscribers, conversation_started, raw_line_buf, session_uuid}`

Status: `:starting | :idle | :running | :awaiting_input | :stopped`

Subscribers receive `{:agent_output, id, data}`, `{:agent_ready, id}`, and `{:agent_stopped, id, code}`.

Session UUID is auto-detected by polling `~/.claude/projects/<encoded-dir>/` for `.jsonl` files modified at or after agent start time (3 s delay, one retry at 8 s).

API: `send_input/2`, `send_raw/2`, `resize/3`, `status/1`, `recent_output/2`, `session_uuid/1`, `subscribe/2`

## Codrift.AgentSupervisor

DynamicSupervisor. Accepts `:name`/`server` for test isolation.

API: `start_agent/4`, `stop_agent/2`, `list_agents/1`, `find_agent/2`, `list_agents_for_initiative/2`

## Codrift.Agent (behaviour)

Callbacks: `cmd/0`, `mode/0`, `args/2`, `args_continue/1`, `env/1`, `parse_status/1`

Adapters: `Codrift.Agent.Adapters.Claude`, `Codrift.Agent.Adapters.Aider`, `Codrift.Agent.Adapters.Terminal`

**Modes:**
- `:pty` — erlexec PTY, full terminal
- `:interactive` — Port with pipes
- `:once` — new Port per message

Claude adapter: `:pty`, passes `--resume <uuid>` or `--continue` from SessionStore, `--add-dir` for context folder.
Terminal adapter: `:pty`, opens `$SHELL` (falls back to `bash`), any output → `:awaiting_input`.
Aider adapter: `:interactive`, plain pipes.

## Codrift.Diff

Pure module. Shells `git diff` via `System.cmd/3`, parses unified diff format.

| Function | Returns |
|----------|---------|
| `generate(dir, opts)` | `{:ok, [%FileDiff{}]} \| {:error, reason}` |
| `parse(patch)` | `[%FileDiff{}]` |
| `to_map(file_diff)` | JSON-serialisable map |
| `to_unified(file_diff)` | Unified diff string (for unified view) |
| `to_split_rows(file_diff)` | `[{:header \| :context \| :change, old \| nil, new \| nil}]` — typed rows for coloured split view |
| `to_split_lines(file_diff)` | `[{old_line \| nil, new_line \| nil}]` — untyped pairs (kept for compatibility) |

Structs:
- `%FileDiff{path, old_path, hunks, additions, deletions}`
- `%Hunk{old_start, old_count, new_start, new_count, header, lines}`
- `%Line{type, content}` — type: `:add | :remove | :context`

## Codrift.TUI.Sidebar

Builds and renders sidebar entries for both context mode and diff mode.

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
`render_diff/3` — diff sidebar widget (title: "Changed Files")

## Codrift.TUI.VT100

Pure Elixir VT100/ANSI terminal emulator. No Rustler NIF needed.

| Function | Description |
|----------|-------------|
| `new(width, height)` | Allocate virtual screen (cell grid) |
| `process(screen, data)` | Feed raw PTY bytes; updates cursor, cells, style, scroll region |
| `to_text(screen, show_cursor)` | Convert cell grid to `%ExRatatui.Text{}` for `Paragraph` |
| `resize(screen, width, height)` | Notify of dimension changes |

Supported sequences: SGR colors/modifiers + attribute-off (21–29), cursor movement (H/f/A/B/C/D/G/d), erase (J/K/X), insert/delete chars (@/P), IL/DL (L/M), SU/SD (S/T), scroll region (r), save/restore cursor (ESC 7/8, [s/u), alternate screen (?1049h/l), cursor visibility (?25h/l), OSC/DCS/PM/APC skip, incomplete-sequence carry buffer across PTY chunks.

## Codrift.Config.Keybindings

Pure module. Loads `~/.codrift/keybindings.json` at TUI start; merges user overrides over the built-in defaults.

`load/0` → `%{action => key}` map (forward) + reverse map `%{key => action}` for dispatch.

Defaults cover all TUI actions; any key in the JSON file overrides the corresponding action. Palette hints and footer status bar read from the resolved map so displayed key labels always match the user's config.

## Codrift.Config.Theme

Pure module. Loads `~/.codrift/theme.json` at TUI start; resolves to a theme struct used by `Codrift.TUI.Styles`.

`load/0` → `%Theme{}` struct with fields: `border`, `sidebar_highlight`, `diff_border`, `syntax_theme`.

Named themes: `default`, `dracula`, `nord`, `solarized`, `tokyo_night`. Unknown theme names and missing files fall back to `default`.

## Codrift.MCP.Handler

Pure module. JSON-RPC 2.0 over HTTP+SSE transport.
Install: `mix codrift.mcp.install`

Tools: `list_initiatives`, `get_diff`, `list_agents`, `start_agent`, `send_to_agent`, `get_agent_output`, `create_initiative`, `add_dir`, `delete_initiative`
