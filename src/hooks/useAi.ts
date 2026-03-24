import { useMutation } from "@tanstack/react-query";
import * as commands from "../services/commands";

export function useSummarizeArticle() {
  return useMutation({
    mutationFn: (args: {
      articleId: string;
      force?: boolean;
      summaryLength?: string;
      summaryTone?: string;
      summaryCustomPrompt?: string;
    }) =>
      commands.summarizeArticle(args.articleId, {
        force: args.force,
        summaryLength: args.summaryLength,
        summaryTone: args.summaryTone,
        summaryCustomPrompt: args.summaryCustomPrompt,
      }),
  });
}
