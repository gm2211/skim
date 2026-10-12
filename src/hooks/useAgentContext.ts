import { useQueryClient } from "@tanstack/react-query";
import { useUiStore } from "../stores/uiStore";
import { useFeeds } from "./useFeeds";
import { useFolders } from "./useFolders";
import { buildAgentContext } from "../lib/agentContext";
import type { AgentContext, AgentStory } from "../services/commands";
import type { TodayEditionView } from "../services/types";

/** The newest Today edition already loaded, without fetching one. */
function useLoadedTodayEdition(): TodayEditionView | null {
  const qc = useQueryClient();
  const editions = qc
    .getQueriesData<TodayEditionView>({ queryKey: ["todayEdition"] })
    .map(([, data]) => data)
    .filter((data): data is TodayEditionView => !!data);
  return editions.sort((a, b) => b.edition.generated_at - a.edition.generated_at)[0] ?? null;
}

/** What the user is looking at right now, for the app agent. */
export function useAgentContext(story?: AgentStory | null): AgentContext {
  const view = useUiStore((s) => s.sidebarView);
  const selectedArticleId = useUiStore((s) => s.selectedArticleId);
  const { data: feeds } = useFeeds();
  const { data: folders } = useFolders();
  const edition = useLoadedTodayEdition();
  return buildAgentContext({ view, selectedArticleId, edition, feeds, folders, story });
}
