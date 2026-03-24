import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useState, useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import * as commands from "../services/commands";
import type { DownloadProgress } from "../services/types";

export function useSearchHfModels(query: string) {
  return useQuery({
    queryKey: ["hf-models", query],
    queryFn: () => commands.searchHfModels(query),
    enabled: query.length >= 1,
    staleTime: 60_000,
  });
}

export function useHfModelFiles(repoId: string | null) {
  return useQuery({
    queryKey: ["hf-model-files", repoId],
    queryFn: () => commands.getHfModelFiles(repoId!),
    enabled: !!repoId,
    staleTime: 60_000,
  });
}

export function useLocalModels() {
  return useQuery({
    queryKey: ["local-models"],
    queryFn: commands.listLocalModels,
  });
}

export function useDownloadModel() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ repoId, filename }: { repoId: string; filename: string }) =>
      commands.downloadModel(repoId, filename),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["local-models"] });
    },
  });
}

export function useCancelDownload() {
  return useMutation({
    mutationFn: commands.cancelDownload,
  });
}

export function useDeleteModel() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (path: string) => commands.deleteLocalModel(path),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["local-models"] });
    },
  });
}

export function useSystemInfo() {
  return useQuery({
    queryKey: ["system-info"],
    queryFn: commands.getSystemInfo,
    staleTime: 300_000, // 5 min
  });
}

export function useDownloadProgress() {
  const [progress, setProgress] = useState<DownloadProgress | null>(null);

  useEffect(() => {
    let mounted = true;
    const promise = listen<DownloadProgress>(
      "model-download-progress",
      (event) => {
        if (mounted) {
          setProgress(event.payload);
          if (event.payload.percent >= 100) {
            setTimeout(() => mounted && setProgress(null), 1500);
          }
        }
      }
    );
    return () => {
      mounted = false;
      promise.then((unlisten) => unlisten());
    };
  }, []);

  return progress;
}
