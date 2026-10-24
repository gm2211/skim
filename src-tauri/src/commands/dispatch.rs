//! The Briefing: an edition an AI journalist writes from the reader's feeds.
//!
//! Two passes. The editor reads every headline in the window (one article per
//! link, round-robin across feeds so a busy feed can't crowd out the rest),
//! finds the themes and ranks them by consequence. A writer then files one
//! piece per theme from the reports behind it, citing them by number. Each
//! piece lands on the page as it is written; the edition is kept, so it is
//! written once per window unless the reader asks for a new one. With a hosted
//! model a short front-page editor call picks the lead first, so its piece is
//! written while the full plan is still being drawn up.

use crate::ai::local_provider::SharedModelState;
use crate::ai::prompts;
use crate::ai::provider::{create_provider_with_app, AiProvider, ChatMessage, ChatRequest};
use crate::commands::ai::{default_model, extract_json_object, lead_image, runs_on_device};
use crate::commands::editions::{chat_with_backoff, transient_model_error};
use crate::db::models::{AppSettings, ArticleFilter, ArticleWithFeed, UserPreferenceProfile};
use crate::db::{queries, Database};
use crate::AppHandle;
use futures_util::future::Either;
use futures_util::StreamExt;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use tauri::{Emitter, State};

pub const DISPATCH_PROGRESS_EVENT: &str = "dispatch_progress";

/// Articles the editor reads from one window. A hosted model reads them all
/// in one request; a model on this machine gets fewer so it answers at all.
const HOSTED_POOL: usize = 160;
const ON_DEVICE_POOL: usize = 60;
const HOSTED_EXCERPT_CHARS: usize = 100;
const ON_DEVICE_EXCERPT_CHARS: usize = 60;
const MAX_THEMES: usize = 6;
const MAX_THEME_ARTICLES: usize = 10;
const MAX_BRIEFS: usize = 8;
/// Reports a writer reads for one piece, and how much of each.
const WRITER_REPORTS: usize = 4;
const WRITER_REPORT_CHARS: usize = 1_200;
const WRITER_CONCURRENCY: usize = 4;
/// The widest window an edition may cover, with a day of slack for DST.
const MAX_WINDOW_SECONDS: i64 = 8 * 24 * 60 * 60;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DispatchArticle {
    pub id: String,
    pub title: String,
    pub publication: String,
    pub url: Option<String>,
    pub published_at: Option<i64>,
    pub feed_icon_url: Option<String>,
    pub image_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DispatchTheme {
    pub kicker: String,
    pub headline: String,
    pub dek: String,
    pub importance: i64,
    /// The theme's reports, in the order the piece numbers them: `[1]` in the
    /// body is the first of these.
    pub article_ids: Vec<String>,
    /// Paragraphs with `[n]` citations. Empty until the piece is written.
    #[serde(default)]
    pub body: Vec<String>,
    #[serde(default)]
    pub takeaways: Vec<String>,
    /// Why the piece couldn't be written, when it couldn't.
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DispatchBrief {
    pub text: String,
    pub article_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DispatchEdition {
    pub id: String,
    pub days: i64,
    pub starts_at: i64,
    pub ends_at: i64,
    pub generated_at: i64,
    /// Articles the editor read.
    pub article_count: i64,
    /// "writing" while pieces are being filed, then "complete".
    pub status: String,
    pub model: String,
    pub themes: Vec<DispatchTheme>,
    pub briefs: Vec<DispatchBrief>,
    pub articles: Vec<DispatchArticle>,
    /// Articles in the window that arrived after the edition was written. Not
    /// stored: counted each time the edition is loaded.
    #[serde(default)]
    pub new_article_count: i64,
}

#[derive(Serialize, Clone)]
struct DispatchProgress {
    edition_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    request_id: Option<String>,
    message: String,
    edition: DispatchEdition,
}

pub fn edition_id(starts_at: i64, ends_at: i64, days: i64) -> String {
    format!("dispatch-{starts_at}-{ends_at}-{days}")
}

fn validate_window(starts_at: i64, ends_at: i64, days: i64) -> Result<(), String> {
    if ends_at <= starts_at || ends_at - starts_at > MAX_WINDOW_SECONDS || !matches!(days, 1 | 3 | 7) {
        return Err("The Briefing covers 1, 3 or 7 days.".into());
    }
    Ok(())
}

// --- Storage ----------------------------------------------------------------

fn load(conn: &Connection, id: &str) -> Result<Option<DispatchEdition>, String> {
    let json: Option<String> = conn
        .query_row("SELECT edition_json FROM dispatch_editions WHERE id = ?1", params![id], |row| row.get(0))
        .optional()
        .map_err(|e| e.to_string())?;
    let Some(mut edition) = json.and_then(|json| serde_json::from_str::<DispatchEdition>(&json).ok()) else {
        return Ok(None);
    };
    edition.new_article_count = conn
        .query_row(
            "SELECT COUNT(*) FROM articles
             WHERE COALESCE(published_at, fetched_at) >= ?1 AND COALESCE(published_at, fetched_at) < ?2
               AND fetched_at > ?3",
            params![edition.starts_at, edition.ends_at, edition.generated_at],
            |row| row.get(0),
        )
        .map_err(|e| e.to_string())?;
    Ok(Some(edition))
}

fn save(conn: &Connection, edition: &DispatchEdition) -> Result<(), String> {
    let json = serde_json::to_string(edition).map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT INTO dispatch_editions (id, edition_json, updated_at) VALUES (?1, ?2, ?3)
         ON CONFLICT(id) DO UPDATE SET edition_json = excluded.edition_json, updated_at = excluded.updated_at",
        params![edition.id, json, chrono::Utc::now().timestamp()],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

// --- What the editor reads ----------------------------------------------------

/// A link or headline reduced to what makes two postings the same article.
fn same_article_key(article: &ArticleWithFeed) -> String {
    let url = article
        .article
        .url
        .as_deref()
        .map(|url| {
            url.trim()
                .trim_start_matches("https://")
                .trim_start_matches("http://")
                .trim_start_matches("www.")
                .split(['?', '#'])
                .next()
                .unwrap_or_default()
                .trim_end_matches('/')
                .to_lowercase()
        })
        .unwrap_or_default();
    // An aggregator's own comments page is not the article it links to.
    if url.is_empty() || url.contains("news.ycombinator.com/item") || url.contains("lobste.rs/s/") {
        let title: String = article
            .article
            .title
            .to_lowercase()
            .chars()
            .filter(|c| c.is_alphanumeric() || c.is_whitespace())
            .collect();
        format!("title:{}", title.split_whitespace().collect::<Vec<_>>().join(" "))
    } else {
        url
    }
}

/// The articles the editor reads: one per link or headline, then taken from
/// each feed in turn, newest first, so a feed that posts fifty times a day
/// can't crowd out one that posts twice.
pub fn select_pool(articles: Vec<ArticleWithFeed>, cap: usize) -> Vec<ArticleWithFeed> {
    let mut seen = HashSet::new();
    let mut by_feed: BTreeMap<String, Vec<ArticleWithFeed>> = BTreeMap::new();
    let mut feed_order = Vec::new();
    let mut articles = articles;
    articles.sort_by_key(|a| std::cmp::Reverse(a.article.published_at.unwrap_or(a.article.fetched_at)));
    for article in articles {
        if article.article.title.trim().is_empty() || !seen.insert(same_article_key(&article)) {
            continue;
        }
        let feed = article.article.feed_id.clone();
        if !by_feed.contains_key(&feed) {
            feed_order.push(feed.clone());
        }
        by_feed.entry(feed).or_default().push(article);
    }
    let mut queues: Vec<std::collections::VecDeque<ArticleWithFeed>> = feed_order
        .iter()
        .filter_map(|feed| by_feed.remove(feed))
        .map(Into::into)
        .collect();
    let mut pool = Vec::new();
    while pool.len() < cap && queues.iter().any(|queue| !queue.is_empty()) {
        for queue in queues.iter_mut() {
            if pool.len() >= cap {
                break;
            }
            if let Some(article) = queue.pop_front() {
                pool.push(article);
            }
        }
    }
    pool
}

fn listing(pool: &[ArticleWithFeed], excerpt_chars: usize) -> String {
    let mut text = String::new();
    for (index, a) in pool.iter().enumerate() {
        let excerpt: String = crate::db::story_text::excerpt(a.article.content_text.as_deref().unwrap_or(""))
            .chars()
            .take(excerpt_chars)
            .collect::<String>()
            .replace(['\n', '\t'], " ");
        let date = chrono::DateTime::from_timestamp(a.article.published_at.unwrap_or(a.article.fetched_at), 0)
            .map(|d| d.format("%b %-d").to_string())
            .unwrap_or_default();
        text.push_str(&format!(
            "{index}\t{}\t[{}]\t{date}\t{}\n",
            a.article.title.trim().replace(['\n', '\t'], " "),
            crate::ai::publication::publication_name(&a.feed_title, a.article.url.as_deref()),
            excerpt.trim()
        ));
    }
    text
}

// --- The editor's plan --------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    pub themes: Vec<DispatchTheme>,
    pub briefs: Vec<DispatchBrief>,
}

fn indexes(value: Option<&serde_json::Value>) -> Vec<usize> {
    value
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
        .filter_map(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok())))
        .map(|n| n as usize)
        .collect()
}

fn text(value: Option<&serde_json::Value>) -> String {
    value.and_then(|v| v.as_str()).unwrap_or_default().trim().to_string()
}

/// Reads the editor's answer. Article handles must be in the listing and each
/// article runs once; themes are ordered by importance, the model's order
/// breaking ties.
pub fn parse_plan(content: &str, pool: &[ArticleWithFeed]) -> Result<Plan, String> {
    let object = extract_json_object(content).ok_or("The editor's answer wasn't JSON")?;
    let value: serde_json::Value = serde_json::from_str(object).map_err(|_| "The editor's answer wasn't valid JSON")?;
    let mut claimed = HashSet::new();
    let mut claim = |handles: Vec<usize>, limit: usize| -> Vec<String> {
        handles
            .into_iter()
            .filter(|&i| i < pool.len() && claimed.insert(i))
            .take(limit)
            .map(|i| pool[i].article.id.clone())
            .collect()
    };
    let mut themes = Vec::new();
    for raw in value.get("themes").and_then(|v| v.as_array()).into_iter().flatten() {
        let headline = text(raw.get("headline"));
        if headline.is_empty() {
            continue;
        }
        let article_ids = claim(indexes(raw.get("articles").or_else(|| raw.get("article_ids"))), MAX_THEME_ARTICLES);
        if article_ids.is_empty() {
            continue;
        }
        let kicker = text(raw.get("kicker"));
        themes.push(DispatchTheme {
            kicker: if kicker.is_empty() { "News".into() } else { kicker.chars().take(24).collect() },
            headline,
            dek: text(raw.get("dek")),
            importance: raw.get("importance").and_then(|v| v.as_f64()).unwrap_or(3.0).round().clamp(1.0, 5.0) as i64,
            article_ids,
            body: Vec::new(),
            takeaways: Vec::new(),
            error: None,
        });
        if themes.len() >= MAX_THEMES {
            break;
        }
    }
    if themes.is_empty() {
        return Err("The editor didn't pick any themes from the listing".into());
    }
    themes.sort_by_key(|theme| std::cmp::Reverse(theme.importance));
    let mut briefs = Vec::new();
    for raw in value.get("briefs").and_then(|v| v.as_array()).into_iter().flatten() {
        let text = text(raw.get("text"));
        let article_ids = claim(indexes(raw.get("articles").or_else(|| raw.get("article_ids"))), 2);
        if text.is_empty() || article_ids.is_empty() {
            continue;
        }
        briefs.push(DispatchBrief { text, article_ids });
        if briefs.len() >= MAX_BRIEFS {
            break;
        }
    }
    Ok(Plan { themes, briefs })
}

/// Reads the front-page editor's answer: the lead theme alone.
pub fn parse_lead(content: &str, pool: &[ArticleWithFeed]) -> Result<DispatchTheme, String> {
    let object = extract_json_object(content).ok_or("The front-page editor's answer wasn't JSON")?;
    let value: serde_json::Value =
        serde_json::from_str(object).map_err(|_| "The front-page editor's answer wasn't valid JSON")?;
    let theme = value
        .get("theme")
        .or_else(|| value.get("lead"))
        .or_else(|| value.get("themes").and_then(|t| t.get(0)))
        .unwrap_or(&value);
    let plan = parse_plan(&serde_json::json!({ "themes": [theme] }).to_string(), pool)?;
    plan.themes.into_iter().next().ok_or_else(|| "The editor didn't pick any themes from the listing".into())
}

/// Puts the lead on top of the full plan. The plan was drawn up without
/// knowing the lead, so a theme that mostly retells it is dropped, and the
/// lead's reports leave the other themes and the briefs.
pub fn merge_lead(lead: DispatchTheme, plan: Plan) -> Plan {
    let taken: HashSet<String> = lead.article_ids.iter().cloned().collect();
    let mut themes = vec![lead];
    for mut theme in plan.themes {
        if themes.len() >= MAX_THEMES {
            break;
        }
        let shared = theme.article_ids.iter().filter(|id| taken.contains(*id)).count();
        if shared * 2 >= theme.article_ids.len() {
            continue;
        }
        theme.article_ids.retain(|id| !taken.contains(id));
        themes.push(theme);
    }
    let briefs = plan
        .briefs
        .into_iter()
        .filter_map(|mut brief| {
            brief.article_ids.retain(|id| !taken.contains(id));
            (!brief.article_ids.is_empty()).then_some(brief)
        })
        .collect();
    Plan { themes, briefs }
}

async fn ask_with_one_correction<T>(
    provider: &dyn AiProvider,
    mut request: ChatRequest,
    parse: impl Fn(&str) -> Result<T, String>,
) -> Result<T, String> {
    let response = chat_with_backoff(provider, &request).await?;
    match parse(&response.content) {
        Ok(value) => Ok(value),
        Err(reason) => {
            // One correction, with the reason, so the model can fix its answer.
            request.messages.push(ChatMessage::text("assistant", response.content.clone()));
            request.messages.push(ChatMessage::text(
                "user",
                format!("{reason}. Answer again with only the JSON object in the format asked for."),
            ));
            let response = chat_with_backoff(provider, &request).await?;
            parse(&response.content)
        }
    }
}

pub async fn plan_edition(
    provider: &dyn AiProvider,
    model: &str,
    days: i64,
    interests: Option<&str>,
    pool: &[ArticleWithFeed],
    excerpt_chars: usize,
    preferences: Option<&UserPreferenceProfile>,
) -> Result<Plan, String> {
    let request = ChatRequest {
        model: model.into(),
        messages: vec![
            ChatMessage::text("system", prompts::dispatch_editor_system_prompt(days, interests, preferences)),
            ChatMessage::text("user", prompts::dispatch_editor_user_prompt(&listing(pool, excerpt_chars))),
        ],
        temperature: Some(0.2),
        max_tokens: Some(3_000),
        json_mode: true,
        tools: None,
    };
    ask_with_one_correction(provider, request, |content| parse_plan(content, pool)).await
}

pub async fn plan_lead(
    provider: &dyn AiProvider,
    model: &str,
    days: i64,
    interests: Option<&str>,
    pool: &[ArticleWithFeed],
    excerpt_chars: usize,
    preferences: Option<&UserPreferenceProfile>,
) -> Result<DispatchTheme, String> {
    let request = ChatRequest {
        model: model.into(),
        messages: vec![
            ChatMessage::text("system", prompts::dispatch_lead_system_prompt(days, interests, preferences)),
            ChatMessage::text("user", prompts::dispatch_lead_user_prompt(&listing(pool, excerpt_chars))),
        ],
        temperature: Some(0.2),
        max_tokens: Some(400),
        json_mode: true,
        tools: None,
    };
    ask_with_one_correction(provider, request, |content| parse_lead(content, pool)).await
}

// --- The writer's piece -------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub struct Piece {
    pub headline: Option<String>,
    pub dek: Option<String>,
    pub body: Vec<String>,
    pub takeaways: Vec<String>,
}

/// Keeps the citations that name a supplied report and drops the rest, so a
/// `[7]` for a piece written from four reports never links anywhere.
/// Returns the cleaned text and how many valid citations it kept.
pub fn clean_citations(text: &str, reports: usize) -> (String, usize) {
    static CITE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re = CITE.get_or_init(|| regex::Regex::new(r"\s*\[(\d+(?:\s*,\s*\d+)*)\]").unwrap());
    let mut kept = 0;
    let cleaned = re.replace_all(text, |caps: &regex::Captures| {
        let valid: Vec<String> = caps[1]
            .split(',')
            .filter_map(|n| n.trim().parse::<usize>().ok())
            .filter(|&n| n >= 1 && n <= reports)
            .map(|n| n.to_string())
            .collect();
        kept += valid.len();
        if valid.is_empty() { String::new() } else { format!(" [{}]", valid.join(", ")) }
    });
    (cleaned.trim().to_string(), kept)
}

pub fn parse_piece(content: &str, reports: usize) -> Result<Piece, String> {
    let object = extract_json_object(content).ok_or("The piece wasn't JSON")?;
    let value: serde_json::Value = serde_json::from_str(object).map_err(|_| "The piece wasn't valid JSON")?;
    let strings = |key: &str| -> Vec<String> {
        match value.get(key) {
            Some(serde_json::Value::Array(items)) => items.iter().filter_map(|v| v.as_str()).map(str::to_string).collect(),
            // A body sent as one string still reads as paragraphs.
            Some(serde_json::Value::String(s)) => s.split("\n\n").map(str::to_string).collect(),
            _ => Vec::new(),
        }
    };
    let mut citations = 0;
    let mut clean = |items: Vec<String>, limit: usize| -> Vec<String> {
        items
            .into_iter()
            .map(|item| {
                let (text, kept) = clean_citations(&item, reports);
                citations += kept;
                text
            })
            .filter(|item| !item.is_empty())
            .take(limit)
            .collect()
    };
    let body = clean(strings("body"), 5);
    let takeaways = clean(strings("takeaways"), 4);
    if body.is_empty() {
        return Err("The piece had no body".into());
    }
    if citations == 0 {
        return Err("The piece didn't cite its reports by number, like [1]".into());
    }
    let optional = |key: &str| Some(text(value.get(key))).filter(|s| !s.is_empty());
    Ok(Piece { headline: optional("headline"), dek: optional("dek"), body, takeaways })
}

/// The numbered reports a writer reads, in the theme's order. A report whose
/// text can't be read still keeps its number, with its headline alone.
async fn theme_reports(db: &Database, article_ids: &[String]) -> Result<String, String> {
    let articles = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        article_ids
            .iter()
            .take(WRITER_REPORTS)
            .map(|id| queries::get_article_by_id(&conn, id).map_err(|e| e.to_string()))
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
    };
    let plain: Vec<_> = articles.iter().map(|a| a.article.clone()).collect();
    let bodies = super::article_body::resolve_selected_article_texts(db, &plain).await;
    let mut text = String::new();
    for (number, (article, body)) in articles.iter().zip(bodies).enumerate() {
        let body: String = body.trim().chars().take(WRITER_REPORT_CHARS).collect();
        text.push_str(&format!(
            "[{}] {} ({})\n{}\n\n",
            number + 1,
            article.article.title.trim(),
            crate::ai::publication::publication_name(&article.feed_title, article.article.url.as_deref()),
            if body.trim().is_empty() { "(headline only)" } else { body.trim() }
        ));
    }
    Ok(text)
}

pub async fn write_piece(provider: &dyn AiProvider, model: &str, theme: &DispatchTheme, reports: &str) -> Result<Piece, String> {
    let count = theme.article_ids.len().min(WRITER_REPORTS);
    let request = ChatRequest {
        model: model.into(),
        messages: vec![
            ChatMessage::text("system", prompts::dispatch_writer_system_prompt()),
            ChatMessage::text("user", prompts::dispatch_writer_user_prompt(&theme.headline, &theme.dek, reports)),
        ],
        temperature: Some(0.3),
        max_tokens: Some(1_200),
        json_mode: true,
        tools: None,
    };
    ask_with_one_correction(provider, request, |content| parse_piece(content, count)).await
}

fn apply_piece(theme: &mut DispatchTheme, piece: Piece) {
    if let Some(headline) = piece.headline {
        theme.headline = headline;
    }
    if let Some(dek) = piece.dek {
        theme.dek = dek;
    }
    theme.body = piece.body;
    theme.takeaways = piece.takeaways;
    theme.error = None;
}

/// A reason the reader can act on, for a piece that couldn't be written.
pub fn failure_reason(error: &str) -> String {
    if transient_model_error(error) {
        "The AI provider was busy or rate limited. Try again in a moment.".into()
    } else if error.starts_with("The piece") || error.starts_with("The editor") {
        format!("{error}.")
    } else {
        format!("The AI provider failed: {}", error.chars().take(160).collect::<String>())
    }
}

fn dispatch_article(a: &ArticleWithFeed) -> DispatchArticle {
    DispatchArticle {
        id: a.article.id.clone(),
        title: a.article.title.trim().to_string(),
        publication: crate::ai::publication::publication_name(&a.feed_title, a.article.url.as_deref()),
        url: a.article.url.clone(),
        published_at: a.article.published_at,
        feed_icon_url: a.feed_icon_url.clone(),
        image_url: lead_image(a.article.content_html.as_deref()),
    }
}

// --- Commands -----------------------------------------------------------------

/// Editions being written right now, so a second open while one is written
/// returns the page as it stands instead of starting another.
static WRITING: std::sync::OnceLock<std::sync::Mutex<HashSet<String>>> = std::sync::OnceLock::new();

fn writing() -> &'static std::sync::Mutex<HashSet<String>> {
    WRITING.get_or_init(Default::default)
}

struct WritingGuard(String);
impl Drop for WritingGuard {
    fn drop(&mut self) {
        if let Ok(mut set) = writing().lock() {
            set.remove(&self.0);
        }
    }
}

/// The stored edition for a window, if there is one.
#[tauri::command]
pub async fn get_dispatch(db: State<'_, Database>, starts_at: i64, ends_at: i64, days: i64) -> Result<Option<DispatchEdition>, String> {
    validate_window(starts_at, ends_at, days)?;
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    load(&conn, &edition_id(starts_at, ends_at, days))
}

/// The newest kept edition with written pieces that ended by this window's
/// end, other than this window's own: shown while this one is first written.
#[tauri::command]
pub async fn get_dispatch_stand_in(
    db: State<'_, Database>,
    starts_at: i64,
    ends_at: i64,
    days: i64,
) -> Result<Option<DispatchEdition>, String> {
    validate_window(starts_at, ends_at, days)?;
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    latest_written(&conn, days, ends_at, &edition_id(starts_at, ends_at, days))
}

fn latest_written(conn: &Connection, days: i64, ends_by: i64, excluding: &str) -> Result<Option<DispatchEdition>, String> {
    let mut statement = conn
        .prepare("SELECT edition_json FROM dispatch_editions WHERE id LIKE ?1 AND id != ?2 ORDER BY id DESC LIMIT 12")
        .map_err(|e| e.to_string())?;
    let rows: Vec<String> = statement
        .query_map(params![format!("dispatch-%-{days}"), excluding], |row| row.get::<_, String>(0))
        .map_err(|e| e.to_string())?
        .filter_map(|row| row.ok())
        .collect();
    Ok(rows
        .into_iter()
        .filter_map(|json| serde_json::from_str::<DispatchEdition>(&json).ok())
        .find(|edition| edition.ends_at <= ends_by && edition.themes.iter().any(|theme| !theme.body.is_empty())))
}

/// Writes the edition for a window, or finishes one. `mode` is "open" (keep
/// a written edition), "retry" (write the pieces that failed) or "rewrite"
/// (start a new edition from what is in the window now).
#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub async fn write_dispatch(
    app: AppHandle,
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
    starts_at: i64,
    ends_at: i64,
    days: i64,
    mode: Option<String>,
    request_id: Option<String>,
) -> Result<DispatchEdition, String> {
    validate_window(starts_at, ends_at, days)?;
    let id = edition_id(starts_at, ends_at, days);
    let mode = mode.unwrap_or_else(|| "open".into());
    let (existing, settings, preferences) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let settings: AppSettings = queries::get_setting(&conn, "app_settings")
            .map_err(|e| e.to_string())?
            .as_deref()
            .and_then(|json| serde_json::from_str(json).ok())
            .unwrap_or_default();
        (load(&conn, &id)?, settings, queries::build_preference_profile(&conn).ok())
    };
    if !writing().lock().map_err(|e| e.to_string())?.insert(id.clone()) {
        // Another call is writing it; hand back the page as it stands.
        return Ok(existing.unwrap_or_else(|| empty_edition(&id, starts_at, ends_at, days, "writing")));
    }
    let _guard = WritingGuard(id.clone());
    if settings.ai.provider == "none" {
        return Err("No AI provider configured.".into());
    }
    let mut ai_settings = settings.ai.clone();
    ai_settings.oauth_access_token = crate::ai::subscription_access_token(&db, &ai_settings.provider);
    let provider = create_provider_with_app(&ai_settings, Some(model_state.inner().clone()), &app)?;
    let model = ai_settings.model.clone().unwrap_or_else(|| default_model(&ai_settings.provider));
    let on_device = runs_on_device(&ai_settings.provider);
    let emit = |message: &str, edition: &DispatchEdition| {
        let _ = app.emit(
            DISPATCH_PROGRESS_EVENT,
            DispatchProgress {
                edition_id: edition.id.clone(),
                request_id: request_id.clone(),
                message: message.into(),
                edition: edition.clone(),
            },
        );
    };

    let mut edition = match existing {
        Some(edition) if mode != "rewrite" && edition.status == "complete" && mode != "retry" => return Ok(edition),
        Some(edition) if mode != "rewrite" && !edition.themes.is_empty() => edition,
        _ => {
            let now = chrono::Utc::now().timestamp();
            let pool = {
                let conn = db.conn.lock().map_err(|e| e.to_string())?;
                let articles = queries::get_articles(
                    &conn,
                    &ArticleFilter {
                        published_after: Some(starts_at),
                        published_before: Some(ends_at),
                        limit: Some(4_000),
                        ..Default::default()
                    },
                )
                .map_err(|e| e.to_string())?;
                select_pool(articles, if on_device { ON_DEVICE_POOL } else { HOSTED_POOL })
            };
            let mut edition = empty_edition(&id, starts_at, ends_at, days, "writing");
            edition.generated_at = now.min(ends_at - 1).max(starts_at);
            edition.article_count = pool.len() as i64;
            edition.model = model.clone();
            if pool.is_empty() {
                edition.status = "complete".into();
                let conn = db.conn.lock().map_err(|e| e.to_string())?;
                save(&conn, &edition)?;
                return Ok(edition);
            }
            emit(&format!("Reading {} articles…", pool.len()), &edition);
            let interests = ai_settings.triage_user_prompt.as_deref();
            let excerpt = if on_device { ON_DEVICE_EXCERPT_CHARS } else { HOSTED_EXCERPT_CHARS };
            let planning = plan_edition(provider.as_ref(), &model, days, interests, &pool, excerpt, preferences.as_ref());
            let (plan, lead) = if on_device {
                (planning.await, None)
            } else {
                // The front-page editor answers in seconds with the lead, whose
                // piece is written while the full plan is still being drawn up.
                let leading = async {
                    // Headlines alone: the short listing is what makes this answer quick.
                    let mut lead = plan_lead(provider.as_ref(), &model, days, interests, &pool, 0, preferences.as_ref()).await?;
                    let mut page = edition.clone();
                    page.articles = pool.iter().filter(|a| lead.article_ids.contains(&a.article.id)).map(dispatch_article).collect();
                    page.themes = vec![lead.clone()];
                    emit("Writing the lead while the editor reads the rest…", &page);
                    let piece = match theme_reports(db.inner(), &lead.article_ids).await {
                        Ok(reports) => write_piece(provider.as_ref(), &model, &lead, &reports).await,
                        Err(error) => Err(error),
                    };
                    match piece {
                        Ok(piece) => apply_piece(&mut lead, piece),
                        Err(error) => lead.error = Some(failure_reason(&error)),
                    }
                    page.themes = vec![lead.clone()];
                    emit(&format!("Reading {} articles for the rest of the page…", pool.len()), &page);
                    Ok::<_, String>(lead)
                };
                futures_util::pin_mut!(planning, leading);
                match futures_util::future::select(planning, leading).await {
                    Either::Left((plan, _)) => (plan, None),
                    Either::Right((lead, planning)) => (planning.await, lead.ok()),
                }
            };
            let plan = match (plan, lead) {
                (Ok(plan), Some(lead)) => merge_lead(lead, plan),
                (Ok(plan), None) => plan,
                // A lead already on the page stands on its own.
                (Err(_), Some(lead)) => Plan { themes: vec![lead], briefs: Vec::new() },
                (Err(error), None) => return Err(failure_reason(&error)),
            };
            let used: HashSet<&String> = plan
                .themes
                .iter()
                .flat_map(|t| &t.article_ids)
                .chain(plan.briefs.iter().flat_map(|b| &b.article_ids))
                .collect();
            edition.articles = pool.iter().filter(|a| used.contains(&a.article.id)).map(dispatch_article).collect();
            edition.themes = plan.themes;
            edition.briefs = plan.briefs;
            let conn = db.conn.lock().map_err(|e| e.to_string())?;
            save(&conn, &edition)?;
            edition
        }
    };
    edition.status = "writing".into();

    let pending: Vec<usize> = edition
        .themes
        .iter()
        .enumerate()
        .filter(|(_, theme)| theme.body.is_empty())
        .map(|(index, _)| index)
        .collect();
    let total = pending.len();
    emit(&format!("Writing {total} {}…", if total == 1 { "piece" } else { "pieces" }), &edition);
    let database: &Database = &db;
    let provider_ref = provider.as_ref();
    let model_ref = &model;
    let assignments: Vec<(usize, DispatchTheme)> = pending.into_iter().map(|index| (index, edition.themes[index].clone())).collect();
    let jobs = assignments.into_iter().map(|(index, theme)| {
        async move {
            let result = match theme_reports(database, &theme.article_ids).await {
                Ok(reports) => write_piece(provider_ref, model_ref, &theme, &reports).await,
                Err(error) => Err(error),
            };
            (index, result)
        }
    });
    let mut results = futures_util::stream::iter(jobs).buffer_unordered(if on_device { 1 } else { WRITER_CONCURRENCY });
    let mut done = 0;
    while let Some((index, result)) = results.next().await {
        done += 1;
        match result {
            Ok(piece) => apply_piece(&mut edition.themes[index], piece),
            Err(error) => edition.themes[index].error = Some(failure_reason(&error)),
        }
        {
            let conn = db.conn.lock().map_err(|e| e.to_string())?;
            save(&conn, &edition)?;
        }
        emit(&format!("Filed {done} of {total}…"), &edition);
    }
    edition.status = "complete".into();
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    save(&conn, &edition)?;
    let edition = load(&conn, &id)?.unwrap_or(edition);
    emit("", &edition);
    Ok(edition)
}

fn empty_edition(id: &str, starts_at: i64, ends_at: i64, days: i64, status: &str) -> DispatchEdition {
    DispatchEdition {
        id: id.into(),
        days,
        starts_at,
        ends_at,
        generated_at: starts_at,
        article_count: 0,
        status: status.into(),
        model: String::new(),
        themes: Vec::new(),
        briefs: Vec::new(),
        articles: Vec::new(),
        new_article_count: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::models::Article;

    fn article(id: &str, feed: &str, title: &str, url: &str, at: i64) -> ArticleWithFeed {
        ArticleWithFeed {
            article: Article {
                id: id.into(),
                feed_id: feed.into(),
                title: title.into(),
                url: Some(url.into()),
                author: None,
                content_html: None,
                content_text: Some(format!("{title}. More text here.")),
                published_at: Some(at),
                fetched_at: at,
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
    fn pool_takes_feeds_in_turn_and_drops_reposted_links() {
        let mut articles: Vec<_> = (0..10)
            .map(|i| article(&format!("hn{i}"), "hn", &format!("HN {i}"), &format!("https://x.com/{i}"), 100 - i))
            .collect();
        articles.push(article("ars", "ars", "Ars story", "https://ars.com/a", 50));
        articles.push(article("lob", "lobsters", "Reposted", "https://www.x.com/0/?utm=1", 40));
        let pool = select_pool(articles, 4);
        let ids: Vec<_> = pool.iter().map(|a| a.article.id.as_str()).collect();
        // The busiest feed doesn't take every slot, and a repost of hn0 is dropped.
        assert_eq!(ids, vec!["hn0", "ars", "hn1", "hn2"]);
    }

    #[test]
    fn plan_ranks_by_importance_and_runs_each_article_once() {
        let pool: Vec<_> = (0..5).map(|i| article(&format!("a{i}"), "f", &format!("T{i}"), &format!("https://e.com/{i}"), i)).collect();
        let raw = r#"Here you go: {"themes":[
            {"kicker":"Databases","headline":"DuckDB 2.0 ships","dek":"A release.","importance":2,"articles":[0]},
            {"kicker":"Security","headline":"Two certificate authorities breached","dek":"Trust at stake.","importance":5,"articles":[1,2,9]},
            {"headline":"Duplicate","articles":[1]},
            {"headline":"","articles":[3]}
        ],"briefs":[{"text":"Something small happened.","articles":[3,0]}]}"#;
        let plan = parse_plan(raw, &pool).unwrap();
        assert_eq!(plan.themes.iter().map(|t| t.headline.as_str()).collect::<Vec<_>>(),
            vec!["Two certificate authorities breached", "DuckDB 2.0 ships"]);
        assert_eq!(plan.themes[0].article_ids, vec!["a1", "a2"]);
        assert_eq!(plan.briefs[0].article_ids, vec!["a3"]);
        assert!(parse_plan(r#"{"themes":[]}"#, &pool).is_err());
    }

    #[test]
    fn citations_outside_the_reports_are_dropped() {
        assert_eq!(clean_citations("Breach confirmed [1, 7]. Denied [9].", 3), ("Breach confirmed [1]. Denied.".to_string(), 1));
        let piece = parse_piece(r#"{"headline":"H","body":["One [1].","Two [2,3]."],"takeaways":["Patch now [1]."]}"#, 3).unwrap();
        assert_eq!(piece.body, vec!["One [1].", "Two [2, 3]."]);
        assert_eq!(piece.takeaways, vec!["Patch now [1]."]);
        assert!(parse_piece(r#"{"body":["No citations here."]}"#, 3).unwrap_err().contains("cite"));
    }

    struct Scripted {
        replies: std::sync::Mutex<std::collections::VecDeque<String>>,
        requests: std::sync::Mutex<Vec<ChatRequest>>,
    }
    #[async_trait::async_trait]
    impl AiProvider for Scripted {
        async fn chat(&self, request: ChatRequest) -> Result<crate::ai::provider::ChatResponse, String> {
            self.requests.lock().unwrap().push(request);
            Ok(crate::ai::provider::ChatResponse {
                content: self.replies.lock().unwrap().pop_front().expect("unexpected request"),
                model: "test".into(), usage: None, tool_uses: vec![], stop_reason: None, raw_content: None,
            })
        }
        fn name(&self) -> &str { "test" }
    }

    #[tokio::test]
    async fn an_uncited_piece_is_sent_back_once_with_the_reason() {
        let provider = Scripted {
            replies: std::sync::Mutex::new(vec![
                r#"{"body":["Nothing cited."]}"#.to_string(),
                r#"{"body":["Cited now [1]."],"takeaways":[]}"#.to_string(),
            ].into()),
            requests: Default::default(),
        };
        let theme = DispatchTheme { kicker: "K".into(), headline: "H".into(), dek: "D".into(), importance: 3,
            article_ids: vec!["a".into()], body: vec![], takeaways: vec![], error: None };
        let piece = write_piece(&provider, "m", &theme, "[1] Report\nText").await.unwrap();
        assert_eq!(piece.body, vec!["Cited now [1]."]);
        let requests = provider.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        assert!(requests[1].messages[3].content.contains("didn't cite"));
    }

    #[test]
    fn editions_are_kept_and_count_what_arrived_since() {
        let conn = Connection::open_in_memory().unwrap();
        crate::db::migrations::run_migrations(&conn).unwrap();
        let mut edition = empty_edition("dispatch-0-100-1", 0, 100, 1, "complete");
        edition.generated_at = 50;
        save(&conn, &edition).unwrap();
        conn.execute("INSERT INTO feeds (id, title, url, created_at, updated_at) VALUES ('f', 'Feed', 'https://f', 0, 0)", []).unwrap();
        for (id, fetched) in [("old", 40), ("new", 60), ("late", 200)] {
            conn.execute("INSERT INTO articles (id, feed_id, title, published_at, fetched_at) VALUES (?1, 'f', 'T', ?2, ?2)",
                params![id, fetched]).unwrap();
        }
        let loaded = load(&conn, "dispatch-0-100-1").unwrap().unwrap();
        assert_eq!(loaded.new_article_count, 1);
        assert!(validate_window(0, 100, 2).is_err());
    }

    #[test]
    fn the_lead_is_read_alone_and_tops_the_plan() {
        let pool: Vec<_> = (0..6).map(|i| article(&format!("a{i}"), "f", &format!("T{i}"), &format!("https://e.com/{i}"), i)).collect();
        let lead = parse_lead(r#"Lead: {"kicker":"Security","headline":"CA breached","dek":"Certificates at risk.","importance":5,"articles":[1,2,1,40]}"#, &pool).unwrap();
        assert_eq!(lead.headline, "CA breached");
        assert_eq!(lead.article_ids, vec!["a1", "a2"]);
        assert!(parse_lead(r#"{"headline":"","articles":[]}"#, &pool).is_err());

        let plan = parse_plan(r#"{"themes":[
            {"headline":"Certificate authority breach widens","importance":5,"articles":[1,2,3]},
            {"headline":"DuckDB 2.0 ships","importance":2,"articles":[0,4]}
        ],"briefs":[{"text":"Small thing.","articles":[5]}]}"#, &pool).unwrap();
        let merged = merge_lead(lead, plan);
        assert_eq!(merged.themes.iter().map(|t| t.headline.as_str()).collect::<Vec<_>>(), vec!["CA breached", "DuckDB 2.0 ships"]);
        assert_eq!(merged.themes[1].article_ids, vec!["a0", "a4"]);
        assert_eq!(merged.briefs.len(), 1);
    }

    #[test]
    fn the_stand_in_is_the_newest_earlier_edition_with_pieces() {
        let conn = Connection::open_in_memory().unwrap();
        crate::db::migrations::run_migrations(&conn).unwrap();
        let day = 86_400;
        let base = 1_800_000_000;
        let edition = |start: i64, written: bool| {
            let mut edition = empty_edition(&edition_id(start, start + 3 * day, 3), start, start + 3 * day, 3, "complete");
            edition.themes = vec![DispatchTheme {
                kicker: "K".into(), headline: "H".into(), dek: String::new(), importance: 3,
                article_ids: vec!["x".into()], body: if written { vec!["B [1].".into()] } else { vec![] }, takeaways: vec![], error: None,
            }];
            edition
        };
        for (start, written) in [(base, true), (base + day, true), (base + 2 * day, false)] {
            save(&conn, &edition(start, written)).unwrap();
        }
        let current = edition_id(base + 3 * day, base + 6 * day, 3);
        let newer = edition_id(base + day, base + 4 * day, 3);
        assert_eq!(latest_written(&conn, 3, base + 6 * day, &current).unwrap().unwrap().id, newer);
        assert_eq!(latest_written(&conn, 3, base + 6 * day, &newer).unwrap().unwrap().id, edition_id(base, base + 3 * day, 3));
        assert!(latest_written(&conn, 1, base + 6 * day, &current).unwrap().is_none());
    }
}
