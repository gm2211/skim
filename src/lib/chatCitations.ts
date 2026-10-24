import type { ChatSource } from "../services/commands";

/**
 * The answer is asked to cite articles by bracket number, and those numbers are
 * the 1-based position of the article sources as they were handed to the model.
 * Web results come after them and are cited as [w1], [w2]... in their own order.
 */
export function citedNumbers(content: string): Set<number> {
  const found = new Set<number>();
  for (const match of content.matchAll(/\[(\d{1,3})\]/g)) {
    const n = Number(match[1]);
    if (n > 0) found.add(n);
  }
  return found;
}

/** Matches [n] for an article and [wN] for a web result. */
export const CITATION_PATTERN = /\[(w?)(\d{1,3})\]/gi;

/** The source a citation names: [n] the n-th source, [wN] the N-th web result. */
export function citedSource(sources: ChatSource[], web: string, digits: string): ChatSource | undefined {
  const n = Number(digits);
  if (web) return sources.filter((source) => source.source_type === "web")[n - 1];
  const source = sources[n - 1];
  return source && source.source_type !== "web" ? source : undefined;
}

/** Whether the answer cites web results by number, so uncited ones were only searched. */
function citesWeb(content: string): boolean {
  return /\[w\d{1,3}\]/i.test(content);
}

export type NumberedSource = { source: ChatSource; number: number | null };

/**
 * Splits the candidates the search returned into the ones the answer actually
 * cited and the rest. A web result counts as cited when the answer names it as
 * [wN]; an answer that never numbers web results used every one it fetched.
 */
export function partitionSources(
  sources: ChatSource[],
  content: string,
): { cited: NumberedSource[]; searched: NumberedSource[] } {
  const cited = citedNumbers(content);
  const used = new Set(citationOrder(sources, content).map(({ source }) => source));
  const numbered: NumberedSource[] = sources.map((source, index) => ({
    source,
    number: source.source_type === "web" ? null : index + 1,
  }));
  if (cited.size === 0 && !citesWeb(content)) return { cited: [], searched: numbered };
  return {
    cited: numbered.filter((s) => used.has(s.source)),
    searched: numbered.filter((s) => !used.has(s.source)),
  };
}

/** A cited source with the number the reader sees: its place in the answer, from 1. */
export type CitedSource = { source: ChatSource; label: number };

/**
 * The answer's citations in the order the reader meets them, renumbered from 1,
 * so the chip after a sentence and the card it points at carry the same small
 * number no matter where the source sat in the model's search results. Web
 * results an answer fetched without numbering come after everything it cited.
 */
export function citationOrder(sources: ChatSource[], content: string): CitedSource[] {
  const order: ChatSource[] = [];
  for (const match of content.matchAll(CITATION_PATTERN)) {
    const source = citedSource(sources, match[1], match[2]);
    if (source && !order.includes(source)) order.push(source);
  }
  if (!citesWeb(content)) {
    for (const source of sources) if (source.source_type === "web" && !order.includes(source)) order.push(source);
  }
  return order.map((source, index) => ({ source, label: index + 1 }));
}
