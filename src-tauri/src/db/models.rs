use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Feed {
    pub id: String,
    pub title: String,
    pub url: String,
    pub site_url: Option<String>,
    pub description: Option<String>,
    pub icon_url: Option<String>,
    pub feedly_id: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub last_fetched_at: Option<i64>,
    #[serde(default)]
    pub folder_id: Option<String>,
    #[serde(default)]
    pub opml_category: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Folder {
    pub id: String,
    pub name: String,
    pub sort_order: i32,
    pub is_smart: bool,
    pub rules_json: Option<String>,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SmartRule {
    RegexTitle { pattern: String },
    RegexUrl { pattern: String },
    OpmlCategory { value: String },
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SmartRules {
    #[serde(default = "default_match_mode")]
    pub mode: MatchMode, // any | all
    pub rules: Vec<SmartRule>,
}

fn default_match_mode() -> MatchMode {
    MatchMode::Any
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum MatchMode {
    #[default]
    Any,
    All,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Article {
    pub id: String,
    pub feed_id: String,
    pub title: String,
    pub url: Option<String>,
    pub author: Option<String>,
    pub content_html: Option<String>,
    pub content_text: Option<String>,
    pub published_at: Option<i64>,
    pub fetched_at: i64,
    pub is_read: bool,
    pub is_starred: bool,
    pub feedly_entry_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArticleWithFeed {
    #[serde(flatten)]
    pub article: Article,
    pub feed_title: String,
    pub feed_icon_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArticleSummary {
    pub article_id: String,
    pub bullet_summary: Option<String>,
    pub full_summary: Option<String>,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Theme {
    pub id: String,
    pub label: String,
    pub summary: Option<String>,
    pub created_at: i64,
    pub expires_at: i64,
    pub article_count: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArticleFilter {
    pub feed_id: Option<String>,
    pub theme_id: Option<String>,
    pub is_read: Option<bool>,
    pub is_starred: Option<bool>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    pub ai: AiSettings,
    pub appearance: AppearanceSettings,
    pub sync: SyncSettings,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiSettings {
    pub provider: String,
    pub api_key: Option<String>,
    pub model: Option<String>,
    pub endpoint: Option<String>,
    #[serde(default)]
    pub local_model_path: Option<String>,
    #[serde(default)]
    pub local_gpu_layers: Option<i32>,
    #[serde(default)]
    pub models_directory: Option<String>,
    #[serde(default)]
    pub summary_length: Option<String>,       // "short", "medium", "long"
    #[serde(default)]
    pub summary_tone: Option<String>,         // "concise", "detailed", "casual", "technical"
    #[serde(default)]
    pub summary_format: Option<String>,       // "bullets", "paragraph", "both"
    #[serde(default)]
    pub summary_custom_prompt: Option<String>, // advanced: override system prompt
    #[serde(default)]
    pub summary_custom_word_count: Option<i32>,
    #[serde(default)]
    pub chat_provider: Option<String>,      // "same" or provider name; None = same as main
    #[serde(default)]
    pub chat_model: Option<String>,
    #[serde(default)]
    pub chat_api_key: Option<String>,
    #[serde(default)]
    pub chat_endpoint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppearanceSettings {
    pub theme: String,
    pub font_size: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncSettings {
    pub refresh_interval_minutes: i32,
    pub max_articles_per_feed: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArticleTriage {
    pub article_id: String,
    pub priority: i32,
    pub reason: String,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArticleWithTriage {
    #[serde(flatten)]
    pub article: Article,
    pub feed_title: String,
    pub feed_icon_url: Option<String>,
    pub priority: Option<i32>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TriageResult {
    pub triaged_count: i32,
    pub batches: i32,
    pub errors: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TriageStats {
    pub total: i64,
    pub by_priority: std::collections::HashMap<i32, i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArticleInteraction {
    pub article_id: String,
    pub reading_time_sec: i64,
    pub chat_messages: i64,
    pub feedback: Option<String>,       // "more" | "less"
    pub priority_override: Option<i32>, // user-corrected priority
    pub updated_at: i64,
}

/// A learned preference signal derived from user interactions
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserPreferenceProfile {
    pub top_feeds: Vec<String>,           // feeds the user engages with most
    pub preferred_topics: Vec<String>,    // topics from highly-engaged articles
    pub deprioritized_topics: Vec<String>, // topics user gave "less" feedback on
    pub avg_reading_time_sec: f64,
    pub total_interactions: i64,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            ai: AiSettings {
                provider: "none".to_string(),
                api_key: None,
                model: None,
                endpoint: None,
                local_model_path: None,
                local_gpu_layers: None,
                models_directory: None,
                summary_length: None,
                summary_tone: None,
                summary_format: None,
                summary_custom_prompt: None,
                summary_custom_word_count: None,
                chat_provider: None,
                chat_model: None,
                chat_api_key: None,
                chat_endpoint: None,
            },
            appearance: AppearanceSettings {
                theme: "dark".to_string(),
                font_size: 14,
            },
            sync: SyncSettings {
                refresh_interval_minutes: 30,
                max_articles_per_feed: 200,
            },
        }
    }
}
