# Persona Test Pass — Codrift desktop UI

Manual exploratory pass driven through Chrome DevTools MCP against the Svelte UI
served by the Francis backend. Six personas, each mapped to the flows they
actually depend on, so a regression in any one of them is a regression for a
real user rather than for an abstract "feature".

- **Date:** 2026-08-03 (second pass; supersedes the pass at `6909d47`)
- **Build:** `main` @ `577c5a1` ("cleanup code") **plus the uncommitted working
  tree** — `App.svelte` split into `Sidebar`/`Overlay`/`Confirm`/`workspace.svelte.ts`,
  `memory.ex`, `core.ex`, `codrift.ex` and the new `lib/codrift/web/event_relay.ex`.
  SPA built with `pnpm build:fast`.
- **Surface:** web UI at `http://localhost:43117/index.html` (same SPA the Tauri
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
Application.put_env(:codrift, :bandit_opts, ip: {127, 0, 0, 1}, port: 43117)
{:ok, _} = Application.ensure_all_started(:codrift)
```

```bash
cd assets && pnpm run build:fast && cd ..
MIX_ENV=dev mix run --no-start --no-halt scratchpad/boot.exs   # run from the project root
```

Fixtures: **three** throwaway git repos (`projects/webapp`, `projects/api`,
`projects/docs`), each with one commit plus uncommitted edits; `webapp`
additionally holds an untracked `notes.txt` and a nested `src/components/` tree.

**Fixture set — two initiatives per persona, all four statuses represented**
(created through the UI for P1/P7, via `POST /api/rpc` for the rest):

| Status | Initiatives |
|---|---|
| `planning` | P2 Keyboard drills, P1b Onboarding retry (0 dirs), P5b Memory audit |
| `ongoing` | P3 Multi-repo orchestration (3 dirs), P5 Knowledge base, P1 First run, P7 Selection check, P3b Cross-repo refactor (3 dirs) |
| `done` | P4 Review queue (2 dirs), P2b Shortcut regression, P6b Restart drill |
| `archived` | P6 Ops archive, P4b Post-merge review (2 dirs) |

Agent statuses exercised concurrently: `starting`, `awaiting_input` ("needs
input"), and stopped — across `terminal` and real `claude` agents, some under a
launch profile (`claude-personal`), one at an initiative's scratchpad root
(folderless) and the rest attached to project dirs.

Verification is three-legged — UI assertions via `evaluate_script` on the live
DOM, backend truth via `POST /api/rpc`, and disk truth via shell. A UI claim is
only accepted when the backend or the filesystem agrees.

---

## Personas & flows

| # | Persona | What they need | Flows exercised | How it is driven |
|---|---------|----------------|-----------------|------------------|
| **P1** | First-run solo dev | Get from empty app to a running agent without reading docs | Empty state → `n` initiative (and `Esc` cancel) → `a` add dir with picker filter / `Tab` completion / `↓` selection → launch agent → agent pane renders → trust prompt answered | `press_key`, `fill`, `type_text`, `take_snapshot` |
| **P2** | Keyboard power user | Every action reachable by key; no focus traps | `j`/`k` nav, `←`/`→` tree collapse/expand, `1`/`2`/`3` views, `*` all-files, `⌃P` palette + filter + run, `⌃B` sidebar, `Tab`/`Shift+Tab` focus cycling, key gating while PTY focused, `⌘D` / `⌘⇧D` / `⌘⌃=`, `[` / `]` status cycle, `r` refresh | `press_key` only; state asserted from DOM/ARIA |
| **P3** | Multi-repo orchestrator | Supervise several agents across repos and keep them straight | 3 dirs in one initiative, 3 concurrent agents, launch **profile** selection, split panes with independent views, sidebar grouping agents under their dir with per-dir "N running" and per-initiative "N waiting" | `fill` on `<select>`, `click`, screenshots |
| **P4** | Reviewer | Understand what an agent changed without leaving the app | Diff view across both repos, tree expand/collapse, file preview, `e` → CodeMirror vim editor, `:w` save, `:q` close | `type_text` into CodeMirror, result verified on disk |
| **P5** | Knowledge keeper | Memory + context survive and stay searchable | `memory` tab, FTS5 search (happy path and hostile queries), type badges, context file tabs | seeded via `/api/rpc` `memory_add`, then driven through the UI |
| **P6** | Integrator / operator | Import work; survive restarts; clean up safely | Integrations panel inventory, server kill → reconnect banner → auto-recovery, `d` delete/stop with confirm modal (`Esc` cancel and `Enter` confirm), post-delete cleanup | server killed/restarted via shell while the page stays open |
| **P9** | Playbook keeper | Keep the team's scripts and docs *in* the initiative, not beside it | A context folder holding `scripts/` (3 files), `docs/runbooks/` (2), `templates/`, `conventions.md` → rendered as a tree in the sidebar; folder expand/collapse; `memory` row; git repo vs plain folder | `click`, `press_key`, `evaluate_script` on the tree |
| **P10** | Theme switcher | Work in the theme (and typeface) they already use everywhere else | Appearance panel: 65 bundled VS Code themes + drop-ins from `~/.codrift/themes`, live preview on ↑↓, Enter keeps / Esc reverts, persistence across reload; font family + size | picker driven by keyboard, verified via CSS custom properties and screenshots |
| **P11** | Integration authenticator | Connect their tracker **once**, from inside the app, without registering a developer app or exporting a token | **Device Flow** (GitHub, GitHub Projects): Connect → user code + `github.com/login/device` → poll → connected badge. **PKCE** (Linear, GitLab): Connect → provider consent → redirect to `127.0.0.1:43117/oauth/callback/<service>` → token stored. Plus: `state` mismatch rejected, Disconnect/revoke, env-var precedence over the bundled client ID, and an import that actually spends the fresh token | Chrome MCP against the **real** provider pages; token truth read from `$SANDBOX/.codrift/oauth_tokens.json`; import verified via `POST /api/rpc` |

A **real Claude agent** was launched twice (adapter `claude`, once under profile
`claude-personal`) rather than only shell agents: it answered the trust prompt,
read `index.js`, requested edit permission, and wrote a JSDoc block — so P3/P4
were validated against genuine agent output, not a simulated diff.

### P11 harness — what makes this persona different

P11 is the only persona that reaches **outside the sandbox**. Three constraints
follow from that:

1. **The port is not free to choose.** Every other persona would work on any
   port; P11 will not. The PKCE redirect URI is stored by the provider at app
   registration time and cannot be renegotiated at runtime, so the sandbox must
   bind exactly `43117` — which `boot.exs` already pins. On any other port
   Linear and GitLab fail with `redirect_uri_mismatch` before the callback is
   ever reached. Bandit binds IPv4 `127.0.0.1` only, and the redirect uses the
   literal IP rather than `localhost` (which can resolve to `::1` first).
2. **It grants real credentials.** Completing a flow issues a genuine token
   against the tester's own GitHub / Linear / GitLab account. Tokens land in
   `$SANDBOX/.codrift/oauth_tokens.json` because `Codrift.Paths` honours
   `:data_dir` — assert that the real `~/.codrift/oauth_tokens.json` is
   untouched, then revoke afterwards (in-app **Disconnect**, or the provider's
   authorized-apps page) so the pass leaves nothing behind.
3. **No env vars are needed to start.** Client IDs ship in
   `lib/codrift/oauth/config.ex`, so the default path is "click Connect". The
   env-var leg is a *separate* assertion: export `GITHUB_CLIENT_ID` (etc.) to a
   junk value and confirm it overrides the bundled ID — that proves resolution
   order rather than merely that OAuth works.

Assertions worth making explicit, because a green badge alone does not prove
them:

| Claim | How to check it |
|---|---|
| Token actually persisted | `oauth_tokens.json` contains the service key, file mode is `0600` |
| PKCE round-trip is sound | Tamper with `state` on the callback URL → rejected; correct `state` → token |
| Device Flow is enabled on the app | The device-code request returns `user_code` / `verification_uri`, not `device_flow_disabled` |
| The token is usable | Import an issue (`import_from_integration` or the CLI) and confirm the content lands in the initiative |
| Fallback still works | Unset OAuth, set `GITHUB_TOKEN` / `LINEAR_API_KEY` / `GITLAB_TOKEN`, repeat the import |

---

## Verdict: the application works

Every persona completed its primary flow end to end. No console errors or
warnings were logged across the whole session.

- **P1** — empty → initiative → directory → running agent, no mouse. Dir picker
  filters live, `Tab` completes and descends, `Enter` adds; `.git` is no longer
  offered as a project directory. Onboarding copy matches reality.
- **P2** — key gating is correct: with the terminal focused, `jjj123 gating check`
  went to the PTY and did not switch views or move the cursor, while `⌃P` and
  `⌃B` **do** now work from the terminal. `←`/`→` collapse/expand the tree
  properly, `⌘D` splits, `⌘⇧D` re-orients, `⌘⌃=` balances (415px vs 411px), each
  pane keeps its own view. `[` / `]` cycle status and persist to the backend.
- **P3** — three agents ran concurrently across three repos; the sidebar grouped
  each under its directory with per-dir "1 running" and a per-initiative
  "N waiting" badge that also shows while the initiative is **collapsed**; the
  profile badge (`claude-personal`) shows on the agent row and the launch button
  relabels to `start claude-personal`. Agents started via the API appeared in the
  sidebar live, with no refresh.
- **P4** — diff rendered all repos with a `repo/path` prefix per card and carried
  the agent's real `/** Builds a greeting… */` change; tree excluded `.git`,
  expanded `src` → `components`; vim `:w` wrote `// reviewed-by-human` to disk
  (confirmed by reading the file).
- **P5** — memory entries render with type badges (`DECISION`, `NOTE`,
  `SNIPPET`, `SUMMARY`, `FILE_CONTEXT`); FTS search for `Stripe` returned exactly
  the two Stripe rows, and `greet()` — which crashed the previous pass — now
  returns the snippet and note.
- **P6** — killing the backend surfaced *"Lost connection to the Codrift server.
  Reconnecting…"* plus a sidebar error; restarting cleared the banner and
  reloaded initiatives with **no page reload**. `d` on an initiative and `d` on an
  agent both open a confirm modal that takes focus; `Esc` cancels, `Enter`
  confirms. Delete removed the registry entry and the context folder, and left
  the project files untouched.

- **P9** — an initiative folder with `scripts/`, `docs/runbooks/`, `templates/`
  and loose docs renders as a real tree in the sidebar: folders expand and
  collapse, `←`/`→` walk in and out, and every file opens in the context pane.
  Directories under version control draw a branch glyph; a plain folder draws a
  folder. The `memory` row sits with the rest of the context and opens the
  memory store.
- **P10** — every one of the 65 bundled VS Code themes re-skins the *whole*
  app — sidebar, header, panels, borders, diff tints, syntax, the editor and the
  terminal's 16 ANSI colours — with live preview while arrowing, Esc to revert,
  and the choice persisted to `settings.json`. A hand-written 12-key theme
  dropped into `~/.codrift/themes` does the same. Font family and size are
  chosen from the faces actually installed on the machine.

### Fixed since the previous pass

| # | Previous defect | Status |
|---|---|---|
| 1 | `memory_search` leaked an Elixir crash on `greet()` | **Fixed** — `greet()`, `un"balanced`, `AND`, `*`, `foo NEAR/`, `"` all return HTTP 200 |
| 2 | Agent status never live-updated | **Fixed** — `starting` → `needs input` propagates without `r`, plus "N waiting" roll-ups |
| 4 | `⌃P` / `⌃B` dead while the terminal is focused | **Fixed** |
| 5 | Dir rows showed a chevron that was not a toggle | **Fixed** — real Expand/Collapse buttons with `aria-expanded` |
| 6 | Palette exposed dead commands (`v`, `c`) | **Fixed** — `PALETTE_ACTIONS` gates the list |
| 8 | Diff cards omitted the repo | **Fixed** — cards read `webapp/README.md`, `api/index.js` |
| 9 | Stale TUI copy in generated `initiative.md` | **Fixed** — "press `a` to add one" |
| 10a | Dir picker listed `.git` | **Fixed** |
| 10b | Loose agents showed raw `awaiting_input` | **Fixed** — humanized everywhere |
| 10d | Confirm modal did not take focus | **Fixed** — focus lands on Cancel |
| 10e | Sidebar was a flat list of buttons | **Fixed** — `tree` / `treeitem` / `aria-level` / `aria-selected` |

---

## Defects found in this pass — and what happened to them

Every defect below was found by the pass, fixed in the same session, and then
**re-verified through Chrome MCP** against a rebuilt app. The repro is kept so a
regression is recognisable.

| # | Defect | Personas | Fix |
|---|---|---|---|
| 1 | **Sidebar highlight and content pane desync.** Stopping the last agent under a directory moved the highlight to the *next* initiative while the pane kept showing the previous one; `s`/`t`/`a`/`d` then acted on the initiative the user was *not* looking at. Repro: select `P5b` → its `docs` dir → `t` → click the agent row → `Shift+Tab`, `d`, `Enter`; highlight lands on `P6b`, pane still reads `P5b`, and `t` creates the agent under `P5b`. | P2, P3, P6 | **Fixed.** The cursor is keyed by row identity, not by index, and re-anchors inside the pane's initiative when its row disappears (`workspace.svelte.ts`). Re-verified: highlight, pane and the resulting agent all agree. |
| 2 | **`n` did not select the initiative it created** — it was appended to the end unselected, so the natural next key (`a`) added the directory to whatever was selected before. | P1 | **Fixed.** `create_initiative` now selects what it created. Re-verified: `n` → `a` put `docs` on the new `P8`. |
| 3 | **Untracked files never appeared in the diff.** `git diff` only reports tracked files, so `notes.txt` and `src/components/Button.js` were invisible to the reviewer even though an agent had created them. | P4 | **Fixed.** `Codrift.Diff.generate/2` lists untracked files (`git ls-files --others --exclude-standard`, honouring `.gitignore`) and diffs each against `/dev/null`; only for plain working-tree diffs. 6 new unit tests. |
| 4 | **Launch profiles were reload-only.** A profile added to `settings.json` did not appear after `r`. | P3 | **Fixed.** Profiles are refetched by every `load()`. Re-verified: `claude-audit` appeared after `r`. |
| 5 | **Running agents vanished silently after a backend restart.** | P6 | **Fixed.** The reconnect compares agent counts and says so: *"Reconnected — 1 running agent was lost."* |
| 6 | **File preview was stale right after `:w`.** | P4 | **Fixed.** The editor reports saves; the tree re-reads the file. |
| 7 | **A collapsed initiative re-expanded when it stayed selected**, and every refresh re-expanded the pane's initiative. | P2 | **Fixed.** Cursor movement no longer expands; only an explicit click, `→`, or the first load does. |
| 8 | **xterm threw on every themed glyph** — `Unexpected fillStyle color format "oklch(…)"` — because `getComputedStyle` now keeps colours in their own space. Found while re-verifying, not in the original pass. | P1–P6 | **Fixed.** Colours are resolved through a 1×1 canvas readback, so xterm always receives `rgb()`. Console is clean. |
| 9 | **45 of 65 VS Code themes mapped to an unusable accent** (many at 1.00:1 — `focusBorder` equal to the background). Found by auditing the mapping rather than by eye. | P10 | **Fixed.** Candidate keys are ranked and each token falls back until it clears WCAG (4.5:1 body, 3:1 secondary/accent). `pnpm check` now runs `scripts/audit-themes.mjs`: **65 themes, 0 below threshold.** |
| 10 | Sidebar agent rows wrapped to two lines; the launch profile reset in a cloned pane; the dir picker did not scroll to the caret after `Tab`. | P2, P3 | **Fixed** — verified individually. |
| 11 | **Every OAuth request was sent as JSON, so no PKCE connect could ever complete.** `Codrift.Integration.HTTP.post/3` always sets a JSON body, but OAuth 2.0 token and device-authorization endpoints require `application/x-www-form-urlencoded` (RFC 6749 §4.1.3, RFC 8628 §3.1). Linear rejected the token exchange with `HTTP 400 invalid_request: content must be application/x-www-form-urlencoded`. Repro: complete a Linear or GitLab consent and exchange the resulting `code`. Found while registering the OAuth apps — **not** by a UI pass, because no pass had ever completed a real consent. | P11 | **Fixed.** New `HTTP.post_form/3` (`{:form, params}` → Req's `:form`); the three OAuth call sites in `oauth.ex` use it, while the adapters keep JSON/GraphQL. 4 new tests assert the bytes on the wire against a live Bandit listener. GitHub Device Flow re-verified through the fixed path (real `user_code` issued). |

### Known limits (not defects)

- A theme with no `tokenColors` — Codrift's own default, or a minimal drop-in —
  skins the whole app but has nothing to colour code with, so syntax falls back
  to a bundled theme of the same polarity. Full marketplace theme JSON carries
  `tokenColors` and highlights natively.
- Font *size* applies to the terminal and the editor; the surrounding UI is laid
  out in fixed pixels, so scaling it needs a rem-based pass first.
- Themes are applied from `colors` only — VS Code's `include` (theme
  inheritance) is not resolved, so a drop-in that only extends another theme
  renders from whatever it defines itself.

---

## Not covered

- **OAuth connect flows** (GitHub / GitHub Projects / GitLab / Linear / Linear
  Projects) — the panel inventory was verified (five providers, all
  disconnected, each with a Connect button), but no flow was completed **through
  the UI**. P11 above is the persona that closes this; it has not been run yet.

  What *is* established, at the protocol level rather than through the app:

  | Service | State |
  |---|---|
  | GitHub / GitHub Projects | OAuth App registered, Device Flow enabled, client ID bundled. Verified live — a device-code request returned a real `user_code` and `verification_uri`. |
  | GitLab | Public (non-confidential) app registered with `read_api` + `read_user`, client ID bundled. Verified live — consent granted, provider redirected to `127.0.0.1:43117/oauth/callback/gitlab?code=…&state=…` with the state echoed intact. |
  | Linear / Linear Projects | Public app registered with both loopback redirect URIs, client ID bundled (shared by both services). Verified live — consent granted, provider redirected to `127.0.0.1:43117/oauth/callback/linear?code=…&state=…`. Note that Linear's authorize endpoint renders client-side, so an HTTP-level check cannot tell a valid client ID from an invalid one; only a logged-in consent proves it. |

  None of these exercised the callback handler or anything in the UI — the local
  server was not running to receive the redirect. Attempting the Linear token
  *exchange* by hand is what surfaced defect 11 above: the whole PKCE leg was
  broken and no UI pass had ever reached far enough to notice. Closing the
  remaining gap — callback handler, token persistence, badge state, revoke — is
  P11's job.
- **Worktrees** — `worktree_enable` / `worktree_disable` and the `wt` badge.
- **Orchestration** (`o` / conductor) and the MCP SSE transport.
- **Session persistence across restarts** for Claude agents (`SessionStore`);
  this pass only re-confirmed agents disappear from the list after a backend
  restart.
- **Tauri shell specifics** — native menu, `⌃Q` quit, heartbeat shutdown. The
  SPA is identical, but WebKit-only behaviour is not covered by Chrome. Worth a
  look for themes specifically: the palette is plain `rgb()` and the terminal
  gets explicit colours, but WKWebView is where the old OKLCH bug would have
  hurt most.
- **Themes on a high-DPI light setup at small font sizes** — contrast is
  checked numerically for all 65 themes, but hinting and stem weight are not.
