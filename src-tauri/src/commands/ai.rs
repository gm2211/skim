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
use std::sync::Arc;
use crate::AppHandle;
use futures_util::future::{AbortHandle, AbortRegistration, Abortable, Aborted};
use tauri::{Emitter, State};
#[cfg(target_os = "ios")]
use tauri_plugin_skim_ai::{CompleteArgs, SkimAiExt};
use tokio::sync::Mutex;
use uuid::Uuid;

const SUMMARY_CACHE_MAX: usize = 100;

/// Cancellation and publication share one linearization point. Never hold
/// this synchronous guard across an await (cache lock is acquired first).
#[derive(Default)]
pub struct SummaryGeneration(std::sync::Mutex<u64>);

impl SummaryGeneration {
    fn begin(&self) -> Result<u64, String> {
        let mut current = self.0.lock().map_err(|e| e.to_string())?;
        *current = current.checked_add(1).ok_or("Summary generation exhausted")?;
        Ok(*current)
    }

    fn check(&self, id: u64) -> Result<(), String> {
        self.with_current(id, || Ok(()))
    }

    fn with_current<T>(&self, id: u64, action: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
        let current = self.0.lock().map_err(|e| e.to_string())?;
        if *current != id { return Err("Summary cancelled".into()); }
        let result = action();
        drop(current);
        result
    }
}

/// The message a cancelled Quick Catch-up run resolves with, so the frontend
/// can tell an explicit stop apart from a real failure.
pub const CATCHUP_CANCELLED: &str = "Catch-up cancelled";

/// Tracks the single in-flight Quick Catch-up run. The backend only ever runs
/// one at a time: starting a new run aborts whatever was running before it,
/// and an explicit stop aborts the current one. Never hold this synchronous
/// guard across an await.
#[derive(Default)]
pub struct CatchupRuns(std::sync::Mutex<Option<(String, AbortHandle)>>);

impl CatchupRuns {
    /// Registers `run_id` as the current run, aborting whatever run held the
    /// slot before it.
    fn begin(&self, run_id: &str) -> AbortRegistration {
        let (handle, registration) = AbortHandle::new_pair();
        let mut slot = self.0.lock().unwrap();
        if let Some((_, previous)) = slot.take() {
            previous.abort();
        }
        *slot = Some((run_id.to_string(), handle));
        registration
    }

    /// Aborts the run named by `run_id`, or whichever run is current when
    /// `run_id` is `None`.
    fn cancel(&self, run_id: Option<&str>) {
        let slot = self.0.lock().unwrap();
        if let Some((current_id, handle)) = slot.as_ref() {
            let matches_current = match run_id {
                Some(id) => id == current_id,
                None => true,
            };
            if matches_current {
                handle.abort();
            }
        }
    }

    /// Clears the slot, but only if it still holds `run_id` — a finished run
    /// must never clear the slot a newer run has since claimed.
    fn finish(&self, run_id: &str) {
        let mut slot = self.0.lock().unwrap();
        if slot.as_ref().map(|(id, _)| id.as_str()) == Some(run_id) {
            *slot = None;
        }
    }
}

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

/// Both cached responses and forced invalidation obey cancellation, including
/// requests cancelled while waiting for the asynchronous memory-cache lock.
async fn cached_summary(
    db: &Database, cache: &SharedSummaryCache, generation: &SummaryGeneration,
    id: u64, article_id: &str, key: &str, force: bool,
) -> Result<Option<ArticleSummary>, String> {
    let mut cache = cache.lock().await;
    generation.with_current(id, || {
        if !force {
            if let Some(existing) = cache.get(key) { return Ok(Some(existing.clone())); }
        }
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        if force {
            queries::delete_article_summary(&conn, article_id, key).map_err(|e| e.to_string())?;
            cache.remove(key);
            return Ok(None);
        }
        let existing = queries::get_article_summary(&conn, article_id, key).map_err(|e| e.to_string())?;
        if let Some(ref summary) = existing { cache.insert(key.to_string(), summary.clone()); }
        Ok(existing)
    })
}

/// Commit both caches and accept the result atomically with respect to cancel
/// and newer summary requests. No inference or await occurs under the guard.
async fn publish_summary(
    db: &Database, cache: &SharedSummaryCache, generation: &SummaryGeneration,
    id: u64, key: &str, summary: ArticleSummary,
) -> Result<ArticleSummary, String> {
    let mut cache = cache.lock().await;
    generation.with_current(id, || {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::upsert_article_summary(&conn, key, &summary).map_err(|e| e.to_string())?;
        cache.insert(key.to_string(), summary.clone());
        Ok(summary)
    })
}

fn summary_cache_key(article_id: &str, title: &str, evidence: &str, ai: &AiSettings) -> String {
    #[derive(Serialize)]
    struct SummaryKey<'a> {
        prompt_version: u32,
        plan: crate::db::story_policy::SummaryPlan,
        article_id: &'a str,
        article_title: &'a str,
        source_fingerprint: String,
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
        prompt_version: 4, // Shared normalized length and bounded output budgets.
        plan: crate::db::story_policy::summary_plan(ai.summary_length.as_deref(),
            ai.summary_custom_word_count.map(i64::from)),
        article_id,
        article_title: title,
        source_fingerprint: format!("{:x}", Sha256::digest(evidence.as_bytes())),
        provider: &ai.provider,
        model: ai.model.as_deref(),
        endpoint: ai.endpoint.as_deref(),
        local_model_path: ai.local_model_path.as_deref(),
        summary_length: ai.summary_length.as_deref(),
        summary_tone: ai.summary_tone.as_deref(),
        summary_format: ai.summary_format.as_deref(),
        summary_custom_prompt: ai.summary_custom_prompt.as_deref(),
        summary_custom_word_count: (ai.summary_length.as_deref() == Some("custom")).then(||
            crate::db::story_policy::summary_plan(ai.summary_length.as_deref(),
                ai.summary_custom_word_count.map(i64::from)).word_count),
    };

    let bytes = serde_json::to_vec(&key).unwrap_or_default();
    let digest = Sha256::digest(bytes);
    format!("{digest:x}")
}

#[cfg(test)]
mod summary_cache_tests {
    use super::*;

    fn fixture() -> (Database, SharedSummaryCache, ArticleSummary) {
        let db = Database::new(std::env::temp_dir().join(format!("skim-summary-cancel-{}", uuid::Uuid::new_v4()))).unwrap();
        db.conn.lock().unwrap().execute_batch(
            "INSERT INTO feeds (id,title,url,created_at,updated_at) VALUES ('feed','Feed','https://example.test',0,0);
             INSERT INTO articles (id,feed_id,title,fetched_at) VALUES ('article','feed','Title',0);"
        ).unwrap();
        let cache = Arc::new(Mutex::new(SummaryCache::new()));
        let summary = ArticleSummary {
            article_id: "article".into(), bullet_summary: None,
            full_summary: Some("Late model completion".into()), provider: Some("custom".into()),
            model: Some("configured-model".into()), created_at: 1,
        };
        (db, cache, summary)
    }

    #[tokio::test]
    async fn cancellation_while_publication_waits_cannot_write_either_cache() {
        let (db, cache, summary) = fixture();
        let generation = SummaryGeneration::default();
        let id = generation.begin().unwrap();
        generation.check(id).unwrap(); // Earlier cancellation check passed.
        let held = cache.lock().await;
        let publication = publish_summary(&db, &cache, &generation, id, "key", summary);
        tokio::pin!(publication);
        assert!(futures_util::poll!(&mut publication).is_pending());
        generation.begin().unwrap(); // Cancel while awaiting the cache lock.
        drop(held);
        assert_eq!(publication.await.unwrap_err(), "Summary cancelled");
        assert!(cache.lock().await.get("key").is_none());
        assert!(queries::get_article_summary(&db.conn.lock().unwrap(), "article", "key").unwrap().is_none());
    }

    #[tokio::test]
    async fn newer_generation_survives_late_old_completion_and_can_reload_from_sqlite() {
        let (db, cache, old) = fixture();
        let generation = SummaryGeneration::default();
        let old_id = generation.begin().unwrap();
        let new_id = generation.begin().unwrap();
        let mut current = old.clone();
        current.full_summary = Some("Current result".into());
        publish_summary(&db, &cache, &generation, new_id, "key", current).await.unwrap();
        assert_eq!(publish_summary(&db, &cache, &generation, old_id, "key", old).await.unwrap_err(), "Summary cancelled");
        assert_eq!(cache.lock().await.get("key").unwrap().full_summary.as_deref(), Some("Current result"));
        cache.lock().await.clear();
        let restored = cached_summary(&db, &cache, &generation, new_id, "article", "key", false).await.unwrap().unwrap();
        assert_eq!(restored.full_summary.as_deref(), Some("Current result"));
        assert_eq!(cache.lock().await.get("key").unwrap().full_summary.as_deref(), Some("Current result"));
    }

    #[tokio::test]
    async fn cancelled_cache_hits_and_force_requests_do_not_return_or_delete_results() {
        let (db, cache, summary) = fixture();
        let generation = SummaryGeneration::default();
        let id = generation.begin().unwrap();
        publish_summary(&db, &cache, &generation, id, "key", summary).await.unwrap();
        generation.begin().unwrap();
        for force in [false, true] {
            assert_eq!(cached_summary(&db, &cache, &generation, id, "article", "key", force).await.unwrap_err(), "Summary cancelled");
        }
        assert!(cache.lock().await.get("key").is_some());
        cache.lock().await.clear();
        assert_eq!(cached_summary(&db, &cache, &generation, id, "article", "key", false).await.unwrap_err(), "Summary cancelled");
        assert!(cache.lock().await.get("key").is_none());
        assert!(queries::get_article_summary(&db.conn.lock().unwrap(), "article", "key").unwrap().is_some());
    }

    #[test]
    fn cache_keys_normalize_unused_counts_without_colliding_different_effective_plans() {
        let mut ai = crate::db::models::AppSettings::default().ai;
        ai.summary_length = Some("long".into());
        let key = summary_cache_key("a", "title", "source", &ai);
        ai.summary_custom_word_count = Some(i32::MAX);
        assert_eq!(key, summary_cache_key("a", "title", "source", &ai));
        ai.summary_length = Some("custom".into());
        let invalid = summary_cache_key("a", "title", "source", &ai);
        ai.summary_custom_word_count = Some(-100);
        assert_eq!(invalid, summary_cache_key("a", "title", "source", &ai));
        ai.summary_custom_word_count = None;
        assert_eq!(invalid, summary_cache_key("a", "title", "source", &ai));
        ai.summary_custom_word_count = Some(30);
        assert_ne!(invalid, summary_cache_key("a", "title", "source", &ai));
    }

    #[test]
    fn summary_cache_tracks_evidence_title_and_requested_detail() {
        let mut ai = crate::db::models::AppSettings::default().ai;
        let key = summary_cache_key("article", "Initial headline", "RSS teaser.", &ai);
        let summary = ArticleSummary {
            article_id: "article".into(), bullet_summary: None,
            full_summary: Some("Summary of teaser.".into()), provider: None,
            model: None, created_at: 1,
        };
        let mut cache = SummaryCache::new();
        cache.insert(key.clone(), summary);
        assert!(cache.get(&summary_cache_key("article", "Initial headline", "RSS teaser.", &ai)).is_some());
        assert!(cache.get(&summary_cache_key("article", "Initial headline", "Full reader evidence with corrected facts.", &ai)).is_none());
        assert!(cache.get(&summary_cache_key("article", "Corrected headline", "RSS teaser.", &ai)).is_none());
        ai.summary_length = Some("long".into());
        assert!(cache.get(&summary_cache_key("article", "Initial headline", "RSS teaser.", &ai)).is_none());
    }
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
    generation.begin().map(|_| ())
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
    let gen_id = generation.begin()?;
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
        if !crate::db::story_policy::summary_custom_words_valid(i64::from(word_count)) {
            let (min, max) = crate::db::story_policy::summary_word_bounds();
            return Err(format!("Summary word count must be between {min} and {max}"));
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

    // Resolve evidence before looking up a summary: reader enrichment and feed
    // corrections must not reuse a summary of an older teaser for the same ID.
    let text = super::article_body::resolve_article_text(db.inner(), &article.article).await;
    if text.trim().is_empty() {
        return Err("No article content to summarize.".to_string());
    }
    generation.check(gen_id)?;
    let cache_key = summary_cache_key(&article_id, &article.article.title, &text, &settings.ai);
    if let Some(existing) = cached_summary(
        db.inner(), summary_cache.inner(), generation.inner(), gen_id,
        &article_id, &cache_key, force.unwrap_or(false),
    ).await? {
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
            let text = if provider_name == "mlx" {
                ios_local_summary_text(&text)
            } else {
                text.clone()
            };

            let plugin = app.skim_ai();
            let system_prompt = prompts::article_summary_system_prompt(&settings.ai);
            let repo_id = settings.ai.model.clone();

            let bullet_prompt = prompts::article_bullet_summary_prompt(title, &text, &settings.ai);
            let bullet_text = if !bullet_prompt.is_empty() {
                let args = CompleteArgs {
                    messages: None,
                    system: system_prompt.clone(),
                    user: bullet_prompt,
                    repo_id: repo_id.clone(),
                    json_mode: Some(true),
                    max_tokens: Some(prompts::bullet_max_tokens(&settings.ai) as u32),
                    temperature: None,
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

            generation.check(gen_id)?;

            let full_prompt = prompts::article_full_summary_prompt(title, &text, &settings.ai);
            let full_text = if !full_prompt.is_empty() {
                let args = CompleteArgs {
                    messages: None,
                    system: system_prompt,
                    user: full_prompt,
                    repo_id,
                    json_mode: Some(true),
                    max_tokens: Some(prompts::full_max_tokens(&settings.ai) as u32),
                    temperature: None,
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
            return publish_summary(db.inner(), summary_cache.inner(), generation.inner(),
                gen_id, &cache_key, summary).await;
        }
    }

    settings.ai.oauth_access_token = crate::ai::claude_oauth::stored_access_token(&db);

    let provider = create_provider_with_app(&settings.ai, Some(model_state.inner().clone()), &app)?;

    let model = settings
        .ai
        .model
        .clone()
        .unwrap_or_else(|| default_model(&settings.ai.provider));

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
    generation.check(gen_id)?;

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
        log::debug!("Bullet response: {} characters", r.content.chars().count());
        extract_bullets_field(&r.content)
    });
    let full_text = full_response.map(|r| {
        log::debug!("Summary response: {} characters", r.content.chars().count());
        extract_summary_field(&r.content)
    });

    let summary = ArticleSummary {
        article_id: article_id.clone(),
        bullet_summary: bullet_text,
        full_summary: full_text,
        provider: Some(provider.name().to_string()),
        model: Some(model),
        created_at: Utc::now().timestamp(),
    };

    publish_summary(db.inner(), summary_cache.inner(), generation.inner(),
        gen_id, &cache_key, summary).await
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
    /// Which run this progress belongs to, so a UI that started a newer run
    /// (or stopped this one) can ignore progress from a run it no longer owns.
    run_id: String,
}

fn emit_catchup(
    app: &AppHandle,
    stage: &str,
    completed: u32,
    total: u32,
    message: &str,
    report: &CatchupReport,
    run_id: &str,
) {
    let _ = app.emit(
        CATCHUP_PROGRESS_EVENT,
        CatchupProgress {
            stage: stage.to_string(),
            completed,
            total,
            message: message.to_string(),
            report: report.clone(),
            run_id: run_id.to_string(),
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
/// Articles cited under one story. A story gathers every article on its
/// topic, so this is generous; it only stops a model that hands one story
/// every handle it was given from turning the source list into a manifest.
const CATCHUP_MAX_CITATIONS_PER_STORY: usize = 8;
const CATCHUP_MAX_CITATIONS_PER_BRIEF: usize = 2;
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

/// A title reduced to what two postings of the same link share, so the copy on
/// Hacker News and the copy on Lobsters compare equal.
fn same_story_key(title: &str) -> String {
    let normalized = normalize_for_dedup(title);
    ["show hn ", "ask hn ", "launch hn ", "tell hn "]
        .iter()
        .find_map(|prefix| normalized.strip_prefix(prefix))
        .unwrap_or(&normalized)
        .to_string()
}

/// The article's link with scheme, `www.`, query and trailing slash dropped.
fn same_story_url(url: Option<&str>) -> Option<String> {
    let url = url?.trim();
    let rest = url.split_once("://").map(|(_, r)| r).unwrap_or(url);
    let rest = rest.strip_prefix("www.").unwrap_or(rest);
    let rest = rest.split(['?', '#']).next().unwrap_or(rest).trim_end_matches('/');
    (!rest.is_empty()).then(|| rest.to_lowercase())
}

/// Whether two articles are plainly the same piece: the same link, or the same
/// title posted on another aggregator.
fn same_story(a: &crate::db::models::ArticleWithFeed, b: &crate::db::models::ArticleWithFeed) -> bool {
    let key = same_story_key(&a.article.title);
    if key.split(' ').count() >= 3 && key == same_story_key(&b.article.title) {
        return true;
    }
    match (
        same_story_url(a.article.url.as_deref()),
        same_story_url(b.article.url.as_deref()),
    ) {
        (Some(x), Some(y)) => x == y,
        _ => false,
    }
}

/// Folds a later story into an earlier one when they cite the same piece. A
/// model will sometimes run the Hacker News posting of a link as its own story
/// under a reworded headline; the page then prints the same news twice.
fn merge_same_story_stories(
    stories: &mut Vec<CatchupStory>,
    pool: &[crate::db::models::ArticleWithFeed],
) {
    let by_id: HashMap<&str, &crate::db::models::ArticleWithFeed> =
        pool.iter().map(|a| (a.article.id.as_str(), a)).collect();
    let articles = |story: &CatchupStory| -> Vec<&crate::db::models::ArticleWithFeed> {
        story.article_ids.iter().filter_map(|id| by_id.get(id.as_str()).copied()).collect()
    };
    let mut i = 0;
    while i < stories.len() {
        let mut j = i + 1;
        while j < stories.len() {
            let earlier = articles(&stories[i]);
            let overlaps = articles(&stories[j])
                .iter()
                .any(|b| earlier.iter().any(|a| same_story(a, b)));
            if overlaps {
                let later = stories.remove(j);
                for id in later.article_ids {
                    if stories[i].article_ids.len() < CATCHUP_MAX_CITATIONS_PER_STORY {
                        stories[i].article_ids.push(id);
                    }
                }
            } else {
                j += 1;
            }
        }
        i += 1;
    }
}

/// Adds to each story the unclaimed articles that are plainly the same piece:
/// the same link, or the same title posted on another aggregator. The model is
/// asked to do this and usually does, but a front page that cites one of two
/// identical postings looks like it missed the obvious.
fn attach_same_story_articles(
    stories: &mut [CatchupStory],
    pool: &[crate::db::models::ArticleWithFeed],
    claimed: &mut std::collections::HashSet<String>,
) {
    for story in stories.iter_mut() {
        let cited: Vec<&crate::db::models::ArticleWithFeed> = pool
            .iter()
            .filter(|a| story.article_ids.contains(&a.article.id))
            .collect();
        for a in pool {
            if story.article_ids.len() >= CATCHUP_MAX_CITATIONS_PER_STORY {
                break;
            }
            if claimed.contains(&a.article.id) {
                continue;
            }
            if cited.iter().any(|c| same_story(c, a)) {
                claimed.insert(a.article.id.clone());
                story.article_ids.push(a.article.id.clone());
            }
        }
    }
}

/// Feeds whose name a model likes to glue onto the front of a headline.
const AGGREGATOR_NAMES: &[&str] = &["hacker news", "lobsters", "lobste.rs", "reddit", "slashdot"];

/// The headline without a publication's name stuck to its front
/// ("Hacker News back-and-shoulder surgery is often worse than useless"). The
/// sources are cited under the story; the name adds nothing to the headline and
/// reads as though the publication were the subject.
fn strip_publication_prefix(headline: &str, publications: &[String]) -> String {
    let trimmed = headline.trim();
    let lower = trimmed.to_lowercase();
    let mut names: Vec<String> = publications
        .iter()
        .map(|p| p.trim().to_lowercase())
        .filter(|p| !p.is_empty())
        .collect();
    names.extend(AGGREGATOR_NAMES.iter().map(|n| n.to_string()));
    names.sort_by_key(|n| std::cmp::Reverse(n.len()));
    for name in names {
        let Some(rest) = lower.strip_prefix(&name) else {
            continue;
        };
        // A whole-word match only: "Reddit" must not eat "Redditors".
        if !rest.starts_with([' ', ':', '-', '|', '\u{2013}', '\u{2014}']) {
            continue;
        }
        let Some(after) = trimmed.get(name.len()..) else {
            continue;
        };
        let remainder = after
            .trim_start_matches(|c: char| c.is_whitespace() || matches!(c, ':' | '-' | '|' | '\u{2013}' | '\u{2014}'));
        // A headline that is only the name, or whose subject is the name
        // ("Reddit bans ..."), keeps it: stripping would leave a fragment.
        if remainder.split_whitespace().count() < 3 || starts_with_verb(remainder) {
            return trimmed.to_string();
        }
        let mut chars = remainder.chars();
        return match chars.next() {
            Some(first) => first.to_uppercase().chain(chars).collect(),
            None => trimmed.to_string(),
        };
    }
    trimmed.to_string()
}

/// Whether the text opens with a common headline verb, meaning the name before
/// it was the story's subject rather than a label.
fn starts_with_verb(text: &str) -> bool {
    let first = text
        .split_whitespace()
        .next()
        .unwrap_or("")
        .trim_matches(|c: char| !c.is_alphanumeric())
        .to_lowercase();
    const VERBS: &[&str] = &[
        "is", "was", "has", "adds", "bans", "launches", "releases", "ships", "announces", "buys",
        "sues", "cuts", "raises", "removes", "changes", "shuts", "goes", "gets", "says", "blocks",
        "introduces", "updates", "drops", "wins", "loses", "hires", "fires", "faces", "plans",
    ];
    VERBS.contains(&first.as_str())
}

/// A lede for when no verified passage could be selected: the first clean
/// excerpt among the story's articles, with markdown, link references and bare
/// URLs stripped. Empty when every body is link-only, so the story prints its
/// headline and sources and nothing else, rather than `[Comments][1]`.
fn fallback_lede<'a>(bodies: impl IntoIterator<Item = &'a str>) -> String {
    bodies
        .into_iter()
        .map(crate::db::story_text::excerpt)
        // What survives stripping a link-only post is its link label
        // ("Comments"), which is not a lede either.
        .find(|text| text.split_whitespace().count() >= 6)
        .unwrap_or_default()
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
    runs: State<'_, CatchupRuns>,
    scope: Option<String>,
    since_hours: Option<i64>,
    run_id: Option<String>,
) -> Result<CatchupReport, String> {
    let id = run_id.unwrap_or_else(|| Uuid::new_v4().to_string());
    let registration = runs.begin(&id);
    let result = Abortable::new(
        build_catchup_report(app, db, model_state, scope, since_hours, id.clone()),
        registration,
    )
    .await;
    runs.finish(&id);
    match result {
        Ok(inner) => inner,
        Err(Aborted) => Err(CATCHUP_CANCELLED.to_string()),
    }
}

/// Cancels the Quick Catch-up run named by `run_id`, or whichever run is
/// current when `run_id` is omitted (closing the dialog mid-run, for example,
/// where the caller may not have kept track of the id).
#[tauri::command]
pub async fn cancel_catchup_report(
    runs: State<'_, CatchupRuns>,
    run_id: Option<String>,
) -> Result<(), String> {
    runs.cancel(run_id.as_deref());
    Ok(())
}

async fn build_catchup_report(
    app: AppHandle,
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
    scope: Option<String>,
    since_hours: Option<i64>,
    run_id: String,
) -> Result<CatchupReport, String> {
    let run_id = run_id.as_str();
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
        emit_catchup(&app, "done", 0, 0, message, &report, run_id);
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
        run_id,
    );

    // --- Pass one: pick the stories and write their headlines ---------------

    let mut listing = String::new();
    for (i, a) in pool.iter().enumerate() {
        // Markup stripped first: a link-only aggregator post is otherwise
        // listed as `[Comments][1] [1]: https://…`, which tells the editor
        // nothing about what it links to.
        let clean: String = crate::db::story_text::excerpt(
            a.article.content_text.as_deref().unwrap_or(""),
        )
        .chars()
        .take(CATCHUP_PICK_EXCERPT_CHARS)
        .collect::<String>()
        .replace(['\n', '\t'], " ");
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
        max_tokens: Some(2000),
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
        let publications: Vec<String> = pool
            .iter()
            .filter(|a| article_ids.contains(&a.article.id))
            .map(|a| {
                crate::ai::publication::publication_name(&a.feed_title, a.article.url.as_deref())
            })
            .collect();
        let headline = strip_publication_prefix(&headline, &publications);
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

    // Before the briefs claim anything: a second posting of a story's link
    // belongs under that story, not beside it or below the fold as its own item.
    merge_same_story_stories(&mut report.stories, &pool);
    attach_same_story_articles(&mut report.stories, &pool, &mut claimed);

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
        run_id,
    );

    // --- Pass two: pick each lede from the articles behind it ---------------
    //
    // The same source-verified passage Today prints: the reader resolver turns
    // a link-only aggregator post into the page it links to, and the lede is a
    // passage copied from one of those reports, checked against its text.

    for index in 0..report.stories.len() {
        let (headline, article_ids) = {
            let story = &report.stories[index];
            (story.headline.clone(), story.article_ids.clone())
        };

        let evidence = super::editions::lede_source_text(&db, &article_ids).await;
        let lede = match &evidence {
            Ok(evidence) if !evidence.sources.is_empty() => {
                match super::editions::verified_preview(provider.as_ref(), &model, &headline, evidence).await {
                    Some(preview) => preview.excerpt,
                    None => fallback_lede(evidence.sources.iter().map(|s| s.body.as_str())),
                }
            }
            _ => fallback_lede(
                pool.iter()
                    .filter(|a| article_ids.contains(&a.article.id))
                    .filter_map(|a| a.article.content_text.as_deref()),
            ),
        };

        report.stories[index].lede = lede;

        let completed = index as u32 + 1;
        emit_catchup(
            &app,
            "writing",
            completed,
            story_count,
            &format!("Writing story {completed} of {story_count}…"),
            &report,
            run_id,
        );
    }

    emit_catchup(&app, "done", story_count, story_count, "", &report, run_id);

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
mod catchup_runs_tests {
    use super::*;

    #[tokio::test]
    async fn cancel_by_id_aborts_the_matching_run() {
        let runs = CatchupRuns::default();
        let reg = runs.begin("run-1");
        let fut = Abortable::new(std::future::pending::<()>(), reg);
        runs.cancel(Some("run-1"));
        assert_eq!(fut.await, Err(Aborted));
    }

    #[tokio::test]
    async fn beginning_a_second_run_aborts_the_first() {
        let runs = CatchupRuns::default();
        let reg1 = runs.begin("run-1");
        let fut1 = Abortable::new(std::future::pending::<()>(), reg1);
        let _reg2 = runs.begin("run-2");
        assert_eq!(fut1.await, Err(Aborted));
    }

    #[tokio::test]
    async fn cancelling_a_stale_id_leaves_the_current_run_alone() {
        let runs = CatchupRuns::default();
        let reg = runs.begin("run-2");
        // "run-1" already finished (or never existed); this must not touch
        // the run that currently holds the slot.
        runs.cancel(Some("run-1"));
        let fut = Abortable::new(async { 42 }, reg);
        assert_eq!(fut.await, Ok(42));
    }

    #[tokio::test]
    async fn finish_does_not_clear_a_newer_runs_slot() {
        let runs = CatchupRuns::default();
        let _reg1 = runs.begin("run-1");
        let reg2 = runs.begin("run-2");
        // A late cleanup call from the first run's own `finish` must not
        // clear the slot the second run has since claimed.
        runs.finish("run-1");
        runs.cancel(Some("run-2"));
        let fut2 = Abortable::new(std::future::pending::<()>(), reg2);
        assert_eq!(fut2.await, Err(Aborted));
    }
}

#[cfg(test)]
mod catchup_tests {
    use super::*;

    fn article(id: &str, title: &str, url: &str, feed: &str) -> crate::db::models::ArticleWithFeed {
        crate::db::models::ArticleWithFeed {
            article: crate::db::models::Article {
                id: id.into(),
                feed_id: feed.into(),
                title: title.into(),
                url: Some(url.into()),
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
            feed_title: feed.into(),
            feed_icon_url: None,
        }
    }

    #[test]
    fn publication_glued_to_a_headline_is_stripped() {
        // Verbatim from the page Giulio sent back.
        assert_eq!(
            strip_publication_prefix(
                "Hacker News back-and-shoulder surgery is often worse than useless",
                &["hacker news".into()]
            ),
            "Back-and-shoulder surgery is often worse than useless"
        );
        assert_eq!(
            strip_publication_prefix("Lobsters: SourceHut fixes XSS in build logs", &[]),
            "SourceHut fixes XSS in build logs"
        );
    }

    #[test]
    fn publication_that_is_the_subject_stays() {
        assert_eq!(
            strip_publication_prefix(
                "Daemonology.net launches FreeBSD/EC2 desktop AMIs",
                &["daemonology.net".into()]
            ),
            "Daemonology.net launches FreeBSD/EC2 desktop AMIs"
        );
        assert_eq!(
            strip_publication_prefix("Reddit bans third-party API clients", &[]),
            "Reddit bans third-party API clients"
        );
        assert_eq!(
            strip_publication_prefix("Redditors revolt over API pricing", &[]),
            "Redditors revolt over API pricing"
        );
    }

    #[test]
    fn second_posting_of_a_link_joins_its_story() {
        let pool = vec![
            article("a", "Launching FreeBSD/EC2 desktop AMIs", "https://www.daemonology.net/blog/amis/", "Lobsters"),
            article("b", "Launching FreeBSD/EC2 desktop AMIs", "https://daemonology.net/blog/amis", "Hacker News"),
            article("c", "Show HN: Launching FreeBSD/EC2 desktop AMIs", "https://example.com/x", "Hacker News"),
            article("d", "SourceHut account takeover via build logs", "https://blog.arusekk.pl/x", "Lobsters"),
        ];
        let mut stories = vec![CatchupStory {
            headline: "FreeBSD ships desktop AMIs on EC2".into(),
            lede: String::new(),
            article_ids: vec!["a".into()],
        }];
        let mut claimed: std::collections::HashSet<String> = ["a".to_string()].into();
        attach_same_story_articles(&mut stories, &pool, &mut claimed);
        assert_eq!(stories[0].article_ids, vec!["a", "b", "c"]);
        assert!(!claimed.contains("d"));
    }

    #[test]
    fn story_citing_the_same_link_folds_into_the_earlier_one() {
        let pool = vec![
            article("a", "EU regulators open formal probe into cloud egress fees", "http://x/article/at-1", "Ars Technica"),
            article("b", "Cloud providers race to publish egress fee schedules", "http://x/article/tv-1", "The Verge"),
            article("c", "EU opens probe into AWS, Azure and Google Cloud egress fees", "http://x/article/at-1", "Hacker News"),
            article("d", "Rust 1.94 lands with a faster trait solver", "http://x/article/at-2", "Ars Technica"),
        ];
        let story = |headline: &str, ids: &[&str]| CatchupStory {
            headline: headline.into(),
            lede: String::new(),
            article_ids: ids.iter().map(|s| s.to_string()).collect(),
        };
        let mut stories = vec![
            story("EU probes cloud egress fees", &["a", "b"]),
            story("Rust 1.94 ships a faster trait solver", &["d"]),
            story("EU opens egress probe into AWS, Azure and Google", &["c"]),
        ];
        merge_same_story_stories(&mut stories, &pool);
        assert_eq!(stories.len(), 2);
        assert_eq!(stories[0].article_ids, vec!["a", "b", "c"]);
        assert_eq!(stories[1].article_ids, vec!["d"]);
    }

    #[test]
    fn fallback_lede_never_prints_link_references() {
        let hn = "[Comments][1]\n\n[1]: https://news.ycombinator.com/item?id=49837473";
        assert_eq!(fallback_lede([hn]), "");
        let real = "FreeBSD now publishes desktop images for EC2, so a graphical system is one launch away.";
        assert_eq!(fallback_lede([hn, real]), real);
    }

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
