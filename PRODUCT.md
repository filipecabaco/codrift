# Product

## Register

product

## Users

Professional software engineers who run multiple AI coding agents (Claude Code, Codex, Opencode, Gemini, Copilot) and shell sessions side by side across several project directories. They live in the keyboard, work across many repositories at once, and treat agents as parallel collaborators they supervise rather than tools they babysit. Context when using Codrift: a focused, high-attention work session where the user is launching agents, watching live output, reviewing diffs, and steering work across initiatives without leaving one surface.

The job to be done: group related directories into an "initiative", launch and supervise agents per directory, watch their output live, review the resulting diffs, browse the file tree, and let agents share a memory store, all from a single keyboard-driven surface (terminal TUI or the Tauri desktop / web UI).

## Product Purpose

Codrift is a control surface for orchestrating many AI coding agents at once. It exists because driving several agents across projects from separate terminals is chaotic: output scatters, diffs are hard to compare, and there is no shared context between sessions. Codrift unifies that into one place, with initiatives, per-directory agents, live diff and tree views, a shared FTS5 memory store, and an MCP server other tools connect to.

Success looks like: a user supervising several concurrently-running agents without losing track of any, reviewing each one's changes in place, and moving between them faster than they could with raw terminals, never feeling the tool is in the way of the agents' own interfaces.

## Brand Personality

Sharp, technical, confident. The register of Linear, Raycast, and Ghostty: precise, engineered, opinionated, made for people who know exactly what they want. Voice and tone are terse and expert, no hand-holding, no marketing gloss inside the app. The interface should feel fast and deliberate, like a well-tuned instrument. It earns trust by exposing real system state plainly rather than by decoration.

## Anti-references

- **Generic SaaS dashboard.** No card grids, no hero-metric tiles (big number + label + gradient), no rounded-everything, no gradient accents. The AI-tool default look.
- **Bright light-mode admin.** No white/teal corporate enterprise panels, no heavy admin chrome.
- **Neon-on-black "AI / crypto".** No glowing gradients, purple/cyan neon, decorative glassmorphism, or sci-fi vibes.
- **Cluttered legacy IDE.** No Eclipse-style toolbar soup, tiny-icon rows, or dense panels without hierarchy.

## Design Principles

- **The agent is the star.** Codrift's own chrome stays out of the way. The focal content is each agent's live output (its native PTY/TUI, rendered faithfully); the surrounding UI frames it and never competes with it.
- **Keyboard is the primary interface.** Every action is reachable and discoverable by key (navigation, view switching, launching, the command palette). The mouse is a convenience, not the main path. This carries the TUI heritage into every surface.
- **Dense, but with hierarchy.** Information-dense like a terminal, yet always legible: clear type hierarchy, deliberate spacing rhythm, and grouping that keeps density from becoming clutter.
- **One model across surfaces.** The desktop / web UI mirrors the TUI's mental model (initiatives, Context / Diff / Tree, per-directory agent panes). A user who knows one knows the other.
- **Show real state, earn every pixel.** Surfaces reflect live system truth (agent status, diffs, memory entries, git state). No decorative filler, no fabricated affordances, nothing on screen that does not mean something.

## Accessibility & Inclusion

Target WCAG 2.1 AA. Keyboard-first is a hard requirement, not a nicety: all navigation, view switching, selection, launching, and focus movement must be fully operable from the keyboard, with a visible focus indicator on the active pane and row. Respect `prefers-reduced-motion`. Do not encode agent status (running / awaiting input / stopped) by color alone; pair it with text or shape. Maintain AA contrast across the dark surface, including dimmed/secondary text.
