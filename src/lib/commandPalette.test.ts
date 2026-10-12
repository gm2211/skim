import { describe, expect, it } from "vitest";
import { askFirst, filterCommands, formatShortcutKey, isQuestionLike, scoreText, type PaletteCommand } from "./commandPalette";

const cmd = (title: string, extra: Partial<PaletteCommand> = {}): PaletteCommand => ({
  id: title,
  title,
  group: "Actions",
  run: () => undefined,
  ...extra,
});

describe("command palette matching", () => {
  it("ranks word prefixes above scattered letters", () => {
    expect(scoreText("Quick Catch-up", "catch")).toBeGreaterThan(scoreText("Search articles", "cah"));
    expect(scoreText("Quick Catch-up", "xyz")).toBe(-1);
  });

  it("matches initials and multi-word prefixes", () => {
    const commands = [cmd("Refresh all feeds"), cmd("Quick Catch-up"), cmd("Mark all as read")];
    expect(filterCommands(commands, "qc")[0].title).toBe("Quick Catch-up");
    expect(filterCommands(commands, "mark read")[0].title).toBe("Mark all as read");
  });

  it("finds commands by keyword and keeps order for an empty query", () => {
    const commands = [cmd("Add feed"), cmd("Open Settings", { keywords: ["preferences"] })];
    expect(filterCommands(commands, "prefer").map((c) => c.title)).toEqual(["Open Settings"]);
    expect(filterCommands(commands, "  ")).toBe(commands);
  });

  it("prefers a title match over a keyword match", () => {
    const commands = [cmd("Ask Skim", { keywords: ["search"] }), cmd("Search articles")];
    expect(filterCommands(commands, "search")[0].title).toBe("Search articles");
  });

  it("formats shortcut keys per platform", () => {
    expect(formatShortcutKey("mod", true)).toBe("⌘");
    expect(formatShortcutKey("mod", false)).toBe("Ctrl");
    expect(formatShortcutKey("k", true)).toBe("K");
  });
});

describe("asking Skim from the palette", () => {
  it("reads questions and requests as questions, command names as commands", () => {
    for (const q of ["where's an article about rust?", "where's an article about rust", "find the piece on fusion", "summarize this story", "what changed in the AI story", "any news on the election"]) {
      expect(isQuestionLike(q), q).toBe(true);
    }
    for (const q of ["refresh", "qc", "open settings", "starred", "mark all"]) {
      expect(isQuestionLike(q), q).toBe(q === "open settings");
    }
  });

  it("puts Ask first when nothing matches well or the input is a question", () => {
    const commands = [cmd("Refresh all feeds"), cmd("Quick Catch-up")];
    expect(askFirst(commands, "refresh")).toBe(false);
    expect(askFirst(commands, "qc")).toBe(false);
    expect(askFirst(commands, "zebra migration")).toBe(true);
    expect(askFirst(commands, "where's the rust article")).toBe(true);
    // Three scattered-letter words are a sentence, not a fuzzy command name.
    expect(askFirst(commands, "rust ai chips")).toBe(true);
  });
});
