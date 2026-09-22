import { beforeEach, describe, expect, it, vi } from "vitest";
import { AI_DISCLAIMER_VERSION, acceptAiDisclaimer, hasAcceptedAiDisclaimer } from "./aiDisclaimer";

function useStore(store: Record<string, string>) {
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem: (k: string) => (k in store ? store[k] : null),
      setItem: (k: string, v: string) => {
        store[k] = v;
      },
    },
  });
}

/**
 * "By tapping Got it you accept the Terms and Privacy Policy" is an acceptance
 * gate, so it is answered once. It was held in component state alone, which
 * meant every launch asked again.
 */
describe("aiDisclaimer", () => {
  beforeEach(() => useStore({}));

  it("has not been accepted before the first Got it", () => {
    expect(hasAcceptedAiDisclaimer()).toBe(false);
  });

  it("stays accepted across a reload", () => {
    acceptAiDisclaimer();
    expect(hasAcceptedAiDisclaimer()).toBe(true);
  });

  it("asks again when the disclaimer's terms change", () => {
    useStore({ "ai-boot-disclaimer-accepted": "an-older-version" });
    expect(hasAcceptedAiDisclaimer()).toBe(false);
    expect(AI_DISCLAIMER_VERSION).not.toBe("an-older-version");
  });

  it("shows the notice again rather than throwing when storage is blocked", () => {
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      value: {
        getItem: vi.fn(() => {
          throw new Error("blocked");
        }),
        setItem: vi.fn(() => {
          throw new Error("blocked");
        }),
      },
    });
    expect(() => acceptAiDisclaimer()).not.toThrow();
    expect(hasAcceptedAiDisclaimer()).toBe(false);
  });
});
