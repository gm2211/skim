import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import * as commands from "../services/commands";
import type { ArticleWithInteraction } from "../services/types";

/**
 * Collapse duplicate entries (same article ingested from multiple feeds,
 * same feed duplicated, etc) by a (title, feed_title) key. Backend does
 * this too but the running Tauri binary may be older than the Rust fix —
 * the frontend copy hot-reloads, so the UI self-heals on next save.
 */
function dedupRecent(rows: ArticleWithInteraction[]): ArticleWithInteraction[] {
  const seen = new Set<string>();
  const out: ArticleWithInteraction[] = [];
  for (const r of rows) {
    const key = `${r.title.trim().toLowerCase()}|${(r.feed_title ?? "").trim().toLowerCase()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(r);
  }
  return out;
}

export function useRecentArticles(order: "engagement" | "recency" = "engagement") {
  return useQuery({
    queryKey: ["recent", order],
    queryFn: () => commands.getRecentArticles(order, 500),
    select: dedupRecent,
  });
}

export function useReadMatchCount(query: string) {
  const trimmed = query.trim();
  return useQuery({
    queryKey: ["readMatchCount", trimmed],
    queryFn: () => commands.countReadMatches(trimmed),
    enabled: trimmed.length >= 2,
  });
}

export function useRemoveRecent() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (articleId: string) => commands.removeRecentArticle(articleId),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["recent"] }),
  });
}
