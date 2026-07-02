# Diff View

Press `2` (or click **2 Diff**) to see every uncommitted change across the
selected initiative's directories, updated live as agents work.

![Diff view with syntax-highlighted additions and deletions](images/diff-view.png)

## Layout

The initiative sidebar stays on the left; the main pane lists each changed file
as a card. Every card shows:

- the file path (relative to its directory),
- an `+additions` / `−deletions` summary in the header,
- the changed hunks, with `@@ … @@` hunk headers.

Lines are syntax-highlighted with [Shiki](https://shiki.style) (the same
highlighter used by the tree preview). Added lines have a green background and a
`+` gutter; removed lines have a red background and a `−` gutter; context lines
are shown plain. Scroll the pane to move through all the files — there is no
per-file cursor to manage.

## Where the diff comes from

The frontend calls the `get_diff` RPC, which runs `git diff` across each
directory in the initiative and returns structured data:

```
DiffFile { path, additions, deletions, hunks: [ DiffHunk { header, lines: [ DiffLine ] } ] }
DiffLine { type: "add" | "del" | "context", content }
```

Directories with no changes are omitted. If a directory has a worktree enabled,
the diff is taken against that worktree's branch.

## Live updates

While agents run, their output streams over SSE at `/events/initiative/:id`.
Hit `r` (refresh) after an agent finishes a batch of edits to pull the latest
`git diff`.

## Implementation notes

- `Codrift.Diff.generate/2` shells out to `git diff` and parses it into
  `FileDiff` / `Hunk` / `Line` structs.
- `Codrift.Diff.to_map/1` is what the `get_diff` RPC returns to the UI.
- `Codrift.Diff` also exposes `to_unified/1` and `to_split_rows/1`; these back
  alternate renderings and the (reserved) `toggle_diff_view` action.
```
