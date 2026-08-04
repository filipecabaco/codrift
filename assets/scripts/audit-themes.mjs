// Audits the VS Code → Codrift colour mapping across every bundled theme.
//
// The claim "any VS Code theme works" is only worth making if it is checked:
// themes disagree wildly about which workbench keys they define, and a mapping
// that looks fine in Dracula can produce unreadable secondary text in Solarized.
// This runs `toPalette` over all of them and reports WCAG contrast for the
// pairs that carry meaning.
//
//   node scripts/audit-themes.mjs            # summary + failures
//   node scripts/audit-themes.mjs --all      # every theme, every ratio
//
// Exit code is non-zero when a theme falls below the thresholds, so it can gate
// a change to the mapping.

import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const assets = join(here, "..");

// Thresholds: 4.5 is WCAG AA for body text, 3.0 is AA for large text and the
// minimum for a UI component boundary to be perceivable.
const MIN_FG = 4.5;
const MIN_MUTED = 3.0;
const MIN_ACCENT = 3.0;
const MIN_SURFACE_DELTA = 1.02; // panels must not be identical to the canvas

// Imported straight from source: theme-map.ts is deliberately free of Svelte
// runes and of non-erasable TypeScript, so Node's type stripping runs it as-is
// and this audit can never drift from what the app actually ships.
const loadMapper = () => import(join(assets, "src/lib/theme-map.ts"));

function channel(v) {
  const s = v / 255;
  return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
}

function rgb(color) {
  const m = color.match(/rgba?\(([^)]+)\)/);
  if (!m) return [0, 0, 0];
  return m[1].split(",").slice(0, 3).map((n) => parseFloat(n));
}

function luminance(color) {
  const [r, g, b] = rgb(color);
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

const fmt = (n) => n.toFixed(2).padStart(5);

const { toPalette } = await loadMapper();

const themesDir = join(assets, "node_modules/shiki/dist/themes");
const ids = readdirSync(themesDir)
  .filter((f) => f.endsWith(".mjs"))
  .map((f) => f.replace(/\.mjs$/, ""))
  .sort();

const showAll = process.argv.includes("--all");
const failures = [];

for (const id of ids) {
  const theme = (await import(join(themesDir, `${id}.mjs`))).default;
  const p = toPalette(theme);

  const checks = {
    fg: contrast(p.fg, p.canvas),
    muted: contrast(p.muted, p.canvas),
    accent: contrast(p.accent, p.canvas),
    surface: contrast(p.surface, p.canvas),
    addFg: contrast(p.addFg, p.canvas),
    removeFg: contrast(p.removeFg, p.canvas),
  };

  const bad = [];
  if (checks.fg < MIN_FG) bad.push(`fg ${fmt(checks.fg)}`);
  if (checks.muted < MIN_MUTED) bad.push(`muted ${fmt(checks.muted)}`);
  if (checks.accent < MIN_ACCENT) bad.push(`accent ${fmt(checks.accent)}`);
  if (checks.surface < MIN_SURFACE_DELTA) bad.push(`surface==canvas`);
  if (checks.addFg < MIN_MUTED) bad.push(`add ${fmt(checks.addFg)}`);
  if (checks.removeFg < MIN_MUTED) bad.push(`remove ${fmt(checks.removeFg)}`);

  if (bad.length) failures.push({ id, bad });

  if (showAll || bad.length) {
    const flag = bad.length ? "✗" : " ";
    console.log(
      `${flag} ${id.padEnd(28)} ${p.dark ? "dark " : "light"}  fg ${fmt(checks.fg)}  muted ${fmt(
        checks.muted,
      )}  accent ${fmt(checks.accent)}  ${bad.join(", ")}`,
    );
  }
}

console.log(`\n${ids.length} themes audited, ${failures.length} below threshold.`);
process.exit(failures.length ? 1 : 0);
