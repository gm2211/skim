import { useQuery } from "@tanstack/react-query";
import * as commands from "../services/commands";

export function useRecentArticles(order: "engagement" | "recency" = "engagement") {
  return useQuery({
    queryKey: ["recent", order],
    queryFn: () => commands.getRecentArticles(order, 500),
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
