import { afterEach, describe, expect, it, vi } from "vitest";
import { shareArticle } from "./shareArticle";

const original = { share: navigator.share, clipboard: navigator.clipboard };

function stub(share: ((data: ShareData) => Promise<void>) | undefined, writeText = vi.fn().mockResolvedValue(undefined)) {
  Object.defineProperty(navigator, "share", { value: share, configurable: true });
  Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
  return writeText;
}

afterEach(() => {
  Object.defineProperty(navigator, "share", { value: original.share, configurable: true });
  Object.defineProperty(navigator, "clipboard", { value: original.clipboard, configurable: true });
});

describe("shareArticle", () => {
  it("uses the native share sheet with the url and title", async () => {
    const share = vi.fn().mockResolvedValue(undefined);
    const writeText = stub(share);
    await expect(shareArticle({ url: "https://example.com/a", title: "A story" })).resolves.toBe("shared");
    expect(share).toHaveBeenCalledWith({ url: "https://example.com/a", title: "A story" });
    expect(writeText).not.toHaveBeenCalled();
  });

  it("treats a dismissed sheet as cancelled, not a copy", async () => {
    const writeText = stub(vi.fn().mockRejectedValue(new DOMException("closed", "AbortError")));
    await expect(shareArticle({ url: "https://example.com/a" })).resolves.toBe("cancelled");
    expect(writeText).not.toHaveBeenCalled();
  });

  it("copies the link when there is no share sheet", async () => {
    const writeText = stub(undefined);
    await expect(shareArticle({ url: "https://example.com/a", title: "A" })).resolves.toBe("copied");
    expect(writeText).toHaveBeenCalledWith("https://example.com/a");
  });

  it("copies the link when sharing fails for another reason", async () => {
    const writeText = stub(vi.fn().mockRejectedValue(new DOMException("nope", "NotAllowedError")));
    await expect(shareArticle({ url: "https://example.com/a" })).resolves.toBe("copied");
    expect(writeText).toHaveBeenCalledWith("https://example.com/a");
  });
});
