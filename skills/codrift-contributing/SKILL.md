---
name: codrift-contributing
description: Use when changing the Codrift codebase itself — Elixir backend, Svelte UI, Tauri shell, the release pipeline, or the Homebrew tap. Triggers on work in lib/codrift, assets/src, src-tauri, .github/workflows, Casks/ or Formula/, and on "ex_tauri", "Burrito", "sidecar", "Francis", "erlexec", "port 43117", "release.yml", "bump the cask", "why does this work in dev but not in the packaged app".
---

# Working on Codrift itself

Codrift is a Tauri app: a native window wrapping a Svelte UI, backed by an
Elixir (**Francis**, not Phoenix) server that manages agents, worktrees, memory
and integrations.

```
assets/         Svelte 5 SPA (runes), built by Vite into priv/static
lib/codrift/    Elixir: agents, initiatives, memory, MCP handler, CLI
src-tauri/      Rust shell + tauri.conf.json
website/        The codrift.app marketing site (separate mix project)
Casks/ Formula/ This repo doubles as its own Homebrew tap
```

## The trap that has bitten twice: dev ≠ packaged

The `desktop` sidecar is launched two different ways, and they do not have the
same environment.

| | Launch | Sets `RELEASE_NAME`? |
|---|---|---|
| `mix ex_tauri.dev` | shim → `mix francis.server` | no |
| `sidecar: :release` | shim → `bin/desktop start` | yes |
| **Shipped build** | **Burrito wrapper → `execve` of `erl`** | **no** |

Burrito's launcher builds its own env map (`RELEASE_ROOT`, `RELEASE_SYS_CONFIG`,
`__BURRITO`, `__BURRITO_BIN_PATH`) and never sets `RELEASE_NAME`. Gating
desktop-only behaviour on `RELEASE_NAME == "desktop"` therefore passes every
local test and silently no-ops in every release. Gate on `desktop_sidecar?/0`
in `lib/codrift/codrift.ex`, which checks `RELEASE_NAME` **or** `__BURRITO`.

More generally: **a GUI app launched from Finder inherits launchd's minimal
`PATH`**, not your shell's. That is why `ensure_login_path/0` exists. Anything
that shells out to a user-installed binary (`claude`, `git`, `mise` shims) is
broken in the packaged app until that runs.

When something "works in dev but not in the packaged app", suspect environment
before logic.

## Local development

```bash
mix ex_tauri.dev        # Tauri window + hot-reloaded Svelte, no Burrito, no Zig
mix francis.server      # backend only, on 43117
cd assets && pnpm dev
```

`BURRITO_SKIP=true` is what keeps local builds off Zig. Production bundles build
in CI, one native triple per runner via `BURRITO_TARGET`.

## Checks before you call something done

```bash
mix test                          # 390+ tests
mix format --check-formatted
mix credo                         # enforced, not advisory
mix dialyzer
cd assets && pnpm check           # svelte-check + theme contrast audit
```

The website is a **separate mix project** with its own deps and lockfile —
`cd website && mix deps.get` before touching it, and it has no `.formatter.exs`,
so format it with an explicit pattern.

## Things that are fixed on purpose

- **Port 43117.** OAuth redirect URIs are registered against it ahead of time
  and cannot be renegotiated. Do not make it configurable "just in case".
- **OTP 27.** Burrito does not support OTP 28 yet. The patch version is pinned
  because Burrito can only fetch an ERTS the BEAM Machine CDN has built.
- **Agents restart `:temporary`.** Automatic restart would re-run expensive
  inference. Do not "fix" this to `:permanent`.
- **CLI subcommands dispatch through `eval`, not `start`.** Each `codrift <cmd>`
  forks a short-lived process that loads code without starting the supervision
  tree, so the CLI never fights the running app for the port. `mix.exs`
  patches these cases into the boot script; they are inserted at the **top** of
  the dispatch so a CLI command can shadow a boot-script verb (`start` does).

## Releases

Fully automated from Conventional Commits on `main`: `fix:` → patch, `feat:` →
minor, `type!:`/`BREAKING CHANGE` → major. No matching commit means no release.

The versions committed in `mix.exs` and `tauri.conf.json` are **placeholders** —
CI stamps the resolved version into both before building, and tags decide what
ships. Do not hand-edit them to "fix" a version.

The tap lives in this repo. `Casks/codrift.rb` ships the app, `Formula/codrift-cli.rb`
ships the headless `codrift` command, and the cask `depends_on` the formula —
so **both move in the same commit**. `.github/scripts/verify-cask.sh` re-downloads
the published assets and compares them to the checked-in checksums; it runs on a
schedule because drift (a deleted and re-cut release) arrives after the merge
that would have tested it.

## Conventions

- `@moduledoc` and `@doc` on every public module; Credo enforces it.
- Comments explain **why**, especially where behaviour looks wrong without the
  history. The codebase is dense with these — match that, don't strip them.
- Svelte 5 runes (`$state`, `$derived`), not stores.
- `POST /api/rpc` backs the whole UI: `{name, args}` → `Codrift.Core.call/2`.
  Add an op there rather than a bespoke route.

Deeper reading: [docs/architecture.md](https://github.com/filipecabaco/codrift/blob/main/docs/architecture.md),
[docs/modules.md](https://github.com/filipecabaco/codrift/blob/main/docs/modules.md),
[docs/decisions.md](https://github.com/filipecabaco/codrift/blob/main/docs/decisions.md)
