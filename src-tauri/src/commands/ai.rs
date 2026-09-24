use crate::ai::local_provider::SharedModelState;
use crate::ai::prompts;
use crate::ai::provider::{create_provider_with_app, ChatMessage, ChatRequest};
use crate::db::models::{AiSettings, ArticleFilter, ArticleSummary, Theme};
use crate::db::queries;
use crate::db::Database;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use crate::AppHandle;
use tauri::{Emitter, State};
#[cfg(target_os = "ios")]
use tauri_plugin_skim_ai::{CompleteArgs, SkimAiExt};
use tokio::sync::Mutex;
use uuid::Uuid;

const SUMMARY_CACHE_MAX: usize = 100;

/// Monotonic counter — incrementing it cancels any in-flight summary.
pub struct SummaryGeneration(pub AtomicU64);

pub fn default_model(provider: &str) -> String {
    match provider {
        "claude-cli" => "sonnet".to_string(),
        "anthropic" | "claude-subscription" => "claude-sonnet-4-5".to_string(),
        "ollama" => "llama3".to_string(),
        "xai" => "grok-4.3".to_string(),
        "mlx" => "mlx-community/gemma-3-1b-it-4bit".to_string(),
        "foundation-models" => "foundation-model".to_string(),
        "ds4" => "deepseek-v4-flash".to_string(),
        _ => "gpt-4o-mini".to_string(),
    }
}

pub fn is_claude_model(model: &str) -> bool {
    model.starts_with("claude-") || model == "sonnet" || model == "opus" || model == "haiku"
}

pub struct SummaryCache {
    map: HashMap<String, ArticleSummary>,
    order: VecDeque<String>,
}

impl SummaryCache {
    pub fn new() -> Self {
        Self {
            map: HashMap::new(),
            order: VecDeque::new(),
        }
    }

    pub fn get(&self, cache_key: &str) -> Option<&ArticleSummary> {
        self.map.get(cache_key)
    }

    pub fn insert(&mut self, cache_key: String, summary: ArticleSummary) {
        if self.map.contains_key(&cache_key) {
            // Move to back (most recent)
            self.order.retain(|k| k != &cache_key);
        } else if self.order.len() >= SUMMARY_CACHE_MAX {
            // Evict oldest
            if let Some(oldest) = self.order.pop_front() {
                self.map.remove(&oldest);
            }
        }
        self.order.push_back(cache_key.clone());
        self.map.insert(cache_key, summary);
    }

    pub fn remove(&mut self, cache_key: &str) {
        self.map.remove(cache_key);
        self.order.retain(|k| k != cache_key);
    }

    pub fn clear(&mut self) {
        self.map.clear();
        self.order.clear();
    }
}

pub type SharedSummaryCache = Arc<Mutex<SummaryCache>>;

fn summary_cache_key(article_id: &str, ai: &AiSettings) -> String {
    #[derive(Serialize)]
    struct SummaryKey<'a> {
        article_id: &'a str,
        provider: &'a str,
        model: Option<&'a str>,
        endpoint: Option<&'a str>,
        local_model_path: Option<&'a str>,
        summary_length: Option<&'a str>,
        summary_tone: Option<&'a str>,
        summary_format: Option<&'a str>,
        summary_custom_prompt: Option<&'a str>,
        summary_custom_word_count: Option<i32>,
    }

    let key = SummaryKey {
        article_id,
        provider: &ai.provider,
        model: ai.model.as_deref(),
        endpoint: ai.endpoint.as_deref(),
        local_model_path: ai.local_model_path.as_deref(),
        summary_length: ai.summary_length.as_deref(),
        summary_tone: ai.summary_tone.as_deref(),
        summary_format: ai.summary_format.as_deref(),
        summary_custom_prompt: ai.summary_custom_prompt.as_deref(),
        summary_custom_word_count: ai.summary_custom_word_count,
    };

    let bytes = serde_json::to_vec(&key).unwrap_or_default();
    let digest = Sha256::digest(bytes);
    format!("{digest:x}")
}

/// Minimal cleanup: only strip ChatML tokens and code fences (structural, not heuristic).
/// All real parsing is done by extract_json_object() which finds the first valid JSON object.
fn clean_raw_output(text: &str) -> String {
    let mut s = text.to_string();
    // Remove ChatML tokens
    for token in &[
        "<|im_start|>",
        "<|im_end|>",
        "<|im_start|>system",
        "<|im_start|>user",
        "<|im_start|>assistant",
    ] {
        s = s.replace(token, "");
    }
    // Remove markdown code fences
    let trimmed = s.trim();
    if trimmed.starts_with("```") {
        s = trimmed
            .trim_start_matches("```json")
            .trim_start_matches("```")
            .trim_end_matches("```")
            .to_string();
    }
    s.trim().to_string()
}

/// Extract the "summary" field from a JSON response, falling back to raw text.
/// Handles both well-formed JSON and malformed model output where strings aren't properly quoted.
fn extract_summary_field(raw: &str) -> String {
    let cleaned = clean_raw_output(raw);

    // First try proper JSON parsing
    if let Some(json_str) = extract_json_object(&cleaned) {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(json_str) {
            if let Some(summary) = val.get("summary").and_then(|s| s.as_str()) {
                return summary.to_string();
            }
        }
    }

    // Fallback: extract text between "summary": and "notes": using string matching
    if let Some(val) = extract_field_fuzzy(&cleaned, "summary") {
        return val;
    }

    cleaned
}

/// Extract bullet points from a JSON response, falling back to raw text.
fn extract_bullets_field(raw: &str) -> String {
    let cleaned = clean_raw_output(raw);

    // First try proper JSON parsing
    if let Some(json_str) = extract_json_object(&cleaned) {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(json_str) {
            if let Some(bullets) = val.get("bullets").and_then(|b| b.as_array()) {
                return bullets
                    .iter()
                    .filter_map(|b| b.as_str())
                    .map(|b| format!("• {}", b))
                    .collect::<Vec<_>>()
                    .join("\n");
            }
        }
    }

    // Fallback: extract text between "bullets": and "notes":
    if let Some(val) = extract_field_fuzzy(&cleaned, "bullets") {
        return val;
    }

    cleaned
}

/// Fuzzy extraction: find "field_name": ... and grab the content until the next top-level key or end.
/// This handles cases where the model outputs JSON-like structure but with unquoted multiline strings.
fn extract_field_fuzzy(text: &str, field: &str) -> Option<String> {
    // Look for "field": or "field" :
    let patterns = [format!("\"{}\":", field), format!("\"{}\" :", field)];

    let field_start = patterns
        .iter()
        .filter_map(|p| text.find(p).map(|pos| pos + p.len()))
        .min()?;

    let after = text[field_start..].trim_start();

    // Find where the next field starts ("notes": or end of object })
    let end_markers = ["\"notes\"", "\"notes\" ", "}\n", "\n}"];
    let end_pos = end_markers
        .iter()
        .filter_map(|m| after.find(m))
        .min()
        .unwrap_or(after.len());

    let value = after[..end_pos].trim();

    // Clean up: strip surrounding quotes, trailing commas, brackets
    let value = value
        .trim_start_matches('"')
        .trim_start_matches('[')
        .trim_end_matches('"')
        .trim_end_matches(',')
        .trim_end_matches(']')
        .trim();

    if value.is_empty() {
        return None;
    }

    Some(value.to_string())
}

/// Fetch the article URL and convert its body to plain text. Used as a fallback
/// when the RSS entry only contains a title + link (Hacker News, Reddit, etc).
pub(super) async fn fetch_article_text(url: &str) -> Result<String, String> {
    let client = reqwest::Client::builder()
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15")
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .map_err(|e| e.to_string())?;
    let html = client
        .get(url)
        .send()
        .await
        .map_err(|e| e.to_string())?
        .text()
        .await
        .map_err(|e| e.to_string())?;

    // Strip everything outside <body>, then remove script/style/nav/etc
    // before handing off to html2text.
    let body = if let Some(start) = html.find("<body") {
        let content_start = html[start..]
            .find('>')
            .map(|i| start + i + 1)
            .unwrap_or(start);
        if let Some(end) = html[content_start..].find("</body>") {
            html[content_start..content_start + end].to_string()
        } else {
            html[content_start..].to_string()
        }
    } else {
        html
    };

    let mut clean = body;
    for tag in &[
        "script", "style", "nav", "header", "footer", "noscript", "aside", "form", "svg", "iframe",
    ] {
        loop {
            let lower = clean.to_lowercase();
            let open = format!("<{}", tag);
            let close = format!("</{}>", tag);
            if let Some(s) = lower.find(&open) {
                if let Some(e) = lower[s..].find(&close) {
                    clean = format!("{}{}", &clean[..s], &clean[s + e + close.len()..]);
                } else if let Some(gt) = clean[s..].find('>') {
                    clean = format!("{}{}", &clean[..s], &clean[s + gt + 1..]);
                } else {
                    break;
                }
            } else {
                break;
            }
        }
    }

    Ok(html2text::from_read(clean.as_bytes(), 12000))
}

/// Find the first JSON object in a string (handles preamble text before the JSON)
/// Find the first JSON object in a string (handles preamble text before the JSON)
pub fn extract_json_object(text: &str) -> Option<&str> {
    let start = text.find('{')?;
    let mut depth = 0;
    let mut in_string = false;
    let mut escape_next = false;
    for (i, ch) in text[start..].char_indices() {
        if escape_next {
            escape_next = false;
            continue;
        }
        match ch {
            '\\' if in_string => escape_next = true,
            '"' => in_string = !in_string,
            '{' if !in_string => depth += 1,
            '}' if !in_string => {
                depth -= 1;
                if depth == 0 {
                    return Some(&text[start..start + i + 1]);
                }
            }
            _ => {}
        }
    }
    None
}

#[cfg(target_os = "ios")]
fn ios_local_summary_text(text: &str) -> String {
    const MAX_CHARS: usize = 12_000;
    if text.chars().count() <= MAX_CHARS {
        return text.to_string();
    }

    text.chars().take(MAX_CHARS).collect()
}

#[tauri::command]
pub async fn cancel_summarize(generation: State<'_, SummaryGeneration>) -> Result<(), String> {
    generation.0.fetch_add(1, Ordering::SeqCst);
    Ok(())
}

#[tauri::command]
pub async fn summarize_article(
    #[cfg_attr(not(target_os = "ios"), allow(unused_variables))] app: AppHandle,
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
    summary_cache: State<'_, SharedSummaryCache>,
    generation: State<'_, SummaryGeneration>,
    article_id: String,
    force: Option<bool>,
    summary_length: Option<String>,
    summary_tone: Option<String>,
    summary_format: Option<String>,
    summary_custom_prompt: Option<String>,
    summary_custom_word_count: Option<i32>,
) -> Result<ArticleSummary, String> {
    let gen_id = generation.0.fetch_add(1, Ordering::SeqCst) + 1;
    // Get article content and settings
    let (article, settings_json) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let article = queries::get_article_by_id(&conn, &article_id)
            .map_err(|e| e.to_string())?
            .ok_or("Article not found")?;
        let settings_json =
            queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;
        (article, settings_json)
    };

    let mut settings: crate::db::models::AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();

    // Apply per-article overrides before deriving the cache key or provider prompt.
    if let Some(word_count) = summary_custom_word_count {
        if !(20..=1000).contains(&word_count) {
            return Err("Summary word count must be between 20 and 1000".to_string());
        }
        settings.ai.summary_custom_word_count = Some(word_count);
    }
    if let Some(len) = summary_length {
        settings.ai.summary_length = Some(len);
    }
    if let Some(tone) = summary_tone {
        settings.ai.summary_tone = Some(tone);
    }
    if let Some(fmt) = summary_format {
        settings.ai.summary_format = Some(fmt);
    }
    if let Some(prompt) = summary_custom_prompt {
        if !prompt.trim().is_empty() {
            settings.ai.summary_custom_prompt = Some(prompt);
        }
    }

    // claude-subscription / anthropic only accept Claude models. Override
    // any stale OpenAI model carried over from a previous provider before
    // deriving the cache key.
    if (settings.ai.provider == "claude-subscription" || settings.ai.provider == "anthropic")
        && settings
            .ai
            .model
            .as_deref()
            .map(|m| !is_claude_model(m))
            .unwrap_or(false)
    {
        settings.ai.model = None;
    }

    if settings.ai.provider == "none" {
        return Err(
            "No AI provider configured. Go to Settings to set up an AI provider.".to_string(),
        );
    }

    let cache_key = summary_cache_key(&article_id, &settings.ai);
    {
        let mut cache = summary_cache.lock().await;
        if force.unwrap_or(false) {
            cache.remove(&cache_key);
        } else if let Some(existing) = cache.get(&cache_key) {
            return Ok(existing.clone());
        }
    }

    let cached_from_db = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        if force.unwrap_or(false) {
            queries::delete_article_summary(&conn, &article_id, &cache_key)
                .map_err(|e| e.to_string())?;
            None
        } else {
            queries::get_article_summary(&conn, &article_id, &cache_key)
                .map_err(|e| e.to_string())?
        }
    };
    if let Some(existing) = cached_from_db {
        let mut cache = summary_cache.lock().await;
        cache.insert(cache_key.clone(), existing.clone());
        return Ok(existing);
    }

    let title = &article.article.title;

    // iOS-only: route mlx / foundation-models through the Swift plugin since
    // those providers are not implemented as Rust AiProvider trait
    // implementations (the inference runs in-process in the WebView host).
    #[cfg(target_os = "ios")]
    {
        let provider_name = settings.ai.provider.as_str();
        if provider_name == "mlx" || provider_name == "foundation-models" {
            // Resolve article body the same way the desktop path does below.
            let text = super::article_body::resolve_article_text(db.inner(), &article.article).await;
            if text.trim().is_empty() {
                return Err("No article content to summarize.".to_string());
            }
            let text = if provider_name == "mlx" {
                ios_local_summary_text(&text)
            } else {
                text
            };

            let plugin = app.skim_ai();
            let system_prompt = prompts::article_summary_system_prompt(&settings.ai);
            let repo_id = settings.ai.model.clone();

            let bullet_prompt = prompts::article_bullet_summary_prompt(title, &text, &settings.ai);
            let bullet_text = if !bullet_prompt.is_empty() {
                let args = CompleteArgs {
                    system: system_prompt.clone(),
                    user: bullet_prompt,
                    repo_id: repo_id.clone(),
                    json_mode: Some(true),
                    max_tokens: Some(prompts::bullet_max_tokens(&settings.ai) as u32),
                };
                let raw = if provider_name == "mlx" {
                    plugin.mlx_complete(args).map_err(|e| e.to_string())?
                } else {
                    plugin.fm_complete(args).map_err(|e| e.to_string())?
                };
                Some(extract_bullets_field(&raw))
            } else {
                None
            };

            if generation.0.load(Ordering::SeqCst) != gen_id {
                return Err("Summary cancelled".to_string());
            }

            let full_prompt = prompts::article_full_summary_prompt(title, &text, &settings.ai);
            let full_text = if !full_prompt.is_empty() {
                let args = CompleteArgs {
                    system: system_prompt,
                    user: full_prompt,
                    repo_id,
                    json_mode: Some(true),
                    max_tokens: Some(prompts::full_max_tokens(&settings.ai) as u32),
                };
                let raw = if provider_name == "mlx" {
                    plugin.mlx_complete(args).map_err(|e| e.to_string())?
                } else {
                    plugin.fm_complete(args).map_err(|e| e.to_string())?
                };
                Some(extract_summary_field(&raw))
            } else {
                None
            };

            let summary = ArticleSummary {
                article_id: article_id.clone(),
                bullet_summary: bullet_text,
                full_summary: full_text,
                provider: Some(provider_name.to_string()),
                model: Some(provider_name.to_string()),
                created_at: Utc::now().timestamp(),
            };
            {
                {
                    let conn = db.conn.lock().map_err(|e| e.to_string())?;
                    queries::upsert_article_summary(&conn, &cache_key, &summary)
                        .map_err(|e| e.to_string())?;
                }
                let mut cache = summary_cache.lock().await;
                cache.insert(cache_key.clone(), summary.clone());
            }
            return Ok(summary);
        }
    }

    settings.ai.oauth_access_token = crate::ai::claude_oauth::stored_access_token(&db);

    let provider = create_provider_with_app(&settings.ai, Some(model_state.inner().clone()), &app)?;

    let model = settings
        .ai
        .model
        .clone()
        .unwrap_or_else(|| default_model(&settings.ai.provider));

    // Use the longest available content — prefer content_text, fall back to HTML stripped to text
    // The reader's extraction first, then the feed body, then the linked page:
    // many aggregator feeds (Hacker News, Reddit, most newsletters) ship only a
    // title and a blurb, and summarizing the blurb is summarizing nothing.
    let text = super::article_body::resolve_article_text(db.inner(), &article.article).await;

    if text.trim().is_empty() {
        return Err("No article content to summarize.".to_string());
    }

    let system_prompt = prompts::article_summary_system_prompt(&settings.ai);

    // Get bullet summary (skip if format is paragraph-only)
    let bullet_prompt = prompts::article_bullet_summary_prompt(title, &text, &settings.ai);
    let bullet_response = if !bullet_prompt.is_empty() {
        let req = ChatRequest {
            model: model.clone(),
            messages: vec![
                ChatMessage {
                    role: "system".to_string(),
                    content: system_prompt.clone(),
                    content_blocks: None,
                },
                ChatMessage {
                    role: "user".to_string(),
                    content: bullet_prompt,
                    content_blocks: None,
                },
            ],
            temperature: Some(0.5),
            max_tokens: Some(prompts::bullet_max_tokens(&settings.ai)),
            json_mode: true,
            tools: None,
        };
        Some(provider.chat(req).await?)
    } else {
        None
    };

    // Check if cancelled between the two AI calls
    if generation.0.load(Ordering::SeqCst) != gen_id {
        return Err("Summary cancelled".to_string());
    }

    // Get full summary (skip if format is bullets-only)
    let full_prompt = prompts::article_full_summary_prompt(title, &text, &settings.ai);
    let full_response = if !full_prompt.is_empty() {
        let req = ChatRequest {
            model: model.clone(),
            messages: vec![
                ChatMessage {
                    role: "system".to_string(),
                    content: system_prompt,
                    content_blocks: None,
                },
                ChatMessage {
                    role: "user".to_string(),
                    content: full_prompt,
                    content_blocks: None,
                },
            ],
            temperature: Some(0.3),
            max_tokens: Some(prompts::full_max_tokens(&settings.ai)),
            json_mode: true,
            tools: None,
        };
        Some(provider.chat(req).await?)
    } else {
        None
    };

    let bullet_text = bullet_response.map(|r| {
        log::info!(
            "Bullet raw response: {}",
            &r.content[..r.content.len().min(200)]
        );
        extract_bullets_field(&r.content)
    });
    let full_text = full_response.map(|r| {
        log::info!(
            "Summary raw response: {}",
            &r.content[..r.content.len().min(500)]
        );
        let result = extract_summary_field(&r.content);
        log::info!("Extracted summary: {}", &result[..result.len().min(200)]);
        result
    });

    let summary = ArticleSummary {
        article_id: article_id.clone(),
        bullet_summary: bullet_text,
        full_summary: full_text,
        provider: Some(provider.name().to_string()),
        model: Some(model),
        created_at: Utc::now().timestamp(),
    };

    // Cache in SQLite and memory.
    {
        {
            let conn = db.conn.lock().map_err(|e| e.to_string())?;
            queries::upsert_article_summary(&conn, &cache_key, &summary)
                .map_err(|e| e.to_string())?;
        }
        let mut cache = summary_cache.lock().await;
        cache.insert(cache_key, summary.clone());
    }

    Ok(summary)
}

#[derive(Deserialize)]
struct ThemeGroupingResponse {
    themes: Vec<ThemeGroupItem>,
}

#[derive(Deserialize)]
struct ThemeGroupItem {
    label: String,
    summary: String,
    articles: Vec<ThemeArticleRef>,
}

#[derive(Deserialize)]
struct ThemeArticleRef {
    #[serde(alias = "id", alias = "handle")]
    id: serde_json::Value,
    #[serde(default = "default_relevance")]
    relevance: f64,
}

fn default_relevance() -> f64 {
    1.0
}

#[derive(Serialize, Clone)]
struct ThemeProgress {
    stage: String,
    completed: u32,
    total: u32,
    message: String,
}

fn emit_progress(app: &AppHandle, stage: &str, completed: u32, total: u32, message: &str) {
    let _ = app.emit(
        "theme_progress",
        ThemeProgress {
            stage: stage.to_string(),
            completed,
            total,
            message: message.to_string(),
        },
    );
}

fn emit_triage_progress(app: &AppHandle, stage: &str, completed: u32, total: u32, message: &str) {
    let _ = app.emit(
        "triage_progress",
        ThemeProgress {
            stage: stage.to_string(),
            completed,
            total,
            message: message.to_string(),
        },
    );
}

#[tauri::command]
pub async fn generate_themes(
    app: AppHandle,
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
) -> Result<Vec<Theme>, String> {
    emit_progress(&app, "fetching", 0, 1, "Fetching articles...");
    // Pull inbox articles (triaged, priority >= 3, unread). Fall back to unread
    // articles if nothing has been triaged yet.
    let (articles, settings_json) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let inbox = queries::get_inbox_articles(&conn, Some(3), Some(false), 200, 0)
            .map_err(|e| e.to_string())?;
        let articles: Vec<crate::db::models::ArticleWithFeed> = if !inbox.is_empty() {
            inbox
                .into_iter()
                .map(|a| crate::db::models::ArticleWithFeed {
                    article: a.article,
                    feed_title: a.feed_title,
                    feed_icon_url: a.feed_icon_url,
                })
                .collect()
        } else {
            let filter = ArticleFilter {
                feed_id: None,
                feed_ids: None,
                search: None,
                theme_id: None,
                is_read: Some(false),
                is_starred: None,
                limit: Some(200),
                published_after: None,
                offset: None,
            };
            queries::get_articles(&conn, &filter).map_err(|e| e.to_string())?
        };
        let settings_json =
            queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;
        (articles, settings_json)
    };

    if articles.is_empty() {
        emit_progress(&app, "done", 1, 1, "No articles to group");
        return Ok(vec![]);
    }

    let settings: crate::db::models::AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();

    if settings.ai.provider == "none" {
        return Err(
            "No AI provider configured. Go to Settings to set up an AI provider.".to_string(),
        );
    }

    let mut ai_settings = settings.ai.clone();
    ai_settings.oauth_access_token = crate::ai::claude_oauth::stored_access_token(&db);
    let provider = create_provider_with_app(&ai_settings, Some(model_state.inner().clone()), &app)?;

    let model = ai_settings
        .model
        .clone()
        .unwrap_or_else(|| default_model(&ai_settings.provider));

    // Batch articles so we can emit real progress per batch. Local models
    // are slow so use smaller batches; remote providers can handle more.
    let batch_size = match settings.ai.provider.as_str() {
        "local" => 25,
        "ollama" => 40,
        _ => 60,
    };
    let total_batches = articles.len().div_ceil(batch_size) as u32;

    // Accumulate grouped themes across all batches. Collapse by lowercased
    // label so the same topic from different batches merges into one theme.
    let mut combined: HashMap<String, CombinedTheme> = HashMap::new();

    for (batch_idx, chunk) in articles.chunks(batch_size).enumerate() {
        let batch_num = batch_idx as u32 + 1;
        emit_progress(
            &app,
            "batch",
            batch_num - 1,
            total_batches,
            &format!("Grouping batch {}/{}...", batch_num, total_batches),
        );

        // Build TSV listing using handles LOCAL to this batch.
        let mut listing = String::new();
        for (i, a) in chunk.iter().enumerate() {
            listing.push_str(&format!(
                "{}\t{}\t[{}]\n",
                i,
                a.article.title.trim(),
                a.feed_title
            ));
        }
        let max_tokens = (chunk.len() as i64 * 6 + 400).min(3072);

        let request = ChatRequest {
            model: model.clone(),
            messages: vec![
                ChatMessage {
                    role: "system".to_string(),
                    content: prompts::theme_grouping_system_prompt(
                        ai_settings.triage_user_prompt.as_deref(),
                    ),
                    content_blocks: None,
                },
                ChatMessage {
                    role: "user".to_string(),
                    content: prompts::theme_grouping_user_prompt(&listing),
                    content_blocks: None,
                },
            ],
            temperature: Some(0.3),
            max_tokens: Some(max_tokens),
            json_mode: true,
            tools: None,
        };

        match provider.chat(request).await {
            Ok(resp) => {
                let content = resp.content.trim();
                let json_str = extract_json_object(content).unwrap_or(content);
                match serde_json::from_str::<ThemeGroupingResponse>(json_str) {
                    Ok(grouping) => {
                        for group in grouping.themes {
                            let label = group.label.trim();
                            if label.is_empty() {
                                continue;
                            }
                            // Resolve batch-local handles to global article UUIDs.
                            let resolved: Vec<(String, f64)> = group
                                .articles
                                .iter()
                                .filter_map(|r| {
                                    let uuid = match &r.id {
                                        serde_json::Value::Number(n) => n.as_u64().and_then(|i| {
                                            chunk.get(i as usize).map(|a| a.article.id.clone())
                                        }),
                                        serde_json::Value::String(s) => {
                                            if let Ok(i) = s.trim().parse::<usize>() {
                                                chunk.get(i).map(|a| a.article.id.clone())
                                            } else if articles.iter().any(|a| a.article.id == *s) {
                                                Some(s.clone())
                                            } else {
                                                None
                                            }
                                        }
                                        _ => None,
                                    };
                                    uuid.map(|id| (id, r.relevance))
                                })
                                .collect();
                            if resolved.is_empty() {
                                continue;
                            }
                            let key = label.to_lowercase();
                            let entry = combined.entry(key).or_insert_with(|| CombinedTheme {
                                label: label.to_string(),
                                summaries: Vec::new(),
                                articles: Vec::new(),
                            });
                            entry.summaries.push(group.summary);
                            for (id, rel) in resolved {
                                entry.articles.push((id, rel));
                            }
                        }
                    }
                    Err(e) => {
                        log::warn!(
                            "Theme batch {} parse failed: {}. Raw: {}",
                            batch_num,
                            e,
                            &content[..content.len().min(200)]
                        );
                    }
                }
            }
            Err(e) => {
                log::warn!("Theme batch {} chat failed: {}", batch_num, e);
            }
        }

        emit_progress(
            &app,
            "batch",
            batch_num,
            total_batches,
            &format!("Grouped batch {}/{}", batch_num, total_batches),
        );
    }

    emit_progress(
        &app,
        "saving",
        total_batches,
        total_batches,
        "Saving themes...",
    );
    let now = Utc::now().timestamp();
    let expires_at = now + 6 * 3600; // 6 hours

    // Clear old themes and store new ones
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::clear_themes(&conn).map_err(|e| e.to_string())?;

    let mut result_themes = Vec::new();

    for (_key, combined_theme) in combined {
        // Dedupe article refs; if the same article appears in multiple batches
        // under the same theme label, keep the max relevance.
        let mut by_id: HashMap<String, f64> = HashMap::new();
        for (id, rel) in combined_theme.articles {
            by_id
                .entry(id)
                .and_modify(|existing| {
                    if rel > *existing {
                        *existing = rel;
                    }
                })
                .or_insert(rel);
        }

        if by_id.is_empty() {
            continue;
        }

        // Pick first non-empty summary; if all batches contributed, take the longest.
        let summary = combined_theme
            .summaries
            .into_iter()
            .max_by_key(|s| s.len())
            .unwrap_or_default();

        let theme_id = Uuid::new_v4().to_string();
        let article_count = by_id.len() as i64;
        let theme = Theme {
            id: theme_id.clone(),
            label: combined_theme.label,
            summary: Some(summary),
            created_at: now,
            expires_at,
            article_count: Some(article_count),
        };

        queries::insert_theme(&conn, &theme).map_err(|e| e.to_string())?;

        for (article_id, relevance) in &by_id {
            queries::insert_theme_article(&conn, &theme_id, article_id, *relevance)
                .map_err(|e| e.to_string())?;
        }

        result_themes.push(theme);
    }

    emit_progress(
        &app,
        "done",
        total_batches,
        total_batches,
        &format!("{} themes", result_themes.len()),
    );
    Ok(result_themes)
}

struct CombinedTheme {
    label: String,
    summaries: Vec<String>,
    articles: Vec<(String, f64)>,
}

#[tauri::command]
pub async fn get_themes(db: State<'_, Database>) -> Result<Vec<Theme>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::get_themes(&conn).map_err(|e| e.to_string())
}

#[derive(Serialize)]
pub struct ArticleThemeTag {
    pub article_id: String,
    pub theme_id: String,
    pub theme_label: String,
}

#[tauri::command]
pub async fn get_article_theme_tags(
    db: State<'_, Database>,
) -> Result<Vec<ArticleThemeTag>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let pairs = queries::list_article_theme_pairs(&conn).map_err(|e| e.to_string())?;
    Ok(pairs
        .into_iter()
        .map(|(article_id, theme_id, theme_label)| ArticleThemeTag {
            article_id,
            theme_id,
            theme_label,
        })
        .collect())
}

// ── Triage (AI Inbox) ──────────────────────────────────────────────

#[derive(Deserialize)]
struct TriageResponseItem {
    #[serde(alias = "id", alias = "handle")]
    id: serde_json::Value,
    priority: i32,
    #[serde(default)]
    reason: String,
}

#[derive(Deserialize)]
struct TriageResponse {
    triage: Vec<TriageResponseItem>,
}

#[tauri::command]
pub async fn triage_articles(
    app: AppHandle,
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
    force: Option<bool>,
) -> Result<crate::db::models::TriageResult, String> {
    emit_triage_progress(&app, "fetching", 0, 1, "Loading unread articles...");

    // Cap per run to avoid runaway cost on remote providers / all-day loops
    // on local ones. 1000 is already 20-40 minutes on a local model.
    const MAX_PER_RUN: i64 = 1000;

    // Drop triage rows written before the prompt fix so they get rescored.
    {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        if let Ok(n) = queries::clear_hallucinated_triage(&conn) {
            if n > 0 {
                log::info!("Cleared {} stale triage rows with hallucinated reasons", n);
            }
        }
    }

    let (articles, settings_json, preferences) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let articles = if force.unwrap_or(false) {
            queries::clear_triage(&conn).map_err(|e| e.to_string())?;
            let filter = ArticleFilter {
                feed_id: None,
                feed_ids: None,
                search: None,
                theme_id: None,
                is_read: Some(false),
                is_starred: None,
                limit: Some(MAX_PER_RUN),
                published_after: None,
                offset: None,
            };
            queries::get_articles(&conn, &filter).map_err(|e| e.to_string())?
        } else {
            queries::get_untriaged_article_ids(&conn, MAX_PER_RUN).map_err(|e| e.to_string())?
        };
        let settings_json =
            queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;
        let prefs = queries::build_preference_profile(&conn).ok();
        (articles, settings_json, prefs)
    };

    if articles.is_empty() {
        emit_triage_progress(&app, "done", 1, 1, "Nothing to triage");
        return Ok(crate::db::models::TriageResult {
            triaged_count: 0,
            batches: 0,
            errors: vec![],
        });
    }

    let settings: crate::db::models::AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();

    if settings.ai.provider == "none" {
        return Err(
            "No AI provider configured. Go to Settings to set up an AI provider.".to_string(),
        );
    }

    let mut ai_settings = settings.ai.clone();
    ai_settings.oauth_access_token = crate::ai::claude_oauth::stored_access_token(&db);
    let provider = create_provider_with_app(&ai_settings, Some(model_state.inner().clone()), &app)?;
    let model = ai_settings
        .model
        .clone()
        .unwrap_or_else(|| default_model(&ai_settings.provider));

    let batch_size = match ai_settings.provider.as_str() {
        "local" => 15,
        "ollama" => 20,
        _ => 30,
    };

    let mut triaged_count = 0i32;
    let mut batch_count = 0i32;
    let mut errors = Vec::new();
    let now = Utc::now().timestamp();
    let total_batches = articles.len().div_ceil(batch_size) as u32;

    for chunk in articles.chunks(batch_size) {
        batch_count += 1;
        emit_triage_progress(
            &app,
            "batch",
            batch_count as u32 - 1,
            total_batches,
            &format!(
                "Triaging {}/{} ({} articles)",
                batch_count,
                total_batches,
                articles.len()
            ),
        );

        // Compact TSV listing using numeric handles. UUIDs (36 chars each)
        // would eat most of the token budget otherwise.
        let mut listing = String::new();
        for (i, a) in chunk.iter().enumerate() {
            let excerpt: String = a
                .article
                .content_text
                .as_deref()
                .unwrap_or("")
                .chars()
                .take(200)
                .collect();
            let excerpt_clean = excerpt.replace(['\n', '\t'], " ");
            listing.push_str(&format!(
                "{}\t{}\t[{}]\t{}\n",
                i,
                a.article.title.trim(),
                a.feed_title,
                excerpt_clean
            ));
        }
        // ~30 output tokens per item is plenty for handle + priority + short reason.
        let max_tokens = (chunk.len() as i64 * 35 + 200).max(512);

        let request = ChatRequest {
            model: model.clone(),
            messages: vec![
                ChatMessage {
                    role: "system".to_string(),
                    content: prompts::triage_system_prompt(
                        preferences.as_ref(),
                        ai_settings.triage_user_prompt.as_deref(),
                    ),
                    content_blocks: None,
                },
                ChatMessage {
                    role: "user".to_string(),
                    content: prompts::triage_user_prompt(&listing),
                    content_blocks: None,
                },
            ],
            temperature: Some(0.3),
            max_tokens: Some(max_tokens),
            json_mode: true,
            tools: None,
        };

        match provider.chat(request).await {
            Ok(response) => {
                let content = response.content.trim();
                let json_str = extract_json_object(content).unwrap_or(content);
                match serde_json::from_str::<TriageResponse>(json_str) {
                    Ok(parsed) => {
                        let triage_items: Vec<crate::db::models::ArticleTriage> = parsed
                            .triage
                            .into_iter()
                            .filter_map(|t| {
                                let article_id = match &t.id {
                                    serde_json::Value::Number(n) => n.as_u64().and_then(|i| {
                                        chunk.get(i as usize).map(|a| a.article.id.clone())
                                    }),
                                    serde_json::Value::String(s) => {
                                        if let Ok(i) = s.trim().parse::<usize>() {
                                            chunk.get(i).map(|a| a.article.id.clone())
                                        } else if chunk.iter().any(|a| a.article.id == *s) {
                                            Some(s.clone())
                                        } else {
                                            None
                                        }
                                    }
                                    _ => None,
                                }?;
                                Some(crate::db::models::ArticleTriage {
                                    article_id,
                                    priority: t.priority.clamp(1, 5),
                                    reason: t.reason,
                                    provider: Some(provider.name().to_string()),
                                    model: Some(model.clone()),
                                    created_at: now,
                                })
                            })
                            .collect();

                        triaged_count += triage_items.len() as i32;
                        let conn = db.conn.lock().map_err(|e| e.to_string())?;
                        queries::upsert_triage_batch(&conn, &triage_items)
                            .map_err(|e| e.to_string())?;
                    }
                    Err(e) => {
                        log::warn!(
                            "Failed to parse triage batch {}: {}. Response: {}",
                            batch_count,
                            e,
                            &content[..content.len().min(300)]
                        );
                        errors.push(format!("Batch {}: parse error: {}", batch_count, e));
                    }
                }
            }
            Err(e) => {
                log::warn!("Triage batch {} failed: {}", batch_count, e);
                errors.push(format!("Batch {}: {}", batch_count, e));
            }
        }

        emit_triage_progress(
            &app,
            "batch",
            batch_count as u32,
            total_batches,
            &format!("Triaged {}/{}", batch_count, total_batches),
        );
    }

    // Post-triage rerank: adjust priorities so articles similar to what the
    // reader already cares about (starred, long-read, chatted) bubble up,
    // and dominant topics in the current batch get a boost.
    {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let signal_titles = queries::collect_signal_titles(&conn, 40).unwrap_or_default();
        let triaged = queries::list_unread_triaged(&conn).unwrap_or_default();
        let adjustments = compute_rerank_adjustments(&signal_titles, &triaged);
        for (article_id, new_priority) in adjustments {
            let _ = queries::update_triage_priority(&conn, &article_id, new_priority);
        }
    }

    emit_triage_progress(
        &app,
        "done",
        total_batches,
        total_batches,
        &format!("Triaged {} articles", triaged_count),
    );

    Ok(crate::db::models::TriageResult {
        triaged_count,
        batches: batch_count,
        errors,
    })
}

fn extract_keywords(text: &str) -> std::collections::HashSet<String> {
    const STOPWORDS: &[&str] = &[
        "the", "and", "for", "that", "this", "with", "from", "your", "about", "into", "over",
        "have", "has", "been", "were", "was", "are", "not", "how", "why", "when", "what", "who",
        "which", "will", "just", "its", "they", "them", "their", "there", "these", "those", "then",
        "than", "because", "also", "some", "more", "most", "like", "between", "against", "upon",
        "after", "before", "during", "only", "such", "any", "all", "but", "can", "you", "your",
        "our",
    ];
    let stop: std::collections::HashSet<&str> = STOPWORDS.iter().copied().collect();
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| w.len() >= 4 && !stop.contains(w))
        .map(|w| w.to_string())
        .collect()
}

/// Given signal titles (starred/engaged) and the current triaged set, return
/// the adjusted priorities for any articles that moved.
fn compute_rerank_adjustments(
    signal_titles: &[String],
    triaged: &[(String, String, i32)],
) -> Vec<(String, i32)> {
    let signal_keywords: std::collections::HashSet<String> = signal_titles
        .iter()
        .flat_map(|t| extract_keywords(t))
        .collect();

    // Build per-article keyword sets.
    let per_article: Vec<(String, std::collections::HashSet<String>, i32)> = triaged
        .iter()
        .map(|(id, title, pri)| (id.clone(), extract_keywords(title), *pri))
        .collect();

    // Cluster sizes: for each article, count how many others share >= 2 keywords.
    let mut cluster_size: Vec<usize> = vec![0; per_article.len()];
    for i in 0..per_article.len() {
        for j in 0..per_article.len() {
            if i == j {
                continue;
            }
            let overlap = per_article[i].1.intersection(&per_article[j].1).count();
            if overlap >= 2 {
                cluster_size[i] += 1;
            }
        }
    }

    let mut out = Vec::new();
    for (i, (id, kws, orig_pri)) in per_article.iter().enumerate() {
        let starred_overlap = kws.intersection(&signal_keywords).count();
        let cluster = cluster_size[i];
        let mut new_pri = *orig_pri;

        // Starred/engagement signal
        if starred_overlap >= 3 {
            new_pri += 2;
        } else if starred_overlap >= 1 {
            new_pri += 1;
        }

        // Cluster volume signal
        if cluster >= 5 {
            new_pri += 2;
        } else if cluster >= 2 {
            new_pri += 1;
        }

        // Isolated + no signal = likely noise
        if cluster == 0 && starred_overlap == 0 && kws.len() >= 3 {
            new_pri -= 1;
        }

        new_pri = new_pri.clamp(1, 5);
        if new_pri != *orig_pri {
            out.push((id.clone(), new_pri));
        }
    }
    out
}

#[tauri::command]
pub async fn get_inbox_articles(
    db: State<'_, Database>,
    min_priority: Option<i32>,
    is_read: Option<bool>,
    limit: Option<i64>,
    offset: Option<i64>,
) -> Result<Vec<crate::db::models::ArticleWithTriage>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::get_inbox_articles(
        &conn,
        min_priority,
        is_read,
        limit.unwrap_or(1000),
        offset.unwrap_or(0),
    )
    .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_triage_stats(
    db: State<'_, Database>,
) -> Result<crate::db::models::TriageStats, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::get_triage_stats(&conn).map_err(|e| e.to_string())
}

// ── Learning / interaction tracking ───────────────────────────────────

#[tauri::command]
pub async fn record_reading_time(
    db: State<'_, Database>,
    article_id: String,
    seconds: i64,
) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let now = Utc::now().timestamp();
    queries::record_reading_time(&conn, &article_id, seconds, now).map_err(|e| e.to_string())?;
    let cap = read_recent_cap(&conn);
    let _ = queries::prune_interactions(&conn, cap);
    Ok(())
}

fn read_recent_cap(conn: &rusqlite::Connection) -> i64 {
    let settings: crate::db::models::AppSettings = queries::get_setting(conn, "app_settings")
        .ok()
        .flatten()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    settings.sync.recent_cap as i64
}

#[tauri::command]
pub async fn get_recent_articles(
    db: State<'_, Database>,
    order: Option<String>,
    limit: Option<i64>,
) -> Result<Vec<crate::db::models::ArticleWithInteraction>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let order = order.unwrap_or_else(|| "engagement".to_string());
    let limit = limit.unwrap_or(500).min(3000);
    queries::list_recent_articles(&conn, &order, limit).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn remove_recent_article(
    db: State<'_, Database>,
    article_id: String,
) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::delete_interaction(&conn, &article_id).map_err(|e| e.to_string())
}

// --- Quick Catch-up ---------------------------------------------------------
//
// The front page is built in two passes so the reader sees it fill in rather
// than watching a blank panel: the first picks and groups the stories and
// writes their headlines, the second reads the articles behind each story and
// writes its lede. Every pass emits the page so far on `catchup_progress`.

/// A story on the front page. `lede` is empty between the two passes.
#[derive(Serialize, Clone)]
pub struct CatchupStory {
    pub headline: String,
    pub lede: String,
    pub article_ids: Vec<String>,
}

/// A one-line item below the fold.
#[derive(Serialize, Clone)]
pub struct CatchupBrief {
    pub text: String,
    pub article_ids: Vec<String>,
}

/// An article cited on the page, with a name fit to print under a story.
#[derive(Serialize, Clone)]
pub struct CatchupSource {
    pub id: String,
    pub title: String,
    pub publication: String,
    pub url: Option<String>,
    pub published_at: Option<i64>,
}

#[derive(Serialize, Clone, Default)]
pub struct CatchupReport {
    pub stories: Vec<CatchupStory>,
    pub briefs: Vec<CatchupBrief>,
    pub sources: Vec<CatchupSource>,
    /// How many articles the chosen scope and time range actually selected.
    /// Rendered in the dialog so the reader can see the scope doing something
    /// — without it, "Priority inbox" and "All unread" look identical.
    pub article_count: u32,
}

pub const CATCHUP_PROGRESS_EVENT: &str = "catchup_progress";

/// The page as it stands, pushed to the UI after every step.
#[derive(Serialize, Clone)]
struct CatchupProgress {
    /// "reading", "picking", "writing" or "done".
    stage: String,
    completed: u32,
    total: u32,
    message: String,
    report: CatchupReport,
}

fn emit_catchup(
    app: &AppHandle,
    stage: &str,
    completed: u32,
    total: u32,
    message: &str,
    report: &CatchupReport,
) {
    let _ = app.emit(
        CATCHUP_PROGRESS_EVENT,
        CatchupProgress {
            stage: stage.to_string(),
            completed,
            total,
            message: message.to_string(),
            report: report.clone(),
        },
    );
}

#[derive(Deserialize)]
struct CatchupPageRaw {
    #[serde(default, alias = "items", alias = "takeaways")]
    stories: Vec<CatchupStoryRaw>,
    #[serde(default, alias = "notable_mentions", alias = "mentions", alias = "also")]
    briefs: Vec<CatchupBriefRaw>,
}

#[derive(Deserialize)]
struct CatchupStoryRaw {
    #[serde(default, alias = "title", alias = "text")]
    headline: String,
    #[serde(default, alias = "summary")]
    lede: String,
    #[serde(default, alias = "article_ids", alias = "articles", alias = "ids")]
    article_ids: serde_json::Value,
}

#[derive(Deserialize)]
struct CatchupBriefRaw {
    #[serde(default, alias = "headline", alias = "summary")]
    text: String,
    #[serde(default, alias = "article_ids", alias = "articles", alias = "ids")]
    article_ids: serde_json::Value,
}

#[derive(Deserialize)]
struct CatchupLedeRaw {
    #[serde(default, alias = "summary", alias = "text")]
    lede: String,
}

fn resolve_handles(
    v: &serde_json::Value,
    articles: &[crate::db::models::ArticleWithFeed],
) -> Vec<String> {
    let arr = match v.as_array() {
        Some(a) => a,
        None => return vec![],
    };
    arr.iter()
        .filter_map(|x| match x {
            serde_json::Value::Number(n) => n
                .as_u64()
                .and_then(|i| articles.get(i as usize).map(|a| a.article.id.clone())),
            serde_json::Value::String(s) => {
                if let Ok(i) = s.trim().parse::<usize>() {
                    articles.get(i).map(|a| a.article.id.clone())
                } else if articles.iter().any(|a| a.article.id == *s) {
                    Some(s.clone())
                } else {
                    None
                }
            }
            _ => None,
        })
        .collect()
}

/// Lowercased words only, for spotting the same item written twice.
fn normalize_for_dedup(text: &str) -> String {
    text.split_whitespace()
        .map(|word| {
            word.chars()
                .filter(|c| c.is_alphanumeric())
                .flat_map(|c| c.to_lowercase())
                .collect::<String>()
        })
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

const CATCHUP_POOL_LIMIT: usize = 100;
const CATCHUP_MAX_STORIES: usize = 6;
const CATCHUP_MAX_BRIEFS: usize = 6;
/// Triage priority a story must reach to count as "priority inbox" for a
/// briefing. Triage is told most articles should land at 2-3, so the old bar of
/// 3 let the whole middle of the scale through and catch-up on "Priority inbox"
/// read exactly like catch-up on everything.
const CATCHUP_INBOX_MIN_PRIORITY: i32 = 4;
/// Articles cited under one story. The model occasionally hands a single item
/// every handle it was given; the byline is a citation, not a manifest.
const CATCHUP_MAX_CITATIONS_PER_STORY: usize = 4;
const CATCHUP_MAX_CITATIONS_PER_BRIEF: usize = 2;
/// Articles read in full when writing one story's lede.
const CATCHUP_ARTICLES_PER_LEDE: usize = 4;
/// Characters of each of those articles handed to the model.
const CATCHUP_LEDE_TEXT_CHARS: usize = 3000;
/// Characters of each article in the first pass, which only picks and groups.
const CATCHUP_PICK_EXCERPT_CHARS: usize = 400;

/// Text the model copied out of the prompt instead of writing.
///
/// Weaker models answer a JSON request by returning the example unchanged, or
/// by filling its placeholder with the feed's name ("Short sentence about the
/// Hacker News article"). That parses cleanly, so nothing downstream rejects
/// it and the page renders a column of template strings. Catch it here, at the
/// only point where prompt text and model output meet.
fn is_placeholder_text(text: &str) -> bool {
    let normalized = normalize_for_dedup(text);
    if normalized.is_empty() {
        return true;
    }
    // Stems lifted from the examples in `prompts::catchup_*`, plus the shapes
    // the older one-pass prompt produced.
    const STEMS: &[&str] = &[
        "short sentence",
        "one concrete sentence",
        "one tight sentence",
        "actor does specific thing",
        "what happened with the specifics",
        "a short sentence",
        "brief summary of the article",
        "summary of the article",
        "headline here",
        "your headline",
        "lorem ipsum",
    ];
    if STEMS.iter().any(|stem| normalized.starts_with(stem)) {
        return true;
    }
    // "... about the Hacker News article", "... about the Finance & economics
    // article" — the placeholder with a feed name dropped into it.
    if normalized.contains("about the") && normalized.ends_with("article") {
        return true;
    }
    false
}

/// The articles one item may cite: unclaimed ones in the order the model gave
/// them, capped at `max`.
///
/// Only the ones kept are marked claimed. Marking the overflow too would take
/// those articles off the page entirely — they would belong to an item that
/// does not cite them and be unavailable to any later one.
fn claim_citations(
    handles: &serde_json::Value,
    pool: &[crate::db::models::ArticleWithFeed],
    claimed: &mut std::collections::HashSet<String>,
    max: usize,
) -> Vec<String> {
    let mut kept = Vec::new();
    for id in resolve_handles(handles, pool) {
        if kept.len() >= max {
            break;
        }
        if claimed.contains(&id) {
            continue;
        }
        claimed.insert(id.clone());
        kept.push(id);
    }
    kept
}

/// A short fallback lede for when the second pass fails for one story, so a
/// story never renders with nothing under it.
fn excerpt_lede(text: &str) -> String {
    let cleaned = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if cleaned.chars().count() <= 240 {
        return cleaned;
    }
    let clipped: String = cleaned.chars().take(240).collect();
    match clipped.rfind(['.', '!', '?']) {
        Some(end) if end > 80 => clipped[..=end].to_string(),
        _ => format!("{}…", clipped.trim_end()),
    }
}

/// The cutoff, in unix seconds, for a "catch up on the last N hours" request.
/// `None` (or a non-positive value) means the whole unread backlog, which is
/// what catch-up did before the reader could choose.
fn catchup_cutoff(since_hours: Option<i64>, now: i64) -> Option<i64> {
    match since_hours {
        Some(hours) if hours > 0 => Some(now - hours * 3600),
        _ => None,
    }
}

#[tauri::command]
pub async fn generate_catchup_report(
    app: AppHandle,
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
    scope: Option<String>,
    since_hours: Option<i64>,
) -> Result<CatchupReport, String> {
    let now = chrono::Utc::now().timestamp();
    let published_after = catchup_cutoff(since_hours, now);
    let scoped_to_inbox = scope.as_deref() == Some("inbox");

    let (pool, settings_json) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let settings_json =
            queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;
        let pool: Vec<crate::db::models::ArticleWithFeed> = if scoped_to_inbox {
            let inbox = queries::get_inbox_articles_since(
                &conn,
                Some(CATCHUP_INBOX_MIN_PRIORITY),
                Some(false),
                published_after,
                CATCHUP_POOL_LIMIT as i64,
                0,
            )
            .map_err(|e| e.to_string())?;
            inbox
                .into_iter()
                .map(|a| crate::db::models::ArticleWithFeed {
                    article: a.article,
                    feed_title: a.feed_title,
                    feed_icon_url: a.feed_icon_url,
                })
                .collect()
        } else {
            queries::get_articles(
                &conn,
                &crate::db::models::ArticleFilter {
                    is_read: Some(false),
                    limit: Some(CATCHUP_POOL_LIMIT as i64),
                    published_after,
                    ..Default::default()
                },
            )
            .map_err(|e| e.to_string())?
        };
        (pool, settings_json)
    };

    let mut report = CatchupReport {
        article_count: pool.len() as u32,
        ..Default::default()
    };

    if pool.is_empty() {
        let message = match (scoped_to_inbox, published_after.is_some()) {
            (true, true) => "No high-priority articles in that time range.",
            (true, false) => "No high-priority articles to catch up on.",
            (false, true) => "Nothing unread in that time range.",
            (false, false) => "Nothing unread to catch up on.",
        };
        emit_catchup(&app, "done", 0, 0, message, &report);
        return Ok(report);
    }

    let settings: crate::db::models::AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();

    if settings.ai.provider == "none" {
        return Err("No AI provider configured.".to_string());
    }

    let mut ai_settings = settings.ai.clone();
    ai_settings.oauth_access_token = crate::ai::claude_oauth::stored_access_token(&db);
    let provider = create_provider_with_app(&ai_settings, Some(model_state.inner().clone()), &app)?;
    let model = ai_settings
        .model
        .clone()
        .unwrap_or_else(|| default_model(&ai_settings.provider));

    emit_catchup(
        &app,
        "reading",
        0,
        pool.len() as u32,
        &format!("Reading {} articles…", pool.len()),
        &report,
    );

    // --- Pass one: pick the stories and write their headlines ---------------

    let mut listing = String::new();
    for (i, a) in pool.iter().enumerate() {
        let excerpt: String = a
            .article
            .content_text
            .as_deref()
            .unwrap_or("")
            .chars()
            .take(CATCHUP_PICK_EXCERPT_CHARS)
            .collect();
        let clean = excerpt.replace(['\n', '\t'], " ");
        let publication = crate::ai::publication::publication_name(
            &a.feed_title,
            a.article.url.as_deref(),
        );
        listing.push_str(&format!(
            "{}\t{}\t[{}]\t{}\n",
            i,
            a.article.title.trim(),
            publication,
            clean
        ));
    }

    let page_request = ChatRequest {
        model: model.clone(),
        messages: vec![
            ChatMessage {
                role: "system".to_string(),
                content: prompts::catchup_page_system_prompt(
                    ai_settings.triage_user_prompt.as_deref(),
                ),
                content_blocks: None,
            },
            ChatMessage {
                role: "user".to_string(),
                content: prompts::catchup_page_user_prompt(&listing),
                content_blocks: None,
            },
        ],
        temperature: Some(0.3),
        max_tokens: Some(1500),
        json_mode: true,
        tools: None,
    };

    let response = provider.chat(page_request).await?;
    let content = response.content.trim();
    let json_str = extract_json_object(content).unwrap_or(content);
    let raw: CatchupPageRaw = serde_json::from_str(json_str).map_err(|e| {
        format!(
            "Failed to parse catchup response: {}. Raw: {}",
            e,
            &content[..content.len().min(300)]
        )
    })?;

    // The model is told each article belongs to one item only; hold it to that
    // here so nothing appears twice on the page.
    let mut claimed: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut seen_text: std::collections::HashSet<String> = std::collections::HashSet::new();

    for story in raw.stories {
        if report.stories.len() >= CATCHUP_MAX_STORIES {
            break;
        }
        let headline = story.headline.trim().to_string();
        if headline.is_empty()
            || is_placeholder_text(&headline)
            || !seen_text.insert(normalize_for_dedup(&headline))
        {
            continue;
        }
        let article_ids = claim_citations(
            &story.article_ids,
            &pool,
            &mut claimed,
            CATCHUP_MAX_CITATIONS_PER_STORY,
        );
        if article_ids.is_empty() {
            // Every article behind it already ran under an earlier story.
            continue;
        }
        let lede = story.lede.trim();
        report.stories.push(CatchupStory {
            headline,
            lede: if is_placeholder_text(lede) {
                String::new()
            } else {
                lede.to_string()
            },
            article_ids,
        });
    }

    for brief in raw.briefs {
        if report.briefs.len() >= CATCHUP_MAX_BRIEFS {
            break;
        }
        let text = brief.text.trim().to_string();
        if text.is_empty()
            || is_placeholder_text(&text)
            || !seen_text.insert(normalize_for_dedup(&text))
        {
            continue;
        }
        let article_ids = claim_citations(
            &brief.article_ids,
            &pool,
            &mut claimed,
            CATCHUP_MAX_CITATIONS_PER_BRIEF,
        );
        if article_ids.is_empty() {
            continue;
        }
        report.briefs.push(CatchupBrief { text, article_ids });
    }

    report.sources = pool
        .iter()
        .filter(|a| claimed.contains(&a.article.id))
        .map(|a| CatchupSource {
            id: a.article.id.clone(),
            title: a.article.title.clone(),
            publication: crate::ai::publication::publication_name(
                &a.feed_title,
                a.article.url.as_deref(),
            ),
            url: a.article.url.clone(),
            published_at: a.article.published_at,
        })
        .collect();

    let story_count = report.stories.len() as u32;
    emit_catchup(
        &app,
        "picking",
        0,
        story_count,
        &match story_count {
            0 => "Nothing on the page yet…".to_string(),
            1 => "Writing the lead story…".to_string(),
            n => format!("Writing {n} stories…"),
        },
        &report,
    );

    // --- Pass two: write each lede from the articles behind it --------------

    let by_id: HashMap<&str, &crate::db::models::ArticleWithFeed> = pool
        .iter()
        .map(|a| (a.article.id.as_str(), a))
        .collect();

    for index in 0..report.stories.len() {
        let (headline, article_ids) = {
            let story = &report.stories[index];
            (story.headline.clone(), story.article_ids.clone())
        };

        let mut articles_text = String::new();
        for id in article_ids.iter().take(CATCHUP_ARTICLES_PER_LEDE) {
            let Some(a) = by_id.get(id.as_str()) else {
                continue;
            };
            let body: String = a
                .article
                .content_text
                .as_deref()
                .unwrap_or("")
                .chars()
                .take(CATCHUP_LEDE_TEXT_CHARS)
                .collect();
            articles_text.push_str(&format!(
                "--- {} [{}]\n{}\n\n",
                a.article.title.trim(),
                crate::ai::publication::publication_name(
                    &a.feed_title,
                    a.article.url.as_deref()
                ),
                body.trim()
            ));
        }

        let lede = if articles_text.trim().is_empty() {
            String::new()
        } else {
            let lede_request = ChatRequest {
                model: model.clone(),
                messages: vec![
                    ChatMessage {
                        role: "system".to_string(),
                        content: prompts::catchup_lede_system_prompt(),
                        content_blocks: None,
                    },
                    ChatMessage {
                        role: "user".to_string(),
                        content: prompts::catchup_lede_user_prompt(&headline, &articles_text),
                        content_blocks: None,
                    },
                ],
                temperature: Some(0.3),
                max_tokens: Some(300),
                json_mode: true,
                tools: None,
            };

            match provider.chat(lede_request).await {
                Ok(lede_response) => {
                    let text = lede_response.content.trim().to_string();
                    let parsed = extract_json_object(&text)
                        .and_then(|json| serde_json::from_str::<CatchupLedeRaw>(json).ok())
                        .map(|raw| raw.lede.trim().to_string())
                        .filter(|lede| !lede.is_empty() && !is_placeholder_text(lede));
                    // A provider that ignored json_mode still gave us prose.
                    parsed.unwrap_or_else(|| {
                        if text.starts_with('{') || is_placeholder_text(&text) {
                            String::new()
                        } else {
                            text
                        }
                    })
                }
                Err(_) => String::new(),
            }
        };

        let fallback = || {
            article_ids
                .first()
                .and_then(|id| by_id.get(id.as_str()))
                .and_then(|a| a.article.content_text.as_deref())
                .map(excerpt_lede)
                .unwrap_or_default()
        };

        report.stories[index].lede = if lede.is_empty() { fallback() } else { lede };

        let completed = index as u32 + 1;
        emit_catchup(
            &app,
            "writing",
            completed,
            story_count,
            &format!("Writing story {completed} of {story_count}…"),
            &report,
        );
    }

    emit_catchup(&app, "done", story_count, story_count, "", &report);

    Ok(report)
}

#[tauri::command]
pub async fn count_read_matches(db: State<'_, Database>, query: String) -> Result<i64, String> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Ok(0);
    }
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::count_read_matches(&conn, trimmed).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn set_article_feedback(
    db: State<'_, Database>,
    article_id: String,
    feedback: Option<String>,
) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let now = Utc::now().timestamp();
    queries::set_article_feedback(&conn, &article_id, feedback.as_deref(), now)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn set_priority_override(
    db: State<'_, Database>,
    article_id: String,
    priority: i32,
) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let now = Utc::now().timestamp();
    queries::set_priority_override(&conn, &article_id, priority.clamp(1, 5), now)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_preference_profile(
    db: State<'_, Database>,
) -> Result<crate::db::models::UserPreferenceProfile, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::build_preference_profile(&conn).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_article_interaction(
    db: State<'_, Database>,
    article_id: String,
) -> Result<Option<crate::db::models::ArticleInteraction>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::get_article_interaction(&conn, &article_id).map_err(|e| e.to_string())
}

#[cfg(test)]
mod catchup_tests {
    use super::*;

    #[test]
    fn placeholder_text_catches_prompt_examples_the_model_echoed() {
        // Exactly what the dialog rendered when a weak model returned the
        // prompt's own example instead of writing anything.
        assert!(is_placeholder_text("Short sentence"));
        assert!(is_placeholder_text("Short sentence about the Hacker News article"));
        assert!(is_placeholder_text(
            "Short sentence about the Finance & economics article"
        ));
        assert!(is_placeholder_text("Actor does specific thing"));
        assert!(is_placeholder_text(
            "One concrete sentence about what happened."
        ));
        assert!(is_placeholder_text("   "));
    }

    #[test]
    fn placeholder_text_leaves_real_writing_alone() {
        assert!(!is_placeholder_text(
            "ByteDance open-sources its RL training stack"
        ));
        assert!(!is_placeholder_text(
            "Apple delayed the rebuilt Siri to spring 2026, its second slip this year."
        ));
        // A real sentence that happens to mention an article.
        assert!(!is_placeholder_text(
            "Stripe's engineering blog walks through the outage in a detailed article."
        ));
    }

    #[test]
    fn cutoff_is_relative_to_now_and_absent_without_a_range() {
        let now = 1_700_000_000;
        assert_eq!(catchup_cutoff(Some(24), now), Some(now - 86_400));
        assert_eq!(catchup_cutoff(Some(6), now), Some(now - 21_600));
        assert_eq!(catchup_cutoff(None, now), None);
        // A nonsense range means the whole backlog, not an empty page.
        assert_eq!(catchup_cutoff(Some(0), now), None);
        assert_eq!(catchup_cutoff(Some(-5), now), None);
    }

    #[test]
    fn citations_are_capped_and_only_the_kept_ones_are_claimed() {
        let pool: Vec<crate::db::models::ArticleWithFeed> = (0..6)
            .map(|i| crate::db::models::ArticleWithFeed {
                article: crate::db::models::Article {
                    id: format!("a{i}"),
                    feed_id: "f".into(),
                    title: format!("Title {i}"),
                    url: None,
                    author: None,
                    content_html: None,
                    content_text: None,
                    published_at: None,
                    fetched_at: 0,
                    is_read: false,
                    is_starred: false,
                    feedly_entry_id: None,
                    comments_url: None,
                },
                feed_title: "Feed".into(),
                feed_icon_url: None,
            })
            .collect();

        let mut claimed = std::collections::HashSet::new();
        let handles = serde_json::json!([0, 1, 2, 3, 4, 5]);
        let kept = claim_citations(&handles, &pool, &mut claimed, 2);

        assert_eq!(kept, vec!["a0".to_string(), "a1".to_string()]);
        // The overflow stays available to a later story rather than vanishing.
        assert_eq!(claimed.len(), 2);
        let next = claim_citations(&serde_json::json!([2, 3]), &pool, &mut claimed, 2);
        assert_eq!(next, vec!["a2".to_string(), "a3".to_string()]);
    }
}
