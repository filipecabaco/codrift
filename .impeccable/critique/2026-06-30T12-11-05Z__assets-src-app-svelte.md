---
target: the Codrift web UI (assets/src/App.svelte)
total_score: 27
p0_count: 0
p1_count: 2
timestamp: 2026-06-30T12-11-05Z
slug: assets-src-app-svelte
---
## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Agent status + live output + focus ring are strong; no global "server connected" signal (drop = blank pane). |
| 2 | Match System / Real World | 3 | Initiative/diff/tree/terminal language fits the dev audience well. |
| 3 | User Control and Freedom | 3 | Esc closes modals, Tab cycles focus, stop-agent confirm; no undo, no explicit "back". |
| 4 | Consistency and Standards | 3 | github-dark tokens applied consistently; tabs/rows/overlays coherent. |
| 5 | Error Prevention | 2 | Delete confirm is good; otherwise errors only surface as transient toasts; server-down has no guard. |
| 6 | Recognition Rather Than Recall | 3 | Command palette lists every action with key hints; sidebar tree exposes structure. |
| 7 | Flexibility and Efficiency | 3 | Excellent for power users (palette, per-dir launch, full keymap); thin for novices. |
| 8 | Aesthetic and Minimalist Design | 3 | Clean, restrained, no slop patterns; Context view is a text wall and the sidebar reads samey. |
| 9 | Error Recovery | 2 | Error toasts vanish in ~2.8s; server-drop leaves a blank pane with no retry path. |
| 10 | Help and Documentation | 2 | Palette + key hints help; no onboarding, no empty-state guidance, no cheatsheet. |
| **Total** | | **27/40** | **Solid foundation, clear gaps in error/help/identity** |

## Anti-Patterns Verdict

**LLM assessment:** Passes the absolute bans cleanly: no card grids, no hero-metric tiles, no gradient text, no decorative glass, no side-stripe borders, no modal-first reflex. It reads as a real terminal-adjacent dev tool, not generic AI SaaS. The one slop-adjacent tell is **borrowed identity**: the palette is GitHub's dark theme verbatim (`#0d1117` canvas, `#58a6ff` accent, `#161b22` surface, `#30363d` border). It looks like a GitHub surface, not like Codrift. That is the "terminal-native dark" second-order reflex for a dev/AI tool, executed well but not owned.

**Deterministic scan:** Unavailable. `detect.mjs` reported "bundled detector not found" after a real attempt; no automated overlay was produced.

## Overall Impression

The bones are genuinely good. It is fast, dense, keyboard-first, and it gets out of the way of the agent terminals exactly as the North Star ("The Workbench") intends. The single biggest opportunity is **identity plus hierarchy**: stop wearing GitHub's palette, and give the Context view a real information structure instead of a markdown wall, so the most important truths (status, dirs, running agents, goal) lead.

## What's Working

- **The agent-as-star principle is real.** Selecting an agent fills the pane with its native terminal, byte-for-byte, with zero competing chrome. That is the product's whole thesis and it lands.
- **Recognition over recall.** `Ctrl+P` surfaces every action with its key hint, and the sidebar tree exposes the full initiative/dir/agent structure. A user never has to memorize the model.
- **Restraint.** Hairline borders, one accent, mono everywhere, flat surfaces. It resists every SaaS-dashboard temptation and stays legible at high density.

## Priority Issues

- **[P1] Borrowed identity (GitHub-dark verbatim).** The exact GitHub tokens make Codrift indistinguishable from a GitHub surface and trip the second-order slop check. **Why it matters:** the product has no visual identity of its own; "confident" was a stated personality goal. **Fix:** shift the accent off GitHub-blue to a distinct hue and tint the neutrals toward it (keep the dark, keep the restraint). One move, big identity gain. **Command:** colorize.
- **[P1] Context view is a text wall with weak hierarchy.** The rendered `initiative.md` leads with boilerplate (Memory Store CLI instructions) that outweighs the actual Goal/Problem/dirs. **Why it matters:** the most important state competes with instructions; users scan past it. **Fix:** lead the Context pane with a structured header (status, dirs with git state, running agents, quick actions), then the prose; demote or collapse the standing instructions. **Command:** layout.
- **[P2] No connection / error / empty states.** When the server drops, the pane goes blank (observed: `ERR_CONNECTION_REFUSED`), and errors only flash as 2.8s toasts. **Why it matters:** high-stakes moments (agent died, server gone) give no recoverable signal. **Fix:** a persistent "disconnected, retrying" banner, a non-transient error surface, and reconnect. **Command:** harden.
- **[P2] Novice discoverability.** Power users are well served; a first-timer sees a dense tree and a terminal with no hint that `Tab`, `⌃P`, and `j/k` exist (only a tiny emoji button and "press N"). **Why it matters:** the keyboard model is invisible until discovered. **Fix:** a slim persistent key-hint footer (the TUI has one) plus a real empty/first-run state. **Command:** onboard.
- **[P3] Sidebar rhythm and Context toolbar density.** Rows are visually samey at a glance, and the Context header stacks launch buttons + file tabs + a "memory" tab in a busy band. **Fix:** spacing/rhythm and grouping pass. **Command:** layout.

## Persona Red Flags

**Alex (Power User):** Mostly served (palette, full keymap, per-dir launch). Red flags: `Tab` is taken for focus-cycling, so sending a literal tab to the agent is awkward; no visible shortcut cheatsheet; refresh is a manual button rather than live.

**Jordan (First-Timer):** Lands in a dense tree with many identical-looking initiatives, terminal panes with no explanation, and error toasts that vanish before they are read. No onboarding or help. Likely lost within the first minute.

**The Supervising Engineer (project persona):** Strong fit overall; the per-directory launch + live diff + memory loop matches the job. Friction: when one of several agents dies, the only signal is a vanished status and a blank pane, which is exactly the moment they need a durable cue.

## Minor Observations

- Error/“Started …” toasts disappear in ~2.8s; too fast to read mid-task.
- The command-palette trigger is an emoji glyph (⌘) while the rest of the chrome uses Heroicons: inconsistent.
- "memory" tab is lowercased next to `initiative.md` / `orchestration.md`; minor casing inconsistency.
- The store is full of `test-init` duplicates (data hygiene, not design) that make the sidebar look noisier than the real UX.

## Questions to Consider

- What would a version that owns its color (not GitHub's) look like, while staying dark and restrained?
- Does the Context view need to show the standing Memory/CLI instructions every time, or only the live state plus the goal?
- When an agent dies, what is the one cue the supervisor must never miss?
