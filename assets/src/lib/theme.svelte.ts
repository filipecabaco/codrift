// Full-application theming from VS Code colour themes.
//
// A VS Code theme is two things: `colors` (the workbench palette — editor
// background, sidebar, borders, terminal ANSI…) and `tokenColors` (syntax).
// Codrift uses BOTH: the workbench colours drive the app's CSS custom
// properties, so the sidebar, header, panels, terminal and diff re-skin, and
// the token colours drive syntax highlighting through Shiki. That is why any
// of the thousands of themes written for VS Code can be dropped in here: this
// module is the only place that knows the mapping.

import { rpc } from "$lib/api";
import { toPalette, type Palette, type VsCodeTheme } from "$lib/theme-map";

export type { Palette, VsCodeTheme };

export type ThemeEntry = {
  /** Stable id: the bundled Shiki name, or `custom:<file>` for a drop-in. */
  id: string;
  label: string;
  kind: "bundled" | "custom";
  /** Known upfront for bundled themes; filled in after loading a custom one. */
  type?: "dark" | "light";
};

/** Codrift's default — matches the brand tokens in app.css. */
export const DEFAULT_THEME = "codrift-dark";

// Shiki ships ~65 VS Code themes; each is a lazy import so only the chosen one
// is ever downloaded.
const bundled = import.meta.glob<{ default: VsCodeTheme }>("../../node_modules/shiki/dist/themes/*.mjs");

const BUNDLED_IDS = Object.keys(bundled)
  .map((path) => path.split("/").pop()!.replace(/\.mjs$/, ""))
  .sort();

function title(id: string): string {
  return id
    .split("-")
    .map((w) => (w.length <= 2 ? w : w[0].toUpperCase() + w.slice(1)))
    .join(" ");
}

async function loadBundled(id: string): Promise<VsCodeTheme> {
  const key = Object.keys(bundled).find((p) => p.endsWith(`/${id}.mjs`));
  if (!key) throw new Error(`unknown theme: ${id}`);
  return (await bundled[key]()).default;
}

// ── Applying a theme ────────────────────────────────────────────────────────

// Codrift's own look, expressed as a VS Code theme so it travels the exact same
// code path as every other theme — one renderer, no special case.
const CODRIFT_DARK: VsCodeTheme = {
  name: DEFAULT_THEME,
  displayName: "Codrift Dark",
  type: "dark",
  colors: {
    "editor.background": "#0a0d12",
    "editor.foreground": "#e9ebf0",
    "sideBar.background": "#12151b",
    "panel.border": "#282c35",
    descriptionForeground: "#8d93a1",
    focusBorder: "#e0922e",
  },
};

export const themeState = $state({
  /** Currently applied theme id. */
  id: DEFAULT_THEME,
  label: "Codrift Dark",
  palette: toPalette(CODRIFT_DARK),
  /** The raw theme, for consumers that want tokenColors (Shiki, CodeMirror). */
  theme: CODRIFT_DARK as VsCodeTheme,
  /** Everything selectable, bundled + drop-ins from ~/.codrift/themes. */
  available: [] as ThemeEntry[],
});

/** Paints a palette onto the document as CSS custom properties. */
export function applyPalette(p: Palette) {
  const root = document.documentElement;
  const vars: Record<string, string> = {
    "--color-canvas": p.canvas,
    "--color-surface": p.surface,
    "--color-border": p.border,
    "--color-fg": p.fg,
    "--color-muted": p.muted,
    "--color-accent": p.accent,
    "--color-diff-add": p.addBg,
    "--color-diff-remove": p.removeBg,
    "--color-diff-add-fg": p.addFg,
    "--color-diff-remove-fg": p.removeFg,
    "--color-selection": p.selection,
  };
  for (const [k, v] of Object.entries(vars)) root.style.setProperty(k, v);
  // Native widgets (scrollbars, form controls) follow the theme's polarity.
  root.style.colorScheme = p.dark ? "dark" : "light";
}

async function loadTheme(id: string): Promise<VsCodeTheme> {
  if (id === DEFAULT_THEME) return CODRIFT_DARK;
  if (id.startsWith("custom:")) {
    return await rpc<VsCodeTheme>("read_theme", { name: id.slice("custom:".length) });
  }
  return await loadBundled(id);
}

/**
 * Applies a theme by id. Returns the theme so callers can preview without
 * committing (the picker applies on hover and only persists on Enter).
 */
export async function applyTheme(id: string): Promise<VsCodeTheme> {
  const theme = await loadTheme(id);
  const palette = toPalette(theme);
  applyPalette(palette);
  themeState.id = id;
  themeState.label = labelFor(id, theme);
  themeState.palette = palette;
  themeState.theme = theme;
  return theme;
}

function labelFor(id: string, theme: VsCodeTheme): string {
  if (theme.displayName) return theme.displayName;
  if (id.startsWith("custom:")) return id.slice("custom:".length).replace(/\.json$/, "");
  return title(id);
}

/** Applies and remembers the choice, so the next launch starts here. */
export async function selectTheme(id: string): Promise<void> {
  await applyTheme(id);
  try {
    await rpc("set_theme", { name: id });
  } catch {
    /* a themed UI that can't persist is still better than an error toast */
  }
}

/**
 * Builds the pick list: Codrift's own theme, every Shiki-bundled VS Code theme,
 * and any `*.json` the user dropped in `~/.codrift/themes` — which is how you
 * bring in a theme from the VS Code marketplace.
 */
export async function refreshThemeList(): Promise<ThemeEntry[]> {
  let custom: string[] = [];
  try {
    custom = (await rpc<{ themes: string[] }>("list_themes")).themes;
  } catch {
    custom = [];
  }

  themeState.available = [
    { id: DEFAULT_THEME, label: "Codrift Dark", kind: "bundled", type: "dark" },
    ...custom.map((name) => ({
      id: `custom:${name}`,
      label: name.replace(/\.json$/, ""),
      kind: "custom" as const,
    })),
    ...BUNDLED_IDS.map((id) => ({ id, label: title(id), kind: "bundled" as const })),
  ];
  return themeState.available;
}

/** Restores the persisted theme at boot; falls back to Codrift's own. */
export async function initTheme(): Promise<void> {
  await refreshThemeList();
  let saved = DEFAULT_THEME;
  try {
    saved = (await rpc<{ name: string }>("get_theme")).name || DEFAULT_THEME;
  } catch {
    /* offline or old backend — keep the default */
  }
  try {
    await applyTheme(saved);
  } catch {
    await applyTheme(DEFAULT_THEME);
  }
}
