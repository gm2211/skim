// The boot disclaimer is an acceptance gate ("By tapping Got it you accept the
// Terms and Privacy Policy"), so it is answered once and remembered. The stored
// value is the version that was accepted: editing the disclaimer's terms means
// bumping this constant, which asks everyone again.
export const AI_DISCLAIMER_VERSION = "2026-09-21";

const STORAGE_KEY = "ai-boot-disclaimer-accepted";

export function hasAcceptedAiDisclaimer(): boolean {
  try {
    return localStorage.getItem(STORAGE_KEY) === AI_DISCLAIMER_VERSION;
  } catch {
    // Storage can be unavailable or blocked; showing the notice again is the
    // safe side of that failure.
    return false;
  }
}

export function acceptAiDisclaimer(): void {
  try {
    localStorage.setItem(STORAGE_KEY, AI_DISCLAIMER_VERSION);
  } catch {
    // Nothing to do: the notice will simply be shown again next launch.
  }
}
