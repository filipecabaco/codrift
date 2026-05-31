# Per-initiative Memory Store

Each initiative has a shared, searchable knowledge base backed by SQLite FTS5. All agents working on the same initiative can write summaries, decisions, and code snippets to it, and search it before starting work. This saves tokens and keeps agents aligned across sessions.

## Storage

`~/.codrift/initiatives/{id}/memory.db` — created automatically alongside `initiative.md`. Removed when the initiative is deleted.

## Schema

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS memory USING fts5(
  chunk_type,
  content,
  source,      -- agent_id, "user", or file path
  tokenize = 'porter unicode61'
);
```

The `rowid` is implicit and used as the stable delete handle.

## Chunk types

| Type | When to use |
|------|-------------|
| `decision` | Architectural or design choices made during this initiative |
| `summary` | Completion summary after finishing a task or subtask |
| `snippet` | Reusable code pattern or config fragment |
| `file_context` | What a key file does and why |
| `note` | Free-form observation |

## Using memory from agents

The `initiative.md` file (picked up automatically by Claude Code via `--add-dir`) includes the initiative ID and usage instructions. Agents can use either MCP tools or CLI commands.

### MCP tools (Claude Code — preferred)

| Tool | Arguments |
|------|-----------|
| `memory_search` | `initiative_id`, `query` |
| `memory_add` | `initiative_id`, `chunk_type`, `content`, `source?` |
| `memory_delete` | `initiative_id`, `id` |
| `memory_recent` | `initiative_id`, `limit?` |
| `memory_list` | `initiative_id`, `chunk_type` |

### CLI (any agent or shell)

```bash
codrift memory search <id> "authentication middleware"
codrift memory add    <id> decision "use JWT not sessions"
codrift memory add    <id> summary  "completed auth module"
codrift memory add    <id> snippet  "code pattern or fragment"
codrift memory delete <id> <rowid>
codrift memory recent <id>
codrift memory list   <id> decision
codrift memory stats  <id>
```

All commands print JSON to stdout and exit 0 on success. Results include an `id` field — use it with `memory delete` to remove stale entries.

## Module reference

**`Codrift.Memory`** — pure module, no process. Opens and closes its own SQLite connection per call, safe for use in `eval` context (CLI) and inside GenServers.

```elixir
Codrift.Memory.search(initiative_id, "query")
# → [%{id: rowid, chunk_type, content, source, rank}]

Codrift.Memory.add(initiative_id, "decision", "we use JWT", "agent-abc")
# → {:ok, rowid}

Codrift.Memory.delete(initiative_id, rowid)
# → :ok | {:error, :not_found}

Codrift.Memory.recent(initiative_id, limit \\ 20)
# → [%{id, chunk_type, content, source}]

Codrift.Memory.list(initiative_id, chunk_type)
# → [%{id, chunk_type, content, source}]

Codrift.Memory.stats(initiative_id)
# → %{total: n, by_type: %{"decision" => 3, "snippet" => 7, ...}}
```
