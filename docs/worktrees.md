# Git Worktrees

Each project directory added to an initiative can optionally run in a **git worktree** — an isolated checkout of the same repository on a dedicated branch. Agents work in the worktree so their changes never touch your main working tree.

## Storage layout

```
~/.codrift/initiatives/{initiative_id}/
  worktrees/
    {dir-slug}/    ← the worktree checkout
  initiative.md
  CLAUDE.md
```

Branch name: `codrift/{initiative_id_prefix}/{dir-slug}`

## Enabling worktrees

### When adding a new directory (`a`)

If the directory is a git repository, the add-dir modal shows:

```
[x] Use git worktree  (w to toggle)
```

The toggle defaults to the initiative's `worktree_default` setting (off unless you change it). Press `w` to flip it before confirming with Enter.

### On an existing directory

With the cursor on a dir entry in the sidebar:

- Press **`W`** — creates the worktree immediately, or removes it if one exists
- Or open the palette (`Ctrl+P`) → **Toggle Worktree for Directory**

### Per-initiative default

Open the palette → **Toggle Worktree Default (initiative)** — sets the default for all future dirs added to that initiative.

## What changes for agents

Agents spawned on a worktree-enabled dir run inside the worktree directory, not the source path. The sidebar still shows the source path for identity; the branch shown is the worktree branch.

## Sidebar indicator

Each dir entry in the sidebar shows its worktree state inline:

```
  ▸ ~/projects/realtime  [wt]   1   ← clean worktree, 1 agent
  ▸ ~/projects/walrus    [wt*]  0   ← dirty worktree (uncommitted changes)
  ▸ ~/projects/other               ← no worktree
```

`[wt]` is shown in muted gray; `[wt*]` is yellow. Status is computed by `Worktree.status/1` each time the sidebar is rebuilt (on initiative/agent changes, not on every frame).

## CLI commands

```bash
codrift initiative worktree-status  <initiative_id>
codrift initiative worktree-enable  <initiative_id> <dir_path>
codrift initiative worktree-disable <initiative_id> <dir_path>
```

`worktree-status` prints a JSON array of all dirs with their worktree state (branch, dirty, path).
`worktree-enable` and `worktree-disable` work without the TUI running — they call `Worktree.ensure/3` and `Worktree.remove/2` directly and persist the result to `initiatives.json`.

## Cleanup

- **Remove dir** (`d`) — worktree is pruned from git and the directory is deleted.
- **Delete initiative** (`d` on the initiative row) — all worktrees for that initiative are cleaned up before the context folder is removed.

## Initiative overview pane

Every dir always shows its worktree status:

```
**~/projects/myrepo**
branch: `codrift/abc12345/myrepo` · worktree: `~/.codrift/.../worktrees/myrepo` · commit: `abc1234 ...` · agents: 1 running
```

Or when no worktree:

```
**~/projects/myrepo**
branch: `main` · worktree: off  (W to enable) · commit: `abc1234 ...` · agents: none
```

The section header also shows `(worktree default: on/off)` for the initiative.

## Dir detail pane

When cursor is on a dir entry, the pane shows:

```
Branch:  codrift/abc12345/myrepo
Worktree: ~/.codrift/.../worktrees/myrepo
Source:   main (~/projects/myrepo)
Remote:  https://github.com/...

Recent commits:
  abc1234 feature work
```

Or without a worktree:

```
Branch:  main
Worktree: none  (W to enable, or Ctrl+P → Toggle Worktree)
Remote:  https://github.com/...
```

## Module reference

**`Codrift.Worktree`** — pure module, no process.

| Function | Description |
|----------|-------------|
| `git_repo?(path)` | Returns `true` if `.git` exists in `path` (fast stat, no subprocess) |
| `ensure(context_path, initiative_id, source_path)` | Idempotent worktree + branch creation; `{:error, _}` when source is not a git repo |
| `remove(source_path, worktree_path)` | `git worktree remove --force`; falls back to `File.rm_rf` |
| `worktree_path(context_path, source_path)` | Computes `{context_path}/worktrees/{slug}/` |
| `branch_name(initiative_id, source_path)` | Computes `codrift/{id_prefix}/{slug}` |

**`Codrift.Initiative.DirEntry`** — replaces plain `String.t()` in `Initiative.dirs`.

| Field | Type | Description |
|-------|------|-------------|
| `path` | `String.t()` | Source path (canonical identity, used for display) |
| `worktree_enabled` | `boolean()` | Whether the worktree is active |
| `worktree_path` | `String.t() \| nil` | Absolute path to the worktree directory |

`DirEntry.effective_path/1` returns `worktree_path` when set, otherwise `path` — the value passed to agents as their working directory.

`DirEntry.from_value/1` accepts both the legacy format (plain string) and the new map format for transparent migration.
