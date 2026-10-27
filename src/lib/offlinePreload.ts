import { preloadArticlesForOffline, type OfflinePreloadProgress } from "../services/commands";

const DEFAULT_LIMIT = 300;
const LIMIT_KEY = "offline-reader-limit";
const AUTO_KEY = "offline-reader-auto";
// One preload at a time, shared by Settings and the after-refresh run, so
// Settings shows a background run's progress when opened mid-way.
let activePreload: Promise<OfflinePreloadProgress> | null = null;
let latestProgress: OfflinePreloadProgress | null = null;

export const latestPreloadProgress = () => latestProgress;
export const offlinePreloadRunning = () => activePreload !== null;
export function rememberPreloadProgress(progress: OfflinePreloadProgress) {
  latestProgress = progress;
}

function readStorage(key: string): string | null {
  try { return localStorage.getItem(key); } catch { return null; }
}

function writeStorage(key: string, value: string) {
  try { localStorage.setItem(key, value); } catch { /* the setting just isn't remembered */ }
}

export function offlinePreloadLimit(): number {
  return Number(readStorage(LIMIT_KEY)) || DEFAULT_LIMIT;
}

export function setOfflinePreloadLimit(limit: number) {
  writeStorage(LIMIT_KEY, String(limit));
}

export function setOfflineAutoPreload(on: boolean) {
  writeStorage(AUTO_KEY, on ? "on" : "off");
}

/** On unless the reader turned it off. */
export function offlineAutoPreloadEnabled(): boolean {
  return readStorage(AUTO_KEY) !== "off";
}

export function startOfflinePreload(limit: number): Promise<OfflinePreloadProgress> {
  if (!activePreload) {
    activePreload = preloadArticlesForOffline(limit)
      .then((result) => { latestProgress = result; return result; })
      .finally(() => { activePreload = null; });
  }
  return activePreload;
}

/**
 * After a feed refresh, quietly save the newest articles (reader copy and
 * pictures) so they open with no connection. Skipped when the reader turned
 * it off or a preload is already running; failures stay silent because the
 * articles are still there to read online.
 */
export function preloadAfterRefresh(): void {
  if (!offlineAutoPreloadEnabled() || activePreload) return;
  try {
    void startOfflinePreload(offlinePreloadLimit()).catch(() => undefined);
  } catch {
    // Saving for offline is a bonus; a refresh never fails because of it.
  }
}
