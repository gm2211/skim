/** The two Web Storage areas the kit writes to. Injectable so tests, workers and server-side
 * rendering can pass their own (or none); defaults to the page's globals when they exist. */
export type ByosStorage = { session?: Storage; local?: Storage };

/** Reject accidental unscoped keys that could collide with another app on a shared origin. */
export function requireStoragePrefix(prefix: string): string {
  if (typeof prefix !== 'string' || !prefix.trim() || prefix !== prefix.trim() || prefix.length > 128) {
    throw new TypeError('Storage prefix must be a non-empty, trimmed string of at most 128 characters.');
  }
  return prefix;
}

export function resolveStorage(storage?: ByosStorage): ByosStorage {
  if (storage) return storage;
  const scope = globalThis as { sessionStorage?: Storage; localStorage?: Storage };
  let session: Storage | undefined;
  let local: Storage | undefined;
  // Reading the accessor itself throws in some locked-down profiles.
  try { session = scope.sessionStorage; } catch { session = undefined; }
  try { local = scope.localStorage; } catch { local = undefined; }
  return { session, local };
}

export function safeGet(store: Storage | undefined, key: string): string | null {
  try { return store ? store.getItem(key) : null; } catch { return null; }
}

export function safeSet(store: Storage | undefined, key: string, value: string): void {
  try { store?.setItem(key, value); } catch { /* quota or disabled storage */ }
}

export function safeRemove(store: Storage | undefined, key: string): void {
  try { store?.removeItem(key); } catch { /* disabled storage */ }
}
