---
name: codrift-initiatives
description: Use when creating or managing Codrift initiatives — grouping directories, moving an initiative through its lifecycle, reading the combined diff, or working inside a codrift/ worktree branch. Triggers on "create an initiative", "add a directory", "initiative status", "planning/ongoing/done/archived", "get_diff", "worktree", "codrift/ branch", "which branch am I on", or reviewing work spread across several repos.
---

# Codrift initiatives

An initiative is a named unit of work — a feature, a bug fix, a milestone. It
holds one or more project directories, and everything else (agents, memory,
worktrees, imported context) hangs off it.

## Shape of an initiative

```
list_initiatives  {}                                   # always start here for an id
create_initiative { name: "auth redesign", dirs: ["~/projects/api"] }
add_dir           { initiative_id, dir: "~/projects/web" }   # ~ is expanded
delete_initiative { initiative_id }
```

An initiative can be **folderless** — no directories at all. It then has only
its context folder at `~/.codrift/initiatives/{id}/`, which is where
`start_agent` runs when you omit `dir`. That is the right shape for planning and
research work that is not yet anchored to a repo.

(Not to be confused with a **scratchpad**, which the user opens from the desktop
UI: a folderless initiative flagged `scratch: true`, listed separately, and
renamed into a real one when it turns out to matter. It is an ordinary
initiative to every tool here — the flag is a UI concern.)

## Lifecycle

```
set_initiative_status { initiative_id, status: "ongoing" }
```

`planning → ongoing → done → archived`. Move it to `ongoing` when work actually
starts and `done` when it is finished — the status drives what the user sees at
a glance, so a stale one is actively misleading. Do not set `archived` unless
asked; that is the user's call.

## Reading the work

```
get_diff { initiative_id }
```

This is the reliable way to see what has changed across **every** directory in
the initiative, including work another agent has made but not committed. Those
changes will not appear in `git log`, and they may be on a worktree branch you
are not standing on — so prefer `get_diff` over `git diff` in your own cwd when
you want the full picture.

## Worktrees: check before you assume

A directory can be checked out to a dedicated branch, `codrift/{id}/{slug}`, so
agents never touch the user's main checkout.

```bash
git rev-parse --abbrev-ref HEAD     # do this before reasoning about branch state
```

Rules:

- **Never `git checkout` another branch.** Your directory may be a worktree
  another agent is working in; switching it out from under them breaks their
  session.
- **Never `git worktree remove`** a `codrift/` tree, and never `git worktree add`
  one of your own. Codrift owns those, and one you make by hand lands outside
  `~/.codrift`, where nothing can find it again. Use `set_dir_worktree` instead.
- Committing on your worktree branch is fine and expected. Merging back to the
  user's default branch is not yours to do unless asked.

**Every Codrift worktree lives at
`~/.codrift/initiatives/<id>/worktrees/<slug>`** on a `codrift/<id>/<slug>`
branch. That is the only place to look for one, and the only place to put one.

Manage them with these tools:

```
list_worktrees   { }                                   # or { initiative_id }
set_dir_worktree { initiative_id, dir, enabled: true }  # false to remove it
prune_worktrees  { }                                   # report only
prune_worktrees  { force: true }                       # actually remove
```

`state` is `"linked"` when an initiative still claims the worktree, or
`"orphan"` when nothing does — `reason` says whether the initiative was deleted
or the directory was removed from it.

**Before pruning with `force`, read `dirty` on every orphan.** A dirty worktree
holds uncommitted work that removal destroys. Committed work is safe either way:
removing a worktree keeps its branch. When something is dirty and you did not put
it there, ask rather than force.

The same operations from a shell:

```bash
codrift worktree list
codrift prune                       # dry run
codrift prune --force

codrift initiative worktree-status  <id>
codrift initiative worktree-enable  <id> <path>
codrift initiative worktree-disable <id> <path>
```

Setting `worktree_default` on an initiative makes new directories inherit it.
Full model: [docs/worktrees.md](https://github.com/filipecabaco/codrift/blob/main/docs/worktrees.md)

## The context folder

Each initiative has `~/.codrift/initiatives/{id}/`, passed to agents
automatically via `--add-dir`. It holds:

| File | What it is |
|---|---|
| `initiative.md` | The brief. Imported issues write a source block here. |
| `orchestration.md` | Orchestrator goal and strategy — see `codrift-orchestration`. |
| `integration.json` | Link back to the external item it was imported from. |

Treat `initiative.md` as shared, user-visible context: append to it, do not
rewrite somebody else's section.

## CLI

```bash
codrift initiative list
codrift initiative create <name>
codrift initiative add-dir <id> <path>
codrift initiative delete  <id>
```
