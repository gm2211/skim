import { useEffect } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { getOfflineAiStatus, type OfflineAiStatus } from "../services/commands";

const QUERY_KEY = ["offlineAiStatus"] as const;

/**
 * Whether the configured AI provider is out of reach and which on-device
 * model answers meanwhile. The backend reroutes requests on its own; this only
 * tells the AI controls what to show. Rechecked every 30 seconds, and at once
 * when the system reports the connection dropping or coming back.
 */
export function useOfflineAi(enabled = true): OfflineAiStatus | null {
  const qc = useQueryClient();
  const { data } = useQuery({
    queryKey: QUERY_KEY,
    queryFn: getOfflineAiStatus,
    enabled,
    staleTime: 10_000,
    refetchInterval: 30_000,
    retry: false,
  });

  useEffect(() => {
    if (!enabled || typeof window === "undefined") return;
    const recheck = () => void qc.invalidateQueries({ queryKey: QUERY_KEY });
    window.addEventListener("online", recheck);
    window.addEventListener("offline", recheck);
    return () => {
      window.removeEventListener("online", recheck);
      window.removeEventListener("offline", recheck);
    };
  }, [enabled, qc]);

  return enabled ? (data ?? null) : null;
}

/** The note an AI control shows while an on-device model stands in. */
export function offlineFallbackNote(status: OfflineAiStatus | null): string | null {
  if (!status?.offline || !status.fallback_label) return null;
  return `Offline · using ${status.fallback_label}`;
}
