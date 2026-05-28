# Codrift — AI Coding Companion TUI

## Overview

Terminal UI application for driving AI coding agents across multiple working
directories grouped under a single "initiative". First-class diff viewing,
keyboard-driven actions, embedded web server for rich views, MCP server for
external tool integration. Full terminal emulator pane for arbitrary shell
access. SQLite for session persistence; SQLite + vector search planned for
project memory.

**Stack:** Elixir · Francis (web layer only) · ex_ratatui · Git (diffs) · SQLite (Exqlite)

**Docs:** [Architecture](docs/architecture.md) · [Modules](docs/modules.md) · [Decisions](docs/decisions.md)

---

## Build Order

### ✅ Done — Backend foundation

| # | Step | Notes |
|---|------|-------|
| 1 | Project skeleton | Francis + supervision tree, port 7437 |
| 2 | Initiative model + persistence | GenServer + JSON file; status lifecycle (planning/ongoing/done/archived) |
| 3 | Agent process (Port → CLI) | DynamicSupervisor + behaviour, Registry |
| 4 | Diff module | `git diff` parser, pure functions |
| 5 | Code quality | Credo clean, `@doc`/`@moduledoc` throughout |

### ✅ Done — TUI core

| # | Step | Notes |
|---|------|-------|
| 6 | Full VT100 emulation | Pure Elixir `Codrift.TUI.VT100`: cell-grid rendering, SGR colors, cursor movement, erase, scroll regions, IL/DL, SU/SD, OSC/DCS/APC skip, incomplete-sequence carry buffer, `to_text/2` → `%ExRatatui.Text{}` |
| 7 | TUI shell | `mix codrift.tui`, sidebar + output + diff panes |
| 8 | PTY agents + terminals | `erlexec :pty`, direct keypress forwarding, `t` key opens `$SHELL` pane |
| 9 | Task.Supervisor for async starts | `Codrift.TaskSupervisor` wraps agent start to avoid blocking TUI loop |
| 10 | Graceful shutdown | `terminate/2` kills all agents + terminals on TUI exit |
| 11 | Mouse support | Scroll (sidebar navigation / PTY arrow keys / pane scroll) + left-click focus switch |

### ✅ Done — TUI navigation & context

| # | Step | Notes |
|---|------|-------|
| 12 | Multi-dir sidebar | initiative → dir → agent hierarchy |
| 13 | Cursor-driven pane | initiative → overview, dir → git log, agent/terminal → ANSI output |
| 14 | Initiative management | `n` new, `a` add-dir, `s` start-agent, `d` delete/stop (context), `Ctrl+P` palette |
| 15 | Multiple agents + terminals per dir | `dir_entries/3` maps all agents under each dir into `{:agent, ...}` sidebar rows |
| 16 | Initiative root agents | `context_dir_entries/3` catches agents whose dir is the initiative context path |
| 17 | Initiative status lifecycle | `:planning → :ongoing → :done → :archived`; cycle with `[`/`]` keys |
| 18 | Context folder + CLAUDE.md | Each initiative gets `~/.codrift/initiatives/{id}/`; CLAUDE.md symlink shared to all dirs |
| 19 | In-TUI context file editor | `c` to create, `e` to open textarea editor, autosave every 500 ms, Esc to save & close |

### ✅ Done — Diff

| # | Step | Notes |
|---|------|-------|
| 20 | Web diff view | `/diff.html` + SSE `/events/initiative/:id` |
| 21 | Diff viewer overhaul | Sidebar transforms in diff mode; cursor-driven content pane; unified + coloured split view; `v` toggle; `*` reset. See [Diff Mode](docs/diff-mode.md). |

### ✅ Done — Agents & sessions

| # | Step | Notes |
|---|------|-------|
| 22 | Multi-agent per initiative | Registry lookup + initiative filter |
| 23 | Session persistence | `Codrift.SessionStore` (SQLite via Exqlite) stores Claude session UUIDs per initiative+dir; agents auto-detect session file and `--resume` on next start |
| 24 | Session auto-restart | TUI re-launches Claude agents from saved sessions on boot (`:autostart_sessions`) |
| 31 | Session store: multi-agent per dir | Schema keyed by `agent_id TEXT PRIMARY KEY`; `save/4`, `get_by_agent/1`, `list_by_dir/2`; migration drops old `(initiative_id, dir)` PK on first boot |

### ✅ Done — Integrations

| # | Step | Notes |
|---|------|-------|
| 25 | MCP server | HTTP+SSE transport, `mix codrift.mcp.install` |
| 26 | MCP initiative tools | `create_initiative`, `add_dir`, `delete_initiative` |

### ✅ Done — Polish

| # | Step | Notes |
|---|------|-------|
| 27 | Remove emoji from TUI | Replaced `📁`/`📂` → `▸`, `✏` → `~`, `⚠` → `!`; all Unicode line-art kept |
| 28 | Mode bar labels | `1: Context │ 2: Diff` — symmetric ASCII, no Unicode ball |
| 29 | Sidebar collapse | `Ctrl+B` toggles sidebar; PTY screens resize immediately; focus shifts to main on collapse |
| 30 | Command palette expansion | Toggle Sidebar, Context/Diff View, Toggle Diff Unified/Split, Diff All Files, Edit Context File, Cycle Status — grouped with section comments |

### ✅ Done — Config layer

| # | Step | Notes |
|---|------|-------|
| 32 | Keybinding config layer | `Codrift.Config.Keybindings` — loads `~/.codrift/keybindings.json`, merges over defaults; TUI dispatch uses reverse map; palette hints and footer status bar reflect configured keys |
| 33 | Theme chooser | `Codrift.Config.Theme` — loads `~/.codrift/theme.json`; named themes: `default`, `dracula`, `nord`, `solarized`, `tokyo_night`; controls border colours, sidebar highlight, diff border, and CodeBlock syntax theme |

### ✅ Done — Memory store, CLI & distribution

| # | Step | Notes |
|---|------|-------|
| 34 | Per-initiative memory store + CLI | `Codrift.Memory` (FTS5, pure module); `Codrift.CLI.{TUI,MCP,Initiative,Session,Memory}`; `rel/commands/` shell scripts; `releases:` in `mix.exs`; Mix tasks delegate to CLI modules; 5 new MCP tools (`memory_search/add/delete/recent/list`); `initiative.md` template includes hardcoded ID + CLI/MCP usage block |
| 35 | Distribution & installation | `install.sh` (curl-pipe-sh, 4-platform detection, `~/.local/share/codrift` + symlink); `.github/workflows/release.yml` (matrix: macOS ARM/Intel + Linux x86_64/ARM64 via `erlef/setup-beam`, `softprops/action-gh-release`) |
| 36 | GitHub Actions CI | `.github/workflows/ci.yml` — `mix deps.get` → `compile --warnings-as-errors` → `format --check-formatted` → `credo --strict` → `test`; deps + build cache keyed on `mix.lock` |

### ✅ Done — Safe paste + input hardening

| # | Step | Notes |
|---|------|-------|
| 41 | Safe paste + input hardening | Full 1:1 paste experience via bracketed paste mode. Forked `ex_ratatui` as `vendor/ex_ratatui` git submodule; NIF extended to deliver `Event::Paste(String)` → `%ExRatatui.Event.Paste{content}` atomically. `EnableBracketedPaste` in `init_terminal` (Rust), `DisableBracketedPaste` in `restore_terminal` and `Drop`. TUI: `handle_event(%Paste{})` appends whole string to buffer; PTY mode forwards as raw `\r`-normalised bytes. Additional fixes: Tab inserts `\t` in main non-PTY (any Tab+modifier cycles focus, covering Ctrl+Tab and Shift+Tab from all terminal emulators); Shift+Enter inserts `\n`; multi-byte Unicode input (em dash, curly quotes) handled by `byte_size > 1 and <= 4` guard placed after all named-key handlers; quit key changed from `q` to `Ctrl+Q` so `q` is safe to type in input buffer; `AgentProcess.handle_cast({:raw, _})` guards `nil` exec_pid; `paste_mode` (`Ctrl+V`) toggle preserved as fallback for terminals without bracketed paste. 67 tests. |

### ✅ Done — Sidequests

| Sidequest | Notes |
|-----------|-------|
| Reduce TUI flickering | **Done.** Five-layer fix: (1) `AgentProcess.resize` dedup via `last_size`; (2) resize only selected PTY — `resize_selected_pty` replaces `resize_all_ptys`; (3) `apply_resize` no-op guard + `render?: false`; (4) skip 600 ms nudge when agent has existing output; (5) cancel stale nudge/restore timers before scheduling. NIF layer: `BeginSynchronizedUpdate`/`EndSynchronizedUpdate` wrap every `draw_frame`; `render?: false` on pure side-effect callbacks (`nudge_agent`, `restore_agent_size`, `input_nudge`, non-selected `agent_output`, focus events). Fork also gains: `FocusGained`/`FocusLost` events, `copy_to_clipboard/1` (OSC 52), `set_title/1`. See [flickering sidequest](docs/flickering.md). |

---

### ✅ Done — External integrations

| # | Step | Notes |
|---|------|-------|
| 39 | External integrations | `Codrift.Integration` behaviour + `%Item{}` struct; `Codrift.Integration.HTTP` (`:httpc`, no extra deps); 9 adapters: GitHub Issues, GitHub Projects v2, Linear Issues, Linear Projects, GitLab, Jira, Notion, Shortcut, Asana; 3 new MCP tools (`list_integration_items`, `import_from_integration`, `sync_initiative_context`); `Codrift.CLI.Integration` (`codrift integration services/list/import/sync`); credentials in env vars; context written to `~/.codrift/initiatives/{id}/integration.md`; metadata in `integration.json` for sync. |

### ⬜ Upcoming

| # | Step | Notes |
|---|------|-------|
| 37 | Git worktrees per initiative | Per-initiative git worktree per dir; isolated branches; TUI shows worktree branch + dirty state. See *Upcoming: Git Worktrees per Initiative*. |
| 38 | Additional CLI adapters | Codex CLI, Opencode, Cursor Agent, Gemini CLI, Copilot CLI, and others. See *Upcoming: Additional CLI Adapters*. |
| 40 | Website | Landing page showcasing features, demo, install one-liner. See *Upcoming: Website*. |

---

## Upcoming: Additional CLI Adapters (Step 38)

The `Codrift.Agent` behaviour already abstracts all CLI differences. Adding a new
agent type is purely a matter of creating a new adapter module under
`lib/codrift/agent/adapters/` and registering it in the TUI picker.

### Behaviour recap (no changes needed)

```elixir
@callback cmd() :: String.t()           # executable name / path
@callback mode() :: :pty | :interactive | :once
@callback args(dir, context_opts) :: [String.t()]
@callback args_continue(dir) :: [String.t()]
@callback env(dir) :: [{String.t(), String.t()}]
@callback parse_status(data) :: agent_status | nil
```

### Adapters planned

| CLI | Mode | Notes |
|-----|------|-------|
| **OpenAI Codex CLI** (`codex`) | `:pty` | `codex` interactive REPL; pass `--cwd <dir>` |
| **Opencode** (`opencode`) | `:pty` | TUI-first agent; full PTY required |
| **Cursor Agent** (`cursor`) | `:pty` | Headless Cursor via `cursor --agent`; experimental |
| **Gemini CLI** (`gemini`) | `:pty` | Google's `gemini` CLI (OSS, released 2025); `--resume` flag TBD |
| **GitHub Copilot CLI** (`gh copilot`) | `:interactive` | Pipe-friendly; `gh copilot suggest` / `gh copilot explain` |
| **Amp** (`amp`) | `:pty` | Sourcegraph's Amp agent |
| **Goose** (`goose`) | `:pty` | Block's Goose agent; `goose run` |
| **Aider** | `:interactive` | Already partially implemented; complete `args_continue/1` |

### Session resume

Each adapter that supports session continuity implements `args_continue/1`
to emit the correct resume flag. `SessionStore` is adapter-agnostic — the
`agent_id` key works for any CLI. Adapters that have no resume concept simply
return `args/2` from `args_continue/1`.

### TUI changes

- Agent picker (the `s` key modal) lists all registered adapters, not just Claude
- Each sidebar `:agent` row shows a short adapter tag (e.g. `claude`, `codex`, `opencode`)
- `save_all_sessions/1` already guards with `adapter == Claude`; extend the guard
  to any adapter that returns a non-nil `session_uuid` (add `supports_resume?/0` callback)

**No changes to `AgentProcess`, `AgentSupervisor`, `SessionStore`, or the supervision tree** — the adapter pattern means all wiring is already in place. Each new CLI is ~40 lines of adapter code.

---

## Upcoming: External Integrations (Step 39)

Connect Codrift to external project management and collaboration tools so that initiatives can be seeded with real context (issue title, description, labels, linked PRs) and kept in sync as work progresses.

### Design principles

- **Read-first**: the primary flow is pulling context *into* Codrift, not pushing state back out.
- **One adapter per service**: each integration is a module implementing the `Codrift.Integration` behaviour.
- **Credentials in env**: API tokens read from environment variables; no secrets stored in the Codrift DB.
- **Context folder injection**: pulled content written into `~/.codrift/initiatives/{id}/` so every Claude agent picks it up via `--add-dir`.

### `Codrift.Integration` behaviour

```elixir
@callback name() :: String.t()
@callback list_items(opts :: keyword()) :: {:ok, [%Item{}]} | {:error, term()}
@callback get_item(id :: String.t(), opts :: keyword()) :: {:ok, %Item{}} | {:error, term()}
@callback to_initiative_context(%Item{}) :: String.t()
```

`%Item{}` carries: `id`, `title`, `description`, `url`, `labels`, `status`, `assignee`, `linked_prs`.

### Adapters planned

| Service | Notes |
|---------|-------|
| **Linear** | GraphQL API; create initiative per issue; sync status |
| **GitHub Issues** | REST + GraphQL; link PRs automatically; import milestone as initiative group |
| **GitHub Projects** | Import project board cards as initiatives |
| **GitLab Issues** | REST API |
| **Jira** | REST API v3; map Epic → initiative, Story → dir context |
| **Notion** | Blocks API; import a page or database row as initiative context |
| **Shortcut (Clubhouse)** | REST API; Story → initiative |
| **Asana** | REST API; Task or Project → initiative |
| **Linear Projects** | Import a Linear Project as a multi-dir initiative |

### MCP tools added

- `list_integration_items(service, filter?)` — list open issues/tasks from a connected service
- `import_from_integration(service, item_id, dir?)` — create an initiative from an external item
- `sync_initiative_context(initiative_id)` — re-fetch and overwrite the context file

---

## Done: Per-initiative Memory Store + CLI, Distribution & CI (Steps 34–36)

### Purpose

A shared, searchable knowledge base for every agent working on an initiative —
regardless of which directory they are in. Agents use it to **offload context**
(summaries, decisions, discovered patterns) instead of re-reading files or
re-deriving knowledge each session. Fewer tokens spent re-discovering the past
means faster, cheaper, more consistent work.

### Memory store

Each initiative gets a dedicated SQLite database at
`~/.codrift/initiatives/{id}/memory.db` alongside the existing `initiative.md`.
Uses SQLite's built-in FTS5 extension — no new dependencies, no vector
embeddings, no ORM.

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS memory USING fts5(
  chunk_type,  -- see vocabulary below
  content,
  source,      -- who wrote it: agent_id, "user", file path
  tokenize = 'porter unicode61'
);
-- rowid is implicit and used as the stable delete handle
```

**chunk_type vocabulary** (agents must use one of these):

| Type | When to use |
|------|-------------|
| `decision` | Architectural or design choices made during this initiative |
| `summary` | Completion summary after finishing a task or subtask |
| `snippet` | Reusable code pattern or config fragment worth remembering |
| `file_context` | What a key file does and why — saves re-reading it next session |
| `note` | Free-form observation that doesn't fit another type |

**`Codrift.Memory`** — pure module, no process, opens/closes its own DB
connection (safe for `eval` context, GenServer delegation, and direct test calls):

```elixir
Codrift.Memory.search(initiative_id, "authentication middleware")
# → [%{id: rowid, chunk_type, content, source, rank}]

Codrift.Memory.add(initiative_id, "decision", "Use JWT, not sessions", "agent-abc")
# → {:ok, rowid}

Codrift.Memory.delete(initiative_id, rowid)
# → :ok | {:error, :not_found}

Codrift.Memory.recent(initiative_id, limit \\ 20)
# → [%{id: rowid, chunk_type, content, source}]

Codrift.Memory.list(initiative_id, chunk_type)
# → [%{id: rowid, chunk_type, content, source}]  (filter by type)

Codrift.Memory.stats(initiative_id)
# → %{total: n, by_type: %{"decision" => 3, "snippet" => 7, ...}}
```

All results include `id` (the FTS5 rowid) so agents can delete stale or
incorrect entries they previously wrote.

The DB is removed automatically when the initiative is deleted.

### Agent discoverability: initiative.md template

`Initiative.Store.create/2` writes the following into `initiative.md` at
creation time, with the initiative ID **hardcoded** so agents running in any
subdirectory always have it without discovery:

```markdown
## Initiative

ID: <initiative_id>
Name: <initiative_name>

## Memory Store

Shared knowledge base for all agents on this initiative.
Search it before starting work; update it when you finish or make a decision.
This saves tokens and keeps all agents aligned.

### Via MCP tool (Claude Code — preferred):
Use the structured tools: memory_search, memory_add, memory_delete,
memory_recent, memory_list. Pass initiative_id: "<initiative_id>" to each.

### Via CLI (any agent):
    codrift memory search <initiative_id> "your query"
    codrift memory add    <initiative_id> decision "we use JWT not sessions"
    codrift memory add    <initiative_id> summary  "completed auth module"
    codrift memory add    <initiative_id> snippet  "pattern or code fragment"
    codrift memory delete <initiative_id> <id>
    codrift memory recent <initiative_id>
    codrift memory list   <initiative_id> decision

Results include an `id` field — use it with `memory delete` to remove
outdated entries.
```

Every agent already reads `initiative.md` via `--add-dir` — no extra tool
registration or wiring needed.

### MCP tools

Four new tools added to `Codrift.MCP.Handler`, available to any MCP client
(Claude Code, etc.) whenever the TUI is running. These are first-class tools,
not a bonus — Claude Code agents prefer structured tool calls over shell
commands.

| Tool | Arguments | Notes |
|------|-----------|-------|
| `memory_search` | `initiative_id`, `query` | FTS5 full-text search; returns `[{id, chunk_type, content, source, rank}]` |
| `memory_add` | `initiative_id`, `chunk_type`, `content`, `source?` | Stores a new entry; returns `{id}` |
| `memory_delete` | `initiative_id`, `id` | Deletes by rowid; agents can correct past entries |
| `memory_recent` | `initiative_id`, `limit?` | Last N entries across all types |
| `memory_list` | `initiative_id`, `chunk_type` | All entries of a specific type |

The CLI path (`codrift memory ...`) works identically when the TUI is not
running — both paths call the same `Codrift.Memory` functions.

### CLI layer

A first-class CLI exposed through the release binary. Each command group is a
thin shell script in `rel/commands/` that calls `eval` with `System.argv()`,
passing arguments via the `--` separator (supported natively by Elixir releases):

```bash
# rel/commands/memory.sh
exec "$RELEASE_ROOT/bin/codrift" eval 'Codrift.CLI.Memory.run(System.argv())' -- "$@"
```

`eval` does not start the supervision tree, so all `Codrift.CLI.*` modules
read storage directly — no GenServers required, works with TUI closed.

#### Full command surface

```
codrift tui                                    # replaces: mix codrift.tui
codrift mcp install                            # replaces: mix codrift.mcp.install

codrift initiative list
codrift initiative show   <id>
codrift initiative create <name>
codrift initiative add-dir <id> <path>
codrift initiative status  <id> <status>
codrift initiative delete  <id>

codrift session list  [<initiative_id>]
codrift session prune

codrift memory search <id> <query>
codrift memory add    <id> <type> <content>
codrift memory delete <id> <rowid>
codrift memory recent <id> [<limit>]
codrift memory list   <id> <type>
codrift memory stats  <id>

codrift integration services
codrift integration list   <service> [filter]
codrift integration import <service> <item_id> [--dir=<path>]
codrift integration sync   <initiative_id>
```

All `memory` commands print JSON to stdout and exit 0 on success, non-zero on
error — suitable for agent shell tool calls and piping.

#### Module layout

```
rel/
  commands/
    tui.sh
    mcp.sh
    initiative.sh
    session.sh
    memory.sh

lib/codrift/
  memory.ex              # pure module: FTS5 CRUD, opens/closes own DB conn
  cli/
    initiative.ex        # reads ~/.config/codrift/initiatives.json directly
    session.ex           # opens ~/.codrift/codrift.db directly
    memory.ex            # delegates to Codrift.Memory
    mcp.ex               # mirrors Mix.Tasks.Codrift.Mcp.Install logic
```

#### Dev parity

Mix tasks stay for dev convenience but delegate to CLI modules — no duplicated
logic:

```elixir
defmodule Mix.Tasks.Codrift.Mcp.Install do
  def run(args), do: Codrift.CLI.MCP.run(args)
end
```

---

## ex_ratatui fork improvements (vendor/ex_ratatui)

Codrift now owns a fork of ex_ratatui at `vendor/ex_ratatui` (git submodule, `github.com/filipecabaco/ex_ratatui`). The NIF is always built from source (`force_build: true`). This unlocks a set of low-cost improvements that were previously blocked by the upstream's "ignore for now" stubs.

### Already done

| Feature | Where | Notes |
|---------|-------|-------|
| `Event::Paste(String)` | `events.rs`, `event.ex`, `ex_ratatui.ex` | Delivers bracketed paste content atomically as `%ExRatatui.Event.Paste{content}` |
| `EnableBracketedPaste` | `terminal.rs` `init_terminal` | Sends `\e[?2004h` after `EnterAlternateScreen`; disabled in `restore_terminal` and `Drop` |
| Synchronized output | `terminal.rs` `with_terminal_draw` | `BeginSynchronizedUpdate`/`EndSynchronizedUpdate` wrap every crossterm draw; terminal composites the full frame at once. Safe no-op on unsupported terminals. |
| Focus events | `events.rs`, `event.ex`, `ex_ratatui.ex`, `terminal.rs` | `FocusGained`/`FocusLost` delivered as `%ExRatatui.Event.FocusGained{}`/`%ExRatatui.Event.FocusLost{}`; `EnableFocusChange` in `init_terminal`, `DisableFocusChange` in `restore_terminal` and `Drop` |
| OSC 52 clipboard write | `terminal.rs`, `ex_ratatui.ex`, `native.ex` | `ExRatatui.copy_to_clipboard/1` — base64 encoding done in Elixir via `Base.encode64/1`. Works in iTerm2, WezTerm, kitty. |
| Window title | `terminal.rs`, `ex_ratatui.ex`, `native.ex` | `ExRatatui.set_title/1` wraps `crossterm::terminal::SetTitle`. |

### Candidates — low effort, remaining

**Kitty keyboard protocol — richer modifier detection**

`PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)` in `init_terminal` lets crossterm distinguish e.g. Ctrl+Enter from Enter, and Shift+Space from Space. No NIF enum changes needed — the existing `Key` variant gains richer modifier data automatically. Deferred: requires testing on multiple terminal emulators to confirm no regressions.

**Wire up `set_title` to initiative selection** — call `ExRatatui.set_title("Codrift — #{name}")` when the selected initiative changes. Currently the API exists but is not called.

**Wire up `copy_to_clipboard` to a yank keybinding** — `y` in agent pane to copy visible output. Currently the API exists but has no TUI binding.

### Removed candidates

**1. Synchronized output — fixes flickering (sidequest)**

Wrap every `draw_frame` call in `EnterSynchronizedOutput` / `LeaveSynchronizedOutput` (`\e[?2026h` / `\e[?2026l`). The terminal composites the frame only once it sees the closing marker, eliminating mid-render flicker. One change to `rendering.rs`:

```rust
// in draw_frame, around the terminal.draw() call:
stdout.execute(EnterSynchronizedOutput)?;
let result = terminal_guard.draw(f);
stdout.execute(LeaveSynchronizedOutput)?;
```

Supported by iTerm2, WezTerm, kitty, foot, and most modern terminals. Safe no-op on terminals that don't recognise it.

**2. Focus events — auto-adjust status when window focus changes**

`FocusGained` / `FocusLost` are currently in the `_ => Ok(None)` arm. Add:

```rust
NifEvent enum:
  FocusGained,
  FocusLost,

match event:
  Event::FocusGained => Ok(Some(NifEvent::FocusGained)),
  Event::FocusLost   => Ok(Some(NifEvent::FocusLost)),
```

Then `EnableFocusChange` in `init_terminal` (crossterm already has it). TUI can dim the status bar or pause tickers when the window loses focus.

**3. Kitty keyboard protocol — richer modifier detection**

`PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)` in `init_terminal` lets crossterm distinguish e.g. Ctrl+Enter from Enter, and Shift+Space from Space. No NIF enum changes needed — the existing `Key` variant gains richer modifier data automatically.

**4. OSC 52 clipboard write — enables copy**

Terminal clipboard write is a pure escape sequence: `\e]52;c;{base64}\a`. No crossterm API needed. Add a NIF function:

```rust
#[rustler::nif]
fn copy_to_clipboard(text: String) -> Result<Atom, Error> {
    let encoded = base64::encode(text.as_bytes());
    print!("\x1b]52;c;{encoded}\x07");
    std::io::stdout().flush()?;
    Ok(atoms::ok())
}
```

Expose as `ExRatatui.copy_to_clipboard/1`. TUI can then offer `y` to yank agent output or diff hunks. Works in iTerm2, WezTerm, kitty; no-op in Terminal.app (which blocks OSC 52 by default).

**5. Window title — show active initiative**

```rust
#[rustler::nif]
fn set_title(title: String) -> Result<Atom, Error> {
    std::io::stdout().execute(crossterm::terminal::SetTitle(title))?;
    Ok(atoms::ok())
}
```

TUI calls `ExRatatui.set_title("Codrift — #{initiative_name}")` on initiative selection change.

---

## Upcoming: Git Worktrees per Initiative (Step 37)

**New module: `Codrift.Worktree`** (pure, no process)
- `ensure/2` — idempotently creates the worktree + branch, returns path
- `remove/1` — removes worktree and deletes branch
- `status/1` — returns `%{branch, dirty?, ahead, behind}`
- `list_for_initiative/1` — returns all worktree paths owned by an initiative

Worktree path: `~/.local/share/codrift/worktrees/<initiative-id>/<dir-slug>/`
Branch: `codrift/<initiative-slug>/<dir-slug>`

`AgentProcess` spawns with the worktree path as working dir. `Initiative.Store` persists `%{worktree_path, branch}` per dir entry. TUI sidebar shows branch + dirty indicator.

---

---

## Upcoming: Website (Step 40)

Plain HTML + CSS deployed to GitHub Pages (`docs/` dir or `gh-pages` branch). Domain: `codrift.sh`.

Page structure: hero + one-liner install, 3–4 feature bullets, asciinema demo, GitHub link.
