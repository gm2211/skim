import { useEffect, useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { listen } from "@tauri-apps/api/event";
import * as commands from "../services/commands";

export function useThemes() {
  return useQuery({
    queryKey: ["themes"],
    queryFn: commands.getThemes,
  });
}

export function useArticleThemeTags() {
  return useQuery({
    queryKey: ["articleThemeTags"],
    queryFn: commands.getArticleThemeTags,
  });
}

export interface ThemeProgress {
  stage: "fetching" | "batch" | "saving" | "done";
  completed: number;
  total: number;
  message: string;
}

export function useThemeProgress() {
  const [progress, setProgress] = useState<ThemeProgress | null>(null);
  useEffect(() => {
    let unlisten: (() => void) | null = null;
    listen<ThemeProgress>("theme_progress", (event) => {
      setProgress(event.payload);
      if (event.payload.stage === "done") {
        // Clear shortly after done so UI returns to idle
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

export function useGenerateThemes() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: commands.generateThemes,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["themes"] });
    },
  });
}
