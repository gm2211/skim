import { describe, expect, it } from "vitest";
import catalog from "../../../shared/feed-catalog.json";
import { topicStyle } from "./topicStyle";

describe("topicStyle", () => {
  it("gives every catalog topic its own colour and glyph", () => {
    const fallback = topicStyle("not-a-topic");
    for (const topic of catalog.topics) {
      expect(topicStyle(topic.id), topic.id).not.toBe(fallback);
    }
  });
});
