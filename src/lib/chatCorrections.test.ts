import { describe, expect, it } from "vitest";
import { applyChatCorrections, extractCorrections } from "./chatCorrections";

const earlier = [
  { role: "user", content: "What does the excerpt cover?" },
  { role: "assistant", content: "The excerpt covers SnapStart and Aurora DSQL [1]. It also mentions double NAT." },
];

describe("chat corrections", () => {
  it("strikes the wrong words in the earlier reply and notes the fix beside them", () => {
    const answer = "Yes, the 100x figure is from your quote.\n\n<correction><was>covers SnapStart and Aurora DSQL</was><now>does not cover SnapStart or Aurora DSQL</now></correction>";
    const result = applyChatCorrections(earlier, answer);
    expect(result.corrected).toBe(1);
    expect(result.messages[1].content).toBe(
      "The excerpt ~~covers SnapStart and Aurora DSQL~~ **[updated]:** does not cover SnapStart or Aurora DSQL [1]. It also mentions double NAT.",
    );
    expect(result.answer).toBe("Yes, the 100x figure is from your quote.");
    expect(result.messages[0]).toBe(earlier[0]);
  });

  it("matches across differences in spacing and case", () => {
    const answer = "<correction><was>also  mentions\ndouble nat</was><now>does not mention double NAT</now></correction>";
    const result = applyChatCorrections(earlier, answer);
    expect(result.messages[1].content).toContain("~~also mentions double NAT~~ **[updated]:** does not mention double NAT");
    expect(result.answer).toBe("*Updated my earlier reply above.*");
  });

  it("keeps a correction that matches nothing visible in the new answer", () => {
    const answer = "Here is more.\n<correction><was>never said this</was><now>right</now></correction>";
    const result = applyChatCorrections(earlier, answer);
    expect(result.corrected).toBe(0);
    expect(result.messages).toBe(earlier);
    expect(result.answer).toBe("~~never said this~~ **[updated]:** right\n\nHere is more.");
  });

  it("edits only replies, never the reader's own messages", () => {
    const result = applyChatCorrections(earlier, "<correction><was>What does the excerpt cover?</was><now>x</now></correction>");
    expect(result.messages[0].content).toBe("What does the excerpt cover?");
    expect(result.corrected).toBe(0);
  });

  it("leaves an answer without corrections untouched", () => {
    expect(extractCorrections("Plain [2] answer.")).toEqual({ text: "Plain [2] answer.", corrections: [] });
    const result = applyChatCorrections(earlier, "Plain answer.");
    expect(result.messages).toBe(earlier);
    expect(result.answer).toBe("Plain answer.");
  });
});
