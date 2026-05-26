# Key Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Francis role | Web server only | No TUI capabilities in Francis |
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
| VT100 emulation | Pure Elixir (`Codrift.TUI.VT100`) | No Rustler/NIF needed; full correctness achievable in Elixir; supports all required sequences including IL/DL and SU/SD |
| Distribution | `mix release` + bundled ERTS, not Burrito | Burrito breaks on macOS Tahoe (relies on Zig to repack BEAM VM); `mix release` is OTP-native, produces a conventional tarball with ERTS included, no third-party toolchain involved |
| Async agent starts | `Task.Supervisor` (`Codrift.TaskSupervisor`) | Non-blocking TUI loop; failures are isolated |
| Diff sidebar | Sidebar transforms in diff mode | Cleaner than a separate file-list panel; sidebar is always visible and drives content |
| Split diff colours | Explicit `%Span{}` rendering via `to_split_rows/1` | Syntect `language: "diff"` doesn't colour stripped-prefix content; span rendering gives full control |
| Diff content border | Always cyan in diff mode | Content pane is always the reading surface in diff mode — grey "inactive" border was misleading |
| Keybinding config | JSON file merge over defaults | User overrides only what they care about; defaults always present for unspecified actions; palette hints + footer derived from the live map so they stay in sync |
| Theme system | Named themes resolved at load time to a struct | Five built-in themes (`default`, `dracula`, `nord`, `solarized`, `tokyo_night`); unknown name → silent fallback to `default`; no runtime theme switching — loaded once at TUI start |
