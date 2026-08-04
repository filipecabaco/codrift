// Turns the active VS Code theme into CodeMirror extensions, so the editor is
// the same theme as the rest of the app rather than a fixed one bolted on.
//
// Two halves, mirroring VS Code's own split: `colors` paint the chrome
// (background, gutter, cursor, selection) and `tokenColors` paint the syntax.

import { EditorView } from "@codemirror/view";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";
import type { Extension } from "@codemirror/state";
import { themeState, type VsCodeTheme } from "$lib/theme.svelte";
import { fontState } from "$lib/fonts.svelte";

type TokenColor = {
  scope?: string | string[];
  settings?: { foreground?: string; fontStyle?: string };
};

/** First token rule whose scope matches one of `scopes`, most specific first. */
function settingsFor(theme: VsCodeTheme, scopes: string[]): TokenColor["settings"] | undefined {
  const rules = (theme.tokenColors ?? []) as TokenColor[];
  for (const scope of scopes) {
    for (const rule of rules) {
      const list = typeof rule.scope === "string" ? rule.scope.split(",") : (rule.scope ?? []);
      if (list.some((s) => s.trim() === scope || s.trim().startsWith(`${scope}.`))) {
        if (rule.settings?.foreground) return rule.settings;
      }
    }
  }
  return undefined;
}

function color(theme: VsCodeTheme, scopes: string[], fallback: string): string {
  return settingsFor(theme, scopes)?.foreground ?? fallback;
}

function italic(theme: VsCodeTheme, scopes: string[]): boolean {
  return !!settingsFor(theme, scopes)?.fontStyle?.includes("italic");
}

/**
 * CodeMirror extensions for the current theme.
 *
 * Recomputed by the caller whenever the theme changes; CodeMirror swaps them
 * through a compartment, so the buffer is never reloaded.
 */
export function editorTheme(): Extension {
  const { palette, theme } = themeState;
  const p = palette;

  const chrome = EditorView.theme(
    {
      "&": {
        color: p.fg,
        backgroundColor: p.canvas,
        fontFamily: fontState.stack,
        fontSize: `${fontState.size}px`,
      },
      ".cm-content": { caretColor: p.accent, fontFamily: fontState.stack },
      ".cm-gutters, .cm-tooltip": { fontFamily: fontState.stack },
      ".cm-cursor, .cm-dropCursor": { borderLeftColor: p.accent },
      "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection": {
        backgroundColor: p.selection,
      },
      ".cm-panels": { backgroundColor: p.surface, color: p.fg },
      ".cm-searchMatch": { backgroundColor: p.selection },
      ".cm-activeLine": { backgroundColor: p.dark ? "rgba(255,255,255,0.04)" : "rgba(0,0,0,0.04)" },
      ".cm-gutters": { backgroundColor: p.canvas, color: p.muted, border: "none" },
      ".cm-activeLineGutter": { backgroundColor: p.surface, color: p.fg },
      ".cm-foldPlaceholder": { backgroundColor: p.surface, border: "none", color: p.muted },
      ".cm-tooltip": { backgroundColor: p.surface, border: `1px solid ${p.border}`, color: p.fg },
      ".cm-tooltip-autocomplete > ul > li[aria-selected]": {
        backgroundColor: p.accent,
        color: p.canvas,
      },
      // The vim command line lives in a panel; keep it legible on any theme.
      ".cm-vim-panel": { backgroundColor: p.surface, color: p.fg },
      ".cm-vim-panel input": { color: p.fg },
    },
    { dark: p.dark },
  );

  const syntax = HighlightStyle.define([
    {
      tag: [t.comment, t.lineComment, t.blockComment],
      color: color(theme, ["comment"], p.muted),
      fontStyle: italic(theme, ["comment"]) ? "italic" : "normal",
    },
    { tag: [t.keyword, t.modifier, t.controlKeyword], color: color(theme, ["keyword", "storage"], p.accent) },
    { tag: [t.string, t.special(t.string)], color: color(theme, ["string"], p.addFg) },
    { tag: [t.number, t.bool, t.null], color: color(theme, ["constant.numeric", "constant"], p.removeFg) },
    { tag: [t.function(t.variableName), t.function(t.propertyName)], color: color(theme, ["entity.name.function", "support.function"], p.fg) },
    { tag: [t.typeName, t.className, t.namespace], color: color(theme, ["entity.name.type", "support.type", "entity.name.class"], p.fg) },
    { tag: [t.propertyName, t.attributeName], color: color(theme, ["variable.other.property", "entity.other.attribute-name"], p.fg) },
    { tag: [t.variableName, t.definition(t.variableName)], color: color(theme, ["variable"], p.fg) },
    { tag: [t.operator, t.punctuation, t.bracket], color: p.muted },
    { tag: [t.tagName], color: color(theme, ["entity.name.tag"], p.accent) },
    { tag: [t.heading], color: color(theme, ["markup.heading"], p.accent), fontWeight: "bold" },
    { tag: [t.link, t.url], color: color(theme, ["markup.underline.link"], p.accent), textDecoration: "underline" },
    { tag: [t.emphasis], fontStyle: "italic" },
    { tag: [t.strong], fontWeight: "bold" },
    { tag: [t.invalid], color: p.removeFg },
  ]);

  return [chrome, syntaxHighlighting(syntax)];
}
