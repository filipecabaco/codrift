// Subsequence fuzzy match: every character of `query` must appear in `text` in
// order but not adjacently — "rjwt" finds "REAL-911 Realtime JWT signer".
export type FuzzyMatch = { score: number; positions: number[] };

const isBoundary = (text: string, i: number) => i === 0 || /[\s\-_/#.:]/.test(text[i - 1]);

export function fuzzyMatch(text: string, query: string): FuzzyMatch | null {
  if (!query) return { score: 0, positions: [] };

  const haystack = text.toLowerCase();
  const needle = query.toLowerCase();

  const positions: number[] = [];
  let score = 0;
  let cursor = 0;
  let previous = -1;

  for (const char of needle) {
    if (char === " ") continue;

    const at = haystack.indexOf(char, cursor);
    if (at === -1) return null;

    if (at === previous + 1) score += 8;
    if (isBoundary(haystack, at)) score += 6;
    score += Math.max(0, 4 - (at - cursor));

    positions.push(at);
    previous = at;
    cursor = at + 1;
  }

  return { score: score - haystack.length / 100, positions };
}

// Splits `text` into alternating unmatched/matched runs for rendering.
export function highlight(text: string, positions: number[]): { text: string; hit: boolean }[] {
  if (positions.length === 0) return [{ text, hit: false }];

  const marked = new Set(positions);
  const runs: { text: string; hit: boolean }[] = [];

  for (let i = 0; i < text.length; i++) {
    const hit = marked.has(i);
    const last = runs[runs.length - 1];
    if (last && last.hit === hit) last.text += text[i];
    else runs.push({ text: text[i], hit });
  }

  return runs;
}
