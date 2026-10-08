import { requireStoragePrefix, resolveStorage, safeGet, safeRemove, type ByosStorage } from './storage.js';

/**
 * TOKEN RULE: a provider token may cross the site's backend once, only to complete the sign-in
 * handshake (disclosed to the user). After that it lives only here, in the browser, and every model
 * call goes browser to provider. Nothing in this vault sends a token anywhere; never add a method
 * that does.
 */

/** `session`: this tab only. `browser`: remembered on this browser until signed out. */
export type CredentialPersistence = 'session' | 'browser';

/** The rotation half of a subscription connection. Absent for a plain API key. */
export type SubscriptionRefresh = { refreshToken: string; expiresAt?: number };

export type CredentialVault<P extends string = string> = ReturnType<typeof createCredentialVault<P>>;

export type CredentialVaultOptions = {
  /** Storage key prefix, e.g. `motive-ai-credential:`. One per site, so sites sharing an origin
   * never read each other's tokens. */
  prefix: string;
  storage?: ByosStorage;
};

function restore(storage: Storage, key: string, value: string | null): void {
  try {
    if (value === null) storage.removeItem(key);
    else storage.setItem(key, value);
  } catch { /* Best-effort rollback; source values stay untouched until the destination verifies. */ }
}

export function createCredentialVault<P extends string = string>(options: CredentialVaultOptions) {
  const prefix = requireStoragePrefix(options.prefix);
  const tokenKey = (provider: P) => `${prefix}${provider}`;
  // A sibling key, not a JSON blob in the token slot, so every reader of "the credential" stays a
  // plain string.
  const refreshKey = (provider: P) => `${tokenKey(provider)}:refresh`;
  const areas = () => resolveStorage(options.storage);

  function targetStorage(where: CredentialPersistence): Storage {
    const area = where === 'browser' ? areas().local : areas().session;
    if (!area) throw new Error('Browser storage is unavailable, so this sign-in cannot be kept.');
    return area;
  }

  function snapshot(area: Storage | undefined, tokenKey: string, grantKey: string) {
    if (!area) return undefined;
    try { return { area, tokenKey, grantKey, token: area.getItem(tokenKey), grant: area.getItem(grantKey) }; }
    catch { return undefined; }
  }

  function rollback(snapshots: Array<ReturnType<typeof snapshot>>): void {
    for (const prior of snapshots) if (prior) {
      restore(prior.area, prior.tokenKey, prior.token);
      restore(prior.area, prior.grantKey, prior.grant);
    }
  }

  function read(provider: P): string {
    const { session, local } = areas();
    return safeGet(session, tokenKey(provider)) ?? safeGet(local, tokenKey(provider)) ?? '';
  }

  function persistence(provider: P): CredentialPersistence {
    const { session, local } = areas();
    return safeGet(session, tokenKey(provider)) ? 'session' : safeGet(local, tokenKey(provider)) ? 'browser' : 'session';
  }

  function store(provider: P, value: string, where: CredentialPersistence): void {
    const token = value.trim();
    const { session, local } = areas();
    const key = tokenKey(provider);
    const grantKey = refreshKey(provider);
    const target = targetStorage(where);
    const prior = snapshot(target, key, grantKey);
    if (!prior) throw new Error('Browser storage is unavailable, so this sign-in cannot be kept.');
    const other = where === 'browser' ? session : local;
    const snapshots = [prior, ...(other && other !== target ? [snapshot(other, key, grantKey)] : [])];
    try {
      if (token) {
        target.setItem(key, token);
        if (target.getItem(key) !== token) throw new Error('Browser storage did not preserve the sign-in.');
        target.removeItem(grantKey);
      } else {
        target.removeItem(key);
        target.removeItem(grantKey);
      }
      // A newly stored credential starts a new lifecycle. Keep no refresh grant from a prior
      // account; callers that have a matching grant store it explicitly with storeRefresh.
      if (other && other !== target) {
        const otherSnapshot = snapshots[1];
        if (otherSnapshot) {
          other.removeItem(key);
          other.removeItem(grantKey);
        } else {
          safeRemove(other, key);
          safeRemove(other, grantKey);
        }
      }
    } catch (error) {
      rollback(snapshots);
      throw error;
    }
  }

  function readRefresh(provider: P): SubscriptionRefresh | null {
    const { session, local } = areas();
    const raw = safeGet(session, refreshKey(provider)) ?? safeGet(local, refreshKey(provider));
    if (!raw) return null;
    try {
      const parsed = JSON.parse(raw) as Partial<SubscriptionRefresh>;
      if (!parsed?.refreshToken) return null;
      return { refreshToken: parsed.refreshToken, expiresAt: typeof parsed.expiresAt === 'number' ? parsed.expiresAt : undefined };
    } catch {
      // Malformed reads as "no refresh grant", which degrades to reconnecting.
      return null;
    }
  }

  /** Stores (or, with null, clears) the refresh record in the same area as the access token, so the
   * two never outlive one another. */
  function storeRefresh(provider: P, record: SubscriptionRefresh | null, where: CredentialPersistence): void {
    const { session, local } = areas();
    const key = tokenKey(provider);
    const grantKey = refreshKey(provider);
    const target = targetStorage(where);
    const prior = snapshot(target, key, grantKey);
    if (!prior) throw new Error('Browser storage is unavailable, so this sign-in cannot be kept.');
    const other = where === 'browser' ? session : local;
    const snapshots = [prior, ...(other && other !== target ? [snapshot(other, key, grantKey)] : [])];
    try {
      if (record?.refreshToken) target.setItem(grantKey, JSON.stringify(record));
      else target.removeItem(grantKey);
      if (record?.refreshToken && target.getItem(grantKey) !== JSON.stringify(record)) {
        throw new Error('Browser storage did not preserve the sign-in.');
      }
      if (other && other !== target) {
        const otherSnapshot = snapshots[1];
        if (otherSnapshot) other.removeItem(grantKey);
        else safeRemove(other, grantKey);
      }
    } catch (error) {
      rollback(snapshots);
      throw error;
    }
  }

  function clearRefresh(provider: P): void {
    const { session, local } = areas();
    safeRemove(session, refreshKey(provider));
    safeRemove(local, refreshKey(provider));
  }

  /** Forgets the token and its refresh grant together, so a later refresh cannot silently revive a
   * connection the user removed. */
  function clear(provider: P): void {
    const { session, local } = areas();
    safeRemove(session, tokenKey(provider));
    safeRemove(local, tokenKey(provider));
    clearRefresh(provider);
  }

  /** Moves a token and its refresh grant together between tab-only and remembered storage. The
   * destination is verified before the source is cleared, so a quota or security error cannot erase
   * the working sign-in; partial destination writes roll back. */
  function setPersistence(provider: P, where: CredentialPersistence): void {
    const { session, local } = areas();
    const key = tokenKey(provider);
    const grantKey = refreshKey(provider);
    const source = safeGet(session, key) !== null ? session : safeGet(local, key) !== null ? local : null;
    if (!source) return;
    const target = where === 'browser' ? local : session;
    if (!target) throw new Error('Browser storage is unavailable, so this sign-in cannot be kept.');
    if (source === target) return;

    const token = source.getItem(key);
    if (token === null) return;
    const grant = safeGet(session, grantKey) ?? safeGet(local, grantKey);
    const targetPrior = snapshot(target, key, grantKey);
    if (!targetPrior) throw new Error('Browser storage is unavailable, so this sign-in cannot be kept.');
    const sourcePrior = snapshot(source, key, grantKey);
    if (!sourcePrior) throw new Error('Browser storage is unavailable, so this sign-in cannot be kept.');
    try {
      target.setItem(key, token);
      if (grant === null) target.removeItem(grantKey);
      else target.setItem(grantKey, grant);
      if (target.getItem(key) !== token || target.getItem(grantKey) !== grant) {
        throw new Error('Browser storage did not preserve the sign-in.');
      }
      source.removeItem(grantKey);
      source.removeItem(key);
    } catch (error) {
      rollback([targetPrior, sourcePrior]);
      throw error;
    }
  }

  return { read, persistence, store, clear, setPersistence, readRefresh, storeRefresh, clearRefresh };
}

/** True when an access token expiring at `expiresAt` should be refreshed now. */
export function tokenNeedsRefresh(expiresAt: number | undefined, skewMs: number, now = Date.now()): boolean {
  return Boolean(expiresAt && expiresAt - now <= skewMs);
}
