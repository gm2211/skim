import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { listen } from "@tauri-apps/api/event";
import * as commands from "../services/commands";
import type { TodayEditionView } from "../services/types";
import { msUntilWindowRollover, todayWindow, type TodayWindow } from "../lib/todayEdition";
import { useSettings } from "./useSettings";

/** Merge generated text only; stale progress must never roll back reading state. */
function mergeLedesIntoCurrent(current: TodayEditionView | undefined, incoming: TodayEditionView): TodayEditionView {
  if (!current || current.edition.id !== incoming.edition.id) return incoming;
  const incomingItems = new Map(incoming.items.map((item) => [item.story_id, item]));
  return {
    ...current,
    items: current.items.map((item) => {
      const next = incomingItems.get(item.story_id);
      return next ? {
        ...item,
        lede: item.lede || next.lede,
        lede_source_article_id: item.lede ? item.lede_source_article_id : next.lede_source_article_id,
        lede_source_evidence_hash: item.lede ? item.lede_source_evidence_hash : next.lede_source_evidence_hash,
        editorial: item.editorial ?? next.editorial,
      } : item;
    }),
  };
}

/** Preserve generated summaries while applying a consumption-save response. */
function preserveLatestLedes(saveView: TodayEditionView, current: TodayEditionView | undefined): TodayEditionView {
  if (!current || current.edition.id !== saveView.edition.id) return saveView;
  return mergeLedesIntoCurrent(saveView, current);
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
  const { data: settings } = useSettings();
  const aiEnabled = !!settings && settings.ai.provider !== "none";
  const win = useTodayWindow();
  const queryKey = useMemo(() => ["todayEdition", win.startsAt, win.endsAt, storyLimit] as const, [win.startsAt, win.endsAt, storyLimit]);

  const query = useQuery({
    queryKey,
    queryFn: () =>
      commands.getOrGenerateTodayEdition(
        win.startsAt,
        win.endsAt,
        Math.floor(Date.now() / 1000),
        storyLimit,
      ),
  });

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

  // Editorial summaries arrive after grouping and ranking, one story at a time.
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
  const missingLedes = !!query.data?.items.some((item) => !item.editorial?.summary.trim());
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
    void commands.generateTodayEditorial(editionId, requestId).then((view) => {
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
    aiEnabled,
    setConsumed,
    ledeProgress,
    isWritingLedes,
    canRetryLedes: aiEnabled && missingLedes && !isWritingLedes,
    retryLedes,
  };
}
