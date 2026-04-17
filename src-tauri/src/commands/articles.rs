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

    // Extract body content -- strip everything outside <body> if present
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
                    // Self-closing or unclosed -- remove to next >
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
        loop {
            let lower = clean.to_lowercase();
            if let Some(pos) = lower.find(pattern) {
                let tag_start = clean[..pos].rfind('<').unwrap_or(pos);
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
