---
name: project-worktree
description: Git worktree support per initiative dir — design decisions and key files
metadata:
  type: project
---

Git worktrees implemented as an opt-in per-dir feature (step 37).

**Why:** Agents need isolated branches per initiative dir without polluting the main working tree. Worktrees live at `~/.codrift/initiatives/{id}/worktrees/{slug}/`.

**Key data model change:** `Initiative.dirs` changed from `[String.t()]` to `[DirEntry.t()]` (new struct `Codrift.Initiative.DirEntry` in `lib/codrift/initiative/dir_entry.ex`). Old JSON with plain string dirs is migrated via `DirEntry.from_value/1`. `DirEntry.effective_path/1` returns the worktree path when active, else source path.

**Core module:** `lib/codrift/worktree.ex` — pure functions, no process. `ensure/3` takes `(context_path, initiative_id, source_path)` where `context_path` is the initiative folder, so tests can use tmp_dir instead of `~/.codrift`.

**TUI UX:** `w` key toggles worktree in the add-dir modal; toggle only shown when the typed dir is a git repo (detected live via `File.exists?(.git)`). Defaults to enabled when git is first detected.

**How to apply:** Any code touching `initiative.dirs` must use `DirEntry.effective_path(entry)` for git operations and `entry.path` for display/identity. Agents run in `effective_path`. Sidebar groups agents by `effective_path` but shows `source path`.

**Test pattern:** Store tests use `ctx = Path.join(tmp_dir, "ctx")` as `context_dir_base` — never pass `tmp_dir` directly or `clean_orphaned_context_dirs` will delete test repos placed in `tmp_dir`.
