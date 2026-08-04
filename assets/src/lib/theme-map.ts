// Pure VS Code theme → Codrift palette mapping. No Svelte runes on purpose:
// this is the part that must be auditable outside the browser
// (scripts/audit-themes.mjs runs it over every bundled theme and fails if one
// comes out unreadable), so it stays plain TypeScript.
//
// The hard part is not reading `colors` — it is that themes disagree about
// which keys they define. Some set three workbench colours, some set four
// hundred, and plenty set `focusBorder` to something invisible. So every token
// resolves as: candidate keys in order → the first that is actually legible →
// otherwise the theme's own hue, corrected until it is.

export type VsCodeTheme = {
  name?: string;
  displayName?: string;
  type?: "dark" | "light" | "hc" | "hcLight" | string;
  colors?: Record<string, string>;
  tokenColors?: unknown[];
  semanticHighlighting?: boolean;
  /** Present on themes loaded from disk, absent for bundled ones. */
  include?: string;
};

export type Palette = {
  canvas: string;
  surface: string;
  border: string;
  fg: string;
  muted: string;
  accent: string;
  /** Diff row tints, flattened over `canvas` so translucency never stacks. */
  addBg: string;
  removeBg: string;
  addFg: string;
  removeFg: string;
  selection: string;
  dark: boolean;
  /** 16 ANSI colours + fg/bg/cursor for xterm. */
  terminal: Record<string, string>;
};

type Rgb = [number, number, number];
type Rgba = [number, number, number, number];

const WHITE: Rgb = [255, 255, 255];
const BLACK: Rgb = [0, 0, 0];

// ── Colour primitives ───────────────────────────────────────────────────────

/** Parses `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()` and `rgba()`. */
function parse(value: string | undefined): Rgba | null {
  if (!value) return null;
  const v = value.trim();

  const fn = v.match(/^rgba?\(([^)]+)\)$/i);
  if (fn) {
    const parts = fn[1].split(/[\s,/]+/).filter(Boolean).map(Number);
    if (parts.length < 3 || parts.slice(0, 3).some(Number.isNaN)) return null;
    return [parts[0], parts[1], parts[2], parts.length > 3 ? parts[3] : 1];
  }

  const hex = v.replace(/^#/, "");
  if (!/^[0-9a-f]+$/i.test(hex)) return null;
  const pair = (s: string) => parseInt(s.length === 1 ? s + s : s, 16);
  if (hex.length === 3 || hex.length === 4) {
    return [pair(hex[0]), pair(hex[1]), pair(hex[2]), hex.length === 4 ? pair(hex[3]) / 255 : 1];
  }
  if (hex.length === 6 || hex.length === 8) {
    return [
      parseInt(hex.slice(0, 2), 16),
      parseInt(hex.slice(2, 4), 16),
      parseInt(hex.slice(4, 6), 16),
      hex.length === 8 ? parseInt(hex.slice(6, 8), 16) / 255 : 1,
    ];
  }
  return null;
}

/** Composites a possibly-translucent colour over an opaque one. */
function flatten(top: Rgba, bottom: Rgb): Rgb {
  return [0, 1, 2].map((i) => Math.round(top[i] * top[3] + bottom[i] * (1 - top[3]))) as Rgb;
}

function mix(a: Rgb, b: Rgb, ratio: number): Rgb {
  return [0, 1, 2].map((i) => Math.round(a[i] * (1 - ratio) + b[i] * ratio)) as Rgb;
}

function luminance(c: Rgb): number {
  const channel = (v: number) => {
    const s = v / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(c[0]) + 0.7152 * channel(c[1]) + 0.0722 * channel(c[2]);
}

function contrast(a: Rgb, b: Rgb): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

const toCss = (c: Rgb) => `rgb(${c[0]}, ${c[1]}, ${c[2]})`;
const rgbaCss = (c: Rgb, alpha: number) => `rgba(${c[0]}, ${c[1]}, ${c[2]}, ${alpha})`;

/**
 * Pushes a colour toward white or black — whichever the background is not —
 * until it clears `min` contrast. Hue survives, so the theme still looks like
 * itself; only its legibility is corrected.
 */
function ensure(color: Rgb, bg: Rgb, min: number): Rgb {
  const target = luminance(bg) < 0.5 ? WHITE : BLACK;
  let out = color;
  for (let i = 0; i < 24 && contrast(out, bg) < min; i++) out = mix(out, target, 0.08);
  return out;
}

// ── Reading a theme ─────────────────────────────────────────────────────────

/** First key that carries a visible colour, composited over `bg`. */
function pick(colors: Record<string, string>, bg: Rgb, keys: string[]): Rgb | null {
  for (const key of keys) {
    const parsed = parse(colors[key]);
    // A fully transparent value is how themes say "not set" — skip it.
    if (parsed && parsed[3] > 0.05) return flatten(parsed, bg);
  }
  return null;
}

/** First candidate that is already legible; else the first one, corrected. */
function pickLegible(
  colors: Record<string, string>,
  bg: Rgb,
  keys: string[],
  min: number,
  fallback: Rgb,
): Rgb {
  const candidates: Rgb[] = [];
  for (const key of keys) {
    const parsed = parse(colors[key]);
    if (parsed && parsed[3] > 0.05) candidates.push(flatten(parsed, bg));
  }
  return candidates.find((c) => contrast(c, bg) >= min) ?? ensure(candidates[0] ?? fallback, bg, min);
}

const ANSI_NAMES = [
  "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
  "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue",
  "brightMagenta", "brightCyan", "brightWhite",
] as const;

const ANSI_FALLBACK_DARK: Record<string, string> = {
  black: "#3b4048", red: "#e06c75", green: "#98c379", yellow: "#e5c07b",
  blue: "#61afef", magenta: "#c678dd", cyan: "#56b6c2", white: "#dcdfe4",
  brightBlack: "#5c6370", brightRed: "#ef596f", brightGreen: "#89ca78",
  brightYellow: "#e5c07b", brightBlue: "#61afef", brightMagenta: "#d55fde",
  brightCyan: "#2bbac5", brightWhite: "#ffffff",
};

const ANSI_FALLBACK_LIGHT: Record<string, string> = {
  black: "#24292e", red: "#d73a49", green: "#22863a", yellow: "#b08800",
  blue: "#0366d6", magenta: "#6f42c1", cyan: "#1b7c83", white: "#6a737d",
  brightBlack: "#959da5", brightRed: "#cb2431", brightGreen: "#28a745",
  brightYellow: "#dbab09", brightBlue: "#0366d6", brightMagenta: "#5a32a3",
  brightCyan: "#3192aa", brightWhite: "#d1d5da",
};

const ansiKey = (name: string) => `terminal.ansi${name[0].toUpperCase()}${name.slice(1)}`;

/** Derives Codrift's palette from a VS Code theme. */
export function toPalette(theme: VsCodeTheme): Palette {
  const c = theme.colors ?? {};

  const canvasRaw = parse(c["editor.background"]) ?? parse(c["editorPane.background"]);
  const bg: Rgb = canvasRaw ? [canvasRaw[0], canvasRaw[1], canvasRaw[2]] : [10, 13, 18];

  const declared = String(theme.type ?? "").toLowerCase();
  const dark = declared
    ? !declared.startsWith("light") && declared !== "hclight"
    : luminance(bg) < 0.5;

  // Body text: 4.5:1 is the line between "themed" and "unusable".
  const fg = pickLegible(c, bg, ["editor.foreground", "foreground"], 4.5, dark ? WHITE : BLACK);

  // Panels sit a hair off the canvas. Themes that reuse one colour for both get
  // a derived nudge, or the sidebar dissolves into the content area.
  const surfaceRaw = pick(c, bg, [
    "sideBar.background",
    "editorGroupHeader.tabsBackground",
    "panel.background",
    "activityBar.background",
  ]);
  const surface =
    surfaceRaw && contrast(surfaceRaw, bg) >= 1.02
      ? surfaceRaw
      : mix(bg, dark ? WHITE : BLACK, 0.06);

  const borderRaw = pick(c, bg, [
    "panel.border",
    "editorGroup.border",
    "sideBar.border",
    "contrastBorder",
    "widget.border",
  ]);
  const border =
    borderRaw && contrast(borderRaw, bg) >= 1.25 ? borderRaw : mix(bg, fg, dark ? 0.18 : 0.14);

  // Secondary text: legible (3:1) but clearly quieter than body text.
  let muted = pickLegible(
    c,
    bg,
    [
      "descriptionForeground",
      "editorLineNumber.foreground",
      "disabledForeground",
      "tab.inactiveForeground",
    ],
    3,
    mix(bg, fg, 0.6),
  );
  // A "muted" that reads identically to body text is no hierarchy at all — dim
  // it, then re-check, because dimming is exactly what can push it under 3:1.
  if (contrast(muted, fg) < 1.25) muted = ensure(mix(fg, bg, 0.4), bg, 3);

  // The accent carries focus, selection and every "this is actionable" mark, so
  // it has to stand out. Link and badge colours are chosen for exactly that;
  // many themes make `focusBorder` a near-invisible grey, hence its low rank.
  const accent = pickLegible(
    c,
    bg,
    [
      "textLink.foreground",
      "editorLink.activeForeground",
      "activityBarBadge.background",
      "progressBar.background",
      "button.background",
      "focusBorder",
      ansiKey("brightBlue"),
      ansiKey("blue"),
      ansiKey("brightMagenta"),
      ansiKey("yellow"),
    ],
    3,
    [224, 146, 46],
  );

  const addFg = pickLegible(
    c,
    bg,
    [
      "gitDecoration.addedResourceForeground",
      "charts.green",
      ansiKey("green"),
      ansiKey("brightGreen"),
    ],
    3,
    dark ? [74, 222, 128] : [22, 134, 58],
  );
  const removeFg = pickLegible(
    c,
    bg,
    ["gitDecoration.deletedResourceForeground", "charts.red", ansiKey("red"), ansiKey("brightRed")],
    3,
    dark ? [248, 113, 113] : [215, 58, 73],
  );

  // Diff row tints: the theme's own where present, else a wash of its own
  // add/remove hues, faint enough to read code through.
  const addBg =
    pick(c, bg, ["diffEditor.insertedTextBackground", "diffEditor.insertedLineBackground"]) ??
    mix(bg, addFg, dark ? 0.16 : 0.2);
  const removeBg =
    pick(c, bg, ["diffEditor.removedTextBackground", "diffEditor.removedLineBackground"]) ??
    mix(bg, removeFg, dark ? 0.16 : 0.2);

  const selection =
    pick(c, bg, ["editor.selectionBackground", "selection.background"]) ?? mix(bg, accent, 0.35);

  return {
    canvas: toCss(bg),
    surface: toCss(surface),
    border: toCss(border),
    fg: toCss(fg),
    muted: toCss(muted),
    accent: toCss(accent),
    addBg: toCss(addBg),
    removeBg: toCss(removeBg),
    addFg: toCss(addFg),
    removeFg: toCss(removeFg),
    selection: toCss(selection),
    dark,
    terminal: terminalColors(c, bg, fg, accent, dark),
  };
}

function terminalColors(
  c: Record<string, string>,
  bg: Rgb,
  fg: Rgb,
  accent: Rgb,
  dark: boolean,
): Record<string, string> {
  const fallback = dark ? ANSI_FALLBACK_DARK : ANSI_FALLBACK_LIGHT;
  const termBg = pick(c, bg, ["terminal.background"]) ?? bg;

  const out: Record<string, string> = {
    background: toCss(termBg),
    foreground: toCss(pick(c, termBg, ["terminal.foreground"]) ?? fg),
    cursor: toCss(
      pick(c, termBg, ["terminalCursor.foreground", "editorCursor.foreground"]) ?? accent,
    ),
    selectionBackground: rgbaCss(
      pick(c, termBg, ["terminal.selectionBackground"]) ?? (dark ? WHITE : BLACK),
      0.25,
    ),
  };

  for (const name of ANSI_NAMES) {
    out[name] = toCss(pick(c, termBg, [ansiKey(name)]) ?? flatten(parse(fallback[name])!, termBg));
  }
  return out;
}
