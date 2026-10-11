import { providerErrorText, redactProviderSecrets } from './chat.js';

/**
 * OpenRouter sign-in with PKCE, entirely in the browser. OpenRouter's /auth/keys endpoint answers
 * browser origins, so the site's server never sees the code, the verifier or the resulting key.
 *
 * The flow navigates this tab to openrouter.ai/auth and back. The PKCE transaction (verifier,
 * start time, and the route to return to) is written to sessionStorage and to a temporary
 * localStorage copy, so a callback that lands in a new tab can still finish. The key is stored in
 * localStorage; an empty stored value is an explicit disconnect that an older tab's session copy
 * must not resurrect. Other tabs learn about a new connection from a credential-free
 * BroadcastChannel or storage-event signal, never from a message carrying the key.
 *
 * Every storage key and channel name comes from the site, so two sites on one origin, or a site
 * migrating from its own older keys, keep separate state.
 */

export type OpenRouterSignInOptions = {
  /** Browser storage key holding the connected key. */
  keyStorageKey: string;
  /** Defaults to browser-wide persistence. Session mode keeps the key in this tab only.
   * Legacy local keys migrate to the session and are removed from localStorage.
   * PKCE transactions still use the short-lived local fallback for callback recovery. */
  credentialPersistence?: 'browser' | 'session';
  /** Storage key holding the in-flight PKCE transaction. */
  transactionStorageKey: string;
  /** BroadcastChannel name for the credential-free "connected / disconnected / error" signal. */
  handoffChannel: string;
  /** localStorage key used as the storage-event fallback for that signal. */
  handoffFallbackKey: string;
  /** Extra window events that should make listeners re-read the stored key. */
  resyncEvents?: string[];
  /** Hash to return to when sign-in starts on a page with none. */
  defaultReturnRoute?: string;
  ttlMs?: number;
  apiRoot?: string;
  authUrl?: string;
  messages?: Partial<OpenRouterSignInMessages>;
};

export type OpenRouterSignInMessages = {
  noAttempt: string;
  expired: string;
  unverifiable: string;
  exchangeFailed: string;
};

const DEFAULT_MESSAGES: OpenRouterSignInMessages = {
  noAttempt: 'This OpenRouter callback no longer matches a sign-in attempt. Retry connection.',
  expired: 'The OpenRouter sign-in attempt expired. Retry connection.',
  unverifiable: 'This OpenRouter callback could not be verified. Retry connection.',
  exchangeFailed: 'OpenRouter could not finish the connection. Retry sign-in.',
};

export type PkceTransaction = { verifier: string; createdAt: number; returnRoute: string };

export type OpenRouterOAuthResult =
  | { type: 'connected'; key: string }
  | { type: 'error'; message: string }
  | { type: 'disconnected' };

function toBase64Url(bytes: Uint8Array): string {
  let binary = '';
  bytes.forEach(byte => { binary += String.fromCharCode(byte); });
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function randomVerifier(): string {
  return toBase64Url(crypto.getRandomValues(new Uint8Array(64)));
}

async function challengeFor(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return toBase64Url(new Uint8Array(digest));
}

export function createOpenRouterSignIn(options: OpenRouterSignInOptions) {
  const KEY_STORAGE = options.keyStorageKey;
  const SESSION_ONLY = options.credentialPersistence === 'session';
  const VERIFIER_STORAGE = options.transactionStorageKey;
  const HANDOFF_CHANNEL = options.handoffChannel;
  const HANDOFF_FALLBACK_KEY = options.handoffFallbackKey;
  const PKCE_TTL_MS = options.ttlMs ?? 20 * 60 * 1000;
  const API_ROOT = options.apiRoot ?? 'https://openrouter.ai/api/v1';
  const AUTH_URL = options.authUrl ?? 'https://openrouter.ai/auth';
  const DEFAULT_RETURN_ROUTE = options.defaultReturnRoute ?? '';
  const RESYNC_EVENTS = options.resyncEvents ?? [];
  const messages = { ...DEFAULT_MESSAGES, ...options.messages };
  let oauthExchangeCode: string | undefined;
  let oauthExchangePromise: Promise<string> | undefined;

  function storePkceTransaction(transaction: PkceTransaction): void {
    const serialized = JSON.stringify(transaction);
    sessionStorage.setItem(VERIFIER_STORAGE, serialized);
    // sessionStorage is scoped to one tab. The temporary local copy lets an OAuth provider return
    // through a new tab. The resulting connection also lives in browser storage, so the
    // originating tab can recover even when an ephemeral handoff message is missed.
    localStorage.setItem(VERIFIER_STORAGE, serialized);
  }

  function clearPkceTransaction(): void {
    sessionStorage.removeItem(VERIFIER_STORAGE);
    localStorage.removeItem(VERIFIER_STORAGE);
  }

  /** Parses the raw stashed transaction (session first, then the local fallback), applying the same
   * TTL and legacy-format handling readPkceVerifier does. Returns undefined rather than throwing --
   * both callers (readPkceVerifier below and peekReturnRoute) treat "nothing usable" as a
   * fine outcome, just with different fallbacks. */
  function parseStoredTransaction(): Partial<PkceTransaction> | undefined {
    const raw = sessionStorage.getItem(VERIFIER_STORAGE) || localStorage.getItem(VERIFIER_STORAGE);
    if (!raw) return undefined;
    try {
      const transaction = JSON.parse(raw) as Partial<PkceTransaction>;
      if (typeof transaction.verifier !== 'string' || !transaction.verifier) return undefined;
      if (typeof transaction.createdAt !== 'number' || Date.now() - transaction.createdAt > PKCE_TTL_MS) return undefined;
      return transaction;
    } catch {
      return undefined;
    }
  }

  function readPkceVerifier(): string {
    const raw = sessionStorage.getItem(VERIFIER_STORAGE) || localStorage.getItem(VERIFIER_STORAGE);
    if (!raw) throw new Error(messages.noAttempt);
    try {
      const transaction = JSON.parse(raw) as Partial<PkceTransaction>;
      if (typeof transaction.verifier !== 'string' || !transaction.verifier) throw new Error('invalid');
      if (typeof transaction.createdAt !== 'number' || Date.now() - transaction.createdAt > PKCE_TTL_MS) {
        clearPkceTransaction();
        throw new Error('expired');
      }
      return transaction.verifier;
    } catch (error) {
      // Accept the previous session-only verifier format during a rolling update.
      if (!raw.startsWith('{') && raw.length >= 43) return raw;
      if (error instanceof Error && error.message === 'expired') {
        throw new Error(messages.expired);
      }
      clearPkceTransaction();
      throw new Error(messages.unverifiable);
    }
  }

  /**
   * The hash the page was on when sign-in began, read back WITHOUT consuming the transaction, so a
   * site's startup code (which runs before complete() clears it) can restore the originating route.
   * A peek, not a read-and-clear: complete() still needs the verifier, and a site may read the
   * route more than once while rendering.
   */
  function peekReturnRoute(): string | undefined {
    const transaction = parseStoredTransaction();
    return typeof transaction?.returnRoute === 'string' ? transaction.returnRoute : undefined;
  }

  function getStoredKey(): string {
    if (SESSION_ONLY) {
      const key = sessionStorage.getItem(KEY_STORAGE) ?? localStorage.getItem(KEY_STORAGE) ?? '';
      if (key) sessionStorage.setItem(KEY_STORAGE, key);
      localStorage.removeItem(KEY_STORAGE);
      return key;
    }
    const browserKey = localStorage.getItem(KEY_STORAGE);
    // An empty browser value is an explicit disconnect: an older tab's session key must not
    // resurrect it. Migrate existing session connections only when no browser decision exists.
    if (browserKey !== null) {
      sessionStorage.removeItem(KEY_STORAGE);
      return browserKey;
    }
    const sessionKey = sessionStorage.getItem(KEY_STORAGE) || '';
    if (sessionKey) storeKey(sessionKey);
    return sessionKey;
  }

  function storeKey(key: string): void {
    if (SESSION_ONLY) {
      sessionStorage.setItem(KEY_STORAGE, key);
      localStorage.removeItem(KEY_STORAGE);
      return;
    }
    sessionStorage.removeItem(KEY_STORAGE);
    localStorage.setItem(KEY_STORAGE, key);
  }

  function clearKey(): void {
    sessionStorage.removeItem(KEY_STORAGE);
    if (SESSION_ONLY) localStorage.removeItem(KEY_STORAGE);
    else localStorage.setItem(KEY_STORAGE, '');
  }

  /** Starts sign-in in this tab and keeps the originating route in the PKCE transaction so the
   * callback can restore it. */
  async function begin(): Promise<void> {
    const verifier = randomVerifier();
    const challenge = await challengeFor(verifier);
    const returnRoute = window.location.hash || DEFAULT_RETURN_ROUTE;
    storePkceTransaction({ verifier, createdAt: Date.now(), returnRoute });
    const callbackUrl = new URL(`${window.location.origin}${window.location.pathname}`);
    const authUrl = new URL(AUTH_URL);
    authUrl.searchParams.set('callback_url', callbackUrl.toString());
    authUrl.searchParams.set('code_challenge', challenge);
    authUrl.searchParams.set('code_challenge_method', 'S256');
    window.location.assign(authUrl.toString());
  }

  async function complete(code: string): Promise<string> {
    if (oauthExchangeCode === code && oauthExchangePromise) return oauthExchangePromise;
    oauthExchangeCode = code;
    oauthExchangePromise = (async () => {
      const verifier = readPkceVerifier();
      const response = await fetch(`${API_ROOT}/auth/keys`, {
        method: 'POST',
        redirect: 'error',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code, code_verifier: verifier, code_challenge_method: 'S256' }),
      });
      const payload = await response.json().catch(() => ({})) as { key?: string; error?: { message?: string } };
      if (!response.ok || !payload.key) {
        if (response.status === 400 || response.status === 403) clearPkceTransaction();
        const message = providerErrorText(payload) || messages.exchangeFailed;
        throw new Error(redactProviderSecrets(message, [code, verifier]));
      }
      clearPkceTransaction();
      storeKey(payload.key);
      return payload.key;
    })();
    return oauthExchangePromise;
  }

  function broadcast(result: OpenRouterOAuthResult): void {
    // The durable credential is the handoff. Messages carry only a notification, never the key.
    if (result.type === 'connected') storeKey(result.key);
    const signal = result.type === 'connected' ? { type: 'connected' } : result;
    try {
      if (typeof BroadcastChannel !== 'undefined') {
        const channel = new BroadcastChannel(HANDOFF_CHANNEL);
        channel.postMessage(signal);
        channel.close();
      }
    } catch {
      // best effort -- the storage fallback below still has a chance of getting through
    }
    try {
      localStorage.setItem(HANDOFF_FALLBACK_KEY, JSON.stringify({ ...signal, at: Date.now() }));
      localStorage.removeItem(HANDOFF_FALLBACK_KEY);
    } catch {
      // best effort
    }
  }

  /** Subscribes every settings instance to the shared connection, including tabs that did not
   * initiate sign-in. Focus/page restoration recovers missed events; equal keys are deduplicated. */
  function listen(onResult: (result: OpenRouterOAuthResult) => void): () => void {
    const teardown: Array<() => void> = [];
    let lastKey = getStoredKey();
    const syncConnection = () => {
      const key = getStoredKey();
      if (key === lastKey) return;
      lastKey = key;
      onResult(key ? { type: 'connected', key } : { type: 'disconnected' });
    };
    const receiveSignal = (value: unknown) => {
      if (!value || typeof value !== 'object') return;
      const signal = value as { type?: unknown; message?: unknown };
      if (signal.type === 'error' && typeof signal.message === 'string') {
        onResult({ type: 'error', message: signal.message });
      } else if (signal.type === 'connected' || signal.type === 'disconnected') {
        syncConnection();
      }
    };
    try {
      if (typeof BroadcastChannel !== 'undefined') {
        const channel = new BroadcastChannel(HANDOFF_CHANNEL);
        channel.onmessage = event => receiveSignal(event.data);
        teardown.push(() => channel.close());
      }
    } catch {
      // Storage and focus events still recover the durable connection.
    }
    const onStorage = (event: StorageEvent) => {
      if (event.key === KEY_STORAGE || event.key === null) {
        syncConnection();
        return;
      }
      if (event.key !== HANDOFF_FALLBACK_KEY || !event.newValue) return;
      try { receiveSignal(JSON.parse(event.newValue)); } catch { /* Ignore malformed messages. */ }
    };
    window.addEventListener('storage', onStorage);
    window.addEventListener('focus', syncConnection);
    window.addEventListener('pageshow', syncConnection);
    RESYNC_EVENTS.forEach(name => window.addEventListener(name, syncConnection));
    teardown.push(() => window.removeEventListener('storage', onStorage));
    teardown.push(() => window.removeEventListener('focus', syncConnection));
    teardown.push(() => window.removeEventListener('pageshow', syncConnection));
    RESYNC_EVENTS.forEach(name => teardown.push(() => window.removeEventListener(name, syncConnection)));
    return () => teardown.forEach(fn => fn());
  }

  return {
    begin,
    complete,
    peekReturnRoute,
    getStoredKey,
    storeKey,
    clearKey,
    broadcast,
    listen,
    /** Exposed so a site can test its return-route handling without a real redirect. */
    storePkceTransaction,
  };
}

export type OpenRouterSignIn = ReturnType<typeof createOpenRouterSignIn>;
