import { isReasoningEffort, type EffortOption, type ReasoningEffort } from './effort.js';
import { requireStoragePrefix, resolveStorage, safeGet, safeSet, type ByosStorage } from './storage.js';

/**
 * A provider's model list as the picker shows it. Lists always come from the provider; this cache
 * only remembers the last live answer (public model ids, not a secret, so localStorage) so a failed
 * discovery call does not silently swap the user's model for a hard-coded one.
 */
export type CatalogModel = {
  id: string;
  name: string;
  recommended?: boolean;
  hidden?: boolean;
  reasoningEfforts?: EffortOption[];
  defaultReasoningEffort?: ReasoningEffort;
};

/** A ceiling on what gets written back, so a provider that returns hundreds of ids cannot grow
 * localStorage without bound. */
const MAX_CACHED_MODELS = 120;

/** Ids are echoed into request bodies, so anything not shaped like an id is dropped. */
export function isUsableModelId(id: unknown): id is string {
  return typeof id === 'string' && id.trim().length > 0 && id.length <= 128 && !/\s/.test(id);
}

/** Everything that can be wrong with a stored catalog degrades to `undefined` ("nothing
 * remembered"), never to an empty catalog. */
export function parseModelCatalog(raw: string | null): CatalogModel[] | undefined {
  if (!raw) return undefined;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return undefined;
  }
  if (!Array.isArray(parsed)) return undefined;
  const models = parsed
    .filter((entry): entry is { id: string } => Boolean(entry) && typeof entry === 'object' && isUsableModelId((entry as { id?: unknown }).id))
    .map(entry => {
      const row = entry as Record<string, unknown> & { id: string };
      const model: CatalogModel = { id: row.id, name: typeof row.name === 'string' && row.name ? row.name : row.id };
      if (row.hidden === true) model.hidden = true;
      if (Array.isArray(row.reasoningEfforts)) model.reasoningEfforts = row.reasoningEfforts
        .filter((value): value is EffortOption => Boolean(value) && isReasoningEffort(value.effort))
        .map(value => ({ effort: value.effort, ...(typeof value.description === 'string' ? { description: value.description } : {}) }));
      if (isReasoningEffort(row.defaultReasoningEffort)) model.defaultReasoningEffort = row.defaultReasoningEffort;
      return model;
    });
  return models.length ? models : undefined;
}

export type ModelCatalogCache = ReturnType<typeof createModelCatalogCache>;

export function createModelCatalogCache(options: { prefix: string; storage?: ByosStorage }) {
  const prefix = requireStoragePrefix(options.prefix);
  const key = (provider: string) => `${prefix}${provider}`;
  return {
    read(provider: string): CatalogModel[] | undefined {
      return parseModelCatalog(safeGet(resolveStorage(options.storage).local, key(provider)));
    },
    store(provider: string, models: CatalogModel[]): void {
      if (!models.length) return;
      safeSet(resolveStorage(options.storage).local, key(provider), JSON.stringify(models.slice(0, MAX_CACHED_MODELS)));
    },
  };
}

/**
 * The options the picker renders. `live` means the list came from the provider on this page, so a
 * selection missing from it is genuinely gone. A remembered or partial list never drops the user's
 * own selection: a model vanishing from a stale list is not evidence it stopped existing.
 */
export function pickerModels(models: CatalogModel[], selection: string, live: boolean): CatalogModel[] {
  if (live || !isUsableModelId(selection) || models.some(model => model.id === selection)) return models;
  return [...models, { id: selection, name: selection }];
}
