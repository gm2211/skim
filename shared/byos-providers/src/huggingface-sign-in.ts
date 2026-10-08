import { redactProviderSecrets } from './chat.js';

/**
 * Hugging Face "Sign in with Hugging Face" -- OAuth 2 authorization code + PKCE, entirely in the
 * browser (https://huggingface.co/docs/hub/en/oauth). huggingface.co/oauth/authorize and
 * huggingface.co/oauth/token both answer browser origins for a public (no-secret) client, so the
 * site's server never sees the code, the verifier, or the resulting access/refresh tokens.
 *
 * TOKEN RULE (AGENTS.md): the resulting access token lives only in this browser and is sent only to
 * huggingface.co / router.huggingface.co. It never reaches the site's server and is never logged.
 *
 * Modelled on openrouter-sign-in.ts's storage/handoff-channel shape (PKCE transaction in
 * sessionStorage + a temporary localStorage copy so a callback landing in a new tab can still
 * finish, TTL'd, with a credential-free BroadcastChannel/storage-event signal for other tabs), with
 * two differences OpenRouter's flow does not need:
 *   - `state` is generated at `begin()` and checked at `complete()` -- OpenRouter's own callback
 *     carries no state parameter, but HF's authorize endpoint does, and a mismatch must reject the
 *     callback outright rather than silently trust whatever code showed up.
 *   - the token response carries `expires_in` (and sometimes `refresh_token`); the stored
 *     connection tracks its own expiry, and a caller that finds it expired is told to sign in again
 *     rather than being handed a token that will just be refused downstream.
 */

export type HuggingFaceSignInOptions = {
  /** The OAuth client id. With Client ID Metadata Documents this can be a URL; a classic registered
   * app passes its issued id. Required -- HF sign-in has no default client. */
  clientId: string;
  /** Must exactly match what the client id's metadata (or the registered app) declares. */
  redirectUri: string;
  /** Space-separated OAuth scopes. Defaults to 'openid profile inference-api'. */
  scopes?: string;
  /** localStorage key holding the connected token record. */
  tokenStorageKey: string;
  /** Storage key holding the in-flight PKCE transaction. */
  transactionStorageKey: string;
  /** BroadcastChannel name for the credential-free "connected / disconnected / error" signal. */
  handoffChannel: string;
  /** localStorage key used as the storage-event fallback for that signal. */
  handoffFallbackKey: string;
  /** Extra window events that should make listeners re-read the stored token. */
  resyncEvents?: string[];
  /** Hash to return to when sign-in starts on a page with none. */
  defaultReturnRoute?: string;
  ttlMs?: number;
  authUrl?: string;
  tokenUrl?: string;
  messages?: Partial<HuggingFaceSignInMessages>;
};

export type HuggingFaceSignInMessages = {
  noAttempt: string;
  expired: string;
  stateMismatch: string;
  exchangeFailed: string;
  tokenExpired: string;
};

const DEFAULT_MESSAGES: HuggingFaceSignInMessages = {
  noAttempt: 'This Hugging Face callback no longer matches a sign-in attempt. Retry connection.',
  expired: 'The Hugging Face sign-in attempt expired. Retry connection.',
  stateMismatch: 'This Hugging Face callback could not be verified. Retry connection.',
  exchangeFailed: 'Hugging Face could not finish the connection. Retry sign-in.',
  tokenExpired: 'Your Hugging Face sign-in expired. Sign in again.',
};

export type PkceTransaction = { verifier: string; state: string; createdAt: number; returnRoute: string };

/** The durable connection: an access token, its expiry (ms epoch), and an optional refresh token. */
export type HuggingFaceTokenRecord = { accessToken: string; expiresAt: number; refreshToken?: string };

export type HuggingFaceOAuthResult =
  | { type: 'connected'; token: HuggingFaceTokenRecord }
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

function randomState(): string {
  return toBase64Url(crypto.getRandomValues(new Uint8Array(32)));
}

async function challengeFor(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return toBase64Url(new Uint8Array(digest));
}

export function createHuggingFaceSignIn(options: HuggingFaceSignInOptions) {
  const TOKEN_STORAGE = options.tokenStorageKey;
  const TRANSACTION_STORAGE = options.transactionStorageKey;
  const HANDOFF_CHANNEL = options.handoffChannel;
  const HANDOFF_FALLBACK_KEY = options.handoffFallbackKey;
  const PKCE_TTL_MS = options.ttlMs ?? 20 * 60 * 1000;
  const AUTH_URL = options.authUrl ?? 'https://huggingface.co/oauth/authorize';
  const TOKEN_URL = options.tokenUrl ?? 'https://huggingface.co/oauth/token';
  const SCOPES = options.scopes ?? 'openid profile inference-api';
  const DEFAULT_RETURN_ROUTE = options.defaultReturnRoute ?? '';
  const RESYNC_EVENTS = options.resyncEvents ?? [];
  const messages = { ...DEFAULT_MESSAGES, ...options.messages };
  let oauthExchangeCode: string | undefined;
  let oauthExchangePromise: Promise<HuggingFaceTokenRecord> | undefined;

  function storeTransaction(transaction: PkceTransaction): void {
    const serialized = JSON.stringify(transaction);
    sessionStorage.setItem(TRANSACTION_STORAGE, serialized);
    // sessionStorage is scoped to one tab; the temporary local copy lets the provider return
    // through a new tab (see openrouter-sign-in.ts's identical comment for the full rationale).
    localStorage.setItem(TRANSACTION_STORAGE, serialized);
  }

  function clearTransaction(): void {
    sessionStorage.removeItem(TRANSACTION_STORAGE);
    localStorage.removeItem(TRANSACTION_STORAGE);
  }

  function parseStoredTransaction(): Partial<PkceTransaction> | undefined {
    const raw = sessionStorage.getItem(TRANSACTION_STORAGE) || localStorage.getItem(TRANSACTION_STORAGE);
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

  /** The hash the page was on when sign-in began, read without consuming the transaction, so a
   * site's startup code can restore the originating route before complete() runs. */
  function peekReturnRoute(): string | undefined {
    const transaction = parseStoredTransaction();
    return typeof transaction?.returnRoute === 'string' ? transaction.returnRoute : undefined;
  }

  function readTransaction(state: string): PkceTransaction {
    const raw = sessionStorage.getItem(TRANSACTION_STORAGE) || localStorage.getItem(TRANSACTION_STORAGE);
    if (!raw) throw new Error(messages.noAttempt);
    let transaction: Partial<PkceTransaction>;
    try {
      transaction = JSON.parse(raw) as Partial<PkceTransaction>;
    } catch {
      clearTransaction();
      throw new Error(messages.noAttempt);
    }
    if (typeof transaction.verifier !== 'string' || !transaction.verifier || typeof transaction.state !== 'string' || !transaction.state) {
      clearTransaction();
      throw new Error(messages.noAttempt);
    }
    if (typeof transaction.createdAt !== 'number' || Date.now() - transaction.createdAt > PKCE_TTL_MS) {
      clearTransaction();
      throw new Error(messages.expired);
    }
    // Constant-time-ish comparison is unnecessary here: `state` is a nonce, not a secret, and both
    // values are already public (one came back on the URL). What matters is that they match exactly.
    if (transaction.state !== state) {
      clearTransaction();
      throw new Error(messages.stateMismatch);
    }
    return transaction as PkceTransaction;
  }

  function getStoredToken(): HuggingFaceTokenRecord | null {
    const raw = localStorage.getItem(TOKEN_STORAGE);
    if (!raw) return null;
    try {
      const record = JSON.parse(raw) as Partial<HuggingFaceTokenRecord>;
      if (typeof record.accessToken !== 'string' || !record.accessToken || typeof record.expiresAt !== 'number') return null;
      return { accessToken: record.accessToken, expiresAt: record.expiresAt, refreshToken: typeof record.refreshToken === 'string' ? record.refreshToken : undefined };
    } catch {
      return null;
    }
  }

  /** The stored token, or null when there is none OR it has expired without a usable refresh
   * token -- callers treat both as "not connected, sign in again" per the spec. Does not attempt
   * the refresh itself (that is async); see `refreshIfNeeded` below for the flow that does. */
  function getUsableStoredToken(): HuggingFaceTokenRecord | null {
    const token = getStoredToken();
    if (!token) return null;
    if (Date.now() < token.expiresAt) return token;
    return token.refreshToken ? token : null; // caller may still refresh; expired alone isn't "gone"
  }

  function storeToken(token: HuggingFaceTokenRecord): void {
    localStorage.setItem(TOKEN_STORAGE, JSON.stringify(token));
  }

  function clearToken(): void {
    localStorage.removeItem(TOKEN_STORAGE);
  }

  /** Starts sign-in in this tab, storing the PKCE verifier and a fresh state nonce, then navigates
   * to Hugging Face's authorize endpoint. */
  async function begin(): Promise<void> {
    const verifier = randomVerifier();
    const challenge = await challengeFor(verifier);
    const state = randomState();
    const returnRoute = window.location.hash || DEFAULT_RETURN_ROUTE;
    storeTransaction({ verifier, state, createdAt: Date.now(), returnRoute });
    const authUrl = new URL(AUTH_URL);
    authUrl.searchParams.set('client_id', options.clientId);
    authUrl.searchParams.set('redirect_uri', options.redirectUri);
    authUrl.searchParams.set('scope', SCOPES);
    authUrl.searchParams.set('response_type', 'code');
    authUrl.searchParams.set('state', state);
    authUrl.searchParams.set('code_challenge', challenge);
    authUrl.searchParams.set('code_challenge_method', 'S256');
    window.location.assign(authUrl.toString());
  }

  /** Exposed for tests: builds the same authorize URL `begin()` navigates to, without touching
   * storage or `window.location`. */
  async function buildAuthorizeUrl(state: string, challenge: string): Promise<string> {
    const authUrl = new URL(AUTH_URL);
    authUrl.searchParams.set('client_id', options.clientId);
    authUrl.searchParams.set('redirect_uri', options.redirectUri);
    authUrl.searchParams.set('scope', SCOPES);
    authUrl.searchParams.set('response_type', 'code');
    authUrl.searchParams.set('state', state);
    authUrl.searchParams.set('code_challenge', challenge);
    authUrl.searchParams.set('code_challenge_method', 'S256');
    return authUrl.toString();
  }

  async function exchangeToken(body: URLSearchParams, secrets: readonly string[] = []): Promise<HuggingFaceTokenRecord> {
    const response = await fetch(TOKEN_URL, {
      method: 'POST',
      redirect: 'error',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    });
    const payload = await response.json().catch(() => ({})) as {
      access_token?: string;
      expires_in?: number;
      refresh_token?: string;
      error_description?: string;
      error?: string;
    };
    if (!response.ok || !payload.access_token) {
      throw new Error(redactProviderSecrets(payload.error_description || payload.error || messages.exchangeFailed, secrets));
    }
    const expiresAt = Date.now() + (typeof payload.expires_in === 'number' ? payload.expires_in : 3600) * 1000;
    return { accessToken: payload.access_token, expiresAt, refreshToken: payload.refresh_token };
  }

  /** Verifies `state`, then exchanges `code` for a token at HF's token endpoint. Deduplicates
   * concurrent calls with the same code, exactly like OpenRouter's `complete`. */
  async function complete(code: string, state: string): Promise<HuggingFaceTokenRecord> {
    if (oauthExchangeCode === code && oauthExchangePromise) return oauthExchangePromise;
    oauthExchangeCode = code;
    oauthExchangePromise = (async () => {
      const transaction = readTransaction(state);
      const token = await exchangeToken(new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: options.redirectUri,
        client_id: options.clientId,
        code_verifier: transaction.verifier,
      }), [code, transaction.verifier]);
      clearTransaction();
      storeToken(token);
      return token;
    })();
    return oauthExchangePromise;
  }

  /** Exchanges a stored refresh token for a fresh access token at the same endpoint. Throws (and
   * clears the stored token) when there is nothing to refresh or the provider refuses it -- callers
   * treat that the same as "sign in again" (messages.tokenExpired). */
  async function refresh(): Promise<HuggingFaceTokenRecord> {
    const current = getStoredToken();
    if (!current?.refreshToken) {
      clearToken();
      throw new Error(messages.tokenExpired);
    }
    try {
      const token = await exchangeToken(new URLSearchParams({
        grant_type: 'refresh_token',
        refresh_token: current.refreshToken,
        client_id: options.clientId,
      }), [current.refreshToken]);
      storeToken(token);
      return token;
    } catch (error) {
      clearToken();
      throw error instanceof Error ? error : new Error(messages.tokenExpired);
    }
  }

  function broadcast(result: HuggingFaceOAuthResult): void {
    // The durable credential is the handoff. Messages carry only a notification, never the token.
    if (result.type === 'connected') storeToken(result.token);
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

  /** Subscribes every settings instance to the shared connection. Mirrors
   * openrouter-sign-in.ts's `listen` exactly (see that function's comment). */
  function listen(onResult: (result: HuggingFaceOAuthResult) => void): () => void {
    const teardown: Array<() => void> = [];
    let lastToken = getStoredToken()?.accessToken ?? '';
    const syncConnection = () => {
      const token = getStoredToken();
      const accessToken = token?.accessToken ?? '';
      if (accessToken === lastToken) return;
      lastToken = accessToken;
      onResult(token ? { type: 'connected', token } : { type: 'disconnected' });
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
      if (event.key === TOKEN_STORAGE || event.key === null) {
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
    refresh,
    peekReturnRoute,
    getStoredToken,
    getUsableStoredToken,
    storeToken,
    clearToken,
    broadcast,
    listen,
    /** Exposed so a site (or a test) can build/verify the authorize URL and PKCE machinery without a
     * real redirect. */
    storeTransaction,
    buildAuthorizeUrl,
    challengeFor,
  };
}

export type HuggingFaceSignIn = ReturnType<typeof createHuggingFaceSignIn>;
