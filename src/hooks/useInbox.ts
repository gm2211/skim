import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import * as commands from "../services/commands";

export function useInboxArticles(minPriority?: number, isRead?: boolean | null) {
  const enabled = minPriority !== -1;
  return useQuery({
    queryKey: ["inbox", minPriority, isRead],
    queryFn: () =>
      commands.getInboxArticles({
        minPriority: minPriority != null && minPriority > 0 ? minPriority : null,
        isRead: isRead ?? null,
      }),
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
