import tauriConfig from "../../src-tauri/tauri.conf.json";

// The boot disclaimer is an acceptance gate ("By tapping Got it you accept the
// Terms and Privacy Policy"). Like the native iOS app, Got it accepts it for
// this launch; ticking "Don't show again until the next update" remembers it
// until the app version changes. Editing the disclaimer's terms means bumping
// AI_DISCLAIMER_VERSION, which asks everyone again.
export const AI_DISCLAIMER_VERSION = "2026-09-21";

const STORAGE_KEY = "ai-boot-disclaimer-accepted";

function suppressionKey(appVersion: string): string {
  return `${AI_DISCLAIMER_VERSION}@${appVersion}`;
}

export function hasAcceptedAiDisclaimer(appVersion: string = tauriConfig.version): boolean {
  try {
    return localStorage.getItem(STORAGE_KEY) === suppressionKey(appVersion);
  } catch {
    // Storage can be unavailable or blocked; showing the notice again is the
    // safe side of that failure.
    return false;
  }
}

/// Records "Don't show again until the next update". Without it, acceptance
/// lasts only for the current launch and nothing is stored.
export function acceptAiDisclaimer(
  dontShowUntilUpdate: boolean,
  appVersion: string = tauriConfig.version,
): void {
  try {
    if (dontShowUntilUpdate) localStorage.setItem(STORAGE_KEY, suppressionKey(appVersion));
    else localStorage.removeItem(STORAGE_KEY);
  } catch {
    // Nothing to do: the notice will simply be shown again next launch.
  }
}
