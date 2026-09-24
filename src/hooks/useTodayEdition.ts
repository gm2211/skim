import { useEffect, useMemo, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { listen } from "@tauri-apps/api/event";
import * as commands from "../services/commands";
import { msUntilWindowRollover, todayWindow, type TodayWindow } from "../lib/todayEdition";
import { useSettings } from "./useSettings";

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
      qc.setQueryData(key, view);
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
  useEffect(() => {
    let unlisten: (() => void) | null = null;
    let cancelled = false;
    setLedeProgress(null);
    listen<commands.TodayLedeProgress>(commands.TODAY_LEDE_PROGRESS_EVENT, (event) => {
      if (cancelled || event.payload.view.edition.id !== editionId) return;
      qc.setQueryData(queryKey, event.payload.view);
      // The last emit carries no message and completes the count.
      const done = event.payload.completed >= event.payload.total;
      setLedeProgress(done ? null : event.payload);
    }).then((fn) => {
      if (cancelled) fn();
      else unlisten = fn;
    }).catch(() => { /* The page remains usable without progress events. */ });
    return () => {
      cancelled = true;
      if (unlisten) unlisten();
    };
  }, [qc, queryKey, editionId]);

  // One pass per edition per session; the backend also skips stories that
  // already carry a lede, so a repeat call is cheap but pointless.
  const requestedFor = useRef<string | null>(null);
  const hasStories = (query.data?.items.length ?? 0) > 0;
  useEffect(() => {
    if (!editionId || !hasStories || requestedFor.current === editionId) return;
    requestedFor.current = editionId;
    let cancelled = false;
    commands
      .generateTodayLedes(editionId)
      .then((view) => {
        if (!cancelled && view.edition.id === editionId) qc.setQueryData(queryKey, view);
      })
      .catch(() => {
        // Today is readable without ledes; a failure here is not the page's.
      })
      .finally(() => { if (!cancelled) setLedeProgress(null); });
    return () => { cancelled = true; };
  }, [editionId, hasStories, qc, queryKey]);

  return {
    ...query,
    window: win,
    storyLimit,
    setConsumed,
    ledeProgress,
  };
}
