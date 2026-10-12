import type { AgentContext, AgentStep, AgentStory, ChatSource } from "../services/commands";
import type { Feed, Folder, SidebarView, TodayEditionItem, TodayEditionView } from "../services/types";

/** One turn of an agent conversation, as both the palette and Ask Skim keep it. */
export interface AgentMessage {
  role: "user" | "assistant";
  content: string;
  sources?: ChatSource[];
  articleIds?: string[];
  steps?: AgentStep[];
}

const STORY_ARTICLES = 6;

export function storyForAgent(item: TodayEditionItem): AgentStory {
  const ids = [item.representative_article_id, ...item.member_article_ids]
    .filter((id): id is string => !!id);
  return {
    story_id: item.story_id,
    title: item.snapshot_title,
    summary: item.lede || item.editorial?.summary || item.snapshot_summary || null,
    article_ids: [...new Set(ids)].slice(0, STORY_ARTICLES),
  };
}

/**
 * What the user is looking at: the view, the article open in the reader, and
 * on Today the stories on the page plus the one the open article belongs to.
 */
export function buildAgentContext({
  view,
  selectedArticleId,
  edition,
  feeds,
  folders,
  story,
}: {
  view: SidebarView;
  selectedArticleId: string | null;
  edition?: TodayEditionView | null;
  feeds?: Feed[];
  folders?: Folder[];
  /** A story the caller is pointing at, overriding the inferred one. */
  story?: AgentStory | null;
}): AgentContext {
  const context: AgentContext = { view: view.type, article_id: selectedArticleId };
  if (view.type === "feed") context.view_label = feeds?.find((f) => f.id === view.feedId)?.title ?? null;
  if (view.type === "folder") context.view_label = folders?.find((f) => f.id === view.folderId)?.name ?? null;

  if (view.type === "today" && edition) {
    const items = [...edition.items].sort((a, b) => a.position - b.position);
    context.page_stories = items.map(storyForAgent);
    const open = selectedArticleId
      ? items.find((item) => item.representative_article_id === selectedArticleId || item.member_article_ids.includes(selectedArticleId))
      : undefined;
    if (open) context.story = storyForAgent(open);
  }
  if (story) context.story = story;
  return context;
}

/** A few words naming the context, shown beside the conversation. */
export function agentContextLabel(context: AgentContext, articleTitle?: string | null): string {
  if (context.article_id && articleTitle) return `Reading “${articleTitle}”`;
  if (context.story) return `Story: ${context.story.title}`;
  switch (context.view) {
    case "today": return "Today’s front page";
    case "inbox": return "AI Inbox";
    case "starred": return "Starred";
    case "recent": return "Recently Read";
    case "all": return "All Articles";
    default: return context.view_label ?? "Your articles";
  }
}

/** The empty full chat's heading for a context. */
export function agentAskHeading(context: AgentContext, articleTitle?: string | null): string {
  if (context.article_id && articleTitle) return `Ask about “${articleTitle}”`;
  if (context.story) return `Ask about “${context.story.title}”`;
  if (context.view === "today") return "Ask about today’s front page";
  return "Ask about your articles";
}

/** Questions that fit the context, offered in the empty full chat. */
export function agentExamples(context: AgentContext): string[] {
  if (context.article_id) return ["Summarize this article", "What's the counterargument?", "Find related articles"];
  if (context.story) return ["Summarize this story", "How do the reports differ?", "Find more on this"];
  if (context.view === "today") return ["What are the biggest stories today?", "Which stories are about AI?", "Where's an article about…"];
  return ["What are this week's biggest stories?", "Where's an article about…", "Find pieces about distributed systems"];
}
