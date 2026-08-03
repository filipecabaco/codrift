---
target: Codrift desktop UI (assets/src/App.svelte)
total_score: 23
p0_count: 1
p1_count: 4
timestamp: 2026-08-03T13-15-27Z
slug: assets-src-app-svelte
---
## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 2 | Agent status frozen at `starting`; the one signal the product exists to provide never updates without `r` |
| 2 | Match System / Real World | 3 | Domain language is right; generated `initiative.md` still says "use 'a' in the TUI" inside the desktop app |
| 3 | User Control and Freedom | 2 | `Esc` exits everything, but `:q` silently discards unsaved edits and delete has no undo |
| 4 | Consistency and Standards | 2 | Dir chevron never toggles while the initiative chevron does; raw vs humanized status; `⌃P`/`⌃B` dead in terminal focus |
| 5 | Error Prevention | 2 | Good delete confirm; `.git` offered as a project dir; no unsaved-changes guard |
| 6 | Recognition Rather Than Recall | 3 | Footer hint bar and palette are strong; launch profiles invisible unless you hand-edit settings.json |
| 7 | Flexibility and Efficiency | 3 | Remappable keymap, palette, splits, adapters, MCP + CLI; global chords die when a PTY has focus |
| 8 | Aesthetic and Minimalist Design | 2 | Chrome is excellent; default pane dominated by agent-facing boilerplate and duplicated absolute paths |
| 9 | Error Recovery | 1 | Raw Elixir `no case clause matching: {:error, "fts5: syntax error near ")"}` rendered to the user |
| 10 | Help and Documentation | 3 | Palette doubles as a command index; nothing in-app points at docs/ or keybinding customization |
| **Total** | | **23/40** | **Acceptable — significant improvements needed** |

## Anti-Patterns Verdict

**LLM assessment: not AI slop.** Real point of view: no card grid, no hero-metric tiles, no gradient accents, no glassmorphism. One monospace family, one amber accent, 1px hairlines, flat surfaces. Ghostty/Raycast-adjacent, exactly the register PRODUCT.md claims. The failure mode is the opposite of slop: disciplined but under-serving its own core job.

**Deterministic scan: unavailable.** `detect.mjs` exits with `Error: bundled detector not found`; `scripts/detector/` is absent, and the same bundle backs the browser overlay. No overlay injected. Fallback: manual browser evidence via Chrome DevTools MCP (computed contrast, live `:focus-visible` inspection, ARIA/landmark counts, console, multi-viewport screenshots).

**Browser evidence:** console clean (0 messages); all 20 buttons have accessible names; landmarks present. But `aria-expanded` = 0, tree/listbox roles = 0, `aria-current`/`aria-selected` = 0, `role="dialog"` = 0 (modals are `role="presentation"`).

## Overall Impression

The chrome is better than the product. The frame is quiet, dense, confident, and the agent terminal really is the star. But a supervision tool whose supervision signal is broken: with three agents running, one blocked on a permission prompt, every row said `starting`. Meanwhile the loudest element on the default screen is an amber `## Memory Store` heading above a CLI cheat-sheet aimed at agents. Biggest opportunity: fix the priority inversion — live agent state loudest, boilerplate demoted.

## What's Working

1. **The footer hint bar.** Context-sensitive (`⇥ Terminal` vs `⇥ Sidebar`), teaches the keymap without a tour.
2. **The connection-loss banner.** `role="status"`, `aria-live="polite"`, `motion-safe:animate-pulse`, plain copy, self-heals with no reload. Both animations are `motion-safe:` gated, so reduced motion is genuinely respected.
3. **Restraint under the Quiet Accent Rule.** `fg` on `canvas` = 16.7:1; amber = 7.9:1. Status always paired with text or a dot glyph.

## Priority Issues

**[P0] Agent status never updates, so you cannot tell which agent needs you.** A real Claude agent sat blocked on a permission prompt while the sidebar said `starting`; `list_agents` already reported `awaiting_input`. With five agents you must click each pane to find the blocked one — the exact chaos Codrift replaces. Fix: push status over the existing SSE stream; make `awaiting_input` visually loud; surface a needs-input count on the initiative row. → `craft`

**[P1] A raw Elixir error is rendered to the user.** Searching `greet()` prints `no case clause matching: {:error, "fts5: syntax error near ")"}`. Same path serves the `memory_search` MCP tool. Fix: catch the FTS5 error in `lib/codrift/memory.ex:72`, return a typed failure, and say what to type instead. → `clarify`

**[P1] `:q` throws away unsaved edits with no warning.** Verified: typed a line, `:q`, editor closed, text not on disk, no prompt. Fix: dirty tracking, confirm modal or `:q!` contract, dirty marker in the editor header. → `harden`

**[P1] Keyboard focus is the browser default and fights the app's own cursor.** `Tab` drew a Chrome-blue 1px ring (3.43:1 on canvas) on one row while the amber cursor sat on another. Browser-dependent in a product that calls a visible focus indicator a hard requirement. Fix: one `:focus-visible` treatment using the amber ring (7.9:1); reconcile DOM focus with the keyboard cursor. → `audit`

**[P1] Secondary text fails WCAG AA.** `muted` = 3.72:1 on canvas, 3.58:1 on surface, below the 4.5:1 floor, used at 11–12px for agent status, meta line, section labels, idle tabs, footer hints, toast. Fix: lift `--color-muted` to ≈`oklch(63% 0.01 265)` (≈5.6:1); promote agent status to `fg/80` (9.75:1). → `audit`

**[P2] The default pane shouts documentation and whispers state.** Every initiative opens on a rendered `initiative.md`: amber heading, ID, both absolute paths (duplicated from the strip above), Memory Store explainer, MCP tool list, seven-line CLI block — all written for agents. `Codrift.Paths.compact/1` exists and is unused here. Fix: collapse boilerplate behind a disclosure, compact paths, give the top of the pane to live state. → `distill`

## Persona Red Flags

**Mara (multi-agent supervisor, primary persona).** Five agents, every row `starting`; the blocked one looks identical to the four working. Collapsing an initiative to reduce noise does not stick because the next `j` re-expands it.

**Alex (power user).** `⌃P`/`⌃B` do nothing while the terminal has focus; must `Shift+Tab` out first. "Toggle diff layout" in the palette runs and does nothing. The profile dropdown resets to `claude` after each launch. A new profile in `settings.json` needs a full page reload, not `r`.

**Jordan (first-timer).** Six keystrokes to a running agent — genuinely good. Then the pane fills with MCP tool names and `codrift memory add` commands he cannot tell are meant for him. Clicks the `▸` next to `webapp` expecting a fold; it only selects. Never learns keybindings are remappable.

**Screen-reader / keyboard-only engineer.** Sidebar is a flat list of `<button>`s: no `role="tree"`, no `aria-expanded`, no `aria-current`, so cursor position and expansion state are colour-only. Modals are `role="presentation"` with no `aria-modal` or focus trap; the delete confirm left focus on the header. The 4-second toast is a plain `<span>` with no live region.

## Minor Observations

- Two `<h1>`s on screen; heading order jumps H2 → H1 inside the pane.
- Dir picker lists `.git` as a selectable project directory.
- An RPC arg mismatch reports `unknown tool: add_dir` instead of naming the missing argument.
- At 800×600 the sidebar keeps a fixed proportion; absolute paths wrap to three lines; no structural collapse.
- Diff cards drop the `dir` field the backend sends; same-named files across repos are indistinguishable.
- Split-pane layout is not persisted across reload.

## Questions to Consider

- If the sidebar could show one thing per agent, should it be the adapter name or "does this need me right now?"
- What would the Context pane look like if it opened on live state, with agent instructions behind one keystroke?
- Amber currently means focus, selection, primary action, and markdown headings. If it meant only "needs your attention", what would a healthy screen look like?
- Should `Tab` move the keyboard cursor instead of shadowing it with a second, browser-drawn ring?
