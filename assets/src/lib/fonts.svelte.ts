// Typeface selection.
//
// A coding tool is read for hours, and which monospace face renders well is
// personal (and machine-dependent — ligatures, hinting, whether the font is
// even installed). So Codrift offers the faces that are *actually present* on
// this machine, detected rather than assumed, and applies the choice to the
// whole app: UI chrome, the embedded terminals and the editor.

import { rpc } from "$lib/api";

export type FontOption = {
  /** What the user sees. */
  label: string;
  /** The CSS font-family stack applied. */
  stack: string;
  /** The single family probed to decide whether this is installed. */
  probe?: string;
};

/** Always available: whatever the platform calls its default monospace. */
const SYSTEM: FontOption = {
  label: "System monospace",
  stack: 'ui-monospace, "Cascadia Code", "Source Code Pro", Menlo, monospace',
};

// Faces worth offering when installed — the ones people actually set in an
// editor. Detection keeps the list honest: no dead entries that silently fall
// back to something else.
const CANDIDATES: FontOption[] = [
  { label: "JetBrains Mono", probe: "JetBrains Mono", stack: '"JetBrains Mono", ui-monospace, monospace' },
  { label: "Fira Code", probe: "Fira Code", stack: '"Fira Code", ui-monospace, monospace' },
  { label: "Cascadia Code", probe: "Cascadia Code", stack: '"Cascadia Code", ui-monospace, monospace' },
  { label: "SF Mono", probe: "SF Mono", stack: '"SF Mono", ui-monospace, monospace' },
  { label: "Menlo", probe: "Menlo", stack: "Menlo, ui-monospace, monospace" },
  { label: "Monaco", probe: "Monaco", stack: "Monaco, ui-monospace, monospace" },
  { label: "IBM Plex Mono", probe: "IBM Plex Mono", stack: '"IBM Plex Mono", ui-monospace, monospace' },
  { label: "Source Code Pro", probe: "Source Code Pro", stack: '"Source Code Pro", ui-monospace, monospace' },
  { label: "Iosevka", probe: "Iosevka", stack: "Iosevka, ui-monospace, monospace" },
  { label: "Hack", probe: "Hack", stack: "Hack, ui-monospace, monospace" },
  { label: "Inconsolata", probe: "Inconsolata", stack: "Inconsolata, ui-monospace, monospace" },
  { label: "Roboto Mono", probe: "Roboto Mono", stack: '"Roboto Mono", ui-monospace, monospace' },
  { label: "Ubuntu Mono", probe: "Ubuntu Mono", stack: '"Ubuntu Mono", ui-monospace, monospace' },
  { label: "Courier New", probe: "Courier New", stack: '"Courier New", monospace' },
];

export const MIN_SIZE = 10;
export const MAX_SIZE = 20;
const DEFAULT_SIZE = 13;

/**
 * Is `family` installed?
 *
 * Renders the same string in the family and in two very different generic
 * fallbacks; if the family exists, at least one measurement differs from the
 * fallback it would otherwise inherit.
 */
function installed(family: string): boolean {
  const canvas = document.createElement("canvas");
  const ctx = canvas.getContext("2d");
  if (!ctx) return false;
  const sample = "mmmmmmmmmmlli1IOo0";

  const width = (font: string) => {
    ctx.font = font;
    return ctx.measureText(sample).width;
  };

  return ["monospace", "serif", "sans-serif"].some(
    (generic) => width(`72px "${family}", ${generic}`) !== width(`72px ${generic}`),
  );
}

export const fontState = $state({
  label: SYSTEM.label,
  stack: SYSTEM.stack,
  size: DEFAULT_SIZE,
  /** Only faces present on this machine, system default first. */
  available: [SYSTEM] as FontOption[],
});

/** Applies a family + size to the app, terminals and editor. */
export function applyFont(option: FontOption, size: number) {
  fontState.label = option.label;
  fontState.stack = option.stack;
  fontState.size = clampSize(size);
  document.documentElement.style.setProperty("--font-mono", option.stack);
}

export function clampSize(size: number): number {
  if (!Number.isFinite(size)) return DEFAULT_SIZE;
  return Math.min(MAX_SIZE, Math.max(MIN_SIZE, Math.round(size)));
}

export function optionByLabel(label: string): FontOption | undefined {
  return fontState.available.find((f) => f.label === label);
}

/** Applies and remembers, so the next launch starts here. */
export async function selectFont(option: FontOption, size: number): Promise<void> {
  applyFont(option, size);
  try {
    await rpc("set_font", { family: option.label, size: fontState.size });
  } catch {
    /* a re-typeset UI that can't persist still beats an error toast */
  }
}

/** Detects installed faces and restores the saved choice. */
export async function initFonts(): Promise<void> {
  fontState.available = [SYSTEM, ...CANDIDATES.filter((f) => !f.probe || installed(f.probe))];

  try {
    const saved = await rpc<{ family: string | null; size: number | null }>("get_font");
    const option = saved.family ? optionByLabel(saved.family) : undefined;
    applyFont(option ?? SYSTEM, saved.size ?? DEFAULT_SIZE);
  } catch {
    applyFont(SYSTEM, DEFAULT_SIZE);
  }
}
