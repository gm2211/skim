use crate::ai::local_provider::SharedModelState;
use crate::ai::prompts;
use crate::ai::provider::{ChatMessage, ChatRequest, create_provider};
use crate::db::models::{ArticleFilter, ArticleSummary, Theme};
use crate::db::queries;
use crate::db::Database;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use tauri::{AppHandle, Emitter, State};
use tokio::sync::Mutex;
use uuid::Uuid;

const SUMMARY_CACHE_MAX: usize = 100;

/// Monotonic counter — incrementing it cancels any in-flight summary.
pub struct SummaryGeneration(pub AtomicU64);

pub fn default_model(provider: &str) -> String {
    match provider {
        "claude-cli" => "sonnet".to_string(),
        "anthropic" => "claude-sonnet-4-5-20241022".to_string(),
        "ollama" => "llama3".to_string(),
        _ => "gpt-4o-mini".to_string(),
    }
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

    pub fn get(&self, article_id: &str) -> Option<&ArticleSummary> {
        self.map.get(article_id)
    }

    pub fn insert(&mut self, summary: ArticleSummary) {
        let id = summary.article_id.clone();
        if self.map.contains_key(&id) {
            // Move to back (most recent)
            self.order.retain(|k| k != &id);
        } else if self.order.len() >= SUMMARY_CACHE_MAX {
            // Evict oldest
            if let Some(oldest) = self.order.pop_front() {
                self.map.remove(&oldest);
            }
        }
        self.order.push_back(id.clone());
        self.map.insert(id, summary);
    }

    pub fn remove(&mut self, article_id: &str) {
        self.map.remove(article_id);
        self.order.retain(|k| k != article_id);
    }

    pub fn clear(&mut self) {
        self.map.clear();
        self.order.clear();
    }
}

pub type SharedSummaryCache = Arc<Mutex<SummaryCache>>;

/// Minimal cleanup: only strip ChatML tokens and code fences (structural, not heuristic).
/// All real parsing is done by extract_json_object() which finds the first valid JSON object.
fn clean_raw_output(text: &str) -> String {
    let mut s = text.to_string();
    // Remove ChatML tokens
    for token in &["<|im_start|>", "<|im_end|>", "<|im_start|>system", "<|im_start|>user", "<|im_start|>assistant"] {
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
    let patterns = [
        format!("\"{}\":", field),
        format!("\"{}\" :", field),
    ];

    let field_start = patterns.iter()
        .filter_map(|p| text.find(p).map(|pos| pos + p.len()))
        .min()?;

    let after = text[field_start..].trim_start();

    // Find where the next field starts ("notes": or end of object })
    let end_markers = ["\"notes\"", "\"notes\" ", "}\n", "\n}"];
    let end_pos = end_markers.iter()
        .filter_map(|m| after.find(m))
        .min()
        .unwrap_or(after.len());

    let value = after[..end_pos].trim();

    // Clean up: strip surrounding quotes, trailing commas, brackets
    let value = value.trim_start_matches('"')
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

#[tauri::command]
pub async fn cancel_summarize(
    generation: State<'_, SummaryGeneration>,
) -> Result<(), String> {
    generation.0.fetch_add(1, Ordering::SeqCst);
    Ok(())
}

#[tauri::command]
pub async fn summarize_article(
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
) -> Result<ArticleSummary, String> {
    let gen_id = generation.0.fetch_add(1, Ordering::SeqCst) + 1;
    // Check in-memory cache (skip if force re-summarize)
    {
        let mut cache = summary_cache.lock().await;
        if force.unwrap_or(false) {
            cache.remove(&article_id);
        } else if let Some(existing) = cache.get(&article_id) {
            return Ok(existing.clone());
        }
    }

    // Get article content and settings
    let (article, settings_json) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let article = queries::get_article_by_id(&conn, &article_id)
            .map_err(|e| e.to_string())?
            .ok_or("Article not found")?;
        let settings_json = queries::get_setting(&conn, "app_settings")
            .map_err(|e| e.to_string())?;
        (article, settings_json)
    };

    let mut settings: crate::db::models::AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();

    // Apply per-article overrides
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

    if settings.ai.provider == "none" {
        return Err("No AI provider configured. Go to Settings to set up an AI provider.".to_string());
    }

    let provider = create_provider(
        &settings.ai,
        Some(model_state.inner().clone()),
    )?;

    let model = settings.ai.model.clone().unwrap_or_else(|| default_model(&settings.ai.provider));
    let title = &article.article.title;

    // Use the longest available content — prefer content_text, fall back to HTML stripped to text
    let content_text = article.article.content_text.as_deref().unwrap_or("");
    let html_as_text = article.article.content_html.as_deref()
        .map(|h| html2text::from_read(h.as_bytes(), 10000))
        .unwrap_or_default();
    let text = if html_as_text.len() > content_text.len() { &html_as_text } else { content_text };

    if text.trim().is_empty() {
        return Err("No article content to summarize.".to_string());
    }

    let system_prompt = prompts::article_summary_system_prompt(&settings.ai);

    // Get bullet summary (skip if format is paragraph-only)
    let bullet_prompt = prompts::article_bullet_summary_prompt(title, text, &settings.ai);
    let bullet_response = if !bullet_prompt.is_empty() {
        let req = ChatRequest {
            model: model.clone(),
            messages: vec![
                ChatMessage { role: "system".to_string(), content: system_prompt.clone() },
                ChatMessage { role: "user".to_string(), content: bullet_prompt },
            ],
            temperature: Some(0.5),
            max_tokens: Some(prompts::bullet_max_tokens(&settings.ai)),
            json_mode: true,
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
    let full_prompt = prompts::article_full_summary_prompt(title, text, &settings.ai);
    let full_response = if !full_prompt.is_empty() {
        let req = ChatRequest {
            model: model.clone(),
            messages: vec![
                ChatMessage { role: "system".to_string(), content: system_prompt },
                ChatMessage { role: "user".to_string(), content: full_prompt },
            ],
            temperature: Some(0.3),
            max_tokens: Some(prompts::full_max_tokens(&settings.ai)),
            json_mode: true,
        };
        Some(provider.chat(req).await?)
    } else {
        None
    };

    let bullet_text = bullet_response.map(|r| {
        log::info!("Bullet raw response: {}", &r.content[..r.content.len().min(200)]);
        extract_bullets_field(&r.content)
    });
    let full_text = full_response.map(|r| {
        log::info!("Summary raw response: {}", &r.content[..r.content.len().min(500)]);
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

    // Cache in memory
    {
        let mut cache = summary_cache.lock().await;
        cache.insert(summary.clone());
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

fn default_relevance() -> f64 { 1.0 }

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
                theme_id: None,
                is_read: Some(false),
                is_starred: None,
                limit: Some(200),
                offset: None,
            };
            queries::get_articles(&conn, &filter).map_err(|e| e.to_string())?
        };
        let settings_json = queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;
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
        return Err("No AI provider configured. Go to Settings to set up an AI provider.".to_string());
    }

    let provider = create_provider(
        &settings.ai,
        Some(model_state.inner().clone()),
    )?;

    let model = settings.ai.model.clone().unwrap_or_else(|| default_model(&settings.ai.provider));

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
            listing.push_str(&format!("{}\t{}\t[{}]\n", i, a.article.title.trim(), a.feed_title));
        }
        let max_tokens = (chunk.len() as i64 * 6 + 400).min(3072);

        let request = ChatRequest {
            model: model.clone(),
            messages: vec![
                ChatMessage {
                    role: "system".to_string(),
                    content: prompts::theme_grouping_system_prompt().to_string(),
                },
                ChatMessage {
                    role: "user".to_string(),
                    content: prompts::theme_grouping_user_prompt(&listing),
                },
            ],
            temperature: Some(0.3),
            max_tokens: Some(max_tokens),
            json_mode: true,
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
                                        serde_json::Value::Number(n) => n
                                            .as_u64()
                                            .and_then(|i| chunk.get(i as usize).map(|a| a.article.id.clone())),
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
                        log::warn!("Theme batch {} parse failed: {}. Raw: {}", batch_num, e, &content[..content.len().min(200)]);
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

    emit_progress(&app, "saving", total_batches, total_batches, "Saving themes...");
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

    let (articles, settings_json, preferences) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let articles = if force.unwrap_or(false) {
            queries::clear_triage(&conn).map_err(|e| e.to_string())?;
            let filter = ArticleFilter {
                feed_id: None,
                theme_id: None,
                is_read: Some(false),
                is_starred: None,
                limit: Some(MAX_PER_RUN),
                offset: None,
            };
            queries::get_articles(&conn, &filter).map_err(|e| e.to_string())?
        } else {
            queries::get_untriaged_article_ids(&conn, MAX_PER_RUN)
                .map_err(|e| e.to_string())?
        };
        let settings_json = queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;
        let prefs = queries::build_preference_profile(&conn).ok();
        (articles, settings_json, prefs)
    };

    if articles.is_empty() {
        emit_triage_progress(&app, "done", 1, 1, "Nothing to triage");
        return Ok(crate::db::models::TriageResult { triaged_count: 0, batches: 0, errors: vec![] });
    }

    let settings: crate::db::models::AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();

    if settings.ai.provider == "none" {
        return Err("No AI provider configured. Go to Settings to set up an AI provider.".to_string());
    }

    let provider = create_provider(&settings.ai, Some(model_state.inner().clone()))?;
    let model = settings.ai.model.clone().unwrap_or_else(|| default_model(&settings.ai.provider));

    let batch_size = match settings.ai.provider.as_str() {
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
            &format!("Triaging {}/{} ({} articles)", batch_count, total_batches, articles.len()),
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
                i, a.article.title.trim(), a.feed_title, excerpt_clean
            ));
        }
        // ~30 output tokens per item is plenty for handle + priority + short reason.
        let max_tokens = (chunk.len() as i64 * 35 + 200).max(512);

        let request = ChatRequest {
            model: model.clone(),
            messages: vec![
                ChatMessage { role: "system".to_string(), content: prompts::triage_system_prompt(preferences.as_ref()) },
                ChatMessage { role: "user".to_string(), content: prompts::triage_user_prompt(&listing) },
            ],
            temperature: Some(0.3),
            max_tokens: Some(max_tokens),
            json_mode: true,
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
                                    serde_json::Value::Number(n) => n
                                        .as_u64()
                                        .and_then(|i| chunk.get(i as usize).map(|a| a.article.id.clone())),
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
                        queries::upsert_triage_batch(&conn, &triage_items).map_err(|e| e.to_string())?;
                    }
                    Err(e) => {
                        log::warn!("Failed to parse triage batch {}: {}. Response: {}", batch_count, e, &content[..content.len().min(300)]);
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

    emit_triage_progress(
        &app,
        "done",
        total_batches,
        total_batches,
        &format!("Triaged {} articles", triaged_count),
    );

    Ok(crate::db::models::TriageResult { triaged_count, batches: batch_count, errors })
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
    queries::get_inbox_articles(&conn, min_priority, is_read, limit.unwrap_or(1000), offset.unwrap_or(0))
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_triage_stats(db: State<'_, Database>) -> Result<crate::db::models::TriageStats, String> {
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
    queries::record_reading_time(&conn, &article_id, seconds, now).map_err(|e| e.to_string())
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
