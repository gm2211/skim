import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import type { AiSettings, AppSettings } from "../services/types";
import * as commands from "../services/commands";

export function useSettings() {
  return useQuery({
    queryKey: ["settings"],
    queryFn: commands.getSettings,
  });
}

export function useUpdateSettings() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (settings: AppSettings) => commands.updateSettings(settings),
    onMutate: async (next: AppSettings) => {
      await qc.cancelQueries({ queryKey: ["settings"] });
      const previous = qc.getQueryData<AppSettings>(["settings"]);
      qc.setQueryData(["settings"], next);
      return { previous };
    },
    onError: (_err, _next, context) => {
      if (context?.previous) qc.setQueryData(["settings"], context.previous);
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["settings"] });
    },
  });
}

/**
 * Applies a model-only patch to the current AiSettings and saves the whole
 * AppSettings blob, the way inline model pickers change models without
 * touching anything else in Settings.
 */
export function useSelectModel() {
  const { data: settings } = useSettings();
  const { mutateAsync } = useUpdateSettings();
  return (patch: Partial<AiSettings>) => {
    if (!settings) return Promise.reject(new Error("Settings not loaded"));
    return mutateAsync({ ...settings, ai: { ...settings.ai, ...patch } });
  };
}
