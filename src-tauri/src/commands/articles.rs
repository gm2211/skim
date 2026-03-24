use crate::db::models::{ArticleFilter, ArticleWithFeed};
use crate::db::queries;
use crate::db::Database;
use tauri::State;
use serde::Serialize;

#[tauri::command]
pub async fn get_articles(
    db: State<'_, Database>,
    filter: ArticleFilter,
) -> Result<Vec<ArticleWithFeed>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::get_articles(&conn, &filter).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_article(
    db: State<'_, Database>,
    article_id: String,
) -> Result<ArticleWithFeed, String> {
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
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::mark_articles_read(&conn, &article_ids).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn mark_articles_unread(
    db: State<'_, Database>,
    article_ids: Vec<String>,
) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::mark_articles_unread(&conn, &article_ids).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn mark_all_read(
    db: State<'_, Database>,
    feed_id: Option<String>,
) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::mark_all_read(&conn, feed_id.as_deref()).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn toggle_read(
    db: State<'_, Database>,
    article_id: String,
) -> Result<bool, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::toggle_read(&conn, &article_id).map_err(|e| e.to_string())
}

#[derive(Debug, Serialize)]
pub struct FullArticleContent {
    pub html: String,
    pub raw_html: String,
}

#[tauri::command]
pub async fn fetch_full_article(url: String) -> Result<FullArticleContent, String> {
    let client = reqwest::Client::builder()
        .user_agent("Skim/0.1 RSS Reader")
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let response = client
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("Failed to fetch article: {}", e))?;

    let html = response
        .text()
        .await
        .map_err(|e| format!("Failed to read response: {}", e))?;

    let raw_html = html.clone();

    // Extract body content — strip everything outside <body> if present
    let body_html = if let Some(start) = html.find("<body") {
        let content_start = html[start..].find('>').map(|i| start + i + 1).unwrap_or(start);
        if let Some(end) = html[content_start..].find("</body>") {
            html[content_start..content_start + end].to_string()
        } else {
            html[content_start..].to_string()
        }
    } else {
        html
    };

    // Strip unwanted tags
    let mut clean = body_html;
    for tag in &[
        "script", "style", "nav", "header", "footer", "noscript",
        "aside", "form", "button", "svg", "iframe",
    ] {
        loop {
            let open = format!("<{}", tag);
            let close = format!("</{}>", tag);
            let lower = clean.to_lowercase();
            if let Some(start) = lower.find(&open) {
                if let Some(end) = lower[start..].find(&close) {
                    clean = format!("{}{}", &clean[..start], &clean[start + end + close.len()..]);
                } else {
                    // Self-closing or unclosed — remove to next >
                    if let Some(end_bracket) = clean[start..].find('>') {
                        clean = format!("{}{}", &clean[..start], &clean[start + end_bracket + 1..]);
                    } else {
                        break;
                    }
                }
            } else {
                break;
            }
        }
    }

    // Strip elements with common UI/paywall class patterns
    let ui_patterns = [
        "skip-to", "skip_to", "skipnav", "paywall", "subscriber",
        "ad-slot", "ad_slot", "advert", "newsletter", "popup",
        "toolbar", "topbar", "top-bar", "site-header", "site-nav",
        "story-settings", "minimize-to-nav", "learn-more",
    ];
    for pattern in &ui_patterns {
        // Remove any element whose opening tag contains the pattern
        loop {
            let lower = clean.to_lowercase();
            if let Some(pos) = lower.find(pattern) {
                // Walk back to find the opening <
                let tag_start = clean[..pos].rfind('<').unwrap_or(pos);
                // Find the closing > of this tag
                if let Some(tag_end) = clean[pos..].find('>') {
                    clean = format!("{}{}", &clean[..tag_start], &clean[pos + tag_end + 1..]);
                } else {
                    break;
                }
            } else {
                break;
            }
        }
    }

    Ok(FullArticleContent { html: clean, raw_html })
}

#[tauri::command]
pub async fn toggle_star(
    db: State<'_, Database>,
    article_id: String,
) -> Result<bool, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::toggle_star(&conn, &article_id).map_err(|e| e.to_string())
}
