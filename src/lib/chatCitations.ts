import type { ChatSource } from "../services/commands";

/**
 * The answer is asked to cite articles by bracket number, and those numbers are
 * the 1-based position of the article sources as they were handed to the model.
 * Web results are appended after them and were never numbered in the prompt, so
 * they can never be cited by number.
 */
export function citedNumbers(content: string): Set<number> {
  const found = new Set<number>();
  for (const match of content.matchAll(/\[(\d{1,3})\]/g)) {
    const n = Number(match[1]);
    if (n > 0) found.add(n);
  }
  return found;
}

export type NumberedSource = { source: ChatSource; number: number | null };

/**
 * Splits the candidates the search returned into the ones the answer actually
 * cited and the rest. Web results always count as cited: they are only present
 * because the model went and fetched them.
 */
export function partitionSources(
  sources: ChatSource[],
  content: string,
): { cited: NumberedSource[]; searched: NumberedSource[] } {
  const cited = citedNumbers(content);
  const numbered: NumberedSource[] = sources.map((source, index) => ({
    source,
    number: source.source_type === "web" ? null : index + 1,
  }));
  if (cited.size === 0) return { cited: [], searched: numbered };
  return {
    cited: numbered.filter((s) => s.number === null || cited.has(s.number)),
    searched: numbered.filter((s) => s.number !== null && !cited.has(s.number)),
  };
}
