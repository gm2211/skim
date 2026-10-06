// The boot disclaimer is an acceptance gate ("By tapping Got it you accept the
// Terms and Privacy Policy"). Like iOS (AIBootDisclaimerView.swift), the user can
// tick "Don't show again until the next update": the stored value is then the
// disclaimer's terms version plus the app version it was dismissed on, so either
// an app update or a change to the terms (bump this constant) asks again.
export const AI_DISCLAIMER_VERSION = "2026-09-21";

// Injected from src-tauri/tauri.conf.json by vite.config.ts.
export const APP_VERSION: string =
  typeof __APP_VERSION__ === "string" ? __APP_VERSION__ : "0";

const STORAGE_KEY = "ai-boot-disclaimer-suppressed";
// Before per-update suppression the accepted terms version was kept here.
const LEGACY_STORAGE_KEY = "ai-boot-disclaimer-accepted";

function suppressionStamp(appVersion: string): string {
  return `${AI_DISCLAIMER_VERSION}@${appVersion}`;
}

export function hasAcceptedAiDisclaimer(appVersion: string = APP_VERSION): boolean {
  try {
    return localStorage.getItem(STORAGE_KEY) === suppressionStamp(appVersion);
  } catch {
    // Storage can be unavailable or blocked; showing the notice again is the
    // safe side of that failure.
    return false;
  }
}

export function acceptAiDisclaimer(
  dontShowAgain: boolean,
  appVersion: string = APP_VERSION,
): void {
  try {
    if (dontShowAgain) {
      localStorage.setItem(STORAGE_KEY, suppressionStamp(appVersion));
    } else {
      localStorage.removeItem(STORAGE_KEY);
    }
    localStorage.removeItem(LEGACY_STORAGE_KEY);
  } catch {
    // Nothing to do: the notice will simply be shown again next launch.
  }
}
