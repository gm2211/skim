use crate::ai::local_provider::SharedModelState;
use crate::ai::provider::{create_provider, ChatMessage, ChatRequest};
use crate::commands::ai::{default_model, extract_json_object};
use crate::db::models::{AppSettings, Feed, Folder, SmartRule, SmartRules, MatchMode};
use crate::db::queries;
use crate::db::Database;
use crate::feed::fetch_and_parse_feed;
use crate::feed::feedly;
use crate::feed::feedly_oauth;
use serde::{Deserialize, Serialize};
use tauri::State;

#[derive(Debug, Serialize)]
pub struct FeedWithCount {
    #[serde(flatten)]
    pub feed: Feed,
    pub unread_count: i64,
}

/// Normalize a feed URL for duplicate detection.
/// Strips scheme, www prefix, trailing slash, fragments, and a small set of
/// tracking query params. Case-insensitive on host, case-preserving on path
/// (many feeds have case-sensitive paths).
pub fn normalize_feed_url(url: &str) -> String {
    let trimmed = url.trim();
    let parsed = match url::Url::parse(trimmed) {
        Ok(u) => u,
        Err(_) => return trimmed.trim_end_matches('/').to_lowercase(),
    };
    let host = parsed
        .host_str()
        .map(|h| h.trim_start_matches("www.").to_lowercase())
        .unwrap_or_default();
    let path = parsed.path().trim_end_matches('/');
    let filtered_query: Option<String> = parsed.query().and_then(|q| {
        let kept: Vec<(String, String)> = url::form_urlencoded::parse(q.as_bytes())
            .filter(|(k, _)| {
                let lk = k.to_lowercase();
                !lk.starts_with("utm_") && lk != "fbclid" && lk != "gclid"
            })
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect();
        if kept.is_empty() {
            None
        } else {
            Some(url::form_urlencoded::Serializer::new(String::new()).extend_pairs(kept).finish())
        }
    });
    match filtered_query {
        Some(q) => format!("{}{}?{}", host, path, q),
        None => format!("{}{}", host, path),
    }
}

/// Returns a valid Feedly access token, refreshing if expiry is within 60s.
/// Refresh requires baked-in OAuth credentials.
async fn ensure_feedly_token(db: &Database) -> Result<Option<String>, String> {
    let (token, refresh_token, expires_at) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        (
            queries::get_setting(&conn, "feedly_token").ok().flatten(),
            queries::get_setting(&conn, "feedly_refresh_token").ok().flatten(),
            queries::get_setting(&conn, "feedly_token_expires_at")
                .ok()
                .flatten()
                .and_then(|s| s.parse::<i64>().ok()),
        )
    };

    let Some(token) = token else { return Ok(None) };

    let now = chrono::Utc::now().timestamp();
    let needs_refresh = expires_at.map(|e| e - now < 60).unwrap_or(false);
    if !needs_refresh {
        return Ok(Some(token));
    }

    let (Some(rt), Some((cid, csec))) = (refresh_token, feedly_oauth::baked_credentials()) else {
        return Ok(Some(token));
    };

    match feedly_oauth::refresh_access_token(&cid, &csec, &rt).await {
        Ok(new_token) => {
            let conn = db.conn.lock().map_err(|e| e.to_string())?;
            queries::set_setting(&conn, "feedly_token", &new_token.access_token)
                .map_err(|e| e.to_string())?;
            if let Some(ref nrt) = new_token.refresh_token {
                queries::set_setting(&conn, "feedly_refresh_token", nrt)
                    .map_err(|e| e.to_string())?;
            }
            if let Some(exp) = new_token.expires_in {
                let new_expires = chrono::Utc::now().timestamp() + exp;
                queries::set_setting(&conn, "feedly_token_expires_at", &new_expires.to_string())
                    .map_err(|e| e.to_string())?;
            }
            Ok(Some(new_token.access_token))
        }
        Err(e) => {
            log::warn!("Feedly token refresh failed: {}", e);
            Ok(Some(token))
        }
    }
}

#[tauri::command]
pub async fn add_feed(db: State<'_, Database>, url: String) -> Result<Feed, String> {
    // Dedup on the user-supplied URL first to avoid a wasted network fetch.
    let input_norm = normalize_feed_url(&url);
    {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let existing = queries::list_feeds(&conn).map_err(|e| e.to_string())?;
        if let Some(match_feed) = existing
            .iter()
            .find(|f| normalize_feed_url(&f.url) == input_norm)
        {
            return Err(format!("Already subscribed: {}", match_feed.title));
        }
    }

    let (feed, articles) =
        fetch_and_parse_feed(&url, None).await?;

    let conn = db.conn.lock().map_err(|e| e.to_string())?;

    // Re-check after fetch in case the resolved URL differs (feed auto-discovery).
    let existing = queries::list_feeds(&conn).map_err(|e| e.to_string())?;
    let fetched_norm = normalize_feed_url(&feed.url);
    if let Some(match_feed) = existing
        .iter()
        .find(|f| normalize_feed_url(&f.url) == fetched_norm)
    {
        return Err(format!("Already subscribed: {}", match_feed.title));
    }

    queries::insert_feed(&conn, &feed).map_err(|e| format!("Failed to save feed: {}", e))?;

    for article in &articles {
        queries::insert_article(&conn, article)
            .map_err(|e| format!("Failed to save article: {}", e))?;
    }

    queries::update_feed_fetched(&conn, &feed.id, feed.updated_at)
        .map_err(|e| e.to_string())?;

    Ok(feed)
}

#[tauri::command]
pub async fn list_feeds(db: State<'_, Database>) -> Result<Vec<FeedWithCount>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let feeds = queries::list_feeds(&conn).map_err(|e| e.to_string())?;
    let result: Vec<FeedWithCount> = feeds
        .into_iter()
        .map(|feed| {
            let unread_count = queries::get_unread_count(&conn, &feed.id).unwrap_or(0);
            FeedWithCount {
                feed,
                unread_count,
            }
        })
        .collect();
    Ok(result)
}

#[tauri::command]
pub async fn remove_feed(db: State<'_, Database>, feed_id: String) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::delete_feed(&conn, &feed_id).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn rename_feed(
    db: State<'_, Database>,
    feed_id: String,
    title: String,
) -> Result<(), String> {
    let trimmed = title.trim();
    if trimmed.is_empty() {
        return Err("Title cannot be empty".to_string());
    }
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::rename_feed(&conn, &feed_id, trimmed).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn count_starred_in_feed(
    db: State<'_, Database>,
    feed_id: String,
) -> Result<i64, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::count_starred_in_feed(&conn, &feed_id).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn refresh_feed(
    db: State<'_, Database>,
    feed_id: String,
) -> Result<i32, String> {
    let feed = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::get_feed_by_id(&conn, &feed_id)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "Feed not found".to_string())?
    };
    let feedly_token = ensure_feedly_token(&db).await?;

    let (articles, feedly_star_updates) = if let (Some(ref feedly_id), Some(ref token)) = (&feed.feedly_id, &feedly_token) {
        // Fetch from Feedly streams API
        let stream = feedly::fetch_stream_contents(
            token,
            feedly_id,
            feed.last_fetched_at,
            200,
        ).await?;
        let articles = feedly::feedly_entries_to_articles(&stream.items, &feed_id);
        let star_updates: Vec<(String, bool)> = articles
            .iter()
            .filter_map(|a| a.feedly_entry_id.as_ref().map(|id| (id.clone(), a.is_starred)))
            .collect();
        (articles, star_updates)
    } else {
        // Direct RSS fetch
        let (_feed, articles) = fetch_and_parse_feed(&feed.url, Some(&feed_id)).await?;
        (articles, Vec::new())
    };

    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let mut new_count = 0;
    for article in &articles {
        if queries::insert_article(&conn, article).map_err(|e| e.to_string())? {
            new_count += 1;
        }
    }
    // Keep local star state in sync with Feedly's saved state for already-imported
    // articles too (insert_article uses INSERT OR IGNORE so it doesn't update).
    if !feedly_star_updates.is_empty() {
        let _ = queries::sync_star_state_from_feedly(&conn, &feedly_star_updates);
    }

    let now = chrono::Utc::now().timestamp();
    queries::update_feed_fetched(&conn, &feed_id, now).map_err(|e| e.to_string())?;

    Ok(new_count)
}

#[tauri::command]
pub async fn refresh_all_feeds(db: State<'_, Database>) -> Result<i32, String> {
    use futures_util::stream::{self, StreamExt};

    let feeds = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::list_feeds(&conn).map_err(|e| e.to_string())?
    };
    let feedly_token = ensure_feedly_token(&db).await?;

    // Fan out fetches concurrently. CONCURRENCY caps to keep us off
    // host rate-limits and within the iOS file-descriptor budget.
    #[cfg(target_os = "ios")]
    const CONCURRENCY: usize = 4;
    #[cfg(not(target_os = "ios"))]
    const CONCURRENCY: usize = 16;
    let token_ref = &feedly_token;
    let results: Vec<(crate::db::models::Feed, Result<Vec<crate::db::models::Article>, String>)> =
        stream::iter(feeds.into_iter().map(|feed| async move {
            let res = if let (Some(ref feedly_id), Some(ref token)) = (&feed.feedly_id, token_ref) {
                feedly::fetch_stream_contents(token, feedly_id, feed.last_fetched_at, 200)
                    .await
                    .map(|stream| feedly::feedly_entries_to_articles(&stream.items, &feed.id))
            } else {
                fetch_and_parse_feed(&feed.url, Some(&feed.id))
                    .await
                    .map(|(_f, articles)| articles)
            };
            (feed, res)
        }))
        .buffer_unordered(CONCURRENCY)
        .collect()
        .await;

    let mut total_new = 0;
    let mut refreshed_count = 0usize;
    let mut failures: Vec<String> = Vec::new();
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let now = chrono::Utc::now().timestamp();
    for (feed, result) in results {
        match result {
            Ok(articles) => {
                refreshed_count += 1;
                for article in &articles {
                    if queries::insert_article(&conn, article).map_err(|e| e.to_string())? {
                        total_new += 1;
                    }
                }
                queries::update_feed_fetched(&conn, &feed.id, now).map_err(|e| e.to_string())?;
            }
            Err(e) => {
                log::warn!("Failed to refresh feed {}: {}", feed.title, e);
                failures.push(format!("{}: {}", feed.title, e));
            }
        }
    }

    if refreshed_count == 0 && !failures.is_empty() {
        let preview = failures
            .iter()
            .take(3)
            .cloned()
            .collect::<Vec<_>>()
            .join("; ");
        return Err(format!(
            "All feed refreshes failed{}{}",
            if preview.is_empty() { "" } else { ": " },
            preview
        ));
    }

    Ok(total_new)
}

#[tauri::command]
pub async fn get_total_unread(db: State<'_, Database>) -> Result<i64, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::get_total_unread_count(&conn).map_err(|e| e.to_string())
}

// ── Feedly integration ───────────────────────────────────────────────

#[tauri::command]
pub async fn import_feedly(
    db: State<'_, Database>,
    token: String,
) -> Result<feedly::FeedlyImportResult, String> {
    let subs = feedly::fetch_subscriptions(&token).await?;
    let feeds_and_urls = feedly::subscriptions_to_feeds(&subs);

    let existing_norm: std::collections::HashSet<String> = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let feeds = queries::list_feeds(&conn).map_err(|e| e.to_string())?;
        feeds.into_iter().map(|f| normalize_feed_url(&f.url)).collect()
    };

    let mut imported = 0i32;
    let mut skipped = 0i32;
    let mut errors = Vec::new();

    for (feed, feed_url) in &feeds_and_urls {
        if existing_norm.contains(&normalize_feed_url(feed_url)) {
            skipped += 1;
            continue;
        }

        // Try Feedly streams API first (preferred), fall back to direct RSS
        let articles_result = if let Some(ref feedly_id) = feed.feedly_id {
            feedly::fetch_stream_contents(&token, feedly_id, None, 200)
                .await
                .map(|stream| feedly::feedly_entries_to_articles(&stream.items, &feed.id))
        } else {
            Err("No feedly_id".to_string())
        };

        let articles = match articles_result {
            Ok(articles) => articles,
            Err(_) => {
                // Fall back to direct RSS fetch
                match fetch_and_parse_feed(feed_url, Some(&feed.id)).await {
                    Ok((_parsed_feed, articles)) => articles,
                    Err(e) => {
                        log::warn!("Failed to fetch {}: {}. Saving feed metadata only.", feed_url, e);
                        // Save feed entry without articles
                        let conn = db.conn.lock().map_err(|e| e.to_string())?;
                        if let Err(db_err) = queries::insert_feed(&conn, feed) {
                            errors.push(format!("{}: {}", feed.title, db_err));
                        } else {
                            imported += 1;
                        }
                        continue;
                    }
                }
            }
        };

        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        if let Err(e) = queries::insert_feed(&conn, feed) {
            errors.push(format!("{}: {}", feed.title, e));
            continue;
        }
        for article in &articles {
            let _ = queries::insert_article(&conn, article);
        }
        let now = chrono::Utc::now().timestamp();
        let _ = queries::update_feed_fetched(&conn, &feed.id, now);
        imported += 1;
    }

    // Save the Feedly token and user ID in settings for future syncs
    {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let _ = queries::set_setting(&conn, "feedly_token", &token);
    }
    // Store user ID for tag operations (star/save)
    if let Ok(profile) = feedly::verify_token(&token).await {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let _ = queries::set_setting(&conn, "feedly_user_id", &profile.id);
    }

    Ok(feedly::FeedlyImportResult { imported, skipped, errors })
}

#[tauri::command]
pub async fn feedly_preview(
    token: String,
) -> Result<Vec<feedly::FeedlySubscription>, String> {
    feedly::fetch_subscriptions(&token).await
}

#[tauri::command]
pub async fn feedly_preview_stored(
    db: State<'_, Database>,
) -> Result<Vec<feedly::FeedlySubscription>, String> {
    let token = ensure_feedly_token(&db)
        .await?
        .ok_or_else(|| "Not signed in to Feedly".to_string())?;
    feedly::fetch_subscriptions(&token).await
}

#[derive(Debug, Serialize)]
pub struct OpmlPreviewEntry {
    pub title: String,
    pub url: String,
    pub category: Option<String>,
    pub already_exists: bool,
}

fn parse_opml_entries(xml: &str) -> Result<Vec<(String, String, Option<String>)>, String> {
    let document = opml::OPML::from_str(xml).map_err(|e| format!("Invalid OPML: {}", e))?;
    let mut out = Vec::new();
    fn walk(outlines: &[opml::Outline], parent: Option<String>, out: &mut Vec<(String, String, Option<String>)>) {
        for o in outlines {
            if let Some(ref url) = o.xml_url {
                let title = if o.text.is_empty() {
                    o.title.clone().unwrap_or_else(|| url.clone())
                } else {
                    o.text.clone()
                };
                out.push((title, url.clone(), parent.clone()));
            }
            if !o.outlines.is_empty() {
                let cat = if o.xml_url.is_none() {
                    if o.text.is_empty() { o.title.clone() } else { Some(o.text.clone()) }
                } else {
                    parent.clone()
                };
                walk(&o.outlines, cat, out);
            }
        }
    }
    walk(&document.body.outlines, None, &mut out);
    Ok(out)
}

#[tauri::command]
pub async fn preview_opml(
    db: State<'_, Database>,
    xml: String,
) -> Result<Vec<OpmlPreviewEntry>, String> {
    let entries = parse_opml_entries(&xml)?;
    let existing_norm: std::collections::HashSet<String> = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::list_feeds(&conn)
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(|f| normalize_feed_url(&f.url))
            .collect()
    };
    Ok(entries
        .into_iter()
        .map(|(title, url, category)| {
            let already_exists = existing_norm.contains(&normalize_feed_url(&url));
            OpmlPreviewEntry { title, url, category, already_exists }
        })
        .collect())
}

#[tauri::command]
pub async fn import_opml(
    db: State<'_, Database>,
    xml: String,
) -> Result<feedly::FeedlyImportResult, String> {
    let entries = parse_opml_entries(&xml)?;

    let mut existing_norm: std::collections::HashSet<String> = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::list_feeds(&conn)
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(|f| normalize_feed_url(&f.url))
            .collect()
    };

    // Importing OPML is just registering feed records — title/url/category
    // come straight from the file. Articles will be populated by the next
    // refresh-all pass (auto-runs on startup + on focus when stale). No
    // reason to block the import on dozens of HTTP roundtrips.
    let mut imported = 0i32;
    let mut skipped = 0i32;
    let mut errors: Vec<String> = Vec::new();
    let now = chrono::Utc::now().timestamp();
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    for (title, url, category) in entries {
        let n = normalize_feed_url(&url);
        if !existing_norm.insert(n) {
            skipped += 1;
            continue;
        }
        let feed = crate::db::models::Feed {
            id: uuid::Uuid::new_v4().to_string(),
            title: if title.trim().is_empty() { url.clone() } else { title.clone() },
            url: url.clone(),
            site_url: None,
            description: None,
            icon_url: crate::feed::fetcher::favicon_url(&url),
            feedly_id: None,
            created_at: now,
            updated_at: now,
            last_fetched_at: None,
            folder_id: None,
            opml_category: category,
        };
        match queries::insert_feed(&conn, &feed) {
            Ok(()) => imported += 1,
            Err(db_err) => errors.push(format!("{}: {}", title, db_err)),
        }
    }

    Ok(feedly::FeedlyImportResult { imported, skipped, errors })
}

#[tauri::command]
pub async fn import_feedly_stored(
    db: State<'_, Database>,
) -> Result<feedly::FeedlyImportResult, String> {
    let token = ensure_feedly_token(&db)
        .await?
        .ok_or_else(|| "Not signed in to Feedly".to_string())?;
    import_feedly(db, token).await
}

// ── Feedly connection management ────────────────────────────────────

#[tauri::command]
pub async fn connect_feedly(
    db: State<'_, Database>,
    token: String,
) -> Result<feedly::FeedlyProfile, String> {
    let profile = feedly::verify_token(&token).await?;

    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::set_setting(&conn, "feedly_token", &token).map_err(|e| e.to_string())?;
    queries::set_setting(&conn, "feedly_user_id", &profile.id).map_err(|e| e.to_string())?;
    if let Some(ref email) = profile.email {
        let _ = queries::set_setting(&conn, "feedly_email", email);
    }
    if let Some(ref name) = profile.full_name {
        let _ = queries::set_setting(&conn, "feedly_full_name", name);
    }

    Ok(profile)
}

#[tauri::command]
pub async fn disconnect_feedly(
    db: State<'_, Database>,
) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    conn.execute(
        "DELETE FROM settings WHERE key IN ('feedly_token', 'feedly_refresh_token', 'feedly_token_expires_at', 'feedly_user_id', 'feedly_email', 'feedly_full_name')",
        [],
    ).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub async fn feedly_oauth_login(
    db: State<'_, Database>,
) -> Result<feedly::FeedlyProfile, String> {
    let (client_id, client_secret) = feedly_oauth::baked_credentials()
        .ok_or_else(|| "Feedly sign-in is not available in this build".to_string())?;
    let token = feedly_oauth::run_oauth_flow(&client_id, &client_secret).await?;
    let profile = feedly::verify_token(&token.access_token).await?;

    {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::set_setting(&conn, "feedly_token", &token.access_token)
            .map_err(|e| e.to_string())?;
        if let Some(ref rt) = token.refresh_token {
            queries::set_setting(&conn, "feedly_refresh_token", rt).map_err(|e| e.to_string())?;
        }
        if let Some(exp) = token.expires_in {
            let expires_at = chrono::Utc::now().timestamp() + exp;
            queries::set_setting(&conn, "feedly_token_expires_at", &expires_at.to_string())
                .map_err(|e| e.to_string())?;
        }
        queries::set_setting(&conn, "feedly_user_id", &profile.id).map_err(|e| e.to_string())?;
        if let Some(ref email) = profile.email {
            let _ = queries::set_setting(&conn, "feedly_email", email);
        }
        if let Some(ref name) = profile.full_name {
            let _ = queries::set_setting(&conn, "feedly_full_name", name);
        }
    }

    Ok(profile)
}

#[tauri::command]
pub fn feedly_oauth_available() -> bool {
    feedly_oauth::baked_credentials().is_some()
}

#[tauri::command]
pub async fn get_feedly_status(
    db: State<'_, Database>,
) -> Result<Option<feedly::FeedlyConnectionStatus>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let token = queries::get_setting(&conn, "feedly_token").map_err(|e| e.to_string())?;

    if token.is_none() {
        return Ok(None);
    }

    // We store email/name separately to avoid verifying token on every status check
    // Fall back to just showing "connected" if we don't have cached profile info
    Ok(Some(feedly::FeedlyConnectionStatus {
        connected: true,
        email: queries::get_setting(&conn, "feedly_email").ok().flatten(),
        full_name: queries::get_setting(&conn, "feedly_full_name").ok().flatten(),
    }))
}

// ── Folders (manual + smart) ────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct FolderWithCount {
    #[serde(flatten)]
    pub folder: Folder,
    pub feed_count: i64,
}

#[tauri::command]
pub async fn list_folders(db: State<'_, Database>) -> Result<Vec<FolderWithCount>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let folders = queries::list_folders(&conn).map_err(|e| e.to_string())?;
    let feeds = queries::list_feeds(&conn).map_err(|e| e.to_string())?;

    let out = folders
        .into_iter()
        .map(|folder| {
            let feed_count = if folder.is_smart {
                eval_smart_folder(&folder, &feeds).len() as i64
            } else {
                feeds.iter().filter(|f| f.folder_id.as_deref() == Some(&folder.id)).count() as i64
            };
            FolderWithCount { folder, feed_count }
        })
        .collect();
    Ok(out)
}

#[tauri::command]
pub async fn create_folder(
    db: State<'_, Database>,
    name: String,
) -> Result<Folder, String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("Folder name cannot be empty".to_string());
    }
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let folder = Folder {
        id: uuid::Uuid::new_v4().to_string(),
        name: trimmed.to_string(),
        sort_order: queries::next_folder_sort_order(&conn).map_err(|e| e.to_string())?,
        is_smart: false,
        rules_json: None,
        created_at: chrono::Utc::now().timestamp(),
    };
    queries::insert_folder(&conn, &folder).map_err(|e| e.to_string())?;
    Ok(folder)
}

#[tauri::command]
pub async fn create_smart_folder(
    db: State<'_, Database>,
    name: String,
    rules: SmartRules,
) -> Result<Folder, String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("Folder name cannot be empty".to_string());
    }
    validate_smart_rules(&rules)?;
    let rules_json = serde_json::to_string(&rules).map_err(|e| e.to_string())?;

    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let folder = Folder {
        id: uuid::Uuid::new_v4().to_string(),
        name: trimmed.to_string(),
        sort_order: queries::next_folder_sort_order(&conn).map_err(|e| e.to_string())?,
        is_smart: true,
        rules_json: Some(rules_json),
        created_at: chrono::Utc::now().timestamp(),
    };
    queries::insert_folder(&conn, &folder).map_err(|e| e.to_string())?;
    Ok(folder)
}

#[tauri::command]
pub async fn rename_folder(
    db: State<'_, Database>,
    folder_id: String,
    name: String,
) -> Result<(), String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("Folder name cannot be empty".to_string());
    }
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::rename_folder(&conn, &folder_id, trimmed).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn update_smart_folder_rules(
    db: State<'_, Database>,
    folder_id: String,
    rules: SmartRules,
) -> Result<(), String> {
    validate_smart_rules(&rules)?;
    let rules_json = serde_json::to_string(&rules).map_err(|e| e.to_string())?;
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::update_folder_rules(&conn, &folder_id, &rules_json).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn delete_folder(
    db: State<'_, Database>,
    folder_id: String,
) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::delete_folder(&conn, &folder_id).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn reorder_folders(
    db: State<'_, Database>,
    folder_ids: Vec<String>,
) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::reorder_folders(&conn, &folder_ids).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn assign_feed_to_folder(
    db: State<'_, Database>,
    feed_id: String,
    folder_id: Option<String>,
) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::assign_feed_to_folder(&conn, &feed_id, folder_id.as_deref())
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn preview_smart_folder(
    db: State<'_, Database>,
    rules: SmartRules,
) -> Result<Vec<String>, String> {
    validate_smart_rules(&rules)?;
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let feeds = queries::list_feeds(&conn).map_err(|e| e.to_string())?;
    let folder = Folder {
        id: String::new(),
        name: String::new(),
        sort_order: 0,
        is_smart: true,
        rules_json: serde_json::to_string(&rules).ok(),
        created_at: 0,
    };
    Ok(eval_smart_folder(&folder, &feeds).into_iter().map(|f| f.id.clone()).collect())
}

#[tauri::command]
pub async fn feeds_in_folder(
    db: State<'_, Database>,
    folder_id: String,
) -> Result<Vec<String>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let folders = queries::list_folders(&conn).map_err(|e| e.to_string())?;
    let folder = folders
        .into_iter()
        .find(|f| f.id == folder_id)
        .ok_or_else(|| "Folder not found".to_string())?;
    let feeds = queries::list_feeds(&conn).map_err(|e| e.to_string())?;

    let matching_ids: Vec<String> = if folder.is_smart {
        eval_smart_folder(&folder, &feeds).into_iter().map(|f| f.id.clone()).collect()
    } else {
        feeds
            .into_iter()
            .filter(|f| f.folder_id.as_deref() == Some(&folder.id))
            .map(|f| f.id)
            .collect()
    };
    Ok(matching_ids)
}

fn validate_smart_rules(rules: &SmartRules) -> Result<(), String> {
    if rules.rules.is_empty() {
        return Err("Smart folder needs at least one rule".to_string());
    }
    for r in &rules.rules {
        match r {
            SmartRule::RegexTitle { pattern } | SmartRule::RegexUrl { pattern } => {
                regex::Regex::new(pattern)
                    .map_err(|e| format!("Invalid regex '{}': {}", pattern, e))?;
            }
            SmartRule::OpmlCategory { value } => {
                if value.trim().is_empty() {
                    return Err("OPML category rule cannot have empty value".to_string());
                }
            }
        }
    }
    Ok(())
}

fn eval_smart_folder<'a>(folder: &Folder, feeds: &'a [Feed]) -> Vec<&'a Feed> {
    let Some(ref json) = folder.rules_json else { return Vec::new() };
    let Ok(rules) = serde_json::from_str::<SmartRules>(json) else {
        return Vec::new();
    };
    if rules.rules.is_empty() {
        return Vec::new();
    }

    let compiled: Vec<CompiledRule> = rules
        .rules
        .iter()
        .filter_map(|r| match r {
            SmartRule::RegexTitle { pattern } => regex::Regex::new(pattern)
                .ok()
                .map(|re| CompiledRule::Title(re)),
            SmartRule::RegexUrl { pattern } => regex::Regex::new(pattern)
                .ok()
                .map(|re| CompiledRule::Url(re)),
            SmartRule::OpmlCategory { value } => Some(CompiledRule::Category(value.to_lowercase())),
        })
        .collect();

    feeds
        .iter()
        .filter(|feed| match rules.mode {
            MatchMode::Any => compiled.iter().any(|r| r.matches(feed)),
            MatchMode::All => compiled.iter().all(|r| r.matches(feed)),
        })
        .collect()
}

enum CompiledRule {
    Title(regex::Regex),
    Url(regex::Regex),
    Category(String),
}

impl CompiledRule {
    fn matches(&self, feed: &Feed) -> bool {
        match self {
            CompiledRule::Title(re) => re.is_match(&feed.title),
            CompiledRule::Url(re) => re.is_match(&feed.url),
            CompiledRule::Category(value) => feed
                .opml_category
                .as_ref()
                .map(|c| c.to_lowercase() == *value)
                .unwrap_or(false),
        }
    }
}

// ── Duplicate detection / merging ──────────────────────────────────

#[derive(Debug, Serialize)]
pub struct DuplicateGroup {
    pub normalized_url: String,
    pub feeds: Vec<DuplicateFeedInfo>,
}

#[derive(Debug, Serialize)]
pub struct DuplicateFeedInfo {
    pub id: String,
    pub title: String,
    pub url: String,
    pub article_count: i64,
    pub last_fetched_at: Option<i64>,
}

/// Build dedup groups by trying URL first, falling back to (normalized title).
/// A feed with a unique normalized URL and an empty title has no group.
fn dedup_groups(feeds: Vec<Feed>) -> Vec<(String, Vec<Feed>)> {
    let mut by_url: std::collections::HashMap<String, Vec<Feed>> = std::collections::HashMap::new();
    for f in feeds {
        by_url.entry(normalize_feed_url(&f.url)).or_default().push(f);
    }

    // Pull out URL groups that already have >= 2, leave the singletons for a title pass.
    let (mut dupes, singletons): (Vec<(String, Vec<Feed>)>, Vec<(String, Vec<Feed>)>) = by_url
        .into_iter()
        .partition(|(_, v)| v.len() > 1);

    let mut by_title: std::collections::HashMap<String, Vec<Feed>> =
        std::collections::HashMap::new();
    for (_, mut group) in singletons {
        if let Some(f) = group.pop() {
            let key = f.title.trim().to_lowercase();
            if !key.is_empty() {
                by_title.entry(key).or_default().push(f);
            }
        }
    }
    for (k, v) in by_title {
        if v.len() > 1 {
            dupes.push((format!("title:{}", k), v));
        }
    }
    dupes
}

#[tauri::command]
pub async fn list_duplicate_feeds(db: State<'_, Database>) -> Result<Vec<DuplicateGroup>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let feeds = queries::list_feeds(&conn).map_err(|e| e.to_string())?;

    let mut groups: Vec<DuplicateGroup> = dedup_groups(feeds)
        .into_iter()
        .map(|(n, fs)| DuplicateGroup {
            normalized_url: n,
            feeds: fs
                .into_iter()
                .map(|f| DuplicateFeedInfo {
                    article_count: queries::count_articles_in_feed(&conn, &f.id).unwrap_or(0),
                    last_fetched_at: f.last_fetched_at,
                    id: f.id,
                    title: f.title,
                    url: f.url,
                })
                .collect(),
        })
        .collect();
    groups.sort_by(|a, b| a.normalized_url.cmp(&b.normalized_url));
    Ok(groups)
}

/// Auto-merge every duplicate group. For each group the feed with the most
/// articles wins; ties broken by most recent `last_fetched_at`.
#[tauri::command]
pub async fn merge_duplicate_feeds(db: State<'_, Database>) -> Result<i32, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let feeds = queries::list_feeds(&conn).map_err(|e| e.to_string())?;
    let groups = dedup_groups(feeds);

    let mut merged = 0i32;
    for (_, group) in groups {
        if group.len() < 2 {
            continue;
        }
        // Score: prefer feed with feedly_id set (can sync), then most articles, then recent fetch.
        let scored: Vec<(Feed, i32, i64, i64)> = group
            .into_iter()
            .map(|f| {
                let has_feedly = if f.feedly_id.is_some() { 1 } else { 0 };
                let count = queries::count_articles_in_feed(&conn, &f.id).unwrap_or(0);
                let last = f.last_fetched_at.unwrap_or(0);
                (f, has_feedly, count, last)
            })
            .collect();
        let keeper_idx = scored
            .iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| a.1.cmp(&b.1).then(a.2.cmp(&b.2)).then(a.3.cmp(&b.3)))
            .map(|(i, _)| i)
            .unwrap_or(0);
        let keeper_id = scored[keeper_idx].0.id.clone();
        for (i, (feed, _, _, _)) in scored.into_iter().enumerate() {
            if i == keeper_idx {
                continue;
            }
            if let Err(e) = queries::merge_feed(&conn, &feed.id, &keeper_id) {
                log::warn!("Failed to merge {} into {}: {}", feed.id, keeper_id, e);
                continue;
            }
            merged += 1;
        }
    }
    Ok(merged)
}

// ── AI-powered folder organization ─────────────────────────────────

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct FolderProposal {
    pub name: String,
    pub feed_ids: Vec<String>,
}

#[derive(Deserialize)]
struct LlmOrganizeResponse {
    folders: Vec<LlmFolderItem>,
}

#[derive(Deserialize)]
struct LlmFolderItem {
    name: String,
    #[serde(default, alias = "feed_ids", alias = "ids")]
    feeds: serde_json::Value,
}

/// Compact feed listing for the LLM prompt. Uses short numeric handles (0, 1, 2, ...)
/// instead of UUIDs to cut token count dramatically. Caller holds the uuid mapping.
fn feeds_listing_for_llm(feeds: &[Feed]) -> String {
    let mut out = String::new();
    for (i, f) in feeds.iter().enumerate() {
        let title = f.title.trim();
        let cat = f.opml_category.as_deref().unwrap_or("").trim();
        if cat.is_empty() {
            out.push_str(&format!("{i}\t{title}\n"));
        } else {
            out.push_str(&format!("{i}\t{title}\t[{cat}]\n"));
        }
    }
    out
}

/// Extract numeric feed handles from a JSON array that may contain ints or strings.
fn parse_handles(v: &serde_json::Value) -> Vec<usize> {
    match v.as_array() {
        Some(arr) => arr
            .iter()
            .filter_map(|x| match x {
                serde_json::Value::Number(n) => n.as_u64().map(|n| n as usize),
                serde_json::Value::String(s) => s.trim().parse::<usize>().ok(),
                _ => None,
            })
            .collect(),
        None => vec![],
    }
}

/// Cluster feeds into topic-based folders using the configured LLM.
/// Scope: "all" (default) clusters every feed. "unassigned" only looks at
/// feeds that aren't currently in a folder. Returns proposed folders —
/// does NOT modify the DB.
#[tauri::command]
pub async fn ai_auto_organize_feeds(
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
    scope: Option<String>,
) -> Result<Vec<FolderProposal>, String> {
    let (feeds, settings_json) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let all_feeds = queries::list_feeds(&conn).map_err(|e| e.to_string())?;
        let feeds = match scope.as_deref() {
            Some("unassigned") => all_feeds
                .into_iter()
                .filter(|f| f.folder_id.is_none())
                .collect(),
            _ => all_feeds,
        };
        let settings_json = queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;
        (feeds, settings_json)
    };

    if feeds.is_empty() {
        return Ok(vec![]);
    }

    let settings: AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();

    if settings.ai.provider == "none" {
        return Err("No AI provider configured. Go to Settings to set up an AI provider.".to_string());
    }

    let mut ai_settings = settings.ai.clone();
    ai_settings.oauth_access_token = crate::ai::claude_oauth::stored_access_token(&db);
    let provider = create_provider(&ai_settings, Some(model_state.inner().clone()))?;
    let model = ai_settings.model.clone().unwrap_or_else(|| default_model(&ai_settings.provider));

    let listing = feeds_listing_for_llm(&feeds);
    // Estimate max_tokens: each folder entry needs ~15 tokens + ~3 tokens per feed handle.
    // Target 4-8 folders, assume worst case all feeds referenced once.
    let max_tokens = (feeds.len() as i64 * 4 + 8 * 20).max(512);

    let system = "You group RSS feeds into 4-8 topical folders. Output JSON only. \
                  Each feed goes in exactly one folder. Short folder names (2-4 words). \
                  Refer to feeds by their numeric handle.";
    let user = format!(
        r#"Feeds (handle TAB title [TAB category]):
{listing}
Output JSON:
{{"folders":[{{"name":"Tech","feeds":[0,3,7]}}]}}"#
    );

    let req = ChatRequest {
        model,
        messages: vec![
            ChatMessage { role: "system".to_string(), content: system.to_string(), content_blocks: None },
            ChatMessage { role: "user".to_string(), content: user, content_blocks: None },
        ],
        temperature: Some(0.2),
        max_tokens: Some(max_tokens),
        json_mode: true,
        tools: None,
    };

    let response = provider.chat(req).await?;
    let content = response.content.trim();
    let json_str = extract_json_object(content).unwrap_or(content);
    let parsed: LlmOrganizeResponse = serde_json::from_str(json_str)
        .map_err(|e| format!("Failed to parse AI response: {}. Raw: {}", e, &content[..content.len().min(300)]))?;

    let mut seen = std::collections::HashSet::new();
    let proposals: Vec<FolderProposal> = parsed
        .folders
        .into_iter()
        .filter_map(|f| {
            let name = f.name.trim().to_string();
            if name.is_empty() { return None; }
            let feed_ids: Vec<String> = parse_handles(&f.feeds)
                .into_iter()
                .filter_map(|h| feeds.get(h).map(|feed| feed.id.clone()))
                .filter(|id| seen.insert(id.clone()))
                .collect();
            if feed_ids.is_empty() { return None; }
            Some(FolderProposal { name, feed_ids })
        })
        .collect();

    Ok(proposals)
}

/// Given a natural-language description, return feed IDs that match.
#[tauri::command]
pub async fn ai_match_feeds_for_topic(
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
    description: String,
) -> Result<Vec<String>, String> {
    let trimmed = description.trim();
    if trimmed.is_empty() {
        return Err("Description cannot be empty".to_string());
    }

    let (feeds, settings_json) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let feeds = queries::list_feeds(&conn).map_err(|e| e.to_string())?;
        let settings_json = queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;
        (feeds, settings_json)
    };

    if feeds.is_empty() {
        return Ok(vec![]);
    }

    let settings: AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();

    if settings.ai.provider == "none" {
        return Err("No AI provider configured. Go to Settings to set up an AI provider.".to_string());
    }

    let mut ai_settings = settings.ai.clone();
    ai_settings.oauth_access_token = crate::ai::claude_oauth::stored_access_token(&db);
    let provider = create_provider(&ai_settings, Some(model_state.inner().clone()))?;
    let model = ai_settings.model.clone().unwrap_or_else(|| default_model(&ai_settings.provider));

    let listing = feeds_listing_for_llm(&feeds);
    let max_tokens = (feeds.len() as i64 * 3 + 64).max(256);

    let system = "You pick RSS feeds that match a topic. Output JSON only. \
                  Be selective — only clearly-fitting feeds. Refer to feeds by their numeric handle.";
    let user = format!(
        r#"Topic: "{trimmed}"

Feeds (handle TAB title [TAB category]):
{listing}
Output JSON:
{{"feeds":[0,3,7]}}"#
    );

    let req = ChatRequest {
        model,
        messages: vec![
            ChatMessage { role: "system".to_string(), content: system.to_string(), content_blocks: None },
            ChatMessage { role: "user".to_string(), content: user, content_blocks: None },
        ],
        temperature: Some(0.1),
        max_tokens: Some(max_tokens),
        json_mode: true,
        tools: None,
    };

    let response = provider.chat(req).await?;
    let content = response.content.trim();
    let json_str = extract_json_object(content).unwrap_or(content);

    let val: serde_json::Value = serde_json::from_str(json_str)
        .map_err(|e| format!("Failed to parse AI response: {}. Raw: {}", e, &content[..content.len().min(300)]))?;
    let handles_val = val.get("feeds").or_else(|| val.get("feed_ids")).cloned().unwrap_or(serde_json::Value::Null);
    let ids: Vec<String> = parse_handles(&handles_val)
        .into_iter()
        .filter_map(|h| feeds.get(h).map(|f| f.id.clone()))
        .collect();
    Ok(ids)
}

/// Apply a set of folder proposals: creates regular folders and assigns feeds.
/// Feeds already in other folders get moved. If `replace_existing` is true,
/// all pre-existing folders are deleted first (feeds get reassigned).
#[tauri::command]
pub async fn apply_folder_organization(
    db: State<'_, Database>,
    proposals: Vec<FolderProposal>,
    replace_existing: Option<bool>,
) -> Result<Vec<Folder>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let now = chrono::Utc::now().timestamp();
    let mut created = Vec::new();

    if replace_existing.unwrap_or(false) {
        // ON DELETE SET NULL on feeds.folder_id lets us wipe folders safely.
        let old = queries::list_folders(&conn).map_err(|e| e.to_string())?;
        for f in old {
            let _ = queries::delete_folder(&conn, &f.id);
        }
    }

    let mut sort_order = queries::next_folder_sort_order(&conn).map_err(|e| e.to_string())?;

    for proposal in proposals {
        let name = proposal.name.trim();
        if name.is_empty() || proposal.feed_ids.is_empty() {
            continue;
        }
        let folder = Folder {
            id: uuid::Uuid::new_v4().to_string(),
            name: name.to_string(),
            sort_order,
            is_smart: false,
            rules_json: None,
            created_at: now,
        };
        queries::insert_folder(&conn, &folder).map_err(|e| e.to_string())?;
        for feed_id in &proposal.feed_ids {
            let _ = queries::assign_feed_to_folder(&conn, feed_id, Some(&folder.id));
        }
        created.push(folder);
        sort_order += 1;
    }

    Ok(created)
}
