# Codrift — AI Coding Companion TUI

**Stack:** Elixir · Francis · ex_ratatui · Git · SQLite (Exqlite)

**Docs:** [Architecture](docs/architecture.md) · [Modules](docs/modules.md) · [Decisions](docs/decisions.md) · [Keyboard](docs/keyboard.md) · [Tree View](docs/tree-view.md) · [Diff Mode](docs/diff-mode.md) · [Worktrees](docs/worktrees.md) · [Memory](docs/memory.md) · [Integrations](docs/integrations.md)

---

## ✅ Done

| # | Feature |
|---|---------|
| 1–5 | Backend foundation: initiative model, agent process, diff parser, code quality |
| 6–11 | TUI core: VT100 emulator, PTY agents, terminals, mouse, graceful shutdown |
| 12–19 | TUI navigation: multi-dir sidebar, initiative CRUD, context folder, in-TUI editor |
| 20–21 | Diff viewer: web view, unified/split toggle |
| 22–24, 31 | Agent sessions: multi-agent per dir, SQLite persistence, auto-restart |
| 25–26 | MCP server: HTTP+SSE, initiative tools |
| 27–30 | Polish: ASCII labels, sidebar collapse, expanded command palette |
| 32–33 | Config layer: keybinding overrides, theme chooser (5 themes) |
| 34–36 | Memory store, CLI, distribution, GitHub Actions CI |
| 37, 42 | Git worktrees: per-dir opt-in, sidebar status label, CLI commands |
| 39 | External integrations: 9 adapters, OAuth flows, 5 MCP tools |
| 41 | Safe paste + input hardening: bracketed paste NIF, Unicode, Tab, Shift+Enter |
| 43 | Additional CLI adapters: Claude, Codex, Opencode, Gemini, Copilot; agent picker |
| 44–45, 49 | Tree view: file-tree sidebar, syntax-highlighted preview, embedded `$EDITOR`, quick-open |
| 48, 52 | Sidebar filter: `/` activates, `Esc` clears; fuzzy, glob (`*.test.ts`), regex (`/pattern/`), tag (`#test` `#config` `#doc` `#schema` `#router`); works in tree and diff mode |
| 50 | Modal text-input focus audit |

## ⬜ Upcoming

| # | Feature |
|---|---------|
| 51 | OAuth app credentials: bundle `client_id` into release binary |
| 47 | Website: `codrift.sh` landing page with install one-liner and asciinema demo |
