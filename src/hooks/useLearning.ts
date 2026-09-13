import { useEffect, useRef } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import * as commands from "../services/commands";

/**
 * Track reading time for an article. Sends accumulated time every 15 seconds.
 * When `suppress` is true, records nothing — used when the article is being
 * viewed from a context that shouldn't count as fresh engagement (e.g. the
 * Recent tab, which already reflects past engagement).
 */
export function useReadingTimeTracker(articleId: string | null, suppress = false) {
  const startRef = useRef<number | null>(null);
  const lastSentRef = useRef<number>(0);

  useEffect(() => {
    if (!articleId || suppress) return;
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
      // Flush remaining time on unmount/change. Raised the floor to 15s so
      // quick-skimming the list doesn't mint interactions for every preview.
      if (startRef.current && articleId) {
        const elapsed = Math.floor((Date.now() - startRef.current) / 1000);
        const delta = elapsed - lastSentRef.current;
        if (delta >= 15) {
          commands.recordReadingTime(articleId, delta).catch(() => {});
        }
      }
      startRef.current = null;
    };
  }, [articleId, suppress]);
}

export function useSetArticleFeedback() {
  return useMutation({
    mutationFn: ({ articleId, feedback }: { articleId: string; feedback: "more" | "less" | null }) =>
      commands.setArticleFeedback(articleId, feedback),
  });
}

export function useSetPriorityOverride() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ articleId, priority }: { articleId: string; priority: number }) =>
      commands.setPriorityOverride(articleId, priority),
    onSuccess: (_data, { articleId }) => {
      qc.invalidateQueries({ queryKey: ["interaction", articleId] });
      qc.invalidateQueries({ queryKey: ["article", articleId] });
      qc.invalidateQueries({ queryKey: ["articles"] });
      qc.invalidateQueries({ queryKey: ["articleCount"] });
      qc.invalidateQueries({ queryKey: ["inbox"] });
      qc.invalidateQueries({ queryKey: ["feeds"] });
      qc.invalidateQueries({ queryKey: ["recent"] });
      qc.invalidateQueries({ queryKey: ["preferenceProfile"] });
      qc.invalidateQueries({ queryKey: ["triageStats"] });
    },
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
