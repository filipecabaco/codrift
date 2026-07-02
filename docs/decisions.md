# Key Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Francis role | Web server only | Serves the desktop UI plus the HTTP/RPC, SSE, and MCP endpoints |
| HTTP port | 7437 | Rarely used; avoids clashes with Phoenix (4000), Angular (4200), etc. |
| CLI agents | erlexec PTY (`:pty` mode primary) | Claude Code requires a real TTY for interactive mode; PTY via erlexec gives full terminal support |
| Agent restart | `:temporary` | User-driven; automatic restart would re-run expensive inference |
| Persistence | JSON file (`~/.config/codrift/`) | Simple, human-readable, v1 scope |
| Session storage | SQLite via Exqlite (`~/.codrift/codrift.db`) | Structured, reliable upsert; shares DB with future vector memory |
| Git diffs | Shell to `git diff` | Zero deps, covers all needed formats |
| JSON codec | Elixir 1.18 built-in `JSON` | No extra dep needed |
| MCP transport | HTTP+SSE (`POST /mcp` + `GET /mcp/sse`) | Compatible with `claude mcp add --transport sse` |
| Test isolation | `:name` opt defaults to `__MODULE__`; `server` param on queries | Avoids conflicts with app-started named processes |
| Code style | Credo enforced; `@doc`/`@moduledoc` on all public modules | Consistency + discoverability |
| Desktop shell | Tauri via `ex_tauri`; Elixir `desktop` release runs as a sidecar | Native window + webview per platform; the Svelte UI talks to Francis on `:7437`; no browser or runtime prerequisites for end users |
| Distribution | Tauri bundles (`.dmg`/`.AppImage`) via GitHub Releases | Native installers for macOS and Linux; the headless `codrift` CLI ships alongside for MCP registration and scripting |
| Sidecar packaging | Burrito-wrapped `:desktop` release in prod; `BURRITO_SKIP=true` for dev | ex_tauri needs a single-file `externalBin`; Burrito produces it. `mix ex_tauri.dev` skips Burrito for fast iteration and so the local macOS Tahoe host never invokes Zig; prod bundles build in CI (non-Tahoe) with Zig 0.15.2, one native triple per runner via `BURRITO_TARGET` |
| Async agent starts | `Task.Supervisor` (`Codrift.TaskSupervisor`) | Non-blocking server; failures are isolated |
| View switching | Tabs (Context / Diff / Tree) share one main pane | The initiative sidebar stays put; `1`/`2`/`3` swap what the main pane renders, so navigation context is never lost |
| Keybinding config | JSON file merge over defaults | User overrides only what they care about; defaults always present for unspecified actions; the UI fetches the resolved map via `get_keybindings` so labels stay in sync |
| Memory store | SQLite FTS5, no embeddings | FTS5 (porter+unicode61) ships inside SQLite itself — zero new deps; no vector DB, no embedding model required; BM25 ranking good enough for initiative-scale knowledge bases (dozens to hundreds of entries, not millions); exact-phrase and AND/OR/NOT queries just work |
| CLI in release | `eval` dispatch, not `start` | Each `codrift <subcommand>` forks a short-lived process via `bin/codrift eval 'Module.run(System.argv())'`; the full supervision tree is NOT started — only the code is loaded; avoids port conflicts when the desktop app is already running |
