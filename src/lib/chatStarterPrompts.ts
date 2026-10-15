/**
 * Starter questions shown in an empty Ask Skim chat. Each is a broad catch-up,
 * so it reads the most recent articles in scope rather than searching for its
 * words. iOS keeps the same list in LibraryChatPolicy.starterPrompts.
 */
export const CHAT_STARTER_PROMPTS = [
  "What are the top 10 things I should know from today's articles?",
  "What did I miss this week?",
  "Where do sources disagree on the biggest stories?",
];

/** A prompt ending in an ellipsis is a template the reader finishes before sending. */
export function isPromptTemplate(prompt: string): boolean {
  return prompt.trimEnd().endsWith("…");
}
