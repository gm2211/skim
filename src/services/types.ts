export interface Feed {
  id: string;
  title: string;
  url: string;
  site_url: string | null;
  description: string | null;
  icon_url: string | null;
  feedly_id: string | null;
  created_at: number;
  updated_at: number;
  last_fetched_at: number | null;
  unread_count: number;
}

export interface Article {
  id: string;
  feed_id: string;
  title: string;
  url: string | null;
  author: string | null;
  content_html: string | null;
  content_text: string | null;
  published_at: number | null;
  fetched_at: number;
  is_read: boolean;
  is_starred: boolean;
  feed_title: string;
  feed_icon_url: string | null;
}

export interface ArticleSummary {
  article_id: string;
  bullet_summary: string | null;
  full_summary: string | null;
  provider: string | null;
  model: string | null;
  created_at: number;
}

export interface Theme {
  id: string;
  label: string;
  summary: string | null;
  created_at: number;
  expires_at: number;
  article_count: number | null;
}

export interface ArticleFilter {
  feed_id?: string | null;
  theme_id?: string | null;
  is_read?: boolean | null;
  is_starred?: boolean | null;
  limit?: number | null;
  offset?: number | null;
}

export interface AppSettings {
  ai: AiSettings;
  appearance: AppearanceSettings;
  sync: SyncSettings;
}

export interface AiSettings {
  provider: string;
  api_key: string | null;
  model: string | null;
  endpoint: string | null;
}

export interface AppearanceSettings {
  theme: string;
  font_size: number;
}

export interface SyncSettings {
  refresh_interval_minutes: number;
  max_articles_per_feed: number;
}

export type SidebarView =
  | { type: "all" }
  | { type: "starred" }
  | { type: "feed"; feedId: string }
  | { type: "theme"; themeId: string };
