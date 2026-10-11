import { requireStoragePrefix, resolveStorage, safeGet, safeRemove, safeSet, type ByosStorage } from './storage.js';

/** Reasoning controls accepted by the providers that expose them. */
export type ReasoningEffort = 'none' | 'minimal' | 'low' | 'medium' | 'high' | 'xhigh' | 'max' | 'ultra';
export type EffortOption = { effort: ReasoningEffort; description?: string };

export interface EffortModel {
  id: string;
  reasoningEfforts?: EffortOption[];
  defaultReasoningEffort?: ReasoningEffort;
}

const VALID_EFFORTS = new Set<ReasoningEffort>([
  'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra',
]);

export function isReasoningEffort(value: unknown): value is ReasoningEffort {
  return typeof value === 'string' && VALID_EFFORTS.has(value as ReasoningEffort);
}

function supportedEfforts(model: EffortModel): ReasoningEffort[] {
  return Array.isArray(model.reasoningEfforts)
    ? model.reasoningEfforts.map(option => option.effort).filter(isReasoningEffort)
    : [];
}

/** The currently valid choices for a picker; unknown or capability-free models expose provider default only. */
export function reasoningEffortOptions(model: EffortModel): EffortOption[] {
  return Array.isArray(model.reasoningEfforts)
    ? model.reasoningEfforts.filter(option => isReasoningEffort(option.effort))
    : [];
}

export type EffortStoreOptions = {
  /** Storage key prefix, e.g. `motive-ai-effort:`. One per site. */
  prefix: string;
  /** Site or provider-adapter recommendation, used when nothing is saved. */
  recommend?: (provider: string, modelId: string) => ReasoningEffort | undefined;
  storage?: ByosStorage;
};

export type EffortStore = ReturnType<typeof createEffortStore>;

/**
 * Remembers the user's effort choice per provider and model. Kept in localStorage (an effort level
 * is not a secret) so a new tab keeps it; the sessionStorage copy is the fallback for choices saved
 * before that. A saved value is only honoured while the provider still lists it for that model.
 */
export function createEffortStore(options: EffortStoreOptions) {
  const prefix = requireStoragePrefix(options.prefix);
  const key = (provider: string, model: string) => `${prefix}${provider}:${model}`;
  const storage = () => resolveStorage(options.storage);

  function read(provider: string, model: EffortModel): ReasoningEffort | undefined {
    const { local, session } = storage();
    const saved = safeGet(local, key(provider, model.id)) || safeGet(session, key(provider, model.id));
    return isReasoningEffort(saved) && supportedEfforts(model).includes(saved) ? saved : undefined;
  }

  function store(provider: string, model: string, effort: ReasoningEffort): void {
    const { local, session } = storage();
    safeSet(local, key(provider, model), effort);
    safeSet(session, key(provider, model), effort);
  }

  function clear(provider: string, model: string): void {
    const { local, session } = storage();
    safeRemove(local, key(provider, model));
    safeRemove(session, key(provider, model));
  }

  /** A saved valid choice wins, then the recommendation, then the provider's own default. Empty
   * means the provider should apply its own default, the safe answer for unknown capabilities. */
  function resolve(provider: string, model: EffortModel): ReasoningEffort | '' {
    const supported = supportedEfforts(model);
    const saved = read(provider, model);
    if (saved) return saved;
    const recommendation = options.recommend?.(provider, model.id);
    if (recommendation && supported.includes(recommendation)) return recommendation;
    if (model.defaultReasoningEffort && supported.includes(model.defaultReasoningEffort)) return model.defaultReasoningEffort;
    return '';
  }

  return { key, read, store, clear, resolve };
}
