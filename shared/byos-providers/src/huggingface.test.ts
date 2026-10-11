import assert from 'node:assert/strict';
import test from 'node:test';
// Built output: sources use NodeNext `.js` imports.
import { endpointFor, huggingface, createHuggingFaceSignIn, createOpenRouterSignIn } from '../dist/index.js';

type Call = { url: string; init?: RequestInit };
function fakeFetch(respond: (call: Call) => Response): Call[] {
  const calls: Call[] = [];
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const call = { url: String(url), init };
    calls.push(call);
    return respond(call);
  }) as typeof fetch;
  return calls;
}

/** Minimal in-memory Storage + crypto/BroadcastChannel stand-ins, since these tests run under
 * plain Node (node:test), not a browser or jsdom. */
function installBrowserGlobals(): void {
  class MemoryStorage {
    private store = new Map<string, string>();
    getItem(key: string): string | null { return this.store.has(key) ? this.store.get(key)! : null; }
    setItem(key: string, value: string): void { this.store.set(key, value); }
    removeItem(key: string): void { this.store.delete(key); }
    clear(): void { this.store.clear(); }
  }
  (globalThis as unknown as { sessionStorage: unknown }).sessionStorage = new MemoryStorage();
  (globalThis as unknown as { localStorage: unknown }).localStorage = new MemoryStorage();
  (globalThis as unknown as { window: unknown }).window = {
    location: { hash: '', origin: 'https://motive.example', pathname: '/', assign: () => {} },
    addEventListener: () => {},
    removeEventListener: () => {},
  };
}
installBrowserGlobals();

// Each call gets its own storage keys so tests sharing the module-level localStorage/sessionStorage
// stand-ins (installed once, above) never see another test's stored token or transaction.
let signInCounter = 0;
function makeSignIn() {
  const id = ++signInCounter;
  return createHuggingFaceSignIn({
    clientId: 'https://motive.example/.well-known/oauth-cimd',
    redirectUri: 'https://motive.example/oauth/callback/huggingface',
    tokenStorageKey: `test-hf-token-${id}`,
    transactionStorageKey: `test-hf-pkce-${id}`,
    handoffChannel: `test-hf-oauth-${id}`,
    handoffFallbackKey: `test-hf-oauth-handoff-${id}`,
  });
}

test('endpointFor: Hugging Face is OpenAI-compatible with no server-side search', () => {
  const endpoint = endpointFor('huggingface', 'hf_secret');
  assert.equal(endpoint.baseUrl, 'https://router.huggingface.co/v1');
  assert.equal(endpoint.apiKey, 'hf_secret');
  assert.equal(endpoint.webSearch, 'none');
});

test('huggingface(): PKCE sign-in is offered only with a clientId; paste-token is always there', () => {
  assert.deepEqual(huggingface().signIn.map(m => m.kind), ['api-key']);
  assert.deepEqual(huggingface({ clientId: 'id' }).signIn.map(m => m.kind), ['pkce', 'api-key']);
  assert.equal(huggingface({ clientId: 'id' }).signIn[0].handshakeViaSite, false);
});

test('huggingface() model discovery and streaming reuse the shared kit machinery', async () => {
  const calls = fakeFetch(() => new Response(JSON.stringify({ data: [{ id: 'meta-llama/x', name: 'Llama X' }] })));
  assert.deepEqual(await huggingface().listModels('hf_secret'), [{ id: 'meta-llama/x', name: 'Llama X' }]);
  assert.equal(calls[0].url, 'https://router.huggingface.co/v1/models');
  assert.equal((calls[0].init?.headers as Record<string, string>).Authorization, 'Bearer hf_secret');
  assert.equal(calls[0].init?.redirect, 'error');
});

test('authorize URL carries a fresh state and an S256 PKCE challenge', async () => {
  const signIn = makeSignIn();
  const verifier = 'a'.repeat(64);
  const challenge = await signIn.challengeFor(verifier);
  const url = new URL(await signIn.buildAuthorizeUrl('state-123', challenge));
  assert.equal(url.origin + url.pathname, 'https://huggingface.co/oauth/authorize');
  assert.equal(url.searchParams.get('client_id'), 'https://motive.example/.well-known/oauth-cimd');
  assert.equal(url.searchParams.get('redirect_uri'), 'https://motive.example/oauth/callback/huggingface');
  assert.equal(url.searchParams.get('response_type'), 'code');
  assert.equal(url.searchParams.get('state'), 'state-123');
  assert.equal(url.searchParams.get('code_challenge'), challenge);
  assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(url.searchParams.get('scope'), 'openid profile inference-api');
  // The challenge is a SHA-256 digest of the verifier, not the verifier itself.
  assert.notEqual(challenge, verifier);
});

test('complete() rejects a callback whose state does not match the stored transaction', async () => {
  const signIn = makeSignIn();
  await signIn.storeTransaction({ verifier: 'v'.repeat(64), state: 'expected-state', createdAt: Date.now(), returnRoute: '#explore' });
  await assert.rejects(
    () => signIn.complete('some-code', 'wrong-state'),
    (error: Error) => error.message.includes('could not be verified'),
  );
  // The mismatch clears the transaction so a retried callback can't reuse it either.
  assert.equal(sessionStorage.getItem('test-hf-pkce'), null);
});

test('complete() exchanges the code at HF\'s token endpoint using the stored verifier, and stores expiry', async () => {
  const signIn = makeSignIn();
  await signIn.storeTransaction({ verifier: 'the-verifier', state: 'good-state', createdAt: Date.now(), returnRoute: '#explore' });
  const calls = fakeFetch(() => new Response(JSON.stringify({ access_token: 'hf_new_token', expires_in: 3600, refresh_token: 'r1' })));
  const before = Date.now();
  const token = await signIn.complete('the-code', 'good-state');
  assert.equal(token.accessToken, 'hf_new_token');
  assert.equal(token.refreshToken, 'r1');
  assert.ok(token.expiresAt >= before + 3600 * 1000);
  assert.equal(calls[0].url, 'https://huggingface.co/oauth/token');
  assert.equal(calls[0].init?.redirect, 'error');
  assert.equal(calls[0].init?.headers && (calls[0].init.headers as Record<string, string>)['Content-Type'], 'application/x-www-form-urlencoded');
  const body = new URLSearchParams(String(calls[0].init?.body));
  assert.equal(body.get('grant_type'), 'authorization_code');
  assert.equal(body.get('code'), 'the-code');
  assert.equal(body.get('code_verifier'), 'the-verifier');
  assert.equal(body.get('client_id'), 'https://motive.example/.well-known/oauth-cimd');
  // The exchanged token is now the stored connection.
  assert.deepEqual(signIn.getStoredToken(), token);
});

test('refresh() uses the stored refresh_token and clears the connection when there is none to use', async () => {
  const signIn = makeSignIn();
  await assert.rejects(() => signIn.refresh(), (error: Error) => error.message.includes('Sign in again'));

  signIn.storeToken({ accessToken: 'stale', expiresAt: Date.now() - 1000, refreshToken: 'r1' });
  fakeFetch(() => new Response(JSON.stringify({ access_token: 'fresh', expires_in: 60 })));
  const refreshed = await signIn.refresh();
  assert.equal(refreshed.accessToken, 'fresh');
  assert.equal(signIn.getStoredToken()?.accessToken, 'fresh');
});

test('Hugging Face OAuth errors redact code and refresh token', async () => {
  const signIn = makeSignIn();
  await signIn.storeTransaction({ verifier: 'the-verifier', state: 'state', createdAt: Date.now(), returnRoute: '' });
  let calls = fakeFetch(() => new Response(JSON.stringify({ error_description: 'Rejected the-code the-verifier' }), { status: 400 }));
  await assert.rejects(() => signIn.complete('the-code', 'state'), error => {
    assert.ok(!String(error).includes('the-code'));
    assert.ok(!String(error).includes('the-verifier'));
    assert.match(String(error), /\[redacted\]/);
    return true;
  });
  assert.equal(calls[0].init?.redirect, 'error');

  signIn.storeToken({ accessToken: 'access', expiresAt: Date.now() - 1, refreshToken: 'secret-refresh' });
  calls = fakeFetch(() => new Response(JSON.stringify({ error_description: 'Rejected secret-refresh' }), { status: 400 }));
  await assert.rejects(() => signIn.refresh(), error => {
    assert.ok(!String(error).includes('secret-refresh'));
    assert.match(String(error), /\[redacted\]/);
    return true;
  });
  assert.equal(calls[0].init?.redirect, 'error');
});

test('OpenRouter PKCE exchange rejects redirects and redacts code and verifier errors', async () => {
  const id = ++signInCounter;
  const transactionKey = `test-openrouter-pkce-${id}`;
  const code = 'synthetic-code';
  const verifier = 'synthetic-verifier';
  sessionStorage.setItem(transactionKey, JSON.stringify({ verifier, createdAt: Date.now(), returnRoute: '' }));
  const signIn = createOpenRouterSignIn({
    keyStorageKey: `test-openrouter-key-${id}`,
    transactionStorageKey: transactionKey,
    handoffChannel: `test-openrouter-channel-${id}`,
    handoffFallbackKey: `test-openrouter-fallback-${id}`,
  });
  const calls = fakeFetch(() => new Response(JSON.stringify({ error: { message: 'Rejected synthetic-code synthetic-verifier' } }), { status: 400 }));
  await assert.rejects(() => signIn.complete(code), error => {
    assert.ok(!String(error).includes(code));
    assert.ok(!String(error).includes(verifier));
    assert.match(String(error), /\[redacted\]/);
    return true;
  });
  assert.equal(calls[0].init?.redirect, 'error');
});


function openRouterFixture(credentialPersistence?: 'browser' | 'session') {
  const id = ++signInCounter;
  const key = `test-or-key-${id}`;
  const transaction = `test-or-transaction-${id}`;
  return { key, transaction, flow: createOpenRouterSignIn({
    keyStorageKey: key, transactionStorageKey: transaction,
    handoffChannel: `test-or-channel-${id}`, handoffFallbackKey: `test-or-fallback-${id}`,
    credentialPersistence,
  }) };
}

test('OpenRouter session exchange keeps its credential out of localStorage', async () => {
  const { key, transaction, flow } = openRouterFixture('session');
  flow.storePkceTransaction({ verifier: 'fake-verifier', createdAt: Date.now(), returnRoute: '#research' });
  const originalFetch = globalThis.fetch;
  try {
    const calls = fakeFetch(() => new Response(JSON.stringify({ key: 'fake-session-key' })));
    assert.equal(await flow.complete('fake-code'), 'fake-session-key');
    assert.equal(calls.length, 1);
    assert.equal(sessionStorage.getItem(key), 'fake-session-key');
    assert.equal(localStorage.getItem(key), null);
    assert.equal(sessionStorage.getItem(transaction), null);
    assert.equal(localStorage.getItem(transaction), null);
    flow.clearKey();
    assert.equal(flow.getStoredKey(), '');
    assert.equal(sessionStorage.getItem(key), null);
    assert.equal(localStorage.getItem(key), null);
  } finally { globalThis.fetch = originalFetch; }
});

test('OpenRouter session mode migrates legacy keys and preserves current tab selection', () => {
  const { key, flow } = openRouterFixture('session');
  localStorage.setItem(key, 'fake-legacy-key');
  assert.equal(flow.getStoredKey(), 'fake-legacy-key');
  assert.equal(sessionStorage.getItem(key), 'fake-legacy-key');
  assert.equal(localStorage.getItem(key), null);
  localStorage.setItem(key, 'fake-other-tab-key');
  assert.equal(flow.getStoredKey(), 'fake-legacy-key');
  assert.equal(localStorage.getItem(key), null);
  flow.storeKey('fake-replacement');
  assert.equal(sessionStorage.getItem(key), 'fake-replacement');
  assert.equal(localStorage.getItem(key), null);
  flow.clearKey();
  assert.equal(flow.getStoredKey(), '');
});

test('OpenRouter default mode retains browser persistence and disconnect tombstones', () => {
  const { key, flow } = openRouterFixture();
  sessionStorage.setItem(key, 'fake-session-legacy');
  assert.equal(flow.getStoredKey(), 'fake-session-legacy');
  assert.equal(localStorage.getItem(key), 'fake-session-legacy');
  assert.equal(sessionStorage.getItem(key), null);
  flow.clearKey();
  sessionStorage.setItem(key, 'fake-stale-tab');
  assert.equal(flow.getStoredKey(), '');
  assert.equal(localStorage.getItem(key), '');
  assert.equal(sessionStorage.getItem(key), null);
});
