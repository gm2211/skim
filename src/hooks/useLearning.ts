import { useEffect, useRef } from "react";
import { useMutation, useQuery } from "@tanstack/react-query";
import * as commands from "../services/commands";

/** Track reading time for an article. Sends accumulated time every 15 seconds. */
export function useReadingTimeTracker(articleId: string | null) {
  const startRef = useRef<number | null>(null);
  const lastSentRef = useRef<number>(0);

  useEffect(() => {
    if (!articleId) return;
    startRef.current = Date.now();
    lastSentRef.current = 0;

    const interval = setInterval(() => {
      if (!startRef.current || !articleId) return;
      const elapsed = Math.floor((Date.now() - startRef.current) / 1000);
      const delta = elapsed - lastSentRef.current;
      if (delta >= 15) {
        commands.recordReadingTime(articleId, delta).catch(() => {});
        lastSentRef.current = elapsed;
      }
    }, 15000);

    return () => {
      clearInterval(interval);
      // Flush remaining time on unmount/change
      if (startRef.current && articleId) {
        const elapsed = Math.floor((Date.now() - startRef.current) / 1000);
        const delta = elapsed - lastSentRef.current;
        if (delta >= 3) {
          commands.recordReadingTime(articleId, delta).catch(() => {});
        }
      }
      startRef.current = null;
    };
  }, [articleId]);
}

export function useSetArticleFeedback() {
  return useMutation({
    mutationFn: ({ articleId, feedback }: { articleId: string; feedback: "more" | "less" | null }) =>
      commands.setArticleFeedback(articleId, feedback),
  });
}

export function useSetPriorityOverride() {
  return useMutation({
    mutationFn: ({ articleId, priority }: { articleId: string; priority: number }) =>
      commands.setPriorityOverride(articleId, priority),
  });
}

export function useArticleInteraction(articleId: string | null) {
  return useQuery({
    queryKey: ["interaction", articleId],
    queryFn: () => commands.getArticleInteraction(articleId!),
    enabled: !!articleId,
  });
}

export function usePreferenceProfile() {
  return useQuery({
    queryKey: ["preferenceProfile"],
    queryFn: commands.getPreferenceProfile,
  });
}
