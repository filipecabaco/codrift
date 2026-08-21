---
name: codrift-memory
description: Use when reading from or writing to a Codrift initiative's shared memory store — before exploring a codebase, after making a decision, when finishing a task, or when a previous agent's findings would help. Triggers on "shared memory", "memory_search", "memory_add", "what did the other agents learn", "record this decision", "FTS5", or starting work on an initiative you have not seen before.
---

# Codrift shared memory

Every initiative has its own SQLite FTS5 knowledge base. Agents write findings
to it; later agents search it before starting. It is the only thing in the
workspace that survives a context window.

## Read first, always

Before you explore a codebase, search. Rediscovering a decision somebody already
recorded is the single most common way to waste a Codrift session.

```
memory_search { initiative_id, query: "authentication" }
memory_recent { initiative_id, limit: 20 }
memory_list   { initiative_id, chunk_type: "decision" }
```

**Ask the question you actually have.** Terms are OR-joined and stopwords
dropped, so a whole sentence works as a query and you do not have to guess which
keywords the author used:

```
memory_search { initiative_id, query: "does a sprite sleep while an agent is working" }
```

Returns up to 20 entries ranked by relevance, best first. `rank` is a negative
BM25 score — closer to zero is a better match — so you can stop reading once it
falls away.

| Query | Matches |
|---|---|
| `auth token` | either word, entries with both ranked higher |
| `"refresh token"` | the exact phrase |
| `auth AND jwt` | both |
| `auth NOT oauth` | the first without the second |
| `notar*` | any word starting with `notar` |

An empty result now means the store really has nothing, so take it at face value
rather than retrying synonyms. One caveat if you use `*`: terms are stemmed, so
`notariz*` finds nothing while `notar*` works — prefer a shorter prefix.

## Write back what the next agent would need

```
memory_add {
  initiative_id,
  chunk_type: "decision",
  content: "use JWT, not sessions — sessions break the mobile client, see api/auth.ex",
  source: "agent-3"            # optional; defaults to "mcp"
}
```

The parameter is `chunk_type`, not `type`. Valid values:

| `chunk_type` | Use it for |
|---|---|
| `decision` | A choice made and the reason. The highest-value type — record these. |
| `summary` | What you finished, once you finish it. |
| `snippet` | A small reusable pattern, with the path it came from. |
| `file_context` | What a specific file is for, when it was not obvious. |
| `note` | Anything else worth carrying forward. |

## What makes an entry useful

Entries are chunked before indexing and returned whole, so length is not held
against you — write the rationale out rather than compressing it away. Still
**lead with the terms someone would search for**, and keep each entry to one
self-contained claim.

Good:

> `decision` — Rate limiting lives in the Plug pipeline, not per-controller; see `lib/web/plugs/rate_limit.ex`. Per-controller was tried and dropped because the WebSocket upgrade path bypasses controllers entirely.

Not useful:

> `note` — Looked into the rate limiting question and found some interesting things, will continue tomorrow.

Rules of thumb:

- Record the **reason**, not just the outcome. The next agent needs to know
  whether your constraint still applies.
- Include the **path** when a finding is anchored to a file.
- One claim per entry. Two decisions in one entry means one of them is
  unfindable.
- Do not log narration, progress updates, or a restatement of your diff. The
  diff is already available via `get_diff`.
- Do not paste large code blocks. A path plus a sentence beats forty lines.

## Keep it true

Memory that contradicts the codebase is worse than empty memory, because it is
trusted. When you find an entry that is now wrong, delete it — do not just add a
correction alongside it.

```
memory_delete { initiative_id, id: 42 }   # id comes from memory_search / memory_add
```

## CLI

```bash
codrift memory search <id> <query>
codrift memory add    <id> <chunk_type> <content>
codrift memory recent <id>
codrift memory list   <id> <chunk_type>
codrift memory delete <id> <rowid>
codrift memory stats  <id>
```

Full model: [docs/memory.md](https://github.com/filipecabaco/codrift/blob/main/docs/memory.md)
