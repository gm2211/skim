export interface PaletteCommand {
  id: string;
  title: string;
  group: string;
  /** Extra words the command should match, e.g. "preferences" for Settings. */
  keywords?: string[];
  /** Keys as written in the shortcut, e.g. ["mod", ","] or ["→"]. */
  shortcut?: string[];
  /** Secondary text shown after the title (a feed's folder, an article's feed). */
  detail?: string;
  /** Which of the app's line icons to print before the title. */
  icon?: string;
  run: () => void;
}

export function isMacPlatform(): boolean {
  if (typeof navigator === "undefined") return true;
  return /mac|iphone|ipad/i.test(navigator.platform || navigator.userAgent);
}

export function formatShortcutKey(key: string, mac = isMacPlatform()): string {
  if (key === "mod") return mac ? "⌘" : "Ctrl";
  if (key === "shift") return mac ? "⇧" : "Shift";
  if (key === "alt") return mac ? "⌥" : "Alt";
  if (key === "escape") return "Esc";
  return key.length === 1 ? key.toUpperCase() : key;
}

// Score how well `query` matches `text`: whole-word prefixes beat
// substrings, which beat scattered letters (so "qc" finds "Quick
// Catch-up"). Returns -1 when the letters are not all present in order.
export function scoreText(text: string, query: string): number {
  const t = text.toLowerCase();
  const q = query.toLowerCase().trim();
  if (!q) return 0;
  if (t === q) return 1000;
  if (t.startsWith(q)) return 800;
  const words = t.split(/[^a-z0-9]+/).filter(Boolean);
  if (words.some((w) => w.startsWith(q))) return 600;
  const terms = q.split(/\s+/).filter(Boolean);
  if (terms.length > 1 && terms.every((term) => words.some((w) => w.startsWith(term)))) return 500;
  if (t.includes(q)) return 400;
  const initials = words.map((w) => w[0]).join("");
  if (initials.startsWith(q.replace(/\s+/g, ""))) return 350;

  // Subsequence match; tighter runs score higher.
  let score = 0;
  let ti = 0;
  let run = 0;
  for (const ch of q.replace(/\s+/g, "")) {
    const found = t.indexOf(ch, ti);
    if (found === -1) return -1;
    run = found === ti ? run + 1 : 0;
    score += 1 + run * 2;
    ti = found + 1;
  }
  return Math.min(score, 300);
}

export function scoreCommand(command: PaletteCommand, query: string): number {
  const haystacks = [
    command.title,
    `${command.group} ${command.title}`,
    ...(command.keywords ?? []),
    ...(command.detail ? [command.detail] : []),
  ];
  let best = -1;
  haystacks.forEach((text, index) => {
    const score = scoreText(text, query);
    if (score < 0) return;
    // A title match outranks the same kind of keyword or detail match.
    const adjusted = index === 0 ? score + 5 : index === 1 ? score : Math.max(0, score - 250);
    if (adjusted > best) best = adjusted;
  });
  return best;
}

/** Matching commands, best first; keeps the given order for an empty query. */
export function filterCommands(commands: PaletteCommand[], query: string): PaletteCommand[] {
  if (!query.trim()) return commands;
  return commands
    .map((command, index) => ({ command, index, score: scoreCommand(command, query) }))
    .filter((entry) => entry.score >= 0)
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .map((entry) => entry.command);
}
