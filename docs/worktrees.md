# Git Worktrees

Each directory added to an initiative can optionally run in a **git worktree** — an isolated checkout of the same repository on a dedicated branch. Agents work in the worktree so their changes never touch your main working tree.

## Storage layout

```
~/.codrift/initiatives/{initiative_id}/
  worktrees/
    {dir-slug}/        ← the worktree checkout
  initiative.md
  CLAUDE.md
```

Branch name: `codrift/{initiative_id_prefix}/{dir-slug}`

## Enabling worktrees

Worktrees are managed from the CLI (see below). Enabling one for a directory
creates the worktree checkout and its branch; disabling it removes them. A
directory's worktree state is stored on its `DirEntry` and persists across
restarts.

An initiative can also carry a `worktree_default` flag (`set_worktree_default` /
the `set_dir_worktree` core op) so new directories inherit a preference.

## What changes for agents

Agents spawned on a worktree-enabled directory run inside the **worktree** path,
not the source path — this is what `DirEntry.effective_path/1` resolves to. The
initiative keeps the source path as the directory's identity, so it's still shown
in the tree; edits and diffs, however, happen on the worktree branch.

## Finding them

Every worktree Codrift makes is under `~/.codrift/initiatives/`, so there is one
place to look — but for a long time nothing could enumerate them, and a worktree
left behind by a deleted initiative simply stayed there holding a checkout and a
branch that no surface could show.

```bash
codrift worktree list        # every managed worktree and what claims it
```

Each entry is **linked** when the initiative that owns its folder still exists
*and* still has a directory pointing at it, or an **orphan** when nothing claims
it, with a reason:

| `reason` | Meaning |
|---|---|
| `initiative_deleted` | No initiative has that id any more |
| `not_referenced` | The initiative exists, but no directory of it points here |

Agents get the same view over MCP through `list_worktrees`.

## Cleaning up: `codrift prune`

```bash
codrift prune            # report what would be removed — removes nothing
codrift prune --force    # actually remove it
```

`prune` is a **dry run by default**. Removing a worktree deletes whatever is
uncommitted in it, so nothing goes until `--force` says so a second time. Every
entry carries `dirty`, and `dirty_count` summarises them: the dry run is where to
notice before forcing.

Committed work is never at risk. Removing a worktree leaves its branch alone, so
anything committed on `codrift/{id}/{slug}` is still in the source repository
afterwards.

`prune` also clears **stale registrations** — worktrees a repository still lists
after the folder is gone. These cost nothing on disk but make `git worktree list`
lie and can block re-creating a worktree at the same path. Codrift's own test
suite has leaked them into real repositories, which is what prompted the command.

Over MCP the same operation is `prune_worktrees`, with the same `force` default
of `false`.

## CLI commands

```bash
codrift worktree list
codrift prune [--force]

codrift initiative worktree-status  <initiative_id>
codrift initiative worktree-enable  <initiative_id> <dir_path>
codrift initiative worktree-disable <initiative_id> <dir_path>
```

`worktree-status` prints a JSON array of all dirs with their worktree state (branch, dirty flag, path). `worktree-enable` and `worktree-disable` operate without the app running — they call `Worktree.ensure/3` and `Worktree.remove/2` directly and persist the result.

## Cleanup

- **`worktree-disable`** / `set_dir_worktree` with `enabled: false` — prunes the
  worktree from git and clears it from the `DirEntry`.
- **Delete initiative** (`d` on the initiative row) — all worktrees for that
  initiative are cleaned up before the context folder is removed.
- **`codrift prune --force`** — the backstop for everything the two above miss: a
  crash mid-operation, a hand-edited `initiatives.json`, a context folder that
  outlived its initiative.

## Module reference

**`Codrift.Worktree`** — pure module, no process.

| Function | Description |
|----------|-------------|
| `git_repo?(path)` | `true` if `.git` exists at `path` (fast stat, no subprocess) |
| `ensure(context_path, initiative_id, source_path)` | Idempotent worktree + branch creation |
| `remove(source_path, worktree_path)` | `git worktree remove --force`; falls back to `File.rm_rf` |
| `status(worktree_path)` | `:clean \| :dirty \| :missing` |
| `worktree_path(context_path, source_path)` | Computes `{context_path}/worktrees/{slug}/` |
| `branch_name(initiative_id, source_path)` | Computes `codrift/{id_prefix}/{slug}` |

**`Codrift.Worktree.Inventory`** — pure module, no process. Takes the initiatives
as an argument rather than calling the store, so `codrift prune` works under
`bin/codrift eval` with no supervision tree.

| Function | Description |
|----------|-------------|
| `scan(initiatives)` | Every managed worktree, classified `:linked` or `:orphan` |
| `stale_registrations(initiatives)` | Worktrees git lists whose folder is gone |
| `prune(initiatives, force: bool)` | Reports by default; removes only with `force: true` |

**`Codrift.Initiative.DirEntry`**

| Field | Type | Description |
|-------|------|-------------|
| `path` | `String.t()` | Source path (canonical identity, used for display) |
| `worktree_enabled` | `boolean()` | Whether a worktree is active |
| `worktree_path` | `String.t() \| nil` | Absolute path to the worktree directory |

`DirEntry.effective_path/1` returns `worktree_path` when set, otherwise `path` — the value passed to agents as their working directory.

`DirEntry.from_value/1` accepts both the legacy format (plain string) and the new map format for transparent migration.
