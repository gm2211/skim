use crate::db::models::Feed;
use crate::db::queries;
use crate::db::Database;
use crate::feed::fetch_and_parse_feed;
use crate::feed::feedly;
use crate::feed::feedly_oauth;
use serde::Serialize;
use tauri::State;

#[derive(Debug, Serialize)]
pub struct FeedWithCount {
    #[serde(flatten)]
    pub feed: Feed,
    pub unread_count: i64,
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
    let (feed, articles) =
        fetch_and_parse_feed(&url, None).await?;

    let conn = db.conn.lock().map_err(|e| e.to_string())?;
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

    let articles = if let (Some(ref feedly_id), Some(ref token)) = (&feed.feedly_id, &feedly_token) {
        // Fetch from Feedly streams API
        let stream = feedly::fetch_stream_contents(
            token,
            feedly_id,
            feed.last_fetched_at,
            200,
        ).await?;
        feedly::feedly_entries_to_articles(&stream.items, &feed_id)
    } else {
        // Direct RSS fetch
        let (_feed, articles) = fetch_and_parse_feed(&feed.url, Some(&feed_id)).await?;
        articles
    };

    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let mut new_count = 0;
    for article in &articles {
        if queries::insert_article(&conn, article).map_err(|e| e.to_string())? {
            new_count += 1;
        }
    }

    let now = chrono::Utc::now().timestamp();
    queries::update_feed_fetched(&conn, &feed_id, now).map_err(|e| e.to_string())?;

    Ok(new_count)
}

#[tauri::command]
pub async fn refresh_all_feeds(db: State<'_, Database>) -> Result<i32, String> {
    let feeds = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::list_feeds(&conn).map_err(|e| e.to_string())?
    };
    let feedly_token = ensure_feedly_token(&db).await?;

    let mut total_new = 0;
    for feed in feeds {
        let result = if let (Some(ref feedly_id), Some(ref token)) = (&feed.feedly_id, &feedly_token) {
            feedly::fetch_stream_contents(token, feedly_id, feed.last_fetched_at, 200)
                .await
                .map(|stream| feedly::feedly_entries_to_articles(&stream.items, &feed.id))
        } else {
            fetch_and_parse_feed(&feed.url, Some(&feed.id))
                .await
                .map(|(_f, articles)| articles)
        };

        match result {
            Ok(articles) => {
                let conn = db.conn.lock().map_err(|e| e.to_string())?;
                for article in &articles {
                    if queries::insert_article(&conn, article).map_err(|e| e.to_string())? {
                        total_new += 1;
                    }
                }
                let now = chrono::Utc::now().timestamp();
                queries::update_feed_fetched(&conn, &feed.id, now).map_err(|e| e.to_string())?;
            }
            Err(e) => {
                log::warn!("Failed to refresh feed {}: {}", feed.title, e);
            }
        }
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

    let existing_urls: Vec<String> = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let feeds = queries::list_feeds(&conn).map_err(|e| e.to_string())?;
        feeds.into_iter().map(|f| f.url).collect()
    };

    let mut imported = 0i32;
    let mut skipped = 0i32;
    let mut errors = Vec::new();

    for (feed, feed_url) in &feeds_and_urls {
        if existing_urls.iter().any(|u| u == feed_url) {
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
    let existing_urls: Vec<String> = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::list_feeds(&conn)
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(|f| f.url)
            .collect()
    };
    Ok(entries
        .into_iter()
        .map(|(title, url, category)| {
            let already_exists = existing_urls.iter().any(|u| u == &url);
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

    let existing_urls: Vec<String> = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::list_feeds(&conn)
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(|f| f.url)
            .collect()
    };

    let mut imported = 0i32;
    let mut skipped = 0i32;
    let mut errors = Vec::new();
    let now = chrono::Utc::now().timestamp();

    for (title, url, _category) in entries {
        if existing_urls.iter().any(|u| u == &url) {
            skipped += 1;
            continue;
        }

        let feed_id = uuid::Uuid::new_v4().to_string();
        match fetch_and_parse_feed(&url, Some(&feed_id)).await {
            Ok((mut feed, articles)) => {
                if feed.title.is_empty() || feed.title == "Untitled Feed" {
                    feed.title = title;
                }
                let conn = db.conn.lock().map_err(|e| e.to_string())?;
                if let Err(e) = queries::insert_feed(&conn, &feed) {
                    errors.push(format!("{}: {}", feed.title, e));
                    continue;
                }
                for a in &articles {
                    let _ = queries::insert_article(&conn, a);
                }
                let _ = queries::update_feed_fetched(&conn, &feed.id, now);
                imported += 1;
            }
            Err(e) => {
                log::warn!("Failed to fetch {} ({}): {}", title, url, e);
                let feed = crate::db::models::Feed {
                    id: feed_id,
                    title: title.clone(),
                    url: url.clone(),
                    site_url: None,
                    description: None,
                    icon_url: crate::feed::fetcher::favicon_url(&url),
                    feedly_id: None,
                    created_at: now,
                    updated_at: now,
                    last_fetched_at: None,
                };
                let conn = db.conn.lock().map_err(|e| e.to_string())?;
                match queries::insert_feed(&conn, &feed) {
                    Ok(()) => imported += 1,
                    Err(db_err) => errors.push(format!("{}: {}", title, db_err)),
                }
            }
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
