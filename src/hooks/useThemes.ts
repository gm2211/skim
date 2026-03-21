import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import * as commands from "../services/commands";

export function useThemes() {
  return useQuery({
    queryKey: ["themes"],
    queryFn: commands.getThemes,
  });
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
