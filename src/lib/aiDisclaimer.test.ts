import { beforeEach, describe, expect, it, vi } from "vitest";
import { AI_DISCLAIMER_VERSION, APP_VERSION, acceptAiDisclaimer, hasAcceptedAiDisclaimer } from "./aiDisclaimer";

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
 * "By tapping Got it you accept the Terms and Privacy Policy" is an acceptance
 * gate. As on iOS, ticking "Don't show again until the next update" remembers
 * the answer for this app version only; leaving it unticked asks next launch.
 */
describe("aiDisclaimer", () => {
  beforeEach(() => useStore({}));

  it("has not been accepted before the first Got it", () => {
    expect(hasAcceptedAiDisclaimer("1.0.0")).toBe(false);
  });

  it("stays dismissed across a reload when Don't show again is ticked", () => {
    acceptAiDisclaimer(true, "1.0.0");
    expect(hasAcceptedAiDisclaimer("1.0.0")).toBe(true);
  });

  it("asks again after an app update", () => {
    acceptAiDisclaimer(true, "1.0.0");
    expect(hasAcceptedAiDisclaimer("1.0.1")).toBe(false);
  });

  it("asks again next launch when Don't show again is left unticked", () => {
    acceptAiDisclaimer(true, "1.0.0");
    acceptAiDisclaimer(false, "1.0.0");
    expect(hasAcceptedAiDisclaimer("1.0.0")).toBe(false);
  });

  it("asks again when the disclaimer's terms change", () => {
    useStore({ "ai-boot-disclaimer-suppressed": `an-older-version@1.0.0` });
    expect(hasAcceptedAiDisclaimer("1.0.0")).toBe(false);
    expect(AI_DISCLAIMER_VERSION).not.toBe("an-older-version");
  });

  it("uses the app version injected at build time by default", () => {
    expect(APP_VERSION).toMatch(/^\d+\.\d+\.\d+/);
    acceptAiDisclaimer(true);
    expect(hasAcceptedAiDisclaimer()).toBe(true);
  });

  it("shows the notice again rather than throwing when storage is blocked", () => {
    const blocked = vi.fn(() => {
      throw new Error("blocked");
    });
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      value: { getItem: blocked, setItem: blocked, removeItem: blocked },
    });
    expect(() => acceptAiDisclaimer(true)).not.toThrow();
    expect(hasAcceptedAiDisclaimer()).toBe(false);
  });
});
