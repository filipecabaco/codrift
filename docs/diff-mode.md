# Diff Mode

Press `2` to enter diff mode. The sidebar transforms to show changed files grouped by directory; the main pane shows the diff content driven by the sidebar cursor. Press `1` to return to context mode.

## Sidebar structure

```
  * all files              +42 -17
    ▸ ~/work/project        +30 -10
      ○ lib/foo.ex          +20  -5
      ○ lib/bar.ex          +10  -5
    ▸ ~/work/other          +12  -7
      ○ test/foo_test.ex    +12  -7
```

| Entry type | Description |
|------------|-------------|
| `{:diff_all, adds, dels}` | Always first — combined totals across all directories |
| `{:diff_dir, dir, adds, dels}` | One per directory that has changes |
| `{:diff_file, dir, path, adds, dels}` | One per changed file |

Directories with no changes are excluded. Moving the cursor updates the content pane instantly — no Enter needed.

## Content pane

| Cursor position | Content shown |
|-----------------|---------------|
| `{:diff_all}` | All changed files combined |
| `{:diff_dir}` | All files in that directory |
| `{:diff_file}` | Single file |

The content pane always has a cyan border in diff mode — it is the primary reading surface regardless of which pane has keyboard focus.

## View modes

Toggle between modes with `v`.

### Unified (default)

Syntax-highlighted unified diff rendered as a `CodeBlock`:

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
| Removed | Red foreground, red left border |
| Added | Green foreground, green right border |
| Context | Default white |
| Padding (`~`) | Dark gray |
| Hunk headers | Dark gray |

Both modes share `diff_scroll`. `Ctrl+D` / `Ctrl+U` do half-page jumps.

## File filter

Press `/` to activate the filter at the top of the sidebar. Only matching `{:diff_file, …}` entries are shown; directory headers are hidden while a query is active. The filter mode is inferred from the query:

| Query | Mode |
|-------|------|
| `foo` | fuzzy — substring match |
| `*.test.ts` | glob — `*`/`?` wildcards |
| `/\.ex$/` | regex — Elixir `Regex`, case-insensitive |
| `#test` `#config` `#doc` `#schema` `#router` | tag — predefined file groups |

```
┌ *.ex  glob  e.g. *.test.ts ────────────┐
│ ▶ lib/foo.ex                  +20  -5  │
│   lib/bar.ex                  +10  -5  │
└────────────────────────────────────────┘
```

| Key | Action |
|-----|--------|
| `/` | Activate filter |
| any printable key | Append to query |
| `Backspace` | Delete last character |
| `Esc` | Clear filter and restore full sidebar |

Moving the cursor in a filtered view still drives the content pane normally.

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| `j` / `↓` | Move sidebar cursor down (or scroll content when main pane is focused) |
| `k` / `↑` | Move sidebar cursor up (or scroll content when main pane is focused) |
| `/` | Activate fuzzy file filter |
| `Esc` | Clear filter (when filter is visible) |
| `v` | Toggle unified / split view |
| `*` | Jump sidebar cursor to "all files" (entry 0) |
| `Ctrl+D` / `Ctrl+U` | Half-page scroll in diff content |
| `r` | Refresh diff for the current initiative |
| `Ctrl+P` | Open palette → "Toggle Diff: Unified / Split" |

## Web viewer

A browser diff viewer is available at `http://localhost:7437/diff.html` while the TUI is running, with live updates via SSE at `/events/initiative/:id`.

## Implementation notes

- `Codrift.Diff.to_split_rows/1` returns `[{:header | :context | :change, old | nil, new | nil}]` — typed rows for the split view renderer. Explicit `%Span{}` colouring gives full control over per-line styling that syntax highlighting alone cannot provide.
- `Codrift.Diff.to_unified/1` returns the unified diff string fed to the `CodeBlock` widget.
