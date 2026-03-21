import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import * as commands from "../services/commands";

export function useFeeds() {
  return useQuery({
    queryKey: ["feeds"],
    queryFn: commands.listFeeds,
    refetchInterval: 60_000,
  });
}

export function useAddFeed() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: commands.addFeed,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["feeds"] });
      qc.invalidateQueries({ queryKey: ["articles"] });
    },
  });
}

export function useRemoveFeed() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: commands.removeFeed,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["feeds"] });
      qc.invalidateQueries({ queryKey: ["articles"] });
    },
  });
}

export function useRefreshFeed() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: commands.refreshFeed,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["feeds"] });
      qc.invalidateQueries({ queryKey: ["articles"] });
    },
  });
}

export function useRefreshAllFeeds() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: commands.refreshAllFeeds,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["feeds"] });
      qc.invalidateQueries({ queryKey: ["articles"] });
    },
  });
}
