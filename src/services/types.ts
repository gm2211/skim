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
  folder_id: string | null;
  opml_category: string | null;
  unread_count: number;
}

export type SmartRule =
  | { type: "regex_title"; pattern: string }
  | { type: "regex_url"; pattern: string }
  | { type: "opml_category"; value: string };

export interface SmartRules {
  mode: "any" | "all";
  rules: SmartRule[];
}

export interface Folder {
  id: string;
  name: string;
  sort_order: number;
  is_smart: boolean;
  rules_json: string | null;
  created_at: number;
  feed_count: number;
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
  feedly_entry_id: string | null;
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
  local_model_path: string | null;
  local_gpu_layers: number | null;
  local_preload: string | null;
  local_idle_evict_minutes: number | null;
  local_power_mode: string | null;
  models_directory: string | null;
  summary_length: string | null;
  summary_tone: string | null;
  summary_format: string | null;
  summary_custom_prompt: string | null;
  summary_custom_word_count: number | null;
  chat_provider: string | null;
  chat_model: string | null;
  chat_api_key: string | null;
  chat_endpoint: string | null;
  triage_user_prompt?: string | null;
}

export interface ChatMessageInput {
  role: "user" | "assistant";
  content: string;
}

export interface WebCitation {
  title: string;
  url: string;
  snippet: string;
  query: string;
}

export interface ChatResponse {
  content: string;
  provider: string;
  model: string;
  /** Web-search citations emitted by the tool-use loop, if any. */
  web_citations?: WebCitation[];
}

export interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}

export interface HfModelInfo {
  id: string;
  author: string | null;
  downloads: number | null;
  likes: number | null;
  tags: string[] | null;
  pipeline_tag: string | null;
  last_modified: string | null;
  params_billions: number | null;
  recommended_file_size: number | null;
  summarization_rank: number | null;
  summarization_score: number | null;
}

export interface HfModelFile {
  filename: string;
  size: number | null;
}

export interface LocalModel {
  filename: string;
  path: string;
  size_bytes: number;
  is_partial: boolean;
  download_repo_id: string | null;
}

export interface SystemInfo {
  total_memory_gb: number;
  available_memory_gb: number;
  max_model_size_gb: number;
}

export interface DownloadProgress {
  filename: string;
  downloaded: number;
  total: number;
  percent: number;
}

export interface AppearanceSettings {
  theme: string;
  font_size: number;
  show_excerpt_in_list: boolean;
}

export interface SyncSettings {
  refresh_interval_minutes: number;
  max_articles_per_feed: number;
  recent_cap: number;
}

export interface ArticleWithTriage extends Article {
  priority: number | null;
  reason: string | null;
}

export interface TriageResult {
  triaged_count: number;
  batches: number;
  errors: string[];
}

export interface TriageStats {
  total: number;
  by_priority: Record<number, number>;
}

export interface ArticleInteraction {
  article_id: string;
  reading_time_sec: number;
  chat_messages: number;
  feedback: "more" | "less" | null;
  priority_override: number | null;
  updated_at: number;
}

export interface UserPreferenceProfile {
  top_feeds: string[];
  preferred_topics: string[];
  deprioritized_topics: string[];
  avg_reading_time_sec: number;
  total_interactions: number;
}

export interface FeedlySubscription {
  id: string;
  title: string;
  website: string | null;
  icon_url: string | null;
  categories: { id: string; label: string }[];
}

export interface FeedlyImportResult {
  imported: number;
  skipped: number;
  errors: string[];
}

export interface FeedlyProfile {
  id: string;
  email: string | null;
  full_name: string | null;
}

export interface FeedlyConnectionStatus {
  connected: boolean;
  email: string | null;
  full_name: string | null;
}

export type SidebarView =
  | { type: "all" }
  | { type: "starred" }
  | { type: "feed"; feedId: string }
  | { type: "inbox" }
  | { type: "recent" }
  | { type: "theme"; themeId: string };

export interface ArticleWithInteraction extends Article {
  reading_time_sec: number;
  chat_messages: number;
  interaction_at: number;
  engagement_score: number;
}
