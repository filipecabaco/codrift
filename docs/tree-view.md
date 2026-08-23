# Tree View (Mode 3)

Press `3` (or click **3 Tree**, or select *Tree view* from `Ctrl+P`) to browse
the files of the active initiative.

![Tree view: initiative sidebar, file tree, and syntax-highlighted preview](images/tree-view.png)

## Overview

Tree mode shows three panes: the initiative sidebar on the far left, a file tree
of the initiative's directories in the middle, and a syntax-highlighted preview
of the selected file on the right. Top-level directories are expanded by default;
directories are listed before files, both sorted alphabetically.

The file list comes from the `list_tree` RPC, which walks each directory in the
initiative (respecting `.gitignore` via `git ls-files`, with a naive fallback).

## Directory preview (Mode 1)

You do not have to come here just to see what a directory *is*. Moving the
sidebar cursor onto a project directory replaces the Context pane with a preview
of it: the directory's `README` rendered as markdown, or — only when there is no
README — the top two levels of its file tree.

This is a preview, not a browser: nothing in it expands, and it never switches
the pane to Tree mode on its own. Its **Browse in Tree** button does, when you
want the real thing. For a worktree-backed directory the preview reads the
worktree, since that is the checkout agents work in.

It comes from the `dir_preview` RPC, which only accepts directories the
initiative actually holds, and resolves them through `DirEntry.effective_path/1`.

## Navigation

| Key / action | Effect |
|--------------|--------|
| Click a directory | Expand / collapse it |
| Click a file | Load it into the preview pane |
| `Tab` | Return focus to the sidebar |
| Mouse wheel | Scroll the tree or the preview |

## Editing

The preview pane has an **Edit** button in its header. It opens the file in the
in-app editor — a full-screen CodeMirror pane with **Vim mode** enabled. Save
with `:w`, `:wq`, or `⌘S` / `Ctrl+S`; close with `:q`. See
[Keyboard reference → Editor](keyboard.md#editor).

Reads and writes go through the sandboxed `read_file` / `write_file` RPCs, which
refuse paths outside the initiative's allowed directories and cap previews at
512 KB (`Codrift.Files`).

## Syntax highlighting

Previews are highlighted with [Shiki](https://shiki.style) (theme
`github-dark`). `langForPath/1` in `assets/src/lib/highlight.ts` resolves the
language from the filename (e.g. `mix.exs`, `Dockerfile`) or extension. The
bundled grammar set covers, among others:

| Languages | Examples |
|-----------|----------|
| Elixir | `.ex` `.exs` |
| JavaScript / TypeScript | `.js` `.jsx` `.ts` `.tsx` |
| Svelte / Vue | `.svelte` `.vue` |
| Rust · Go · Python · Ruby | `.rs` `.go` `.py` `.rb` |
| C / C++ | `.c` `.h` `.cpp` |
| Shell | `.sh` `.bash` `.zsh` |
| Markup & data | `.html` `.css` `.scss` `.json` `.yaml` `.toml` `.md` |
| SQL · Docker | `.sql` `Dockerfile` |

Files with an unrecognised extension render as plain text (`"text"`).
```
