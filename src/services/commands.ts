import { invoke } from "@tauri-apps/api/core";
import type {
  Feed,
  Article,
  ArticleSummary,
  Theme,
  ArticleFilter,
  AppSettings,
  HfModelInfo,
  HfModelFile,
  LocalModel,
  SystemInfo,
  ChatMessageInput,
  ChatResponse,
  SearchResult,
  ArticleWithTriage,
  TriageResult,
  TriageStats,
  ArticleInteraction,
  UserPreferenceProfile,
  FeedlySubscription,
  FeedlyImportResult,
  FeedlyProfile,
  FeedlyConnectionStatus,
  Folder,
  SmartRules,
} from "./types";

// Feeds
export const addFeed = (url: string) => invoke<Feed>("add_feed", { url });
export const listFeeds = () => invoke<Feed[]>("list_feeds");
export const removeFeed = (feedId: string) =>
  invoke<void>("remove_feed", { feedId });
export const renameFeed = (feedId: string, title: string) =>
  invoke<void>("rename_feed", { feedId, title });
export const countStarredInFeed = (feedId: string) =>
  invoke<number>("count_starred_in_feed", { feedId });

// Folders
export const listFolders = () => invoke<Folder[]>("list_folders");
export const createFolder = (name: string) =>
  invoke<Folder>("create_folder", { name });
export const createSmartFolder = (name: string, rules: SmartRules) =>
  invoke<Folder>("create_smart_folder", { name, rules });
export const renameFolder = (folderId: string, name: string) =>
  invoke<void>("rename_folder", { folderId, name });
export const updateSmartFolderRules = (folderId: string, rules: SmartRules) =>
  invoke<void>("update_smart_folder_rules", { folderId, rules });
export const deleteFolder = (folderId: string) =>
  invoke<void>("delete_folder", { folderId });
export const reorderFolders = (folderIds: string[]) =>
  invoke<void>("reorder_folders", { folderIds });
export const assignFeedToFolder = (feedId: string, folderId: string | null) =>
  invoke<void>("assign_feed_to_folder", { feedId, folderId });
export const previewSmartFolder = (rules: SmartRules) =>
  invoke<string[]>("preview_smart_folder", { rules });
export const feedsInFolder = (folderId: string) =>
  invoke<string[]>("feeds_in_folder", { folderId });

// AI-powered folder organization
export interface FolderProposal {
  name: string;
  feed_ids: string[];
}
export const aiAutoOrganizeFeeds = () =>
  invoke<FolderProposal[]>("ai_auto_organize_feeds");
export const aiMatchFeedsForTopic = (description: string) =>
  invoke<string[]>("ai_match_feeds_for_topic", { description });
export const applyFolderOrganization = (proposals: FolderProposal[]) =>
  invoke<Folder[]>("apply_folder_organization", { proposals });

// Duplicate feed management
export interface DuplicateFeedInfo {
  id: string;
  title: string;
  url: string;
  article_count: number;
  last_fetched_at: number | null;
}
export interface DuplicateGroup {
  normalized_url: string;
  feeds: DuplicateFeedInfo[];
}
export const listDuplicateFeeds = () =>
  invoke<DuplicateGroup[]>("list_duplicate_feeds");
export const mergeDuplicateFeeds = () =>
  invoke<number>("merge_duplicate_feeds");

export const refreshFeed = (feedId: string) =>
  invoke<number>("refresh_feed", { feedId });
export const refreshAllFeeds = () => invoke<number>("refresh_all_feeds");
export const getTotalUnread = () => invoke<number>("get_total_unread");
export const importFeedly = (token: string) =>
  invoke<FeedlyImportResult>("import_feedly", { token });
export const feedlyPreview = (token: string) =>
  invoke<FeedlySubscription[]>("feedly_preview", { token });
export const feedlyPreviewStored = () =>
  invoke<FeedlySubscription[]>("feedly_preview_stored");
export const importFeedlyStored = () =>
  invoke<FeedlyImportResult>("import_feedly_stored");
export const previewOpml = (xml: string) =>
  invoke<Array<{ title: string; url: string; category: string | null; already_exists: boolean }>>(
    "preview_opml",
    { xml },
  );
export const importOpml = (xml: string) =>
  invoke<FeedlyImportResult>("import_opml", { xml });
export const connectFeedly = (token: string) =>
  invoke<FeedlyProfile>("connect_feedly", { token });
export const disconnectFeedly = () =>
  invoke<void>("disconnect_feedly");
export const getFeedlyStatus = () =>
  invoke<FeedlyConnectionStatus | null>("get_feedly_status");
export const feedlyOauthLogin = () =>
  invoke<FeedlyProfile>("feedly_oauth_login");
export const feedlyOauthAvailable = () =>
  invoke<boolean>("feedly_oauth_available");

// Articles
export const getArticles = (filter: ArticleFilter) =>
  invoke<Article[]>("get_articles", { filter });
export const getArticle = (articleId: string) =>
  invoke<Article>("get_article", { articleId });
export const markArticlesRead = (articleIds: string[]) =>
  invoke<void>("mark_articles_read", { articleIds });
export const markArticlesUnread = (articleIds: string[]) =>
  invoke<void>("mark_articles_unread", { articleIds });
export const markAllRead = (feedId?: string | null) =>
  invoke<void>("mark_all_read", { feedId: feedId ?? null });
export const toggleStar = (articleId: string) =>
  invoke<boolean>("toggle_star", { articleId });
export const toggleRead = (articleId: string) =>
  invoke<boolean>("toggle_read", { articleId });
export const fetchFullArticle = (url: string) =>
  invoke<{ html: string; raw_html: string }>("fetch_full_article", { url });

// AI
export const summarizeArticle = (
  articleId: string,
  opts?: { force?: boolean; summaryLength?: string; summaryTone?: string; summaryFormat?: string; summaryCustomPrompt?: string }
) =>
  invoke<ArticleSummary>("summarize_article", {
    articleId,
    force: opts?.force ?? null,
    summaryLength: opts?.summaryLength ?? null,
    summaryTone: opts?.summaryTone ?? null,
    summaryFormat: opts?.summaryFormat ?? null,
    summaryCustomPrompt: opts?.summaryCustomPrompt ?? null,
  });
export const cancelSummarize = () => invoke<void>("cancel_summarize");
export const generateThemes = () => invoke<Theme[]>("generate_themes");
export const getThemes = () => invoke<Theme[]>("get_themes");
export interface ArticleThemeTag {
  article_id: string;
  theme_id: string;
  theme_label: string;
}
export const getArticleThemeTags = () =>
  invoke<ArticleThemeTag[]>("get_article_theme_tags");
export const triageArticles = (force?: boolean) =>
  invoke<TriageResult>("triage_articles", { force: force ?? null });
export const getInboxArticles = (opts?: {
  minPriority?: number | null;
  isRead?: boolean | null;
  limit?: number | null;
  offset?: number | null;
}) =>
  invoke<ArticleWithTriage[]>("get_inbox_articles", {
    minPriority: opts?.minPriority ?? null,
    isRead: opts?.isRead ?? null,
    limit: opts?.limit ?? null,
    offset: opts?.offset ?? null,
  });
export const getTriageStats = () => invoke<TriageStats>("get_triage_stats");

// Learning / interactions
export const recordReadingTime = (articleId: string, seconds: number) =>
  invoke<void>("record_reading_time", { articleId, seconds });
export const setArticleFeedback = (articleId: string, feedback: string | null) =>
  invoke<void>("set_article_feedback", { articleId, feedback });
export const setPriorityOverride = (articleId: string, priority: number) =>
  invoke<void>("set_priority_override", { articleId, priority });
export const getPreferenceProfile = () =>
  invoke<UserPreferenceProfile>("get_preference_profile");
export const getArticleInteraction = (articleId: string) =>
  invoke<ArticleInteraction | null>("get_article_interaction", { articleId });

// Chat
export const chatWithArticle = (articleId: string, messages: ChatMessageInput[]) =>
  invoke<ChatResponse>("chat_with_article", { articleId, messages });

export interface ArticleChatResponse {
  content: string;
  provider: string;
  model: string;
  article_ids: string[];
}
export const chatWithArticles = (
  scope: "inbox" | "unread" | "all",
  query: string,
  messages: ChatMessageInput[],
) =>
  invoke<ArticleChatResponse>("chat_with_articles", { scope, query, messages });
export const webSearch = (query: string) =>
  invoke<SearchResult[]>("web_search", { query });

// Settings
export const getSettings = () => invoke<AppSettings>("get_settings");
export const updateSettings = (settings: AppSettings) =>
  invoke<void>("update_settings", { settings });

// Models
export const searchHfModels = (query: string) =>
  invoke<HfModelInfo[]>("search_hf_models", { query });
export const getHfModelFiles = (repoId: string) =>
  invoke<HfModelFile[]>("get_hf_model_files", { repoId });
export const downloadModel = (repoId: string, filename: string) =>
  invoke<string>("download_model", { repoId, filename });
export const cancelDownload = () => invoke<void>("cancel_download");
export const listLocalModels = () => invoke<LocalModel[]>("list_local_models");
export const deleteLocalModel = (path: string) =>
  invoke<void>("delete_local_model", { path });
export const getSystemInfo = () => invoke<SystemInfo>("get_system_info");
