import { useCallback, useEffect, useMemo, useState } from 'react';
import { reasoningEffortOptions, type ByosProvider, type CatalogModel, type EffortStore, type ModelCatalogCache, type ReasoningEffort } from '@byos/core';

/**
 * Headless hooks for sites that bring their own components. TOKEN RULE: the token given to
 * useProviderModels goes only to the provider adapter, which calls the provider directly.
 */
export type ModelListState = { models: CatalogModel[]; source: 'live' | 'remembered' | 'none'; error?: string; retry: () => void };

export function useProviderModels(provider: ByosProvider | undefined, token: string, cache?: ModelCatalogCache): ModelListState {
  const remembered = useMemo(() => (provider ? cache?.read(provider.id) : undefined), [provider, cache]);
  const [state, setState] = useState<Omit<ModelListState, 'retry'>>({ models: remembered ?? [], source: remembered ? 'remembered' : 'none' });
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (!provider || !token) return;
    const controller = new AbortController();
    provider.listModels(token, controller.signal).then(models => {
      if (controller.signal.aborted) return;
      cache?.store(provider.id, models);
      setState({ models, source: 'live' });
    }, (error: unknown) => {
      if (controller.signal.aborted) return;
      setState(current => ({ ...current, error: error instanceof Error ? error.message : 'Could not load models.' }));
    });
    return () => controller.abort();
  }, [provider, token, cache, attempt]);
  const retry = useCallback(() => setAttempt(value => value + 1), []);
  return { ...state, retry };
}

export function useEffortChoice(store: EffortStore, providerId: string, model: CatalogModel | undefined) {
  const [version, setVersion] = useState(0);
  const options = model ? reasoningEffortOptions(model) : [];
  // version re-reads storage after a choice; resolve() is cheap.
  const effort = model ? store.resolve(providerId, model) : '';
  void version;
  const choose = useCallback((next: ReasoningEffort) => {
    if (!model) return;
    store.store(providerId, model.id, next);
    setVersion(value => value + 1);
  }, [store, providerId, model]);
  return { effort, options, choose };
}
