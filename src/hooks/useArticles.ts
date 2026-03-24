import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import type { ArticleFilter } from "../services/types";
import * as commands from "../services/commands";

export function useArticles(filter: ArticleFilter) {
  return useQuery({
    queryKey: ["articles", filter],
    queryFn: () => commands.getArticles(filter),
  });
}

export function useArticle(articleId: string | null) {
  return useQuery({
    queryKey: ["article", articleId],
    queryFn: () => commands.getArticle(articleId!),
    enabled: !!articleId,
  });
}

export function useMarkRead() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: commands.markArticlesRead,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["articles"] });
      qc.invalidateQueries({ queryKey: ["feeds"] });
    },
  });
}

export function useMarkUnread() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: commands.markArticlesUnread,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["articles"] });
      qc.invalidateQueries({ queryKey: ["article"] });
      qc.invalidateQueries({ queryKey: ["feeds"] });
    },
  });
}

export function useMarkAllRead() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (feedId?: string | null) => commands.markAllRead(feedId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["articles"] });
      qc.invalidateQueries({ queryKey: ["feeds"] });
    },
  });
}

export function useToggleRead() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: commands.toggleRead,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["articles"] });
      qc.invalidateQueries({ queryKey: ["article"] });
      qc.invalidateQueries({ queryKey: ["feeds"] });
    },
  });
}

export function useToggleStar() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: commands.toggleStar,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["articles"] });
      qc.invalidateQueries({ queryKey: ["article"] });
    },
  });
}
