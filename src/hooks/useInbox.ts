import { useEffect, useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { listen } from "@tauri-apps/api/event";
import * as commands from "../services/commands";

export interface TriageProgress {
  stage: "fetching" | "batch" | "done";
  completed: number;
  total: number;
  message: string;
}

export function useTriageProgress() {
  const [progress, setProgress] = useState<TriageProgress | null>(null);
  useEffect(() => {
    let unlisten: (() => void) | null = null;
    listen<TriageProgress>("triage_progress", (event) => {
      setProgress(event.payload);
      if (event.payload.stage === "done") {
        setTimeout(() => setProgress(null), 1500);
      }
    }).then((fn) => {
      unlisten = fn;
    });
    return () => {
      if (unlisten) unlisten();
    };
  }, []);
  return progress;
}

/** The "For you" order: unread articles ranked like the AI Inbox, limited to
 * `feedIds` when given (a feed or folder), across every feed otherwise. */
export function useInboxArticles(enabled: boolean, feedIds?: string[] | null) {
  return useQuery({
    queryKey: ["inbox", feedIds ?? null],
    queryFn: () => commands.getInboxArticles({ isRead: false, feedIds: feedIds ?? null }),
    enabled,
  });
}

export function useTriageArticles() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (force?: boolean) => commands.triageArticles(force),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["inbox"] });
      qc.invalidateQueries({ queryKey: ["triageStats"] });
    },
  });
}

export function useTriageStats() {
  return useQuery({
    queryKey: ["triageStats"],
    queryFn: commands.getTriageStats,
  });
}
