import type { CatalogModel, ChatEvent, ChatRequest, ProviderAvailability } from '@byos/core';

export type OnDeviceProviderId = 'local' | 'mlx' | 'foundation-models';

export type OnDeviceProviderMetadata = {
  readonly id: OnDeviceProviderId;
  readonly displayName: string;
  readonly description: string;
  readonly execution: 'on-device';
};

/** Native runtimes opt in to each provider they can actually execute. */
export type OnDeviceRuntime = {
  readonly kind: 'native' | 'browser' | 'server';
  readonly supportedProviders: readonly OnDeviceProviderId[];
};

/** Host-owned inference, model management, and async hardware probes stay behind this bridge. */
export interface OnDeviceBridge {
  availability(): ProviderAvailability;
  listModels(signal?: AbortSignal): Promise<CatalogModel[]>;
  stream(request: ChatRequest): AsyncIterable<ChatEvent>;
}

/** Credential-free provider API, deliberately distinct from token-based ByosProvider. */
export interface OnDeviceProvider {
  readonly id: OnDeviceProviderId;
  readonly displayName: string;
  readonly signIn: readonly [];
  availability(): ProviderAvailability;
  listModels(signal?: AbortSignal): Promise<CatalogModel[]>;
  stream(request: ChatRequest): AsyncIterable<ChatEvent>;
}

export const ON_DEVICE_PROVIDERS: readonly OnDeviceProviderMetadata[] = [
  {
    id: 'local',
    displayName: 'Local (Embedded)',
    description: 'Run AI locally with llama.cpp — no server needed',
    execution: 'on-device',
  },
  {
    id: 'mlx',
    displayName: 'On-device (MLX)',
    description: 'Run a downloaded MLX model on-device. Offline. iOS/macOS only.',
    execution: 'on-device',
  },
  {
    id: 'foundation-models',
    displayName: 'Apple Intelligence',
    description: "Apple's on-device model. Requires macOS 26+ or iOS 26+ on Apple Intelligence hardware.",
    execution: 'on-device',
  },
] as const;

const RUNTIME_UNAVAILABLE = 'This provider requires a native on-device runtime.';
const BINDING_UNAVAILABLE = 'This native runtime does not support this provider.';
const BRIDGE_UNAVAILABLE = 'The native provider is not connected.';
const PROVIDER_UNAVAILABLE = 'The on-device provider is unavailable.';
const ABORTED = 'The operation was aborted.';

function isAbortError(error: unknown): boolean {
  try {
    return typeof error === 'object' && error !== null && 'name' in error && error.name === 'AbortError';
  } catch {
    return false;
  }
}

function abortError(): DOMException {
  return new DOMException(ABORTED, 'AbortError');
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw abortError();
}

function safeBridgeCall<T>(operation: () => T): T {
  try {
    return operation();
  } catch (error) {
    if (isAbortError(error)) throw error;
    throw new Error(PROVIDER_UNAVAILABLE);
  }
}

function safeBridgePromise<T>(operation: () => Promise<T>): Promise<T> {
  try {
    return operation().catch(error => {
      if (isAbortError(error)) throw abortError();
      throw new Error(PROVIDER_UNAVAILABLE);
    });
  } catch (error) {
    if (isAbortError(error)) throw abortError();
    throw new Error(PROVIDER_UNAVAILABLE);
  }
}

function bridgeReadiness(bridge?: OnDeviceBridge): ProviderAvailability {
  if (!bridge) return { available: false, reason: BRIDGE_UNAVAILABLE };
  try {
    return safeBridgeCall(() => bridge.availability());
  } catch {
    return { available: false, reason: PROVIDER_UNAVAILABLE };
  }
}

function makeAbortRace(signal?: AbortSignal): { promise: Promise<never>; cancel(): void } | undefined {
  if (!signal) return undefined;
  let rejectAbort!: (error: DOMException) => void;
  const promise = new Promise<never>((_resolve, reject) => { rejectAbort = reject; });
  // The host may synchronously abort during stream construction, before a race is installed.
  // Keep that rejection handled until the generator observes the aborted signal.
  void promise.catch(() => {});
  const onAbort = () => rejectAbort(abortError());
  signal.addEventListener('abort', onAbort, { once: true });
  if (signal.aborted) onAbort();
  return { promise, cancel: () => signal.removeEventListener('abort', onAbort) };
}

async function* guardedStream(
  request: ChatRequest,
  availability: () => ProviderAvailability,
  requireReady: (signal?: AbortSignal) => OnDeviceBridge,
): AsyncGenerator<ChatEvent> {
  const signal = request.signal;
  throwIfAborted(signal);
  const ready = availability();
  if (!ready.available) throw new Error(ready.reason);

  let iterator: AsyncIterator<ChatEvent> | undefined;
  let returned = false;
  const returnIterator = async (wait: boolean) => {
    if (returned || !iterator?.return) return;
    returned = true;
    try {
      const closing = Promise.resolve(iterator.return());
      if (wait) await closing;
      else void closing.catch(() => {});
    } catch {
      // Cleanup errors are not useful to expose to the consumer.
    }
  };
  const abortRace = makeAbortRace(signal);
  let wasAborted = false;
  try {
    throwIfAborted(signal);
    const liveBridge = requireReady(signal);
    const source = safeBridgeCall(() => liveBridge.stream(request));
    iterator = source[Symbol.asyncIterator]();
    throwIfAborted(signal);
    while (true) {
      throwIfAborted(signal);
      const next = safeBridgePromise(() => Promise.resolve(iterator!.next()));
      const result = abortRace ? await Promise.race([next, abortRace.promise]) : await next;
      if (result.done) return;
      yield result.value;
    }
  } catch (error) {
    if (isAbortError(error)) {
      wasAborted = true;
      await returnIterator(false);
      throw abortError();
    }
    throw new Error(PROVIDER_UNAVAILABLE);
  } finally {
    abortRace?.cancel();
    await returnIterator(!wasAborted);
  }
}

/** Return native-only providers advertised by a runtime with explicit per-provider support. */
export function onDeviceProvidersFor(runtime: OnDeviceRuntime): OnDeviceProviderMetadata[] {
  if (runtime.kind !== 'native') return [];
  return ON_DEVICE_PROVIDERS.filter(provider => runtime.supportedProviders.includes(provider.id));
}

/** Bind a native provider to the host bridge without introducing a token or network fallback. */
export function createOnDeviceProvider(
  id: OnDeviceProviderId,
  options: { runtime: OnDeviceRuntime; bridge?: OnDeviceBridge },
): OnDeviceProvider {
  const metadata = ON_DEVICE_PROVIDERS.find(provider => provider.id === id)!;
  const runtimeSupported = options.runtime.kind === 'native'
    && options.runtime.supportedProviders.includes(id);
  const availability = (): ProviderAvailability => {
    if (options.runtime.kind !== 'native') return { available: false, reason: RUNTIME_UNAVAILABLE };
    if (!runtimeSupported) return { available: false, reason: BINDING_UNAVAILABLE };
    return bridgeReadiness(options.bridge);
  };
  const requireReady = (signal?: AbortSignal): OnDeviceBridge => {
    throwIfAborted(signal);
    const state = availability();
    if (!state.available) throw new Error(state.reason);
    return options.bridge!;
  };

  return {
    id,
    displayName: metadata.displayName,
    signIn: [],
    availability,
    async listModels(signal?: AbortSignal): Promise<CatalogModel[]> {
      const bridge = requireReady(signal);
      throwIfAborted(signal);
      return safeBridgePromise(() => bridge.listModels(signal));
    },
    stream(request: ChatRequest): AsyncIterable<ChatEvent> {
      return guardedStream(request, availability, requireReady);
    },
  };
}
