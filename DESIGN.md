---
name: Codrift
description: A keyboard-driven workbench for supervising many AI coding agents at once.
colors:
  canvas: "oklch(11% 0.01 265)"
  surface: "oklch(15% 0.012 265)"
  border: "oklch(22% 0.012 265)"
  muted: "oklch(52% 0.01 265)"
  fg: "oklch(93% 0.008 265)"
  accent: "oklch(72% 0.18 65)"
  status-ok: "#22c55e"
  status-info: "#0ea5e9"
  status-done: "#8b5cf6"
  status-danger: "#f87171"
typography:
  display:
    fontFamily: "ui-monospace, Cascadia Code, Source Code Pro, Menlo, monospace"
    fontSize: "18px"
    fontWeight: 600
    lineHeight: 1.4
  title:
    fontFamily: "ui-monospace, Cascadia Code, Source Code Pro, Menlo, monospace"
    fontSize: "16px"
    fontWeight: 600
    lineHeight: 1.4
  body:
    fontFamily: "ui-monospace, Cascadia Code, Source Code Pro, Menlo, monospace"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "ui-monospace, Cascadia Code, Source Code Pro, Menlo, monospace"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.4
  badge:
    fontFamily: "ui-monospace, Cascadia Code, Source Code Pro, Menlo, monospace"
    fontSize: "10px"
    fontWeight: 400
    letterSpacing: "0.04em"
rounded:
  sm: "4px"
  md: "6px"
  lg: "8px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
components:
  tab-active:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.fg}"
    rounded: "{rounded.md}"
    padding: "4px 10px"
  tab-idle:
    backgroundColor: "transparent"
    textColor: "{colors.muted}"
    rounded: "{rounded.md}"
    padding: "4px 10px"
  launch-button:
    backgroundColor: "oklch(72% 0.18 65 / 0.2)"
    textColor: "{colors.accent}"
    rounded: "{rounded.md}"
    padding: "4px 8px"
  row-active:
    backgroundColor: "oklch(72% 0.18 65 / 0.2)"
    textColor: "{colors.fg}"
    rounded: "{rounded.md}"
    padding: "2px 6px"
  overlay:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "16px"
---

# Design System: Codrift

## 1. Overview

**Creative North Star: "The Workbench"**

Codrift is a precise instrument, not a destination. The interface is the bench you reach across to drive several AI coding agents at once; it should disappear into the work the moment you start. Every surface is quiet, dark, and dense, framing the one thing that matters: each agent's own live output, rendered faithfully in its native terminal. The chrome (sidebar, tabs, panes, overlays) is hairline structure and muted labels. The signal is the agents.

The register is sharp, technical, and confident, in the lane of Linear, Raycast, and Ghostty. It is built for an engineer who already knows what they want and moves by keyboard. Density is a feature: information sits close together like a well-organised toolboard, held legible by clear type weight and deliberate grouping rather than by whitespace and cards.

This system explicitly rejects four looks. It is not a generic SaaS dashboard (no card grids, no hero-metric tiles, no gradient accents, no rounded-everything). It is not a bright light-mode admin panel. It is not neon-on-black "AI/crypto" (no glows, no purple/cyan, no decorative glass). And it is not a cluttered legacy IDE (no toolbar soup, no tiny-icon rows, no panels without hierarchy).

**Key Characteristics:**
- Cool near-black surface tinted toward hue 265, one warm amber accent, used sparingly.
- A single monospace typeface across the entire product.
- Flat by default; 1px borders and tonal background shifts do the separating.
- Keyboard-first: a visible focus ring marks the active pane and row.
- Status is shown by shape and text, never by color alone.

## 2. Colors

A restrained dark palette: cool blue-violet near-black neutrals (hue 265) carrying the whole surface, one warm amber accent for focus and selection, and a small set of semantic status hues that only ever signal state. The accent and neutrals are shared with the Codrift marketing site, so product and brand read as one thing.

### Primary
- **Codrift Amber** (`oklch(72% 0.18 65)`, ≈ #ef8700): The single accent, and the brand's signature. Used for focus rings, the active row and tab, selection tints (at low alpha), links in rendered docs, document headings, and the launch action. It marks "this is where you are" and "this is the thing you can do", nothing else. Its warmth deliberately sits against the cool neutrals.

### Neutral
- **Canvas** (`oklch(11% 0.01 265)`, ≈ #030407): The base surface. The terminal-adjacent near-black the whole app sits on. Tinted toward blue-violet, never pure `#000`.
- **Surface** (`oklch(15% 0.012 265)`, ≈ #090b10): One step up from canvas. Headers, the sidebar background, overlays, code blocks, raised rows. The only tonal "elevation" the system uses.
- **Border** (`oklch(22% 0.012 265)`, ≈ #181b20): Every divider and outline. 1px hairlines that carve structure out of the flat surface.
- **Muted** (`oklch(52% 0.01 265)`, ≈ #66696f): Secondary and dimmed text: labels, statuses, hints, inactive tabs, file/dir glyphs, the worktree marker chip.
- **Foreground** (`oklch(93% 0.008 265)`, ≈ #e5e8ed): Primary text. Off-white, tinted toward the surface, never pure `#fff`.

### Status (semantic only)
Status hues sit deliberately off the amber accent, so "this is selected/focused" never reads as "this is a state". Each is paired with a dot glyph or text label, never carried by color alone.
- **OK Green** (#22c55e): A running or healthy initiative/agent (status dot, additions in diffs).
- **Info Sky** (#0ea5e9): Planning / queued state (status dot).
- **Done Violet** (#8b5cf6): A completed initiative (status dot).
- **Danger Red** (#f87171): Stopped/errored agents, deletions in diffs, destructive confirm actions.

### Named Rules
**The Quiet Accent Rule.** Codrift Amber covers no more than about 10% of any screen. It means focus, selection, or the single primary action. The moment it decorates, it stops meaning anything. Amber is reserved for the accent alone, it never doubles as a status color.

**The Status-Is-Not-Decoration Rule.** Green, sky, violet, and red appear only to encode real state, and never alone: always paired with a glyph (the status dot) or a text label, so meaning survives color blindness and grayscale.

## 3. Typography

**Display / Body / Label Font:** `ui-monospace` (with Cascadia Code, Source Code Pro, Menlo as fallbacks). There is no second family.

**Character:** One monospaced voice for everything. The product embeds real terminals, so the chrome speaks the same language as its content: even prose and headings sit on the monospace grid. This is deliberate and total.

### Hierarchy
- **Display** (600, 18px, line-height 1.4): The largest step, used for the top heading of a rendered context document (initiative.md `# title`).
- **Title** (600, 16px): Section headings inside rendered markdown (`##`), shown in Codrift Amber; also the weight used for initiative names in the sidebar.
- **Body** (400, 13px, line-height 1.5): Default reading size: markdown prose, terminal text, the bulk of the UI. Cap prose measure at 65 to 75ch in document views.
- **Label** (400, 11px): Secondary metadata: agent status, hints, counts, the focus indicator.
- **Badge** (400, 10px, letter-spacing 0.04em, uppercase): Memory entry type chips (decision, summary, snippet).

### Named Rules
**The One Typeface Rule.** Monospace, everywhere, always. No serif, no proportional sans, not even for headings. Hierarchy comes from weight (400 vs 600) and size, never from a font switch.

## 4. Elevation

The system is flat. Surfaces do not float at rest. Depth is conveyed by tonal layering (canvas to surface, one step) and by 1px borders, not by shadow. The only place a shadow appears is on genuinely floating overlays: the command palette, prompts, and confirm dialogs, which lift off the surface because they are modal and temporary.

### Shadow Vocabulary
- **Overlay lift** (`box-shadow: 0 16px 48px -12px rgba(1, 4, 9, 0.85)`, Tailwind `shadow-2xl`): The single shadow in the system, reserved for floating overlays over a `bg-black/50` scrim.

### Named Rules
**The Flat-By-Default Rule.** Panels, rows, cards, and the sidebar are flat. They separate with a `border` hairline or a step from `canvas` to `surface`. If you are reaching for a shadow on a non-floating element, use a border or a tonal shift instead.

## 5. Components

### Tabs (view switcher)
- **Shape:** Pill, `rounded-md` (6px), padding `4px 10px`.
- **Active:** `canvas` background inside the `surface` header, `border` outline, `fg` text. The recessed-into-the-bar look.
- **Idle:** Transparent, `muted` text, brightening to `fg` on hover. No underline, no gradient.

### Sidebar rows (initiatives, files, dirs, agents)
- **Character:** Dense, indented tree rows; one expandable initiative, then context files (◈), directories (▸), and agents (◦) nested beneath.
- **Default:** `fg`/`fg`-dimmed text on transparent, hover tint to `surface`.
- **Cursor / active:** `accent`-at-20% background with `fg`/white text. A single keyboard cursor highlight moves across every row type.
- **Radius / padding:** `rounded-md` (6px), `py-0.5`/`py-1` with left-indent by depth.

### Launch button (Start agent)
- **Style:** `accent`-at-20% background, `accent` text, `rounded-md` (6px), padding `4px 8px`. Brightens to ~30% accent on hover. The one primary action, deliberately low-key.

### Overlays (command palette, prompt, confirm)
- **Surface:** `surface` background, 1px `border`, `rounded-lg` (8px), `shadow-2xl`, over a `bg-black/50` scrim.
- **Behavior:** Centered near the top. Esc / backdrop-click dismisses. The palette filters a flat command list; confirm uses a `danger`-tinted Confirm button. Modals are a last resort, used only for genuinely modal moments (palette, naming, destructive confirm).

### Inputs / Fields
- **Style:** `canvas` background, 1px `border`, `rounded-md` (6px), `fg` text, monospace.
- **Focus:** Border shifts to `accent`. No glow.

### Status badges (memory types)
- **Style:** Tinted chip, semantic color at ~20% background with the matching 300-level text (e.g. decision purple, summary blue, snippet green), `badge` type, uppercase. Rounded `sm` (4px).

### Focus indicator (signature)
- The active pane carries a 1px inset `accent`-at-50% ring (`ring-1 ring-inset ring-accent/50`); the focused sidebar's divider brightens to `accent`-at-50%. Tab and Shift+Tab move focus between sidebar and the agent terminal. Keyboard focus is always visible.

### Agent terminal pane (signature)
- The focal content. A full xterm.js terminal rendering the agent's own PTY/TUI byte-for-byte (Claude Code, Codex, a shell). Codrift draws no chrome inside it. `canvas` background, 6px padding, monospace, GPU-rendered.

## 6. Do's and Don'ts

### Do:
- **Do** keep Codrift Amber to roughly 10% of any screen: focus, selection, and the single primary action only.
- **Do** separate surfaces with a 1px `border` hairline or a step from `canvas` to `surface`, not with a shadow.
- **Do** set everything in `ui-monospace`; build hierarchy with weight (400/600) and size.
- **Do** keep a visible keyboard focus ring on the active pane and row, and make every action key-reachable.
- **Do** pair every status color with a glyph or text label, never color alone.
- **Do** let the agent's own terminal output be the visual centre; keep Codrift's chrome quiet around it.

### Don't:
- **Don't** build a generic SaaS dashboard: no card grids, no hero-metric tiles (big number + label + gradient), no gradient accents, no rounded-everything.
- **Don't** use a bright light-mode admin look, white/teal corporate panels, or heavy enterprise chrome.
- **Don't** go neon-on-black "AI/crypto": no glows, no purple/cyan neon, no decorative glassmorphism, no sci-fi gradients.
- **Don't** recreate a cluttered legacy IDE: no toolbar soup, no tiny-icon rows, no dense panels without hierarchy.
- **Don't** use `#000` or `#fff`; tint neutrals toward the surface.
- **Don't** add a `border-left`/`border-right` colored stripe as an accent on rows, cards, or callouts.
- **Don't** use gradient text (`background-clip: text`); emphasize with weight or size.
- **Don't** reach for a modal when an inline or progressive affordance would do.
