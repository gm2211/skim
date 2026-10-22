import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { listen } from "@tauri-apps/api/event";
import * as commands from "../services/commands";
import type { DispatchEdition } from "../services/types";
import { dispatchDays, dispatchWindow } from "../lib/dispatch";
import { msUntilWindowRollover, type TodayWindow } from "../lib/todayEdition";
import { useSettings } from "./useSettings";
import { useUiStore } from "../stores/uiStore";

/** The window for a page, renewed when the local day rolls over. */
function useDispatchWindow(page: number, days: number): TodayWindow {
  const [win, setWin] = useState<TodayWindow>(() => dispatchWindow(new Date(), page, days));
  useEffect(() => {
    const refresh = () => {
      const next = dispatchWindow(new Date(), page, days);
      setWin((current) => current.startsAt === next.startsAt && current.endsAt === next.endsAt ? current : next);
    };
    refresh();
    const id = window.setTimeout(refresh, msUntilWindowRollover(dispatchWindow(new Date(), 1, days)) + 1000);
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      window.clearTimeout(id);
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [page, days, win.startsAt, win.endsAt]);
  return win;
}

function omit<T>(record: Record<string, T>, key: string): Record<string, T> {
  const next = { ...record };
  delete next[key];
  return next;
}

const newRequestId = () => globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;

/**
 * The Briefing for the page on screen: the stored edition, written when the
 * page is first opened. Pieces land one by one through progress events.
 */
export function useDispatch() {
  const qc = useQueryClient();
  const { data: settings } = useSettings();
  const days = dispatchDays(settings?.sync.dispatch_days);
  const page = useUiStore((state) => state.todayPage);
  const win = useDispatchWindow(page, days);
  const queryKey = useMemo(() => ["dispatch", win.startsAt, win.endsAt, days] as const, [win.startsAt, win.endsAt, days]);
  const query = useQuery({
    queryKey,
    queryFn: () => commands.getDispatch(win.startsAt, win.endsAt, days),
  });

  // One write per edition at a time; the request id ties progress events to it.
  const inFlight = useRef(new Map<string, string>());
  const attempted = useRef(new Set<string>());
  const [writing, setWriting] = useState<Record<string, string>>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const key = queryKey.join(":");

  const write = useCallback((mode: "open" | "retry" | "rewrite") => {
    if (inFlight.current.has(key)) return;
    const requestId = newRequestId();
    inFlight.current.set(key, requestId);
    attempted.current.add(key);
    setWriting((state) => ({ ...state, [key]: mode === "rewrite" ? "Starting a new edition…" : "Reading your feeds…" }));
    setErrors((state) => omit(state, key));
    if (mode === "rewrite") qc.setQueryData(queryKey, null);
    commands.writeDispatch(win.startsAt, win.endsAt, days, mode, requestId)
      .then((edition) => qc.setQueryData(queryKey, edition))
      .catch((error) => setErrors((state) => ({ ...state, [key]: error instanceof Error ? error.message : String(error) })))
      .finally(() => {
        if (inFlight.current.get(key) === requestId) inFlight.current.delete(key);
        setWriting((state) => omit(state, key));
      });
  }, [key, qc, queryKey, win.startsAt, win.endsAt, days]);

  // Write the edition the first time its page is opened, and finish one that
  // was interrupted (the app closed while it was being written).
  const edition = query.data;
  useEffect(() => {
    if (!query.isSuccess || attempted.current.has(key)) return;
    if (!edition || edition.status !== "complete") write("open");
  }, [query.isSuccess, edition, key, write]);

  useEffect(() => {
    let unlisten: (() => void) | null = null;
    let cancelled = false;
    listen<commands.DispatchProgress>(commands.DISPATCH_PROGRESS_EVENT, (event) => {
      const requestId = inFlight.current.get(key);
      if (cancelled || !requestId || event.payload.request_id !== requestId) return;
      qc.setQueryData<DispatchEdition | null>(queryKey, event.payload.edition);
      if (event.payload.message) setWriting((state) => ({ ...state, [key]: event.payload.message }));
    }).then((fn) => {
      if (cancelled) fn();
      else unlisten = fn;
    }).catch(() => { /* The command's own result still lands. */ });
    return () => {
      cancelled = true;
      if (unlisten) unlisten();
    };
  }, [qc, queryKey, key]);

  return {
    edition: edition ?? null,
    window: win,
    days,
    page,
    isLoading: query.isPending,
    progress: writing[key] ?? null,
    error: errors[key] ?? (query.error ? String(query.error) : null),
    retry: () => write(edition?.themes.length ? "retry" : "open"),
    rewrite: () => write("rewrite"),
  };
}
