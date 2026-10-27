/**
 * In-place corrections. When the model finds that an earlier reply of its own
 * was wrong it adds `<correction><was>…</was><now>…</now></correction>` to its
 * answer instead of writing a correction paragraph. Skim strikes the wrong
 * words through in that earlier reply and puts "[updated]: …" beside them.
 * Mirrors ChatCorrections.swift on iOS.
 */

export interface ChatCorrection {
  was: string;
  now: string;
}

const BLOCK = /<correction>\s*<was>([\s\S]*?)<\/was>\s*<now>([\s\S]*?)<\/now>\s*<\/correction>/gi;

/** The answer with its correction blocks taken out, and the corrections. */
export function extractCorrections(text: string): { text: string; corrections: ChatCorrection[] } {
  const corrections: ChatCorrection[] = [];
  const stripped = text.replace(BLOCK, (_, was: string, now: string) => {
    if (was.trim() && now.trim()) corrections.push({ was: was.trim(), now: now.trim() });
    return "";
  });
  if (!corrections.length) return { text, corrections };
  return { text: stripped.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim(), corrections };
}

/** "~~wrong~~ **[updated]:** right", striking each paragraph of a multi-paragraph quote. */
export function correctionMarkdown({ was, now }: ChatCorrection): string {
  const struck = was.split(/\n{2,}/).map((part) => part.trim()).filter(Boolean).map((part) => `~~${part}~~`).join("\n\n");
  return `${struck} **[updated]:** ${now}`;
}

/** Where `was` sits in `text`: exactly, else ignoring whitespace and case. */
function locate(text: string, was: string): { start: number; end: number } | null {
  const exact = text.lastIndexOf(was);
  if (exact >= 0) return { start: exact, end: exact + was.length };
  const words = was.split(/\s+/).filter(Boolean).map((word) => word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  if (!words.length) return null;
  let found: { start: number; end: number } | null = null;
  for (const match of text.matchAll(new RegExp(words.join("\\s+"), "gi"))) found = { start: match.index!, end: match.index! + match[0].length };
  return found;
}

/**
 * Apply the corrections in a new answer to the earlier assistant messages.
 * Each one edits the latest earlier reply that contains its wrong words; one
 * that matches nothing stays visible in the new answer instead of being lost.
 */
export function applyChatCorrections<M extends { role: string; content: string }>(
  earlier: readonly M[],
  answer: string,
): { messages: readonly M[]; answer: string; corrected: number } {
  const { text, corrections } = extractCorrections(answer);
  if (!corrections.length) return { messages: earlier, answer, corrected: 0 };
  const messages = [...earlier];
  const unmatched: string[] = [];
  let corrected = 0;
  for (const correction of corrections) {
    let applied = false;
    for (let i = messages.length - 1; i >= 0 && !applied; i -= 1) {
      const message = messages[i];
      if (message.role !== "assistant") continue;
      const at = locate(message.content, correction.was);
      if (!at) continue;
      const replacement = correctionMarkdown({ was: message.content.slice(at.start, at.end), now: correction.now });
      messages[i] = { ...message, content: message.content.slice(0, at.start) + replacement + message.content.slice(at.end) };
      applied = true;
      corrected += 1;
    }
    if (!applied) unmatched.push(correctionMarkdown(correction));
  }
  const parts = [...unmatched, text].filter(Boolean);
  const finalAnswer = parts.length ? parts.join("\n\n") : "*Updated my earlier reply above.*";
  return { messages: corrected ? messages : earlier, answer: finalAnswer, corrected };
}
