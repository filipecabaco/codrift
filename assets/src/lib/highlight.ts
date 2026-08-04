import { createHighlighter, type Highlighter, type BundledLanguage, type ThemedToken } from "shiki";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";
import { themeState } from "$lib/theme.svelte";

// Syntax follows the app theme: the same VS Code theme that paints the
// workbench carries the `tokenColors` Shiki needs, so code in the diff and the
// file preview is coloured by the theme the user picked — not a fixed one.
const FALLBACK_THEME = "github-dark";

// Curated grammar set — only these are bundled (avoids pulling every Shiki
// grammar). Unknown languages fall back to plaintext.
const LANGS = [
  "elixir",
  "html",
  "typescript",
  "tsx",
  "javascript",
  "jsx",
  "svelte",
  "json",
  "markdown",
  "css",
  "scss",
  "rust",
  "go",
  "python",
  "ruby",
  "bash",
  "yaml",
  "toml",
  "sql",
  "c",
  "docker",
] as const;

const EXT_LANG: Record<string, string> = {
  ex: "elixir",
  exs: "elixir",
  heex: "elixir",
  eex: "html",
  ts: "typescript",
  tsx: "tsx",
  js: "javascript",
  jsx: "jsx",
  mjs: "javascript",
  cjs: "javascript",
  svelte: "svelte",
  json: "json",
  jsonc: "json",
  md: "markdown",
  markdown: "markdown",
  css: "css",
  scss: "scss",
  html: "html",
  rs: "rust",
  go: "go",
  py: "python",
  rb: "ruby",
  sh: "bash",
  bash: "bash",
  zsh: "bash",
  yml: "yaml",
  yaml: "yaml",
  toml: "toml",
  sql: "sql",
  c: "c",
  h: "c",
};

const NAME_LANG: Record<string, string> = {
  "mix.exs": "elixir",
  "mix.lock": "elixir",
  Dockerfile: "docker",
};

let hlPromise: Promise<Highlighter> | null = null;
function highlighter(): Promise<Highlighter> {
  if (!hlPromise) {
    hlPromise = createHighlighter({
      themes: [FALLBACK_THEME],
      langs: LANGS as unknown as BundledLanguage[],
      engine: createJavaScriptRegexEngine({ forgiving: true }),
    });
  }
  return hlPromise;
}

/**
 * Registers the active app theme with Shiki (once per theme) and returns the
 * name to highlight with.
 *
 * Themes without `tokenColors` — Codrift's own, or a minimal drop-in — can't
 * colour syntax, so those fall back to a bundled theme matching the polarity
 * instead of rendering unstyled text.
 */
async function activeTheme(hl: Highlighter): Promise<string> {
  const { theme, palette, id } = themeState;
  const tokens = theme.tokenColors;
  if (!Array.isArray(tokens) || tokens.length === 0) {
    const fallback = palette.dark ? FALLBACK_THEME : "github-light";
    if (!hl.getLoadedThemes().includes(fallback)) await hl.loadTheme(fallback as never);
    return fallback;
  }

  const name = theme.name ?? id;
  if (!hl.getLoadedThemes().includes(name)) {
    // Shiki keys themes by their `name`; give anonymous drop-ins the id.
    await hl.loadTheme({ ...theme, name } as Parameters<Highlighter["loadTheme"]>[0]);
  }
  return name;
}

export function langForPath(path: string): string {
  const name = path.split("/").pop() ?? "";
  if (NAME_LANG[name]) return NAME_LANG[name];
  const ext = name.includes(".") ? name.split(".").pop()!.toLowerCase() : "";
  return EXT_LANG[ext] ?? "text";
}

function resolve(hl: Highlighter, lang: string): BundledLanguage {
  return (hl.getLoadedLanguages().includes(lang) ? lang : "text") as BundledLanguage;
}

export async function highlightToHtml(code: string, lang: string): Promise<string> {
  const hl = await highlighter();
  const theme = await activeTheme(hl);
  return hl.codeToHtml(code, { lang: resolve(hl, lang), theme });
}

export async function highlightLines(lines: string[], lang: string): Promise<ThemedToken[][]> {
  if (lines.length === 0) return [];
  const hl = await highlighter();
  const theme = await activeTheme(hl);
  return hl.codeToTokens(lines.join("\n"), { lang: resolve(hl, lang), theme }).tokens;
}

export type { ThemedToken };
