import { useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { listen } from "@tauri-apps/api/event";
import * as commands from "../services/commands";
import type { TodayEditionView } from "../services/types";
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
    return () => window.clearTimeout(id);
  }, [win]);
  return win;
}

export function useTodayEdition() {
  const qc = useQueryClient();
  const storyLimit = useTodayStoryLimit();
  const win = useTodayWindow();
  const queryKey = ["todayEdition", win.startsAt, win.endsAt, storyLimit] as const;

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
    mutationFn: ({ storyId, isConsumed }: { storyId: string; isConsumed: boolean }) => {
      const edition = query.data;
      if (!edition) {
        return Promise.reject(new Error("Today edition is not loaded yet"));
      }
      return commands.setTodayEditionItemConsumed(
        edition.edition.id,
        storyId,
        isConsumed,
        Math.floor(Date.now() / 1000),
      );
    },
    onSuccess: (updated: TodayEditionView) => {
      qc.setQueryData(queryKey, updated);
      // set_today_edition_item_consumed also marks the underlying member
      // articles read server-side — the raw article/feed views need to
      // reflect that too.
      qc.invalidateQueries({ queryKey: ["articles"] });
      qc.invalidateQueries({ queryKey: ["articleCount"] });
      qc.invalidateQueries({ queryKey: ["article"] });
      qc.invalidateQueries({ queryKey: ["feeds"] });
      qc.invalidateQueries({ queryKey: ["inbox"] });
    },
  });

  // Ledes are written after the edition exists, one model call per story, so
  // the page is published again after each one and the stories fill in.
  const [ledeProgress, setLedeProgress] = useState<commands.TodayLedeProgress | null>(null);
  useEffect(() => {
    let unlisten: (() => void) | null = null;
    let cancelled = false;
    listen<commands.TodayLedeProgress>(commands.TODAY_LEDE_PROGRESS_EVENT, (event) => {
      qc.setQueryData(queryKey, event.payload.view);
      // The last emit carries no message and completes the count.
      const done = event.payload.completed >= event.payload.total;
      setLedeProgress(done ? null : event.payload);
    }).then((fn) => {
      if (cancelled) fn();
      else unlisten = fn;
    });
    return () => {
      cancelled = true;
      if (unlisten) unlisten();
    };
  }, [qc, queryKey]);

  // One pass per edition per session; the backend also skips stories that
  // already carry a lede, so a repeat call is cheap but pointless.
  const requestedFor = useRef<string | null>(null);
  const editionId = query.data?.edition.id;
  const hasStories = (query.data?.items.length ?? 0) > 0;
  useEffect(() => {
    if (!editionId || !hasStories || requestedFor.current === editionId) return;
    requestedFor.current = editionId;
    commands
      .generateTodayLedes(editionId)
      .then((view) => qc.setQueryData(queryKey, view))
      .catch(() => {
        // Today is readable without ledes; a failure here is not the page's.
      })
      .finally(() => setLedeProgress(null));
  }, [editionId, hasStories, qc, queryKey]);

  return {
    ...query,
    window: win,
    storyLimit,
    setConsumed,
    ledeProgress,
  };
}
