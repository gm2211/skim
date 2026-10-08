import assert from 'node:assert/strict';
import test from 'node:test';
// Built output: the sources use NodeNext `.js` imports (see shared/ai-protocol/src/index.test.ts).
import { createCredentialVault, createEffortStore, createModelCatalogCache, pickerModels, tokenNeedsRefresh } from '../dist/index.js';

class MemoryStorage implements Storage {
  private data = new Map<string, string>();
  failWrites = false;
  get length() { return this.data.size; }
  clear() { this.data.clear(); }
  getItem(key: string) { return this.data.has(key) ? this.data.get(key)! : null; }
  key(index: number) { return [...this.data.keys()][index] ?? null; }
  removeItem(key: string) { this.data.delete(key); }
  setItem(key: string, value: string) { if (this.failWrites) throw new Error('quota'); this.data.set(key, String(value)); }
}

const areas = () => ({ session: new MemoryStorage(), local: new MemoryStorage() });

test('vault keeps Motive-compatible keys and separates sites by prefix', () => {
  const storage = areas();
  const motive = createCredentialVault({ prefix: 'motive-ai-credential:', storage });
  const other = createCredentialVault({ prefix: 'garden-ai-credential:', storage });
  motive.store('xai-oauth', ' tok ', 'browser');
  assert.equal(storage.local.getItem('motive-ai-credential:xai-oauth'), 'tok');
  assert.equal(motive.read('xai-oauth'), 'tok');
  assert.equal(motive.persistence('xai-oauth'), 'browser');
  assert.equal(other.read('xai-oauth'), '');
});

test('storage-backed helpers reject unscoped prefixes', () => {
  assert.throws(() => createCredentialVault({ prefix: '', storage: areas() }), /Storage prefix/);
  assert.throws(() => createEffortStore({ prefix: ' ', storage: areas() }), /Storage prefix/);
  assert.throws(() => createModelCatalogCache({ prefix: 'x'.repeat(129), storage: areas() }), /Storage prefix/);
});

test('session-only sign-in works when localStorage is unavailable', () => {
  const session = new MemoryStorage();
  const vault = createCredentialVault({ prefix: 'session-only:', storage: { session } });
  vault.store('provider', 'token', 'session');
  vault.storeRefresh('provider', { refreshToken: 'refresh' }, 'session');
  assert.equal(vault.read('provider'), 'token');
  assert.equal(vault.persistence('provider'), 'session');
  assert.deepEqual(vault.readRefresh('provider'), { refreshToken: 'refresh', expiresAt: undefined });
  vault.setPersistence('provider', 'session');
  assert.throws(() => vault.store('provider', 'token', 'browser'), /storage is unavailable/);
  vault.clear('provider');
  assert.equal(vault.read('provider'), '');
  assert.equal(vault.readRefresh('provider'), null);
});

test('clearing a sign-in also forgets its refresh grant', () => {
  const vault = createCredentialVault({ prefix: 'p:', storage: areas() });
  vault.store('codex', 'a', 'session');
  vault.storeRefresh('codex', { refreshToken: 'r', expiresAt: 5 }, 'session');
  assert.deepEqual(vault.readRefresh('codex'), { refreshToken: 'r', expiresAt: 5 });
  vault.clear('codex');
  assert.equal(vault.read('codex'), '');
  assert.equal(vault.readRefresh('codex'), null);
});

test('replacing a sign-in removes its previous refresh grant and preserves old state on write failure', () => {
  const storage = areas();
  const vault = createCredentialVault({ prefix: 'p:', storage });
  vault.store('codex', 'old-account', 'session');
  vault.storeRefresh('codex', { refreshToken: 'old-refresh', expiresAt: 1 }, 'session');

  storage.local.failWrites = true;
  assert.throws(() => vault.store('codex', 'new-account', 'browser'), /quota/);
  assert.equal(vault.read('codex'), 'old-account');
  assert.deepEqual(vault.readRefresh('codex'), { refreshToken: 'old-refresh', expiresAt: 1 });

  storage.local.failWrites = false;
  vault.store('codex', 'new-account', 'browser');
  assert.equal(vault.read('codex'), 'new-account');
  assert.equal(vault.readRefresh('codex'), null);
  assert.equal(storage.session.getItem('p:codex'), null);
});

test('moving persistence carries the grant and rolls back when storage refuses', () => {
  const storage = areas();
  const vault = createCredentialVault({ prefix: 'p:', storage });
  vault.store('codex', 'a', 'session');
  vault.storeRefresh('codex', { refreshToken: 'r' }, 'session');
  vault.setPersistence('codex', 'browser');
  assert.equal(storage.local.getItem('p:codex'), 'a');
  assert.equal(storage.session.getItem('p:codex'), null);
  assert.ok(storage.local.getItem('p:codex:refresh'));

  storage.session.failWrites = true;
  assert.throws(() => vault.setPersistence('codex', 'session'));
  assert.equal(vault.read('codex'), 'a');
  assert.equal(vault.persistence('codex'), 'browser');
});

test('effort: saved choice only while supported, then recommendation, then provider default', () => {
  const store = createEffortStore({ prefix: 'e:', storage: areas(), recommend: (p, m) => (p === 'codex' && m === 'luna' ? 'max' : undefined) });
  const luna = { id: 'luna', reasoningEfforts: [{ effort: 'low' as const }, { effort: 'max' as const }], defaultReasoningEffort: 'low' as const };
  assert.equal(store.resolve('codex', luna), 'max');
  assert.equal(store.resolve('other', luna), 'low');
  store.store('codex', 'luna', 'low');
  assert.equal(store.resolve('codex', luna), 'low');
  store.store('codex', 'luna', 'ultra');
  assert.equal(store.resolve('codex', luna), 'max');
  assert.equal(store.resolve('codex', { id: 'x' }), '');
});

test('model cache drops junk ids and a stale list keeps the user selection', () => {
  const storage = areas();
  const cache = createModelCatalogCache({ prefix: 'm:', storage });
  assert.equal(cache.read('xai'), undefined);
  cache.store('xai', [{ id: 'grok-4', name: 'Grok 4' }]);
  storage.local.setItem('m:bad', JSON.stringify([{ id: 'has space' }, { id: 'ok' }]));
  assert.deepEqual(cache.read('xai'), [{ id: 'grok-4', name: 'Grok 4' }]);
  assert.deepEqual(cache.read('bad'), [{ id: 'ok', name: 'ok' }]);
  const models = [{ id: 'a', name: 'A' }];
  assert.deepEqual(pickerModels(models, 'gone', true), models);
  assert.deepEqual(pickerModels(models, 'kept', false).map(m => m.id), ['a', 'kept']);
});

test('refresh window matches the providers', () => {
  assert.equal(tokenNeedsRefresh(undefined, 1000, 0), false);
  assert.equal(tokenNeedsRefresh(1500, 1000, 600), true);
  assert.equal(tokenNeedsRefresh(5000, 1000, 600), false);
});
