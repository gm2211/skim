import { describe, expect, it } from "vitest";
import type { Feed, Folder } from "../services/types";
import { feedsForFolder, parseRules } from "./smartFolder";

const folder = (rules: unknown): Folder => ({
  id: "smart", name: "Science", sort_order: 0, is_smart: true,
  rules_json: JSON.stringify(rules), created_at: 0, feed_count: 0,
});

describe("smart folder compatibility", () => {
  it("normalizes legacy native rules while preserving case-insensitive behavior", () => {
    expect(parseRules(folder({ mode: "all", rules: [
      { type: "regex_title", pattern_or_value: "science", id: "legacy" },
      { type: "opml_category", pattern_or_value: "Research" },
    ] }))).toEqual({ mode: "all", rules: [
      { type: "regex_title", pattern: "(?i:science)" },
      { type: "opml_category", value: "Research" },
    ] });
  });

  it("preserves canonical case-sensitive expressions", () => {
    const rules = { mode: "any", rules: [{ type: "regex_url", pattern: "Science" }] };
    expect(parseRules(folder(rules))).toEqual(rules);
  });

  it("rejects malformed and unknown rules without partial matches", () => {
    for (const rules of [null, {}, { mode: "any", rules: [{}] },
      { mode: "any", rules: [{ type: "unknown", pattern: ".*" }] },
      { mode: "any", rules: [{ type: "regex_title", pattern: 42 }] }]) {
      expect(parseRules(folder(rules))).toBeNull();
    }
  });

  it("uses backend membership even when local title suggests a match", () => {
    const feeds = [
      { id: "included", title: "Different title" },
      { id: "excluded", title: "Science" },
    ] as Feed[];
    expect(feedsForFolder({ ...folder({ mode: "any", rules: [] }), matching_feed_ids: ["included"] }, feeds))
      .toEqual([feeds[0]]);
  });
});

it("defaults missing mode and keeps canonical fields authoritative", () => {
  expect(parseRules(folder({ rules: [{ type: "regex_title", pattern: "science", pattern_or_value: "Science", case_sensitive: false }] })))
    .toEqual({ mode: "any", rules: [{ type: "regex_title", pattern: "science" }] });
  expect(parseRules(folder({ rules: [{ type: "regex_title", pattern: "science", case_sensitive: false }] })))
    .toEqual({ mode: "any", rules: [{ type: "regex_title", pattern: "science" }] });
  expect(parseRules(folder({ mode: null, rules: [] }))).toBeNull();
});
