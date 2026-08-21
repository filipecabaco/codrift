---
name: codrift
description: Use when working inside a Codrift initiative or when the Codrift MCP server is connected. Covers the workspace model every other codrift skill builds on — you are one of several agents, the memory store outlives your session, and other agents are editing sibling directories right now. Triggers on "codrift", "initiative", "shared memory", "what are the other agents doing", "codrift/ branch", or any task spanning several repos at once.
---

# Codrift

Codrift runs several coding agents at once across the directories of one
**initiative**. If you are reading this, you are probably one of those agents.

Two facts drive everything else:

1. **You are not alone in this workspace.** Other agents are editing sibling
   directories right now. Their work is invisible to your file reads, and their
   uncommitted changes will not show up in `git log`.
2. **The initiative outlives your session.** The memory store is how a finding
   survives a context window, a restart, or a handoff to a different agent.

## The two habits that matter

**Search memory before you explore.** It is a per-initiative FTS5 index that
previous agents wrote to, and it is almost always cheaper than rediscovering the
same thing from source.

```
memory_search { initiative_id, query: "auth" }
```

**Look before you touch a file outside your own directory.** Two agents editing
one path is the failure mode this workspace makes easy to hit.

```
get_initiative_agents { initiative_id }   # who is running, and where
get_diff              { initiative_id }   # every directory's uncommitted work
```

## Which skill to load

| You are doing | Load |
|---|---|
| Recording or retrieving findings | `codrift-memory` |
| Creating initiatives, adding dirs, worktrees, status, diffs | `codrift-initiatives` |
| Spawning or coordinating other agents; fan-out; conductor | `codrift-orchestration` |
| GitHub / Linear / GitLab issues, OAuth, importing work | `codrift-integrations` |
| Connecting a CLI to Codrift, or tools not showing up | `codrift-mcp` |
| Two accounts, wrapper commands, `--model`, which agent runs | `codrift-profiles` |
| Changing Codrift's own code, build or release pipeline | `codrift-contributing` |

## Your directory may not be where you think

A directory in an initiative can be checked out to a dedicated worktree branch
(`codrift/{id}/{slug}`) so agents never touch the user's main checkout. Run
`git rev-parse --abbrev-ref HEAD` before reasoning about branch state, and never
`git checkout` another branch — you would move a tree another agent is working
in.

Every Codrift worktree lives at `~/.codrift/initiatives/<id>/worktrees/<slug>`.
If you need one, ask for it with `set_dir_worktree` rather than running
`git worktree add` yourself: a worktree you create by hand lands wherever you
chose, outside that tree, where `list_worktrees` and `codrift prune` will never
find it again. See `codrift-initiatives`.

## Identifiers

Almost every tool takes an `initiative_id`. If you do not have one, call
`list_initiatives` — do not guess, and do not assume the initiative you are in
is the only one. `start_agent` and `get_agent_output` take an `agent_id`, which
comes from `get_initiative_agents` or `list_agents`.

## CLI

The same surface is available headlessly, for scripting and when no MCP server
is connected:

```bash
codrift start                     # launch the desktop app
codrift initiative list
codrift memory search <id> <query>
codrift mcp install               # register the MCP server with Claude Code
```

`codrift <command>` with no arguments prints its own help.

## Reference

- [README — MCP server](https://github.com/filipecabaco/codrift#mcp-server)
- [docs/memory.md](https://github.com/filipecabaco/codrift/blob/main/docs/memory.md)
- [docs/worktrees.md](https://github.com/filipecabaco/codrift/blob/main/docs/worktrees.md)
- [docs/integrations.md](https://github.com/filipecabaco/codrift/blob/main/docs/integrations.md)
