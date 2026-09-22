use crate::db::models::ArticleFilter;
use crate::db::queries;
use crate::db::Database;
use crate::feed::feedly;
use regex::Regex;
use serde::Serialize;
use serde_json::Value;
use tauri::State;
use url::Url;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, Weak};

/// Read the Feedly token and user ID from settings, if configured.
fn get_feedly_context(db: &Database) -> Option<(String, String)> {
    let conn = db.conn.lock().ok()?;
    let token = queries::get_setting(&conn, "feedly_token").ok()??;
    let user_id = queries::get_setting(&conn, "feedly_user_id").ok()??;
    Some((token, user_id))
}

#[tauri::command]
pub async fn get_articles(
    db: State<'_, Database>,
    filter: ArticleFilter,
) -> Result<Vec<crate::db::models::ArticleWithFeed>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::get_articles(&conn, &filter).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn count_articles(db: State<'_, Database>, filter: ArticleFilter) -> Result<i64, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::count_articles(&conn, &filter).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_article(
    db: State<'_, Database>,
    article_id: String,
) -> Result<crate::db::models::ArticleWithFeed, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::get_article_by_id(&conn, &article_id)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Article not found".to_string())
}

#[tauri::command]
pub async fn mark_articles_read(
    db: State<'_, Database>,
    article_ids: Vec<String>,
) -> Result<(), String> {
    let feedly_entry_ids = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        // Bulk operations must commit once, rather than fsync each article.
        let transaction = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        queries::mark_articles_read(&transaction, &article_ids).map_err(|e| e.to_string())?;
        transaction.commit().map_err(|e| e.to_string())?;
        queries::get_feedly_entry_ids(&conn, &article_ids).unwrap_or_default()
    };

    if !feedly_entry_ids.is_empty() {
        if let Some((token, _user_id)) = get_feedly_context(&db) {
            let entry_ids: Vec<String> = feedly_entry_ids.into_iter().map(|(_, eid)| eid).collect();
            tokio::spawn(async move {
                if let Err(e) = feedly::mark_entries_read(&token, entry_ids).await {
                    log::warn!("Failed to sync read state to Feedly: {}", e);
                }
            });
        }
    }

    Ok(())
}

#[tauri::command]
pub async fn mark_articles_unread(
    db: State<'_, Database>,
    article_ids: Vec<String>,
) -> Result<(), String> {
    let feedly_entry_ids = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::mark_articles_unread(&conn, &article_ids).map_err(|e| e.to_string())?;
        queries::get_feedly_entry_ids(&conn, &article_ids).unwrap_or_default()
    };

    if !feedly_entry_ids.is_empty() {
        if let Some((token, _user_id)) = get_feedly_context(&db) {
            let entry_ids: Vec<String> = feedly_entry_ids.into_iter().map(|(_, eid)| eid).collect();
            tokio::spawn(async move {
                if let Err(e) = feedly::mark_entries_unread(&token, entry_ids).await {
                    log::warn!("Failed to sync unread state to Feedly: {}", e);
                }
            });
        }
    }

    Ok(())
}

/// Enumerate the full scope, never just the list's current page.
fn scoped_read_ids(
    conn: &rusqlite::Connection,
    mut filter: ArticleFilter,
    recent_only: bool,
) -> Result<Vec<String>, rusqlite::Error> {
    filter.limit = Some(-1);
    filter.offset = None;
    filter.is_read = Some(false);
    let recent_ids = if recent_only {
        let mut statement = conn.prepare(
            "SELECT article_id FROM article_interactions WHERE reading_time_sec >= 10
             OR chat_messages > 0 OR feedback IS NOT NULL OR priority_override IS NOT NULL",
        )?;
        let ids = statement.query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<std::collections::HashSet<_>, _>>()?;
        Some(ids)
    } else { None };
    Ok(queries::get_articles(conn, &filter)?.into_iter()
        .filter(|article| recent_ids.as_ref().map_or(true, |ids| ids.contains(&article.article.id)))
        .map(|article| article.article.id).collect())
}

#[tauri::command]
pub async fn mark_all_read(
    db: State<'_, Database>,
    feed_id: Option<String>,
    filter: Option<ArticleFilter>,
    recent_only: Option<bool>,
) -> Result<(), String> {
    if let Some(filter) = filter {
        let ids = {
            let conn = db.conn.lock().map_err(|e| e.to_string())?;
            scoped_read_ids(&conn, filter, recent_only.unwrap_or(false))
                .map_err(|e| e.to_string())?
        };
        return mark_articles_read(db, ids).await;
    }

    // Gather Feedly context before applying local changes
    let feedly_sync_info = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        if let Some(ref fid) = feed_id {
            // Check if this feed has a feedly_id
            queries::get_feed_by_id(&conn, fid)
                .ok()
                .flatten()
                .and_then(|f| f.feedly_id)
                .map(|feedly_id| (feedly_id, fid.clone()))
        } else {
            None
        }
    };

    {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::mark_all_read(&conn, feed_id.as_deref()).map_err(|e| e.to_string())?;
    }

    // Push to Feedly if applicable
    if let Some((feedly_feed_id, _)) = feedly_sync_info {
        if let Some((token, _user_id)) = get_feedly_context(&db) {
            let now_millis = chrono::Utc::now().timestamp_millis();
            tokio::spawn(async move {
                if let Err(e) = feedly::mark_feed_read(&token, &feedly_feed_id, now_millis).await {
                    log::warn!("Failed to sync mark-all-read to Feedly: {}", e);
                }
            });
        }
    }

    Ok(())
}

#[tauri::command]
pub async fn toggle_read(db: State<'_, Database>, article_id: String) -> Result<bool, String> {
    let (new_is_read, feedly_entry_id) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let new_is_read = queries::toggle_read(&conn, &article_id).map_err(|e| e.to_string())?;
        let entry_ids =
            queries::get_feedly_entry_ids(&conn, &[article_id.clone()]).unwrap_or_default();
        let feedly_entry_id = entry_ids.into_iter().next().map(|(_, eid)| eid);
        (new_is_read, feedly_entry_id)
    };

    if let Some(entry_id) = feedly_entry_id {
        if let Some((token, _user_id)) = get_feedly_context(&db) {
            tokio::spawn(async move {
                let result = if new_is_read {
                    feedly::mark_entries_read(&token, vec![entry_id]).await
                } else {
                    feedly::mark_entries_unread(&token, vec![entry_id]).await
                };
                if let Err(e) = result {
                    log::warn!("Failed to sync read state to Feedly: {}", e);
                }
            });
        }
    }

    Ok(new_is_read)
}

#[derive(Clone, Debug, Serialize)]
pub struct FullArticleContent {
    pub html: String,
    pub raw_html: String,
}

/// Rewrite URLs to static/readable versions when possible. Some popular sites
/// ship hydrated shells that replay poorly inside an embedded srcDoc iframe.
fn rewrite_for_static(url: &str) -> String {
    if let Ok(parsed) = url::Url::parse(url) {
        if let Some(host) = parsed.host_str() {
            let host_lower = host.to_lowercase();
            if host_lower == "www.reddit.com"
                || host_lower == "reddit.com"
                || host_lower == "new.reddit.com"
            {
                let mut new_url = parsed.clone();
                let _ = new_url.set_host(Some("old.reddit.com"));
                return new_url.to_string();
            }

            if (host_lower == "github.com" || host_lower == "www.github.com")
                && parsed.path().to_lowercase().ends_with(".ipynb")
                && parsed.path().contains("/blob/")
            {
                return format!(
                    "https://nbviewer.org/github/{}",
                    parsed.path().trim_start_matches('/')
                );
            }
        }
    }
    url.to_string()
}

fn is_hacker_news_host(host: &str) -> bool {
    host == "news.ycombinator.com" || host.ends_with(".ycombinator.com")
}

fn is_reddit_host(host: &str) -> bool {
    matches!(
        host,
        "reddit.com" | "www.reddit.com" | "old.reddit.com" | "new.reddit.com"
    ) || host.ends_with(".reddit.com")
        || host == "redd.it"
}

fn is_external_to_host_family(candidate: &Url, original: &Url) -> bool {
    let Some(candidate_host) = candidate.host_str().map(str::to_lowercase) else {
        return false;
    };
    let Some(original_host) = original.host_str().map(str::to_lowercase) else {
        return true;
    };

    if is_hacker_news_host(&original_host) {
        return !is_hacker_news_host(&candidate_host);
    }
    if is_reddit_host(&original_host) {
        return !is_reddit_host(&candidate_host);
    }

    candidate_host != original_host
}

fn extract_hacker_news_external_url(html: &str, base: &Url) -> Option<String> {
    let patterns = [
        r#"(?is)<span[^>]*class=["'][^"']*\btitleline\b[^"']*["'][^>]*>\s*<a[^>]*href=["']([^"']+)["']"#,
        r#"(?is)<a[^>]*class=["'][^"']*\bstorylink\b[^"']*["'][^>]*href=["']([^"']+)["']"#,
        r#"(?is)<a[^>]*href=["']([^"']+)["'][^>]*class=["'][^"']*\bstorylink\b[^"']*["']"#,
    ];

    for pattern in patterns {
        let Ok(regex) = Regex::new(pattern) else {
            continue;
        };
        for captures in regex.captures_iter(html) {
            let Some(href) = captures.get(1).map(|m| m.as_str()) else {
                continue;
            };
            let Ok(url) = base.join(href) else { continue };
            if is_external_to_host_family(&url, base) {
                return Some(url.to_string());
            }
        }
    }

    None
}

async fn hacker_news_target_from_api(client: &reqwest::Client, url: &Url) -> Option<String> {
    let story_id = url
        .query_pairs()
        .find(|(name, _)| name == "id")
        .map(|(_, value)| value.into_owned())?;
    let value = client
        .get(format!("https://hn.algolia.com/api/v1/items/{story_id}"))
        .send()
        .await
        .ok()?
        .json::<Value>()
        .await
        .ok()?;
    let candidate = value.get("url").and_then(Value::as_str)?;
    let parsed = Url::parse(candidate).ok()?;
    (matches!(parsed.scheme(), "http" | "https") && is_external_to_host_family(&parsed, url))
        .then(|| parsed.to_string())
}

fn reddit_json_url(url: &Url) -> String {
    let mut json_url = url.clone();
    if let Some(host) = json_url.host_str() {
        if host == "old.reddit.com" {
            let _ = json_url.set_host(Some("www.reddit.com"));
        }
    }
    if !json_url.path().ends_with(".json") {
        let path = json_url.path().trim_end_matches('/');
        json_url.set_path(&format!("{path}.json"));
    }
    json_url.to_string()
}

fn extract_reddit_external_url_from_json(value: &Value) -> Option<String> {
    fn walk(value: &Value) -> Option<String> {
        match value {
            Value::Object(map) => {
                if let Some(data) = map.get("data").and_then(Value::as_object) {
                    let is_self = data
                        .get("is_self")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    let candidate = data
                        .get("url_overridden_by_dest")
                        .or_else(|| data.get("url"))
                        .and_then(Value::as_str);
                    if !is_self {
                        if let Some(url) = candidate {
                            if Url::parse(url)
                                .ok()
                                .and_then(|u| {
                                    u.host_str()
                                        .map(str::to_lowercase)
                                        .filter(|host| !is_reddit_host(host))
                                        .map(|_| u.to_string())
                                })
                                .is_some()
                            {
                                return Some(url.to_string());
                            }
                        }
                    }
                }
                map.values().find_map(walk)
            }
            Value::Array(items) => items.iter().find_map(walk),
            _ => None,
        }
    }

    walk(value)
}

fn extract_reddit_external_url_from_html(html: &str, base: &Url) -> Option<String> {
    let Ok(regex) = Regex::new(r#"(?is)<a[^>]+href=["']([^"']+)["'][^>]*>"#) else {
        return None;
    };
    for captures in regex.captures_iter(html) {
        let Some(href) = captures.get(1).map(|m| m.as_str()) else {
            continue;
        };
        let Ok(url) = base.join(href) else { continue };
        if is_external_to_host_family(&url, base) {
            return Some(url.to_string());
        }
    }
    None
}

async fn resolve_aggregator_target(client: &reqwest::Client, url: &str) -> Option<String> {
    let parsed = Url::parse(url).ok()?;
    let host = parsed.host_str()?.to_lowercase();

    if is_hacker_news_host(&host) {
        if let Ok(response) = client.get(parsed.as_str()).send().await {
            if let Ok(html) = response.text().await {
                if let Some(target) = extract_hacker_news_external_url(&html, &parsed) {
                    return Some(target);
                }
            }
        }
        // Scraping the item page fails whenever HN changes its markup or
        // rate-limits us. The public API carries the same submitted URL.
        return hacker_news_target_from_api(client, &parsed).await;
    }

    if is_reddit_host(&host) {
        let json_endpoint = reddit_json_url(&parsed);
        if let Ok(response) = client.get(&json_endpoint).send().await {
            if let Ok(value) = response.json::<Value>().await {
                if let Some(external) = extract_reddit_external_url_from_json(&value) {
                    return Some(external);
                }
            }
        }

        let html = client
            .get(parsed.as_str())
            .send()
            .await
            .ok()?
            .text()
            .await
            .ok()?;
        return extract_reddit_external_url_from_html(&html, &parsed);
    }

    None
}

#[tauri::command]
pub async fn fetch_full_article(url: String) -> Result<FullArticleContent, String> {
    fetch_article_content(&url).await
}

type ReaderResult = Result<FullArticleContent, String>;
type PendingReader = tokio::sync::OnceCell<ReaderResult>;

fn reader_http_client() -> Result<&'static reqwest::Client, String> {
    static CLIENT: OnceLock<Result<reqwest::Client, String>> = OnceLock::new();
    CLIENT.get_or_init(|| reqwest::Client::builder()
        // Preserve the existing browser identity and complete fetch timeout.
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15")
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e)))
        .as_ref().map_err(Clone::clone)
}

pub(crate) async fn fetch_article_content(url: &str) -> ReaderResult {
    // Share concurrent work only. Completed/failed responses are not retained;
    // the existing persistent reader cache owns reuse and explicit refresh.
    static PENDING: OnceLock<Mutex<HashMap<String, Weak<PendingReader>>>> = OnceLock::new();
    let pending = {
        let mut requests = PENDING.get_or_init(|| Mutex::new(HashMap::new()))
            .lock().map_err(|_| "Reader request registry unavailable".to_string())?;
        requests.retain(|_, request| request.strong_count() > 0);
        if let Some(request) = requests.get(url).and_then(Weak::upgrade) {
            request
        } else {
            let request = Arc::new(PendingReader::new());
            requests.insert(url.to_string(), Arc::downgrade(&request));
            request
        }
    };
    pending.get_or_init(|| fetch_article_content_uncached(url)).await.clone()
}

async fn fetch_article_content_uncached(url: &str) -> ReaderResult {
    let started = std::time::Instant::now();
    let client = reader_http_client()?;
    let target_url = resolve_aggregator_target(&client, url)
        .await
        .unwrap_or_else(|| url.to_string());
    let effective_url = rewrite_for_static(&target_url);

    let response = client
        .get(&effective_url)
        .send()
        .await
        .map_err(|e| format!("Failed to fetch article: {}", e))?;

    // A 403/404/5xx body is an error page, not the article. Say so plainly
    // instead of letting extraction fail later with a misleading message.
    let status = response.status();
    if !status.is_success() {
        return Err(format!(
            "Article site returned HTTP {}.",
            status.as_u16()
        ));
    }

    let html = response
        .text()
        .await
        .map_err(|e| format!("Failed to read response: {}", e))?;

    let network_ms = started.elapsed().as_millis();
    let parsed = tokio::task::spawn_blocking(move || extract_reader_html(&html, &effective_url))
        .await.map_err(|e| format!("Article extraction failed: {}", e))?;
    log::debug!("Reader timing: network={}ms extraction={}ms", network_ms,
        started.elapsed().as_millis().saturating_sub(network_ms));
    parsed
}

// Keep the exact extraction order and thresholds; only its scheduling changes.
fn extract_reader_html(html: &str, effective_url: &str) -> ReaderResult {
    // Inject <base href="..."> so relative URLs (images, stylesheets) resolve
    // against the original site if anything ends up consuming raw_html.
    let base_tag = format!("<base href=\"{}\">", effective_url.replace('"', "&quot;"));
    let raw_html = if let Some(head_end) = html.to_ascii_lowercase().find("<head") {
        if let Some(tag_close) = html[head_end..].find('>') {
            let insert_at = head_end + tag_close + 1;
            format!("{}{}{}", &html[..insert_at], base_tag, &html[insert_at..])
        } else {
            html.to_string()
        }
    } else {
        html.to_string()
    };

    // Many SPAs (Next.js, etc.) ship a <script id="__NEXT_DATA__"> JSON blob
    // with the article body — readability can't see it because the page DOM
    // hasn't been hydrated. Try to pull a usable body string out of common
    // shapes first; fall back to dom_smoothie for traditional pages.
    let nextjs_extract = extract_from_next_data(html);

    let cleaned = if let Some(body) = nextjs_extract {
        plain_to_html(&body)
    } else {
        let readable = match dom_smoothie::Readability::new(
            html,
            Some(&effective_url),
            Some(dom_smoothie::Config::default()),
        ) {
            Ok(mut r) => match r.parse() {
                Ok(article) => article.content.to_string(),
                Err(_) => String::new(),
            },
            Err(_) => String::new(),
        };

        // Readability gives up on plenty of real, server-rendered articles
        // (unusual wrappers, table layouts, heavy chrome). Rather than hand
        // back nothing, try the shapes that still carry the body text.
        if visible_text_len(&readable) >= MIN_EXTRACTED_TEXT {
            readable
        } else {
            extract_from_json_ld(html)
                .map(|body| plain_to_html(&body))
                .or_else(|| extract_main_content_block(html))
                .unwrap_or(readable)
        }
    };

    Ok(FullArticleContent {
        html: cleaned,
        raw_html,
    })
}

/// Minimum plain-text length an extraction must reach before we trust it.
/// Matches dom_smoothie's own `char_threshold` so the fallbacks kick in
/// exactly where readability bails out.
const MIN_EXTRACTED_TEXT: usize = 500;

/// Length of the human-visible text in an HTML fragment, ignoring tags and
/// the contents of script/style blocks.
fn visible_text_len(html: &str) -> usize {
    visible_text(html).chars().count()
}

/// Strip tags (and the bodies of non-content elements) down to visible text.
fn visible_text(html: &str) -> String {
    let stripped = strip_elements(html, &["script", "style", "noscript", "svg", "template"]);
    let mut out = String::with_capacity(stripped.len());
    let mut in_tag = false;
    let mut last_was_space = true;
    for ch in stripped.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                if !last_was_space {
                    out.push(' ');
                    last_was_space = true;
                }
            }
            _ if in_tag => {}
            c if c.is_whitespace() => {
                if !last_was_space {
                    out.push(' ');
                    last_was_space = true;
                }
            }
            c => {
                out.push(c);
                last_was_space = false;
            }
        }
    }
    out.trim().to_string()
}

/// Remove `<tag>…</tag>` spans (including the tags themselves) for each name.
/// Depth-aware so nested elements of the same name are removed as one span.
fn strip_elements(html: &str, tags: &[&str]) -> String {
    let mut out = html.to_string();
    for tag in tags {
        let mut result = String::with_capacity(out.len());
        let mut rest = out.as_str();
        while let Some(start) = find_open_tag(rest, tag) {
            result.push_str(&rest[..start]);
            match element_span(&rest[start..], tag) {
                Some((_, end)) => rest = &rest[start + end..],
                None => {
                    rest = "";
                    break;
                }
            }
        }
        result.push_str(rest);
        out = result;
    }
    out
}

/// Byte offset of the next `<tag` / `<tag ` / `<tag>` occurrence.
fn find_open_tag(html: &str, tag: &str) -> Option<usize> {
    let lower = html.to_ascii_lowercase();
    let needle = format!("<{}", tag);
    let mut from = 0usize;
    while let Some(found) = lower[from..].find(&needle) {
        let at = from + found;
        let after = lower[at + needle.len()..].chars().next();
        if matches!(after, None | Some('>') | Some('/')) || after.is_some_and(char::is_whitespace) {
            return Some(at);
        }
        from = at + needle.len();
    }
    None
}

/// Given a slice starting at `<tag`, return (inner-start, span-end) byte
/// offsets relative to that slice, matching nested elements of the same name.
fn element_span(html: &str, tag: &str) -> Option<(usize, usize)> {
    let lower = html.to_ascii_lowercase();
    let open_end = lower.find('>')? + 1;
    // Self-closing or void usage has no inner content worth scanning.
    if lower[..open_end].ends_with("/>") {
        return Some((open_end, open_end));
    }
    let open = format!("<{}", tag);
    let close = format!("</{}", tag);
    let mut depth = 1usize;
    let mut cursor = open_end;
    while cursor < lower.len() {
        let next_open = find_open_tag(&lower[cursor..], tag).map(|i| cursor + i);
        let next_close = lower[cursor..].find(&close).map(|i| cursor + i);
        match (next_open, next_close) {
            (Some(o), Some(c)) if o < c => {
                depth += 1;
                cursor = o + open.len();
            }
            (_, Some(c)) => {
                depth -= 1;
                let after = lower[c..].find('>').map(|i| c + i + 1).unwrap_or(lower.len());
                if depth == 0 {
                    return Some((open_end, after));
                }
                cursor = after;
            }
            (Some(o), None) => cursor = o + open.len(),
            (None, None) => break,
        }
    }
    // Unclosed element: treat the remainder of the document as its content.
    Some((open_end, lower.len()))
}

/// Inner HTML of the first `<tag>` element in the document, if any.
fn first_element_inner(html: &str, tag: &str) -> Option<String> {
    let start = find_open_tag(html, tag)?;
    let slice = &html[start..];
    let (inner_start, span_end) = element_span(slice, tag)?;
    let close_start = slice[..span_end].rfind('<').unwrap_or(span_end);
    if close_start <= inner_start {
        return None;
    }
    Some(slice[inner_start..close_start].to_string())
}

/// Many CMSes ship the full body as JSON-LD `articleBody` even when the
/// rendered markup defeats readability. Walk every ld+json block for it.
fn extract_from_json_ld(html: &str) -> Option<String> {
    let mut rest = html;
    while let Some(start) = find_open_tag(rest, "script") {
        let slice = &rest[start..];
        let Some((inner_start, span_end)) = element_span(slice, "script") else {
            break;
        };
        let open_tag = slice[..inner_start].to_ascii_lowercase();
        if open_tag.contains("ld+json") {
            let close_start = slice[..span_end].rfind('<').unwrap_or(span_end);
            if close_start > inner_start {
                if let Ok(json) =
                    serde_json::from_str::<serde_json::Value>(slice[inner_start..close_start].trim())
                {
                    if let Some(body) = find_article_body(&json) {
                        return Some(body);
                    }
                }
            }
        }
        rest = &slice[span_end..];
    }
    None
}

fn find_article_body(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::Object(map) => {
            if let Some(body) = map
                .get("articleBody")
                .and_then(serde_json::Value::as_str)
                .filter(|body| body.len() >= MIN_EXTRACTED_TEXT)
            {
                return Some(body.to_string());
            }
            map.values().find_map(find_article_body)
        }
        serde_json::Value::Array(items) => items.iter().find_map(find_article_body),
        _ => None,
    }
}

/// Last resort: drop page chrome and keep the densest semantic container, or
/// failing that the document's paragraphs. Only returned when it carries a
/// believable amount of text, so we never trade a real failure for noise.
fn extract_main_content_block(html: &str) -> Option<String> {
    let body = first_element_inner(html, "body").unwrap_or_else(|| html.to_string());
    let cleaned = strip_elements(
        &body,
        &[
            "script", "style", "noscript", "svg", "template", "nav", "header", "footer", "aside",
            "form", "iframe",
        ],
    );

    for tag in ["article", "main"] {
        if let Some(inner) = first_element_inner(&cleaned, tag) {
            if visible_text_len(&inner) >= MIN_EXTRACTED_TEXT {
                return Some(inner);
            }
        }
    }

    let mut paragraphs = String::new();
    let mut rest = cleaned.as_str();
    while let Some(start) = find_open_tag(rest, "p") {
        let slice = &rest[start..];
        // Bound each paragraph at its close tag, or at the next <p> when the
        // markup leaves it unclosed — legal HTML, and common in the wild.
        let closed = element_span(slice, "p")
            .map(|(_, end)| end)
            .unwrap_or(slice.len());
        let next = find_open_tag(&slice[1..], "p")
            .map(|at| at + 1)
            .unwrap_or(slice.len());
        let end = closed.min(next);
        let paragraph = &slice[..end];
        // Skip one-line captions, bylines and link lists.
        if visible_text_len(paragraph) >= 40 {
            paragraphs.push_str(paragraph);
            paragraphs.push('\n');
        }
        rest = &slice[end..];
    }
    (visible_text_len(&paragraphs) >= MIN_EXTRACTED_TEXT).then_some(paragraphs)
}

// Walk common Next.js / framework JSON shapes to find a long article-body
// string. Returns Some(body) only if the candidate is at least 500 chars,
// which keeps us from picking up excerpts or metadata blurbs.
fn extract_from_next_data(html: &str) -> Option<String> {
    let needle = r#"id="__NEXT_DATA__""#;
    let i = html.find(needle)?;
    let start = html[i..].find('>')? + i + 1;
    let end = html[start..].find("</script>")? + start;
    let blob = &html[start..end];
    let json: serde_json::Value = serde_json::from_str(blob).ok()?;

    // Common keys that hold the actual article content as a string.
    const BODY_KEYS: &[&str] = &[
        "articleBody",
        "body",
        "content",
        "html",
        "markup",
        "rawBody",
        "post_body",
        "story_body",
    ];

    fn walk(v: &serde_json::Value, out: &mut Option<String>) {
        if out.is_some() {
            return;
        }
        match v {
            serde_json::Value::Object(map) => {
                for (k, vv) in map {
                    if BODY_KEYS.contains(&k.as_str()) {
                        if let Some(s) = vv.as_str() {
                            if s.len() >= 500 {
                                *out = Some(s.to_string());
                                return;
                            }
                        }
                    }
                    walk(vv, out);
                    if out.is_some() {
                        return;
                    }
                }
            }
            serde_json::Value::Array(arr) => {
                for vv in arr {
                    walk(vv, out);
                    if out.is_some() {
                        return;
                    }
                }
            }
            _ => {}
        }
    }

    let mut found = None;
    walk(&json, &mut found);
    found
}

// Convert a plain-text (or lightly-marked) article body to renderable HTML:
// split on blank lines for paragraphs, auto-link bare URLs, escape HTML.
fn plain_to_html(text: &str) -> String {
    // If the body already looks like HTML, hand it back unchanged.
    if text.contains("<p") || text.contains("<div") || text.contains("<h2") {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len() + 128);
    let url_re = regex::Regex::new(r"https?://[^\s<>\)\]]+").unwrap();
    for para in text.split("\n\n") {
        let p = para.trim();
        if p.is_empty() {
            continue;
        }
        let escaped = p
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;");
        let linked = url_re.replace_all(&escaped, |caps: &regex::Captures| {
            let u = &caps[0];
            format!(
                r#"<a href="{}" target="_blank" rel="noreferrer">{}</a>"#,
                u, u
            )
        });
        out.push_str("<p>");
        out.push_str(&linked.replace('\n', "<br/>"));
        out.push_str("</p>\n");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{
        extract_hacker_news_external_url, extract_reddit_external_url_from_json, reddit_json_url,
        rewrite_for_static,
    };
    use serde_json::json;
    use url::Url;

    #[test]
    fn rewrites_reddit_to_old_reddit() {
        assert_eq!(
            rewrite_for_static("https://www.reddit.com/r/rust/comments/abc/example/"),
            "https://old.reddit.com/r/rust/comments/abc/example/"
        );
    }

    #[test]
    fn rewrites_github_notebooks_to_nbviewer() {
        assert_eq!(
            rewrite_for_static(
                "https://github.com/norvig/pytudes/blob/main/ipynb/xkcd-Name-Dominoes.ipynb"
            ),
            "https://nbviewer.org/github/norvig/pytudes/blob/main/ipynb/xkcd-Name-Dominoes.ipynb"
        );
    }

    #[test]
    fn leaves_non_notebook_github_urls_unchanged() {
        assert_eq!(
            rewrite_for_static("https://github.com/norvig/pytudes/blob/main/README.md"),
            "https://github.com/norvig/pytudes/blob/main/README.md"
        );
    }

    #[test]
    fn extracts_hacker_news_story_target() {
        let base = Url::parse("https://news.ycombinator.com/item?id=123").unwrap();
        let html =
            r#"<span class="titleline"><a href="https://example.com/story">Story</a></span>"#;
        assert_eq!(
            extract_hacker_news_external_url(html, &base),
            Some("https://example.com/story".to_string())
        );
    }

    #[test]
    fn extracts_reddit_link_post_target_from_json() {
        let value = json!([
            {
                "data": {
                    "children": [
                        {
                            "data": {
                                "is_self": false,
                                "url_overridden_by_dest": "https://example.com/article"
                            }
                        }
                    ]
                }
            }
        ]);
        assert_eq!(
            extract_reddit_external_url_from_json(&value),
            Some("https://example.com/article".to_string())
        );
    }

    #[test]
    fn builds_reddit_json_url() {
        let url =
            Url::parse("https://old.reddit.com/r/rust/comments/abc/example/?sort=top").unwrap();
        assert_eq!(
            reddit_json_url(&url),
            "https://www.reddit.com/r/rust/comments/abc/example.json?sort=top"
        );
    }
}

#[tauri::command]
pub async fn toggle_star(db: State<'_, Database>, article_id: String) -> Result<bool, String> {
    let (new_is_starred, feedly_entry_id) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let new_is_starred = queries::toggle_star(&conn, &article_id).map_err(|e| e.to_string())?;
        let entry_ids =
            queries::get_feedly_entry_ids(&conn, &[article_id.clone()]).unwrap_or_default();
        let feedly_entry_id = entry_ids.into_iter().next().map(|(_, eid)| eid);
        (new_is_starred, feedly_entry_id)
    };

    if let Some(entry_id) = feedly_entry_id {
        if let Some((token, user_id)) = get_feedly_context(&db) {
            tokio::spawn(async move {
                let result = if new_is_starred {
                    feedly::save_entry(&token, &user_id, vec![entry_id]).await
                } else {
                    feedly::unsave_entry(&token, &user_id, &entry_id).await
                };
                if let Err(e) = result {
                    log::warn!("Failed to sync star state to Feedly: {}", e);
                }
            });
        }
    }

    Ok(new_is_starred)
}

#[cfg(test)]
mod reader_performance_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    fn fixture() -> String {
        format!("<html><head><title>Reader fixture</title></head><body><nav>Menu</nav><article><h1>Reader fixture</h1><p>{}</p><p><a href=\"/reference\">Original reference</a></p></article></body></html>",
            "This is the complete article, including its evidence and qualifications. ".repeat(30))
    }

    async fn server(fail_first: bool) -> (String, Arc<AtomicUsize>, Arc<AtomicUsize>, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/article", listener.local_addr().unwrap());
        let requests = Arc::new(AtomicUsize::new(0));
        let connections = Arc::new(AtomicUsize::new(0));
        let request_count = requests.clone();
        let connection_count = connections.clone();
        let handle = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                connection_count.fetch_add(1, Ordering::SeqCst);
                let count = request_count.clone();
                tokio::spawn(async move {
                    let mut stream = BufReader::new(stream);
                    loop {
                        let mut line = String::new();
                        loop {
                            line.clear();
                            if stream.read_line(&mut line).await.unwrap_or(0) == 0 { return; }
                            if line == "\r\n" { break; }
                        }
                        let n = count.fetch_add(1, Ordering::SeqCst);
                        if fail_first && n == 0 {
                            let _ = stream.get_mut().write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 999\r\nConnection: close\r\n\r\nshort").await;
                            return;
                        }
                        tokio::time::sleep(std::time::Duration::from_millis(60)).await;
                        let body = fixture();
                        let response = format!("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n{}", body.len(), body);
                        if stream.get_mut().write_all(response.as_bytes()).await.is_err() { return; }
                    }
                });
            }
        });
        (url, requests, connections, handle)
    }

    #[tokio::test]
    async fn simultaneous_opens_share_fetch_and_reload_reuses_connection() {
        let (url, requests, connections, server) = server(false).await;
        let opened = futures_util::future::join_all((0..3).map(|_| fetch_article_content(&url))).await;
        let expected = extract_reader_html(&fixture(), &url).unwrap();
        for result in opened {
            let result = result.unwrap();
            assert_eq!(result.html, expected.html);
            assert_eq!(result.raw_html, expected.raw_html);
            assert!(result.html.contains("complete article"));
            assert!(result.html.contains("Original reference"));
        }
        assert_eq!(requests.load(Ordering::SeqCst), 1);
        // Explicit new fetch remains fresh; only concurrent calls share results.
        assert_eq!(fetch_article_content(&url).await.unwrap().html, expected.html);
        assert_eq!(requests.load(Ordering::SeqCst), 2);
        assert_eq!(connections.load(Ordering::SeqCst), 1);
        println!("3 simultaneous opens: 1 download; subsequent fresh fetch: same TCP connection; extracted HTML identical");
        server.abort();
    }

    #[tokio::test]
    async fn failed_fetch_does_not_poison_retry() {
        let (url, requests, _, server) = server(true).await;
        assert!(fetch_article_content(&url).await.is_err());
        assert!(!fetch_article_content(&url).await.unwrap().html.is_empty());
        assert_eq!(requests.load(Ordering::SeqCst), 2);
        server.abort();
    }

    #[test]
    fn nextjs_body_and_static_article_keep_complete_text_and_links() {
        let body = format!("<p>{}</p><p><a href=\"https://example.org/evidence\">Evidence</a></p>", "Accurate complete body with qualifications. ".repeat(30));
        let data = serde_json::json!({"props":{"pageProps":{"articleBody":body}}});
        let html = format!("<html><head></head><body><script id=\"__NEXT_DATA__\">{data}</script><p>Short teaser</p></body></html>");
        let result = extract_reader_html(&html, "https://example.org/story").unwrap();
        assert_eq!(result.html, body);
        assert!(result.raw_html.contains("<base href=\"https://example.org/story\">"));
        assert!(result.raw_html.contains("Short teaser"));
        let static_result = extract_reader_html(&fixture(), "https://example.org/story").unwrap();
        assert!(static_result.html.contains("complete article, including its evidence and qualifications"));
        assert!(static_result.html.contains("https://example.org/reference"));
    }
}
#[cfg(test)]
mod reader_fallback_tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    fn long_body() -> String {
        "The piece explains the ruling, the objection to it, and the answer. ".repeat(12)
    }

    // A hydrated shell: nothing readable in the markup, the whole body in JSON-LD.
    fn json_ld_shell() -> String {
        let data = serde_json::json!({
            "@context": "https://schema.org",
            "@graph": [
                {"@type": "WebSite", "name": "Example"},
                {"@type": "Article", "headline": "Shell", "articleBody": long_body()}
            ]
        });
        format!(
            "<html><head><title>Shell</title>\
             <script type=\"application/ld+json\">{data}</script></head>\
             <body><div id=\"root\"></div></body></html>"
        )
    }

    #[test]
    fn json_ld_body_rescues_pages_readability_gives_up_on() {
        let html = json_ld_shell();
        // Readability alone finds nothing in this shell.
        let bare = dom_smoothie::Readability::new(
            html.as_str(),
            Some("https://example.org/story"),
            Some(dom_smoothie::Config::default()),
        )
        .unwrap()
        .parse();
        assert!(bare.is_err(), "fixture must be one readability rejects");

        let result = extract_reader_html(&html, "https://example.org/story").unwrap();
        assert!(result.html.contains("The piece explains the ruling"));
        assert!(result.html.starts_with("<p>"));
    }

    #[test]
    fn paragraph_fallback_skips_chrome_and_keeps_the_body() {
        let html = format!(
            "<html><body><nav><p>Home About Contact Donate Subscribe Newsletter</p></nav>\
             <header><p>Site header text that should never reach the reader pane</p></header>\
             <div class=\"co_body\"><p>{}</p><p>{}</p></div>\
             <footer><p>Footer boilerplate</p></footer></body></html>",
            long_body(),
            long_body()
        );
        let extracted = extract_main_content_block(&html).unwrap();
        assert!(extracted.contains("The piece explains the ruling"));
        assert!(!extracted.contains("Home About Contact"));
        assert!(!extracted.contains("Site header text"));
        assert!(!extracted.contains("Footer boilerplate"));
    }

    #[test]
    fn unclosed_paragraphs_do_not_swallow_the_rest_of_the_page() {
        let html = format!(
            "<html><body><div><p>{}<p>{}</div><footer><p>Footer boilerplate that is plenty long to survive the length filter</p></footer></body></html>",
            long_body(),
            long_body()
        );
        let extracted = extract_main_content_block(&html).unwrap();
        assert!(extracted.contains("The piece explains the ruling"));
        assert!(!extracted.contains("Footer boilerplate"));
    }

    #[test]
    fn main_content_block_prefers_the_article_element() {
        let html = format!(
            "<html><body><aside><p>Related reading</p></aside>\
             <article><p>{}</p></article></body></html>",
            long_body()
        );
        let extracted = extract_main_content_block(&html).unwrap();
        assert!(extracted.contains("The piece explains the ruling"));
        assert!(!extracted.contains("Related reading"));
    }

    #[test]
    fn thin_pages_are_not_dressed_up_as_articles() {
        let html = "<html><body><article><p>Too short to be a story.</p></article></body></html>";
        assert!(extract_main_content_block(html).is_none());
        assert!(extract_from_json_ld(html).is_none());
    }

    #[test]
    fn nested_same_name_elements_close_at_the_right_tag() {
        let html = "<body><article>outer <article>inner</article> tail</article>after</body>";
        assert_eq!(
            first_element_inner(html, "article").as_deref(),
            Some("outer <article>inner</article> tail")
        );
        assert_eq!(strip_elements(html, &["article"]), "<body>after</body>");
    }

    #[test]
    fn visible_text_ignores_tags_and_script_bodies() {
        let html = "<div><script>var junk = 'hidden words here';</script><p>Real&nbsp;words</p></div>";
        let text = visible_text(html);
        assert!(!text.contains("hidden words"));
        assert!(text.contains("Real"));
    }

    #[test]
    fn open_tag_match_is_exact() {
        assert_eq!(find_open_tag("<pre>x</pre><p>y</p>", "p"), Some(12));
        assert_eq!(find_open_tag("<PARAGRAPH>", "p"), None);
        assert_eq!(find_open_tag("<P class=\"a\">", "p"), Some(0));
    }

    #[test]
    fn non_ascii_pages_do_not_shift_offsets() {
        let html = format!("<html><body><article><p>İstanbul — {}</p></article></body></html>", long_body());
        let extracted = extract_main_content_block(&html).unwrap();
        assert!(extracted.contains("İstanbul"));
    }

    #[test]
    fn extraction_miss_still_returns_the_downloaded_page() {
        let html = "<html><head></head><body><div id=\"root\"></div></body></html>";
        let result = extract_reader_html(html, "https://example.org/story").unwrap();
        assert!(result.html.trim().is_empty());
        // The web view needs this: the page downloaded fine, only the reader failed.
        assert!(result.raw_html.contains("<base href=\"https://example.org/story\">"));
        assert!(result.raw_html.contains("id=\"root\""));
    }

    async fn status_server(status_line: &'static str) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/blocked", listener.local_addr().unwrap());
        let handle = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let mut stream = BufReader::new(stream);
                    let mut line = String::new();
                    loop {
                        line.clear();
                        if stream.read_line(&mut line).await.unwrap_or(0) == 0 {
                            return;
                        }
                        if line == "\r\n" {
                            break;
                        }
                    }
                    let body = "<html><body>Access denied</body></html>";
                    let response = format!(
                        "{status_line}\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = stream.get_mut().write_all(response.as_bytes()).await;
                });
            }
        });
        (url, handle)
    }

    #[tokio::test]
    async fn blocked_pages_report_the_http_status() {
        let (url, server) = status_server("HTTP/1.1 403 Forbidden").await;
        let error = fetch_article_content(&url).await.unwrap_err();
        assert!(error.contains("403"), "unexpected error: {error}");
        server.abort();
    }
}


#[cfg(test)]
mod scoped_read_tests {
    use super::*;

    fn fixture() -> rusqlite::Connection {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::db::migrations::run_migrations(&conn).unwrap();
        conn.execute_batch("INSERT INTO feeds (id,title,url,created_at,updated_at) VALUES
            ('inside','Inside','https://inside.test',0,0), ('outside','Outside','https://outside.test',0,0);
            INSERT INTO articles (id,feed_id,title,fetched_at,is_starred) VALUES
            ('outside','outside','Outside',1,1);").unwrap();
        for index in 0..205 {
            conn.execute("INSERT INTO articles (id,feed_id,title,fetched_at,is_starred) VALUES (?1,'inside',?1,1,?2)",
                rusqlite::params![format!("a{index}"), i32::from(index == 0)]).unwrap();
        }
        conn
    }

    fn filter(value: serde_json::Value) -> ArticleFilter {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn scoped_read_updates_entire_folder_without_touching_other_feeds() {
        let conn = fixture();
        let ids = scoped_read_ids(&conn, filter(serde_json::json!({
            "feed_ids": ["inside"], "limit": 2, "offset": 100
        })), false).unwrap();
        assert_eq!(ids.len(), 205);
        queries::mark_articles_read(&conn, &ids).unwrap();
        assert_eq!(queries::count_articles(&conn, &filter(serde_json::json!({"is_read": false}))).unwrap(), 1);
        assert_eq!(conn.query_row("SELECT is_read FROM articles WHERE id='outside'", [], |r| r.get::<_, i32>(0)).unwrap(), 0);
    }

    #[test]
    fn scoped_read_matches_theme_and_url_search_without_other_articles() {
        let conn = fixture();
        conn.execute_batch("INSERT INTO themes(id,label,created_at,expires_at) VALUES ('theme','Theme',0,999);
            INSERT INTO theme_articles(theme_id,article_id) VALUES ('theme','a3');
            UPDATE articles SET url='https://unique-domain.test/story' WHERE id='a4';").unwrap();
        assert_eq!(scoped_read_ids(&conn, filter(serde_json::json!({"theme_id": "theme"})), false).unwrap(), vec!["a3"]);
        assert_eq!(scoped_read_ids(&conn, filter(serde_json::json!({"search": "unique-domain"})), false).unwrap(), vec!["a4"]);
    }

    #[test]
    fn scoped_read_preserves_starred_empty_folder_and_recent_membership() {
        let conn = fixture();
        assert!(scoped_read_ids(&conn, filter(serde_json::json!({"feed_ids": []})), false).unwrap().is_empty());
        assert_eq!(scoped_read_ids(&conn, filter(serde_json::json!({"is_starred": true})), false).unwrap().len(), 2);
        conn.execute_batch("INSERT INTO article_interactions(article_id,reading_time_sec,updated_at) VALUES ('a0',15,1),('a1',2,1)").unwrap();
        assert_eq!(scoped_read_ids(&conn, filter(serde_json::json!({})), true).unwrap(), vec!["a0"]);
    }
}
