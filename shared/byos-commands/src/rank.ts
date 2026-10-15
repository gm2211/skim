import type { Command } from './command.js';

const words = (text: string) => text.split(/[^\p{L}\p{N}]+/u).filter(Boolean);

/**
 * Score how well `query` matches `text`: whole-text and word prefixes beat
 * substrings, which beat initials ("qc" for "Quick Catch-up"), which beat
 * a typo ("refrsh": the letters in order, at most two extra between them).
 * Returns -1 otherwise. `fuzzy: false` stops after substrings.
 */
export function scoreText(text: string, query: string, fuzzy = true): number {
  const t = text.toLocaleLowerCase();
  const q = query.toLocaleLowerCase().trim();
  if (!q) return 0;
  if (t === q) return 1000;
  if (t.startsWith(q)) return 800;
  const tokens = words(t);
  if (tokens.some(w => w.startsWith(q))) return 600;
  const terms = q.split(/\s+/);
  if (terms.length > 1 && terms.every(term => tokens.some(w => w.startsWith(term)))) return 500;
  if (t.includes(q)) return 400;
  if (!fuzzy) return -1;
  const compact = q.replace(/\s+/g, '');
  if (tokens.map(w => w[0]).join('').startsWith(compact)) return 350;

  // A typo: the letters in order within a short stretch ("refrsh" in "refresh"), at most
  // two extra letters, so long titles do not match scattered letters ("run" in "Reviewer conclusion").
  let best = -1;
  for (let start = t.indexOf(compact[0]); start !== -1; start = t.indexOf(compact[0], start + 1)) {
    let score = 1;
    let at = start + 1;
    let run = 0;
    for (const ch of compact.slice(1)) {
      const found = t.indexOf(ch, at);
      if (found === -1 || found - start >= compact.length + 2) { score = -1; break; }
      run = found === at ? run + 1 : 0;
      score += 1 + run * 2;
      at = found + 1;
    }
    if (score > best) best = score;
  }
  return best < 0 ? -1 : Math.min(best, 300);
}

/** Last tier: every term starts a word somewhere across title, group, keywords and detail. */
export const CROSS_FIELD_SCORE = 200;

/** Best score across a command's fields; a title match outranks the same kind of keyword match. */
export function scoreCommand(command: Command, query: string): number {
  // Initials and scattered letters apply to the title only: in longer keyword or
  // detail text they match almost anything ("saved cars" in "Create a saved car search").
  const fields: Array<[string, number, boolean]> = [
    [command.title, 5, true],
    [`${command.group} ${command.title}`, 0, false],
    ...(command.keywords ?? []).map((keyword): [string, number, boolean] => [keyword, -250, false]),
    ...(command.detail ? [[command.detail, -250, false] as [string, number, boolean]] : []),
  ];
  let best = -1;
  for (const [text, adjust, fuzzy] of fields) {
    const score = scoreText(text, query, fuzzy);
    if (score >= 0) best = Math.max(best, Math.max(0, score + adjust));
  }
  if (best >= 0) return best;
  const terms = query.toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);
  if (terms.length < 2) return -1;
  const all = words(fields.map(([text]) => text).join(' ').toLocaleLowerCase());
  return terms.every(term => all.some(w => w.startsWith(term))) ? CROSS_FIELD_SCORE : -1;
}

/** Matching commands, best first; ties and an empty query keep the given order. */
export function rankCommands(commands: readonly Command[], query: string, limit = Infinity): Command[] {
  if (!query.trim()) return commands.slice(0, limit);
  return commands
    .map((command, index) => ({ command, index, score: scoreCommand(command, query) }))
    .filter(entry => entry.score >= 0)
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .slice(0, limit)
    .map(entry => entry.command);
}

const QUESTION_STARTS = new Set([
  'where', 'what', 'whats', "what's", 'which', 'who', 'whos', "who's", 'when', 'why', 'how',
  'is', 'are', 'was', 'were', 'can', 'could', 'should', 'would', 'do', 'does', 'did', 'any', 'anything',
  'find', 'show', 'summarize', 'summarise', 'explain', 'tell', 'list', 'give', 'compare', 'open', 'read',
  'search', 'recommend', 'suggest', 'help',
]);

/** Whether input reads as a question or request for the assistant rather than a command name. */
export function isQuestionLike(query: string): boolean {
  const q = query.trim().toLocaleLowerCase();
  if (!q) return false;
  if (q.endsWith('?')) return true;
  const parts = q.split(/\s+/);
  if (parts.length >= 5) return true;
  return parts.length >= 2 && QUESTION_STARTS.has(parts[0].replace(/[^a-z']/g, ''));
}

/** Whether the Ask row should lead: a question with no command named by it, no match, or only scattered-letter matches for a sentence. */
export function askFirst(commands: readonly Command[], query: string): boolean {
  if (query.trim().endsWith('?')) return true;
  const scores = commands.map(command => scoreCommand(command, query)).filter(score => score >= 0);
  if (scores.length === 0) return true;
  const best = Math.max(...scores);
  // A command whose title starts with the query ("open settings") wins over a request-shaped phrase.
  if (best >= 800) return false;
  if (isQuestionLike(query)) return true;
  return query.trim().split(/\s+/).length >= 3 && best < 350;
}
