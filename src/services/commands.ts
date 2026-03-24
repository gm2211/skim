import { invoke } from "@tauri-apps/api/core";
import type {
  Feed,
  Article,
  ArticleSummary,
  Theme,
  ArticleFilter,
  AppSettings,
} from "./types";

// Feeds
export const addFeed = (url: string) => invoke<Feed>("add_feed", { url });
export const listFeeds = () => invoke<Feed[]>("list_feeds");
export const removeFeed = (feedId: string) =>
  invoke<void>("remove_feed", { feedId });
export const refreshFeed = (feedId: string) =>
  invoke<number>("refresh_feed", { feedId });
export const refreshAllFeeds = () => invoke<number>("refresh_all_feeds");
export const getTotalUnread = () => invoke<number>("get_total_unread");

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
export const summarizeArticle = (articleId: string) =>
  invoke<ArticleSummary>("summarize_article", { articleId });
export const generateThemes = () => invoke<Theme[]>("generate_themes");
export const getThemes = () => invoke<Theme[]>("get_themes");

// Settings
export const getSettings = () => invoke<AppSettings>("get_settings");
export const updateSettings = (settings: AppSettings) =>
  invoke<void>("update_settings", { settings });
