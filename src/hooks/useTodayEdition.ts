import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { listen } from "@tauri-apps/api/event";
import * as commands from "../services/commands";
import type { TodayEditionView } from "../services/types";
import type { TodayPreparationStatus } from "../services/types";
import { msUntilWindowRollover, todayWindow, type TodayWindow } from "../lib/todayEdition";
import { useSettings } from "./useSettings";

/** Merge ledes without allowing an older whole-edition snapshot to erase newer state. */
function mergeLedesIntoCurrent(current: TodayEditionView | undefined, incoming: TodayEditionView): TodayEditionView {
  if (!current || current.edition.id !== incoming.edition.id) return incoming;
  const ledes = new Map(incoming.items.filter((item) => item.lede?.trim()).map((item) => [item.story_id, item.lede]));
  if (ledes.size === 0) return current;
  return {
    ...current,
    items: current.items.map((item) => !item.lede?.trim() && ledes.has(item.story_id) ? { ...item, lede: ledes.get(item.story_id)! } : item),
  };
}

/** Keep the latest generated ledes while applying a consumption-save response. */
function preserveLatestLedes(saveView: TodayEditionView, current: TodayEditionView | undefined): TodayEditionView {
  if (!current || current.edition.id !== saveView.edition.id) return saveView;
  const ledes = new Map(current.items.filter((item) => item.lede?.trim()).map((item) => [item.story_id, item.lede]));
  if (ledes.size === 0) return saveView;
  return {
    ...saveView,
    items: saveView.items.map((item) => ledes.has(item.story_id) ? { ...item, lede: ledes.get(item.story_id)! } : item),
  };
}

export function useTodayStoryLimit(): number {
  const { data: settings } = useSettings();
  return settings?.sync.today_story_limit ?? 10;
}

/**
 * Local midnight-to-midnight window, re-derived whenever the local day rolls
 * over. `get_or_generate_today_edition` rejects a `generated_at` outside its
 * window, so a stale window (rather than the id itself) is what we must not
 * cache across midnight.
 */
function useTodayWindow(): TodayWindow {
  const [win, setWin] = useState<TodayWindow>(() => todayWindow());
  useEffect(() => {
    const id = window.setTimeout(() => {
      setWin(todayWindow());
    }, msUntilWindowRollover(win) + 1000);
    const refresh = () => {
      const next = todayWindow();
      setWin((current) => current.startsAt === next.startsAt && current.endsAt === next.endsAt ? current : next);
    };
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      window.clearTimeout(id);
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [win]);
  return win;
}

export function useTodayEdition() {
  const qc = useQueryClient();
  const storyLimit = useTodayStoryLimit();
  const settingsQuery = useSettings();
  const settings = settingsQuery.data;
  const aiEnabled = !!settings && settings.ai.provider !== "none";
  const win = useTodayWindow();
  const queryKey = useMemo(() => ["todayEdition", win.startsAt, win.endsAt, storyLimit] as const, [win.startsAt, win.endsAt, storyLimit]);
  const preparationKey = useMemo(() => ["todayPreparation", win.startsAt, win.endsAt, storyLimit] as const, [win.startsAt, win.endsAt, storyLimit]);
  // Keep the request identity stable for this local-day scope so every status,
  // slice, and publish call refers to the same preparation generation.
  const generatedAt = useMemo(() => Math.floor(Date.now() / 1000), [win.startsAt, win.endsAt, storyLimit]);

  const query = useQuery({
    queryKey,
    queryFn: () =>
      commands.getOrGenerateTodayEdition(
        win.startsAt,
        win.endsAt,
        generatedAt,
        storyLimit,
      ),
  });

  const preparation = useQuery({
    queryKey: preparationKey,
    queryFn: () => commands.getTodayPreparationStatus(win.startsAt, win.endsAt, generatedAt, storyLimit),
    enabled: !!query.data && !query.isError,
    staleTime: 0,
  });
  const previousPreparationInputs = useRef({ edition: query.dataUpdatedAt, settings: settingsQuery.dataUpdatedAt });
  useEffect(() => {
    const previous = previousPreparationInputs.current;
    const changedAfterInitialLoad = (previous.edition > 0 && query.dataUpdatedAt !== previous.edition)
      || (previous.settings > 0 && settingsQuery.dataUpdatedAt !== previous.settings);
    previousPreparationInputs.current = { edition: query.dataUpdatedAt, settings: settingsQuery.dataUpdatedAt };
    if (changedAfterInitialLoad && query.data) void preparation.refetch();
  }, [query.dataUpdatedAt, settingsQuery.dataUpdatedAt, query.data, preparation.refetch]);
  const [preparationEpoch, setPreparationEpoch] = useState(0);
  const [preparationError, setPreparationError] = useState<string | null>(null);
  const [retryingPreparation, setRetryingPreparation] = useState(false);
  const [pageVisible, setPageVisible] = useState(() => typeof document === "undefined" || document.visibilityState !== "hidden");
  const pageVisibleRef = useRef(pageVisible);
  pageVisibleRef.current = pageVisible;
  const preparationRequest = useRef<{ scope: string; requestId: string } | null>(null);
  const mountedRef = useRef(false);
  const editionLoaded = !!query.data && !query.isError;
  const localScope = `${win.startsAt}:${win.endsAt}:${storyLimit}:${generatedAt}`;
  const currentScope = useRef(localScope);
  currentScope.current = localScope;

  useEffect(() => {
    mountedRef.current = true;
    const updateVisibility = () => {
      const visible = document.visibilityState !== "hidden";
      pageVisibleRef.current = visible;
      setPageVisible(visible);
      if (visible) return;
      const active = preparationRequest.current;
      preparationRequest.current = null;
      if (active) void commands.cancelTodayPreparation(active.requestId).catch(() => {});
      setRetryingPreparation(false);
    };
    document.addEventListener("visibilitychange", updateVisibility);
    return () => {
      mountedRef.current = false;
      document.removeEventListener("visibilitychange", updateVisibility);
      const active = preparationRequest.current;
      preparationRequest.current = null;
      if (active) void commands.cancelTodayPreparation(active.requestId).catch(() => {});
    };
  }, []);

  useEffect(() => {
    const scope = localScope;
    return () => {
      const active = preparationRequest.current;
      if (active?.scope !== scope) return;
      preparationRequest.current = null;
      void commands.cancelTodayPreparation(active.requestId).catch(() => {});
    };
  }, [localScope]);

  useEffect(() => {
    const status = preparation.data;
    if (!status || status.state !== "preparing" || !pageVisible || retryingPreparation || !editionLoaded) return;
    if (preparationRequest.current?.scope === localScope) return;
    const requestId = globalThis.crypto?.randomUUID?.()
      ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const active = { scope: localScope, requestId };
    preparationRequest.current = active;
    let current = true;
    void commands.prepareTodaySlice(win.startsAt, win.endsAt, generatedAt, storyLimit, requestId).then((next) => {
      if (!current || !pageVisibleRef.current || preparationRequest.current?.requestId !== requestId
        || currentScope.current !== localScope || next.scope_key !== status.scope_key) return;
      if (preparationRequest.current?.requestId === requestId) preparationRequest.current = null;
      setPreparationError(null);
      qc.setQueryData<TodayPreparationStatus>(preparationKey, next);
      if (next.state === "preparing") setPreparationEpoch((epoch) => epoch + 1);
    }).catch((error: unknown) => {
      if (!current || currentScope.current !== localScope) return;
      if (preparationRequest.current?.requestId === requestId) preparationRequest.current = null;
      setPreparationError(error instanceof Error ? error.message : "Could not prepare today's coverage.");
    }).finally(() => {
      if (preparationRequest.current?.requestId === requestId) preparationRequest.current = null;
    });
    return () => {
      current = false;
      if (preparationRequest.current?.requestId === requestId) {
        preparationRequest.current = null;
        void commands.cancelTodayPreparation(requestId).catch(() => {});
      }
    };
  }, [preparation.data?.state, preparation.data?.scope_key, pageVisible, retryingPreparation, editionLoaded, localScope, preparationEpoch, win.startsAt, win.endsAt, generatedAt, storyLimit, preparationKey, qc]);

  const retryPreparation = useCallback(async () => {
    if (!preparation.data || (preparation.data.state !== "failed" && !preparationError) || !pageVisible) return;
    const requestId = globalThis.crypto?.randomUUID?.()
      ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    setPreparationError(null);
    setRetryingPreparation(true);
    preparationRequest.current = { scope: localScope, requestId };
    try {
      const next = await commands.prepareTodaySlice(win.startsAt, win.endsAt, generatedAt, storyLimit, requestId, true);
      if (!mountedRef.current || preparationRequest.current?.requestId !== requestId
        || currentScope.current !== localScope || next.scope_key !== preparation.data.scope_key) return;
      preparationRequest.current = null;
      qc.setQueryData<TodayPreparationStatus>(preparationKey, next);
      if (next.state === "preparing") setPreparationEpoch((epoch) => epoch + 1);
    } catch (error) {
      if (mountedRef.current && preparationRequest.current?.requestId === requestId && currentScope.current === localScope) {
        setPreparationError(error instanceof Error ? error.message : "Could not retry today's coverage.");
      }
    } finally {
      if (preparationRequest.current?.requestId === requestId) preparationRequest.current = null;
      if (mountedRef.current) setRetryingPreparation(false);
    }
  }, [preparation.data, preparationError, pageVisible, localScope, win.startsAt, win.endsAt, generatedAt, storyLimit, qc, preparationKey]);

  const [publishingPreparation, setPublishingPreparation] = useState(false);
  const openUpdatedEdition = useCallback(async () => {
    const status = preparation.data;
    if (!status?.can_publish || !status.manifest || publishingPreparation) return;
    setPublishingPreparation(true);
    try {
      const successor = await commands.publishPreparedTodayEdition(win.startsAt, win.endsAt, generatedAt, storyLimit, status.manifest);
      if (!mountedRef.current || currentScope.current !== localScope) return;
      // Publication is the only preparation action that changes the reading
      // snapshot. The currently displayed frozen edition stays put until click.
      qc.setQueryData<TodayEditionView>(queryKey, successor);
      await qc.invalidateQueries({ queryKey: preparationKey });
    } catch (error) {
      if (mountedRef.current && currentScope.current === localScope) setPreparationError(error instanceof Error ? error.message : "Could not open the updated edition.");
    } finally {
      if (mountedRef.current) setPublishingPreparation(false);
    }
  }, [preparation.data, publishingPreparation, win.startsAt, win.endsAt, generatedAt, storyLimit, localScope, qc, queryKey, preparationKey]);

  const setConsumed = useMutation({
    mutationFn: async ({ storyId, isConsumed }: { storyId: string; isConsumed: boolean }) => {
      const edition = query.data;
      if (!edition) {
        return Promise.reject(new Error("Today edition is not loaded yet"));
      }
      const view = await commands.setTodayEditionItemConsumed(
        edition.edition.id,
        storyId,
        isConsumed,
        Math.floor(Date.now() / 1000),
      );
      return { view, key: queryKey };
    },
    onSuccess: ({ view, key }) => {
      qc.setQueryData<TodayEditionView>(key, (current) => preserveLatestLedes(view, current));
      // set_today_edition_item_consumed also marks the underlying member
      // articles read server-side — the raw article/feed views need to
      // reflect that too.
      qc.invalidateQueries({ queryKey: ["articles"] });
      qc.invalidateQueries({ queryKey: ["recent"] });
      qc.invalidateQueries({ queryKey: ["articleCount"] });
      qc.invalidateQueries({ queryKey: ["article"] });
      qc.invalidateQueries({ queryKey: ["feeds"] });
      qc.invalidateQueries({ queryKey: ["inbox"] });
    },
  });

  // Ledes are written after the edition exists, one model call per story, so
  // the page is published again after each one and the stories fill in.
  const editionId = query.data?.edition.id;
  const resetConsumed = setConsumed.reset;
  useEffect(() => {
    // Stop observing the previous edition's save, without cancelling its
    // request or changing the cache key captured by mutationFn.
    resetConsumed();
  }, [queryKey, editionId, resetConsumed]);
  const [ledeProgress, setLedeProgress] = useState<commands.TodayLedeProgress | null>(null);
  const [requests, setRequests] = useState<Record<string, "pending" | "settled">>({});
  const attempted = useRef(new Set<string>());
  const inFlight = useRef(new Map<string, string>());
  const currentEdition = useRef(editionId);
  currentEdition.current = editionId;
  const mounted = useRef(false);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);
  const missingLedes = !!query.data?.items.slice(0, 6).some((item) => !item.lede?.trim());
  const isWritingLedes = !!editionId && requests[editionId] === "pending";

  const retryLedes = useCallback(() => {
    if (!editionId || !aiEnabled || !missingLedes || inFlight.current.has(editionId)) return;
    const requestId = globalThis.crypto?.randomUUID?.()
      ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    attempted.current.add(editionId);
    inFlight.current.set(editionId, requestId);
    setRequests((state) => ({ ...state, [editionId]: "pending" }));
    setLedeProgress(null);
    // Capture the cache key; effect cleanup must not discard a valid response
    // or leave a request permanently pending (including StrictMode replays).
    void commands.generateTodayLedes(editionId, requestId).then((view) => {
      if (view.edition.id === editionId) {
        qc.setQueryData<TodayEditionView>(queryKey, (current) => mergeLedesIntoCurrent(current, view));
      }
    }).catch(() => {
      // Snapshot excerpts remain readable. Missing summaries expose a retry.
    }).finally(() => {
      if (inFlight.current.get(editionId) === requestId) inFlight.current.delete(editionId);
      if (!mounted.current) return;
      setRequests((state) => ({ ...state, [editionId]: "settled" }));
      if (currentEdition.current === editionId) setLedeProgress(null);
    });
  }, [editionId, aiEnabled, missingLedes, qc, queryKey]);

  useEffect(() => {
    if (editionId && !attempted.current.has(editionId)) retryLedes();
  }, [editionId, retryLedes]);

  useEffect(() => {
    let unlisten: (() => void) | null = null;
    let cancelled = false;
    setLedeProgress(null);
    listen<commands.TodayLedeProgress>(commands.TODAY_LEDE_PROGRESS_EVENT, (event) => {
      const activeRequestId = editionId ? inFlight.current.get(editionId) : undefined;
      if (cancelled || !editionId || !activeRequestId
        || event.payload.edition_id !== editionId
        || event.payload.request_id !== activeRequestId
        || event.payload.view.edition.id !== editionId) return;
      qc.setQueryData<TodayEditionView>(queryKey, (current) => mergeLedesIntoCurrent(current, event.payload.view));
      const done = event.payload.completed >= event.payload.total;
      // A delayed terminal event must not resurrect a completed spinner.
      setLedeProgress(!done && inFlight.current.get(editionId) === activeRequestId ? event.payload : null);
    }).then((fn) => {
      if (cancelled) fn();
      else unlisten = fn;
    }).catch(() => { /* Invocation completion also clears loading. */ });
    return () => {
      cancelled = true;
      if (unlisten) unlisten();
    };
  }, [qc, queryKey, editionId]);

  return {
    ...query,
    window: win,
    storyLimit,
    setConsumed,
    ledeProgress,
    isWritingLedes,
    canRetryLedes: aiEnabled && missingLedes && !isWritingLedes,
    retryLedes,
    preparationStatus: preparation.data,
    preparationLoading: preparation.isLoading,
    preparationStatusError: preparation.isError,
    preparationError,
    retryPreparationStatus: preparation.refetch,
    retryPreparation,
    isRetryingPreparation: retryingPreparation,
    openUpdatedEdition,
    isPublishingPreparation: publishingPreparation,
  };
}
