import { beforeEach, describe, expect, it, vi } from "vitest";
import { acceptAiDisclaimer, hasAcceptedAiDisclaimer } from "./aiDisclaimer";

function useStore(store: Record<string, string>) {
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem: (k: string) => (k in store ? store[k] : null),
      setItem: (k: string, v: string) => {
        store[k] = v;
      },
      removeItem: (k: string) => {
        delete store[k];
      },
    },
  });
}

/**
 * Got it accepts the notice for this launch; "Don't show again until the next
 * update" remembers it until the app version (or the terms) change, matching
 * the native iOS app.
 */
describe("aiDisclaimer", () => {
  beforeEach(() => useStore({}));

  it("has not been accepted before the first Got it", () => {
    expect(hasAcceptedAiDisclaimer("0.1.37")).toBe(false);
  });

  it("remembers nothing when Don't show again is off", () => {
    acceptAiDisclaimer(false, "0.1.37");
    expect(hasAcceptedAiDisclaimer("0.1.37")).toBe(false);
  });

  it("stays hidden across a reload when Don't show again is on", () => {
    acceptAiDisclaimer(true, "0.1.37");
    expect(hasAcceptedAiDisclaimer("0.1.37")).toBe(true);
  });

  it("shows again after the app updates", () => {
    acceptAiDisclaimer(true, "0.1.37");
    expect(hasAcceptedAiDisclaimer("0.1.38")).toBe(false);
  });

  it("asks again when the disclaimer's terms change", () => {
    useStore({ "ai-boot-disclaimer-accepted": "an-older-version@0.1.37" });
    expect(hasAcceptedAiDisclaimer("0.1.37")).toBe(false);
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
        removeItem: vi.fn(() => {
          throw new Error("blocked");
        }),
      },
    });
    expect(() => acceptAiDisclaimer(true)).not.toThrow();
    expect(hasAcceptedAiDisclaimer()).toBe(false);
  });
});
