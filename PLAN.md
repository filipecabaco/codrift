# Codrift — AI Coding Companion

**Stack:** Elixir · Francis · ex_tauri · Svelte · xterm.js · Git · SQLite (Exqlite)

**Docs:** [Architecture](docs/architecture.md) · [Modules](docs/modules.md) · [Decisions](docs/decisions.md) · [Keyboard](docs/keyboard.md) · [Tree View](docs/tree-view.md) · [Diff Mode](docs/diff-mode.md) · [Worktrees](docs/worktrees.md) · [Memory](docs/memory.md) · [Integrations](docs/integrations.md)

---

Codrift is a desktop app (Tauri + Svelte + xterm.js) backed by an Elixir/Francis
server that runs and supervises multiple AI coding agents across a project's
directories. See the docs above for the current shape of each subsystem.

## Next

- Verify the desktop build end-to-end in CI (`mix ex_tauri.build`).
- Ship Tauri bundles (`.dmg`/`.AppImage`) from CI on tagged releases.
- Bundle OAuth `client_id`s into the release so integrations work without env vars.
- Deploy the `codrift.sh` landing page (built in `website/`, Francis + Tailwind, with per-platform download links and product screenshots).
</content>
