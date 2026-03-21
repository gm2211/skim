import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import type { AppSettings } from "../services/types";
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
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["settings"] });
    },
  });
}
