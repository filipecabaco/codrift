# Persona Test Pass — Codrift desktop UI

Manual exploratory pass driven through Chrome DevTools MCP against the Svelte UI
served by the Francis backend. Six personas, each mapped to the flows they
actually depend on, so a regression in any one of them is a regression for a
real user rather than for an abstract "feature".

- **Date:** 2026-08-03
- **Build:** `main` @ `6909d47` ("release cycle"), SPA built with `pnpm build:fast`
- **Surface:** web UI at `http://localhost:7437/index.html` (same SPA the Tauri
  webview loads), driven headfully in Chrome at 1440×900

---

## Harness

The pass runs against a **throwaway home** so nothing touches the real
`~/.codrift` / `~/.config/codrift`. Both roots come from `Codrift.Paths`, which
reads `config :codrift, :data_dir/:config_dir`, so they can be set before the
app boots without editing any config file:

```elixir
# scratchpad/boot.exs
sandbox = "<scratch>/sandbox/home"
Application.put_env(:codrift, :data_dir, Path.join(sandbox, ".codrift"))
Application.put_env(:codrift, :config_dir, Path.join(sandbox, ".config/codrift"))
Application.put_env(:codrift, :bandit_opts, ip: {127, 0, 0, 1}, port: 7437)
{:ok, _} = Application.ensure_all_started(:codrift)
```

```bash
cd assets && pnpm run build:fast && cd ..
MIX_ENV=dev mix run --no-start --no-halt scratchpad/boot.exs   # run from the project root
```

Fixtures: two throwaway git repos (`projects/webapp`, `projects/api`), each with
one commit plus uncommitted edits, and `webapp` additionally holding an
untracked `notes.txt` and a nested `src/components/` tree.

Verification is three-legged — UI assertions via `evaluate_script` on the live
DOM, backend truth via `POST /api/rpc`, and disk truth via shell. A UI claim is
only accepted when the backend or the filesystem agrees.

---

## Personas & flows

| # | Persona | What they need | Flows exercised | How it is driven |
|---|---------|----------------|-----------------|------------------|
| **P1** | First-run solo dev | Get from empty app to a running agent without reading docs | Empty state → `n` initiative (and `Esc` cancel) → `a` add dir with picker filter / `Tab` completion / `↓` selection → launch agent → agent pane renders | `press_key`, `fill`, `type_text`, `take_snapshot` |
| **P2** | Keyboard power user | Every action reachable by key; no focus traps | `j`/`k` nav, `1`/`2`/`3` views, `⌃P` palette + filter + run, `⌃B` sidebar, `Tab`/`Shift+Tab` focus cycling, key gating while PTY focused, `⌘D` / `⌘⇧D` / `⌘⌃=`, `[` / `]` status cycle, `r` refresh | `press_key` only; state asserted from DOM classes |
| **P3** | Multi-repo orchestrator | Supervise several agents across repos and keep them straight | 2 dirs in one initiative, 3 concurrent agents, launch **profile** selection, split panes with independent views, sidebar grouping agents under their dir | `fill` on `<select>`, `click`, screenshots |
| **P4** | Reviewer | Understand what an agent changed without leaving the app | Diff view across both repos, tree expand/collapse, file preview, `e` → CodeMirror vim editor, `:w` save, `:q` close | `type_text` into CodeMirror, result verified on disk |
| **P5** | Knowledge keeper | Memory + context survive and stay searchable | `memory` tab, FTS5 search (happy path and hostile query), type badges, context file tabs | seeded via `/api/rpc` `memory_add`, then driven through the UI |
| **P6** | Integrator / operator | Import work; survive restarts; clean up safely | Integrations panel inventory, server kill → reconnect banner → auto-recovery, `d` delete with confirm modal (`Esc` cancel and `Enter` confirm), post-delete cleanup | server killed/restarted via shell while the page stays open |

A **real Claude agent** was launched (adapter `claude`, profile
`claude-personal`) rather than only shell agents: it answered the trust prompt,
read `index.js`, requested edit permission, and wrote the change — so P3/P4 were
validated against genuine agent output, not a simulated diff.

> `claude-personal` did not exist on the machine — it is only the example in
> `Codrift.Config.Settings`' docstring. It was created in the sandbox
> `settings.json` for this pass.

---

## What works

- **P1** — empty → initiative → directory → running agent in ~6 keystrokes, no
  mouse. Onboarding copy matches reality. Dir picker filters live as you type,
  `Tab` completes and descends, `Enter` adds.
- **P2** — key gating is correct: with the terminal focused, `printf 'PTY-OK' ; 12332`
  and `jjj` went to the PTY and did **not** switch views or move the cursor.
  `⌘D` splits, `⌘⇧D` restacks, `⌘⌃=` balances to 50/50 (415px vs 411px), each
  pane keeps its own view, and the sidebar drives the focused one.
- **P3** — three agents ran concurrently across two repos; the sidebar grouped
  each under its directory with per-dir "N running" counts; the profile badge
  (`claude-personal`) shows on the agent row and the launch button relabels to
  `start claude-personal`.
- **P4** — diff rendered both repos with the agent's `/** Returns a greeting… */`
  line; tree excluded `.git`, expanded `src` → `components`; vim `:w` wrote
  `// reviewed-by-human` to disk (confirmed by `tail index.js`).
- **P5** — memory entries render with type badges; FTS search for `Stripe`
  returned exactly the `DECISION` row.
- **P6** — killing the backend surfaced *"Lost connection to the Codrift server.
  Reconnecting…"* plus a sidebar error; restarting cleared the banner and
  reloaded initiatives with **no page reload**. Delete emptied
  `initiatives.json`, removed the context folder, and left the project files
  untouched.

---

## Defects

### 1. `memory_search` leaks an Elixir crash to the user — P5
Searching `greet()` renders, in red, in the UI:

```
no case clause matching: {:error, "fts5: syntax error near \")\""}
```

`Codrift.Memory.search/2` (`lib/codrift/memory.ex:72`) assumes success from
`Exqlite.Sqlite3.prepare/bind`, so any FTS5-invalid query (parentheses,
unbalanced quote, bare `AND`) escapes as a raw error string. The same code path
backs the `memory_search` MCP tool, so **agents** get an error instead of
results. Repro:

```bash
curl -s -H 'content-type: application/json' -H 'Origin: http://localhost:7437' \
  -d '{"name":"memory_search","args":{"initiative_id":"<id>","query":"greet()"}}' \
  http://localhost:7437/api/rpc
# HTTP 400 {"error":"no case clause matching: {:error, \"fts5: syntax error near \\\")\\\"\"}"}
```

Function names with parens are exactly what someone searches a code memory for.

### 2. Agent status never live-updates — P1, P3, P6
The sidebar shows `starting` indefinitely while `list_agents` already reports
`awaiting_input`; only a manual `r` reconciles it. Observed on every agent,
including a real Claude agent that was **blocked on a permission prompt** — the
UI gave no signal that it needed attention. With several agents this removes the
one signal multi-agent supervision depends on: *which agent is waiting for me?*

### 3. New / untracked files never appear in the diff — P4
`Codrift.Diff.generate/2` (`lib/codrift/diff.ex:122`) shells out to plain
`git diff` — unstaged, tracked files only. `notes.txt` existed the whole pass and
never showed. Agents routinely create files; those changes are invisible to the
reviewer.

### 4. `⌃P` and `⌃B` are dead while the terminal is focused — P2
xterm consumes the control combos before the bubble-phase `svelte:window`
handler (`App.svelte:609-629`), and the control bytes go to the PTY instead.
`docs/keyboard.md` promises modifier combos are always intercepted. In practice
you must `Shift+Tab` back to the sidebar first — verified: identical `⌃P`
succeeds from the sidebar and does nothing from the terminal. Fix direction:
`term.attachCustomKeyEventHandler` or a capture-phase listener.

### 5. Directory rows show a chevron that is not a toggle — P1, P3
`App.svelte:853` renders a hardcoded `▸` on every dir row. It never becomes `▾`,
and clicking the row only selects — agents under a dir are always visible when
the initiative is expanded. The affordance promises collapsing that does not
exist, which matters most for the persona with many dirs.

### 6. Palette exposes dead commands — P2
"Toggle diff layout" (`v`) and "New context file" (`c`) are listed, are
selectable, run, close the palette, and do nothing. `docs/keyboard.md` marks
them *reserved*; the palette does not.

### 7. Launch profiles are reload-only and file-only — P3
New profiles in `settings.json` do not appear after `r`; only a full page reload
picks them up. There is also no UI to create, edit, or delete a profile — the
feature is reachable only by hand-editing `~/.codrift/settings.json`, and the
docstring example (`claude-personal`) is the only documentation of the shape.
The dropdown also resets to `claude` after a launch, so launching the same
profile twice means reselecting it.

### 8. Diff cards omit the repo — P4
The backend attaches `"dir"` to each file diff (`Codrift.get_diff`), and the UI
drops it. With two repos in an initiative, two `README.md` diffs are
indistinguishable.

### 9. Stale TUI copy in generated `initiative.md` — P1
`(no project directories configured yet — use 'a' in the TUI to add one)` is
shown inside the desktop app, which is not the TUI.

### 10. Smaller issues
- Dir picker lists `.git` as a selectable project directory.
- Loose agents render the raw status (`awaiting_input`) while dir-attached agents
  render the humanized form (`awaiting input`) — `App.svelte:868` vs `:884`.
- `j` re-expands an initiative that was just collapsed, so the collapse cannot
  survive keyboard navigation.
- The confirm modal does not move focus into itself (focus stayed on the header
  Integrations button); `Enter`/`Esc` work via a capture handler, but tab order
  and screen readers do not follow.
- Sidebar chevrons carry no `aria-expanded`, and the tree is a flat list of
  `<button>`s rather than a `tree`/`treeitem` structure.
- After a backend restart, previously running agents vanish from the sidebar with
  no notice that they were lost.

---

## Not covered

- **OAuth connect flows** (GitHub / GitHub Projects / GitLab / Linear / Linear
  Projects) — the panel inventory was verified, but completing a flow would hit
  real accounts. Needs an explicit go-ahead.
- **Worktrees** — `worktree_enable` / `worktree_disable` and the `wt` badge.
- **Orchestration** (`o` / conductor) and the MCP SSE transport.
- **Session persistence across restarts** for Claude agents (`SessionStore`);
  this pass only confirmed agents disappear from the list after a backend
  restart.
- **Tauri shell specifics** — native menu, `⌃Q` quit, heartbeat shutdown. The
  SPA is identical, but WebKit-only behaviour is not covered by Chrome.
