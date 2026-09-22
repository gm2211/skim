import { describe, expect, it } from "vitest";
import { citedNumbers, partitionSources } from "./chatCitations";

const article = (n: number) => ({
  id: `a${n}`,
  title: `Article ${n}`,
  feed_title: "Feed",
  url: null,
  published_at: null,
  source_type: "article" as const,
});
const web = {
  id: "web-0",
  title: "A web result",
  feed_title: "Web",
  url: "https://example.com",
  published_at: null,
  source_type: "web" as const,
};

/**
 * Ask Skim ranks up to fifteen candidates and hands them all to the model, but
 * listed every one of them under "Sources" as though the answer had used them.
 */
describe("chatCitations", () => {
  it("reads the bracket numbers the answer cited", () => {
    expect([...citedNumbers("As [2] reports, and [11] agrees.")]).toEqual([2, 11]);
  });

  it("ignores brackets that are not citations", () => {
    expect([...citedNumbers("An array like [] or [x] cites nothing.")]).toEqual([]);
  });

  it("keeps only the cited articles under Sources", () => {
    const sources = [article(1), article(2), article(3)];
    const { cited, searched } = partitionSources(sources, "See [2].");
    expect(cited.map((s) => s.number)).toEqual([2]);
    expect(searched.map((s) => s.number)).toEqual([1, 3]);
  });

  it("numbers articles by the position the model was given", () => {
    const { cited } = partitionSources([article(1), article(2)], "Both [1] and [2].");
    expect(cited.map((s) => s.source.id)).toEqual(["a1", "a2"]);
    expect(cited.map((s) => s.number)).toEqual([1, 2]);
  });

  it("always counts a web result as used, since it was fetched on purpose", () => {
    const { cited, searched } = partitionSources([article(1), article(2), web], "See [1].");
    expect(cited.map((s) => s.source.id)).toEqual(["a1", "web-0"]);
    expect(cited[1].number).toBeNull();
    expect(searched.map((s) => s.source.id)).toEqual(["a2"]);
  });

  it("calls them all searched when the answer cited nothing", () => {
    const { cited, searched } = partitionSources([article(1), article(2)], "I could not find it.");
    expect(cited).toEqual([]);
    expect(searched).toHaveLength(2);
  });
});
