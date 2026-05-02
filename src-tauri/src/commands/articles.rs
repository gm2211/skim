use crate::db::models::ArticleFilter;
use crate::db::queries;
use crate::db::Database;
use crate::feed::feedly;
use serde::Serialize;
use tauri::State;

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
pub async fn count_articles(
    db: State<'_, Database>,
    filter: ArticleFilter,
) -> Result<i64, String> {
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
        queries::mark_articles_read(&conn, &article_ids).map_err(|e| e.to_string())?;
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

#[tauri::command]
pub async fn mark_all_read(
    db: State<'_, Database>,
    feed_id: Option<String>,
) -> Result<(), String> {
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
pub async fn toggle_read(
    db: State<'_, Database>,
    article_id: String,
) -> Result<bool, String> {
    let (new_is_read, feedly_entry_id) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let new_is_read = queries::toggle_read(&conn, &article_id).map_err(|e| e.to_string())?;
        let entry_ids = queries::get_feedly_entry_ids(&conn, &[article_id.clone()]).unwrap_or_default();
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

#[derive(Debug, Serialize)]
pub struct FullArticleContent {
    pub html: String,
    pub raw_html: String,
}

/// Rewrite URLs to static/readable versions when possible. Reddit's modern
/// site is a JS SPA that doesn't render inside a cross-origin iframe, but
/// old.reddit.com returns a server-rendered HTML page that works fine.
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
        }
    }
    url.to_string()
}

#[tauri::command]
pub async fn fetch_full_article(url: String) -> Result<FullArticleContent, String> {
    let effective_url = rewrite_for_static(&url);

    let client = reqwest::Client::builder()
        // Use a real browser UA — some sites serve blank shells to unknown UAs
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15")
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let response = client
        .get(&effective_url)
        .send()
        .await
        .map_err(|e| format!("Failed to fetch article: {}", e))?;

    let html = response
        .text()
        .await
        .map_err(|e| format!("Failed to read response: {}", e))?;

    // Inject <base href="..."> so relative URLs (images, stylesheets) resolve
    // against the original site if anything ends up consuming raw_html.
    let base_tag = format!("<base href=\"{}\">", effective_url.replace('"', "&quot;"));
    let raw_html = if let Some(head_end) = html.to_lowercase().find("<head") {
        if let Some(tag_close) = html[head_end..].find('>') {
            let insert_at = head_end + tag_close + 1;
            format!("{}{}{}", &html[..insert_at], base_tag, &html[insert_at..])
        } else {
            html.clone()
        }
    } else {
        html.clone()
    };

    // Many SPAs (Next.js, etc.) ship a <script id="__NEXT_DATA__"> JSON blob
    // with the article body — readability can't see it because the page DOM
    // hasn't been hydrated. Try to pull a usable body string out of common
    // shapes first; fall back to dom_smoothie for traditional pages.
    let nextjs_extract = extract_from_next_data(&html);

    let cleaned = if let Some(body) = nextjs_extract {
        plain_to_html(&body)
    } else {
        match dom_smoothie::Readability::new(
            html.as_str(),
            Some(&effective_url),
            Some(dom_smoothie::Config::default()),
        ) {
            Ok(mut r) => match r.parse() {
                Ok(article) => article.content.to_string(),
                Err(_) => String::new(),
            },
            Err(_) => String::new(),
        }
    };

    Ok(FullArticleContent { html: cleaned, raw_html })
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
        "articleBody", "body", "content", "html", "markup", "rawBody", "post_body", "story_body",
    ];

    fn walk(v: &serde_json::Value, out: &mut Option<String>) {
        if out.is_some() { return; }
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
                    if out.is_some() { return; }
                }
            }
            serde_json::Value::Array(arr) => {
                for vv in arr {
                    walk(vv, out);
                    if out.is_some() { return; }
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
        if p.is_empty() { continue; }
        let escaped = p.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
        let linked = url_re.replace_all(&escaped, |caps: &regex::Captures| {
            let u = &caps[0];
            format!(r#"<a href="{}" target="_blank" rel="noreferrer">{}</a>"#, u, u)
        });
        out.push_str("<p>");
        out.push_str(&linked.replace('\n', "<br/>"));
        out.push_str("</p>\n");
    }
    out
}

#[tauri::command]
pub async fn toggle_star(
    db: State<'_, Database>,
    article_id: String,
) -> Result<bool, String> {
    let (new_is_starred, feedly_entry_id) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let new_is_starred = queries::toggle_star(&conn, &article_id).map_err(|e| e.to_string())?;
        let entry_ids = queries::get_feedly_entry_ids(&conn, &[article_id.clone()]).unwrap_or_default();
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
