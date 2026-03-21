import { useMutation } from "@tanstack/react-query";
import * as commands from "../services/commands";

export function useSummarizeArticle() {
  return useMutation({
    mutationFn: commands.summarizeArticle,
  });
}
