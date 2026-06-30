import { createHighlighter, type Highlighter, type BundledLanguage, type ThemedToken } from "shiki";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";

const THEME = "github-dark";

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
      themes: [THEME],
      langs: LANGS as unknown as BundledLanguage[],
      engine: createJavaScriptRegexEngine({ forgiving: true }),
    });
  }
  return hlPromise;
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
  return hl.codeToHtml(code, { lang: resolve(hl, lang), theme: THEME });
}

export async function highlightLines(lines: string[], lang: string): Promise<ThemedToken[][]> {
  if (lines.length === 0) return [];
  const hl = await highlighter();
  return hl.codeToTokens(lines.join("\n"), { lang: resolve(hl, lang), theme: THEME }).tokens;
}

export type { ThemedToken };
