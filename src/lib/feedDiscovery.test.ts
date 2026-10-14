import { describe, expect, it } from "vitest";
import { compactCount, displayHost, looksLikeUrl, shortAge } from "./feedDiscovery";

describe("looksLikeUrl", () => {
  it("treats addresses as URLs and words as searches", () => {
    expect(looksLikeUrl("theverge.com")).toBe(true);
    expect(looksLikeUrl("https://example.com")).toBe(true);
    expect(looksLikeUrl("blog.rust-lang.org/feed")).toBe(true);
    expect(looksLikeUrl("r/rust")).toBe(true);
    expect(looksLikeUrl("rust programming")).toBe(false);
    expect(looksLikeUrl("rust")).toBe(false);
    expect(looksLikeUrl("v1.2")).toBe(false);
    expect(looksLikeUrl("")).toBe(false);
  });
});

describe("formatting", () => {
  it("formats hosts, counts and ages", () => {
    expect(displayHost("https://www.theverge.com/rss")).toBe("theverge.com");
    expect(compactCount(950)).toBe("950");
    expect(compactCount(1234)).toBe("1.2K");
    expect(compactCount(1_000_000)).toBe("1M");
    expect(compactCount(25_400_000)).toBe("25M");
    const now = Date.UTC(2026, 9, 14, 12);
    expect(shortAge(now / 1000 - 3 * 3600, now)).toBe("3h");
    expect(shortAge(now / 1000 - 2 * 86400, now)).toBe("2d");
    expect(shortAge(null, now)).toBe("");
  });
});
