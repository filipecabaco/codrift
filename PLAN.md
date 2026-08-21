# Codrift — AI Coding Companion

**Stack:** Elixir · Francis · ex_tauri · Svelte · xterm.js · Git · SQLite (Exqlite)

**Docs:** [Architecture](docs/architecture.md) · [Modules](docs/modules.md) · [Decisions](docs/decisions.md) · [Keyboard](docs/keyboard.md) · [Tree View](docs/tree-view.md) · [Diff Mode](docs/diff-mode.md) · [Worktrees](docs/worktrees.md) · [Memory](docs/memory.md) · [Integrations](docs/integrations.md) · [Agent profiles](docs/agent-profiles.md) · [Hosting](docs/hosting.md)

---

Codrift is a desktop app (Tauri + Svelte + xterm.js) backed by an Elixir/Francis
server that runs and supervises multiple AI coding agents across a project's
directories. See the docs above for the current shape of each subsystem.

## Next

- Verify the desktop build end-to-end in CI (`mix ex_tauri.build`).
- Ship Tauri bundles (`.dmg`/`.AppImage`) from CI on tagged releases.
- ~~Bundle OAuth `client_id`s into the release so integrations work without env
  vars.~~ Done — GitHub, Linear and GitLab apps are registered and their client
  IDs ship in `lib/codrift/oauth/config.ex`. Still to do: run persona P11 (see
  [PERSONAS.md](PERSONAS.md)) to validate all three flows through the UI. The
  sandbox must bind `43117`, since the redirect URI is registered with each
  provider and cannot change at runtime.
- Deploy the `codrift.app` landing page (built in `website/`, Francis + Tailwind, with per-platform download links and product screenshots).
- In-app manager for [agent launch profiles](docs/agent-profiles.md) (add/edit/delete) — currently file-defined in `settings.json`, selectable from the Launch dropdown.
</content>
