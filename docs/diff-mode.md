# Diff Mode

Pressing `2` enters diff mode. The sidebar transforms to show changed files grouped by directory; the main pane shows the diff content driven by the sidebar cursor. Pressing `1` returns to context mode.

## Sidebar entries

```
  * all files              +42 -17
    ▸ ~/work/project        +30 -10
      ○ lib/foo.ex          +20  -5
      ○ lib/bar.ex          +10  -5
    ▸ ~/work/other          +12  -7
      ○ test/foo_test.ex    +12  -7
```

Entry types in `Codrift.TUI.Sidebar`:

| Type | Description |
|------|-------------|
| `{:diff_all, total_adds, total_dels}` | Always first; combined totals across all dirs |
| `{:diff_dir, dir, adds, dels}` | One per directory that has changes |
| `{:diff_file, dir, path, adds, dels}` | One per changed file |

Directories with no changes are excluded. Moving the cursor updates the content pane instantly — no Enter needed.

## Content pane

| Cursor position | Content shown |
|-----------------|---------------|
| `{:diff_all}` | All changed files combined |
| `{:diff_dir}` | All files in that directory |
| `{:diff_file}` | Single file |

The content pane always has a cyan border in diff mode (always "active" — it is the primary reading surface regardless of which pane has keyboard focus).

## View modes (toggle with `v`)

### Unified (default)

Single `CodeBlock` with `language: "diff"` syntax highlighting:

```
--- a/lib/foo.ex
+++ b/lib/foo.ex
@@ -1,5 +1,6 @@
-old line
+new line
 context
```

### Split

Two `Paragraph` panels with explicit span colouring:

```
┌─ - removed ──────┬─ + added ────────┐
│ old line  (red)  │ new line  (green) │
│ context          │ context           │
│ ~  (padding)     │ extra add (green) │
└──────────────────┴───────────────────┘
```

| Line type | Colour |
|-----------|--------|
| Removed | Red foreground (left pane, red border) |
| Added | Green foreground (right pane, green border) |
| Context | Default white |
| Padding (`~`) | Dark-gray |
| Hunk headers | Dark-gray |

Both modes share `diff_scroll`; `Ctrl+D`/`Ctrl+U` do half-page jumps.

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| `j` / `↓` | Move diff sidebar cursor down (or scroll content when main focused) |
| `k` / `↑` | Move diff sidebar cursor up (or scroll content when main focused) |
| `v` | Toggle unified / split view |
| `*` | Jump diff sidebar cursor to "all files" (entry 0) |
| `Ctrl+D` / `Ctrl+U` | Half-page scroll in diff content |
| `r` | Refresh diff for current initiative |
| `Ctrl+P` | Open palette → "Toggle Diff: Unified / Split" etc. |

## Implementation notes

- `Codrift.Diff.to_split_rows/1` returns `[{:header | :context | :change, old | nil, new | nil}]` — typed rows used for coloured split view rendering. Syntect `language: "diff"` doesn't colour stripped-prefix content; explicit `%Span{}` rendering gives full control.
- `Codrift.Diff.to_unified/1` returns the unified diff string fed to the `CodeBlock` widget.
- Web diff view available at `/diff.html` + SSE `/events/initiative/:id`.
