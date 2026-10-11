import assert from 'node:assert/strict';
import test from 'node:test';
import type { CatalogModel, ChatEvent, ChatRequest, ProviderAvailability } from '@byos/core';
import {
  ON_DEVICE_PROVIDERS,
  createOnDeviceProvider,
  onDeviceProvidersFor,
  type OnDeviceBridge,
  type OnDeviceProviderId,
  type OnDeviceRuntime,
} from './on-device.ts';

const native = (supportedProviders: readonly OnDeviceProviderId[] = ['local', 'mlx', 'foundation-models']): OnDeviceRuntime => ({
  kind: 'native',
  supportedProviders,
});

function bridge(overrides: Partial<OnDeviceBridge> = {}): OnDeviceBridge {
  return {
    availability: () => ({ available: true }),
    listModels: async () => [{ id: 'tiny-local', name: 'Tiny local model' }],
    stream: async function* () { yield { type: 'text', text: 'local answer' }; yield { type: 'done' }; },
    ...overrides,
  };
}

const request: ChatRequest = { model: 'tiny-local', messages: [{ role: 'user', content: 'hello' }] };

test('catalog metadata matches Skim labels and is exposed only to native runtimes that opt in', () => {
  assert.deepEqual(ON_DEVICE_PROVIDERS.map(provider => provider.id), ['local', 'mlx', 'foundation-models']);
  assert.ok(ON_DEVICE_PROVIDERS.every(provider => provider.execution === 'on-device'));
  assert.match(ON_DEVICE_PROVIDERS.find(provider => provider.id === 'local')!.description, /llama\.cpp/);
  assert.match(ON_DEVICE_PROVIDERS.find(provider => provider.id === 'mlx')!.description, /offline.*iOS\/macOS/i);
  assert.match(ON_DEVICE_PROVIDERS.find(provider => provider.id === 'foundation-models')!.description, /Apple.*26\+/);
  assert.deepEqual(onDeviceProvidersFor(native(['mlx'])).map(provider => provider.id), ['mlx']);
  assert.deepEqual(onDeviceProvidersFor({ kind: 'browser', supportedProviders: ['local'] }), []);
  assert.deepEqual(onDeviceProvidersFor({ kind: 'server', supportedProviders: ['mlx'] }), []);
});

test('browser and server runtimes cannot dispatch even when a bridge is injected', async () => {
  let calls = 0;
  const injected = bridge({
    availability: () => { calls++; return { available: true }; },
    listModels: async () => { calls++; return []; },
    stream: async function* () { calls++; yield { type: 'done' }; },
  });
  for (const kind of ['browser', 'server'] as const) {
    const provider = createOnDeviceProvider('mlx', { runtime: { kind, supportedProviders: ['mlx'] }, bridge: injected });
    assert.deepEqual(provider.availability(), { available: false, reason: 'This provider requires a native on-device runtime.' });
    await assert.rejects(provider.listModels(), /native on-device runtime/);
    await assert.rejects(async () => { for await (const _event of provider.stream(request)) { /* consume */ } }, /native on-device runtime/);
  }
  assert.equal(calls, 0);
});

test('unsupported bindings and missing bridges cannot dispatch', async () => {
  let calls = 0;
  const injected = bridge({
    availability: () => { calls++; return { available: true }; },
    listModels: async () => { calls++; return []; },
    stream: async function* () { calls++; yield { type: 'done' }; },
  });
  const unsupported = createOnDeviceProvider('mlx', { runtime: native(['local']), bridge: injected });
  await assert.rejects(unsupported.listModels(), /does not support this provider/);
  await assert.rejects(async () => { for await (const _event of unsupported.stream(request)) { /* consume */ } }, /does not support this provider/);
  const noBridge = createOnDeviceProvider('mlx', { runtime: native(['mlx']) });
  await assert.rejects(noBridge.listModels(), /not connected/);
  await assert.rejects(async () => { for await (const _event of noBridge.stream(request)) { /* consume */ } }, /not connected/);
  assert.equal(calls, 0);
});

test('unavailable native bridge reason is passed through as host-provided user copy', async () => {
  const reason = 'Apple Intelligence is off';
  const provider = createOnDeviceProvider('foundation-models', {
    runtime: native(['foundation-models']),
    bridge: bridge({ availability: () => ({ available: false, reason }) }),
  });
  assert.deepEqual(provider.availability(), { available: false, reason });
  await assert.rejects(provider.listModels(), new RegExp(reason));
  await assert.rejects(async () => { for await (const _event of provider.stream(request)) { /* consume */ } }, new RegExp(reason));
});

test('models and events flow through a live bridge without a credential argument', async () => {
  const models: CatalogModel[] = [{ id: 'host-model', name: 'Host model' }];
  const events: ChatEvent[] = [{ type: 'text', text: 'from device' }, { type: 'done' }];
  let modelSignal: AbortSignal | undefined;
  let receivedRequest: ChatRequest | undefined;
  const provider = createOnDeviceProvider('local', {
    runtime: native(['local']),
    bridge: bridge({
      listModels: async signal => { modelSignal = signal; return models; },
      stream: async function* (incoming) { receivedRequest = incoming; yield* events; },
    }),
  });
  const controller = new AbortController();
  assert.deepEqual(provider.signIn, []);
  assert.deepEqual(await provider.listModels(controller.signal), models);
  assert.equal(modelSignal, controller.signal);
  const actual: ChatEvent[] = [];
  for await (const event of provider.stream(request)) actual.push(event);
  assert.deepEqual(actual, events);
  assert.equal(receivedRequest, request);
  assert.equal('token' in provider, false);
});

test('aborted discovery does not dispatch; streaming preserves the signal and cleans up on abort', async () => {
  let modelCalls = 0;
  const aborted = new AbortController();
  aborted.abort();
  const provider = createOnDeviceProvider('mlx', {
    runtime: native(['mlx']),
    bridge: bridge({ listModels: async () => { modelCalls++; return []; } }),
  });
  await assert.rejects(provider.listModels(aborted.signal), { name: 'AbortError' });
  assert.equal(modelCalls, 0);

  let streamCalls = 0;
  const alreadyAbortedStream = createOnDeviceProvider('mlx', {
    runtime: native(['mlx']),
    bridge: bridge({ stream: async function* () { streamCalls++; yield { type: 'done' }; } }),
  });
  await assert.rejects(async () => {
    for await (const _event of alreadyAbortedStream.stream({ ...request, signal: aborted.signal })) { /* consume */ }
  }, { name: 'AbortError' });
  assert.equal(streamCalls, 0);

  const streamController = new AbortController();
  let receivedSignal: AbortSignal | undefined;
  let cleanupCount = 0;
  const streaming = createOnDeviceProvider('mlx', {
    runtime: native(['mlx']),
    bridge: bridge({
      stream: incoming => {
        receivedSignal = incoming.signal;
        const iterator: AsyncIterator<ChatEvent> = {
          next: () => new Promise<IteratorResult<ChatEvent>>(() => {}),
          return: async () => { cleanupCount++; return { done: true, value: undefined }; },
        };
        return { [Symbol.asyncIterator]: () => iterator };
      },
    }),
  });
  const iterator = streaming.stream({ ...request, signal: streamController.signal })[Symbol.asyncIterator]();
  const pending = iterator.next();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(receivedSignal, streamController.signal);
  streamController.abort();
  await assert.rejects(pending, { name: 'AbortError' });
  assert.equal(cleanupCount, 1);
});

test('bridge readiness is rechecked before each dispatch', async () => {
  let ready = true;
  let modelCalls = 0;
  const provider = createOnDeviceProvider('local', {
    runtime: native(['local']),
    bridge: bridge({
      availability: (): ProviderAvailability => ready ? { available: true } : { available: false, reason: 'The model is preparing' },
      listModels: async () => { modelCalls++; return []; },
    }),
  });
  await provider.listModels();
  ready = false;
  assert.deepEqual(provider.availability(), { available: false, reason: 'The model is preparing' });
  await assert.rejects(provider.listModels(), /model is preparing/);
  assert.equal(modelCalls, 1);
});

test('consumer early exit closes the host iterator', async () => {
  let cleanupCount = 0;
  const provider = createOnDeviceProvider('local', {
    runtime: native(['local']),
    bridge: bridge({
      stream: async function* () {
        try { yield { type: 'text', text: 'one' }; yield { type: 'text', text: 'two' }; }
        finally { cleanupCount++; }
      },
    }),
  });
  for await (const _event of provider.stream(request)) break;
  assert.equal(cleanupCount, 1);
});

test('host exceptions are sanitized while AbortError remains recognizable', async () => {
  const secret = 'raw native failure with private details';
  const provider = createOnDeviceProvider('local', {
    runtime: native(['local']),
    bridge: bridge({
      availability: () => { throw new Error(secret); },
      listModels: async () => { throw new Error(secret); },
    }),
  });
  assert.deepEqual(provider.availability(), { available: false, reason: 'The on-device provider is unavailable.' });
  await assert.rejects(provider.listModels(), error => error instanceof Error && error.message === 'The on-device provider is unavailable.' && !error.message.includes(secret));

  const lateFailures = createOnDeviceProvider('local', {
    runtime: native(['local']),
    bridge: bridge({
      listModels: async () => { throw new Error(secret); },
      stream: async function* () { throw new Error(secret); },
    }),
  });
  await assert.rejects(lateFailures.listModels(), error => error instanceof Error && error.message === 'The on-device provider is unavailable.' && !error.message.includes(secret));
  await assert.rejects(async () => {
    for await (const _event of lateFailures.stream(request)) { /* consume */ }
  }, error => error instanceof Error && error.message === 'The on-device provider is unavailable.' && !error.message.includes(secret));

  const aborting = createOnDeviceProvider('local', {
    runtime: native(['local']),
    bridge: bridge({ listModels: async () => { throw new DOMException(secret, 'AbortError'); } }),
  });
  await assert.rejects(aborting.listModels(), error => error instanceof Error && error.name === 'AbortError' && error.message === 'The operation was aborted.');
});

test('synchronous abort during host stream construction closes iterator without leaking an unhandled abort race', async () => {
  const controller = new AbortController();
  let cleanupCount = 0;
  const provider = createOnDeviceProvider('local', {
    runtime: native(['local']),
    bridge: bridge({
      stream: () => {
        controller.abort();
        const iterator: AsyncIterator<ChatEvent> = {
          next: async () => ({ done: false, value: { type: 'done' } }),
          return: async () => { cleanupCount++; return { done: true, value: undefined }; },
        };
        return { [Symbol.asyncIterator]: () => iterator };
      },
    }),
  });
  await assert.rejects(async () => {
    for await (const _event of provider.stream({ ...request, signal: controller.signal })) { /* consume */ }
  }, { name: 'AbortError', message: 'The operation was aborted.' });
  assert.equal(cleanupCount, 1);
});
