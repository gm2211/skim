use crate::db::models::Feed;
use crate::db::queries;
use crate::db::Database;
use crate::feed::fetch_and_parse_feed;
use serde::Serialize;
use tauri::State;

#[derive(Debug, Serialize)]
pub struct FeedWithCount {
    #[serde(flatten)]
    pub feed: Feed,
    pub unread_count: i64,
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
    let feed_url = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let feeds = queries::list_feeds(&conn).map_err(|e| e.to_string())?;
        feeds
            .into_iter()
            .find(|f| f.id == feed_id)
            .map(|f| f.url)
            .ok_or_else(|| "Feed not found".to_string())?
    };

    let (_feed, articles) =
        fetch_and_parse_feed(&feed_url, Some(&feed_id)).await?;

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

    let mut total_new = 0;
    for feed in feeds {
        match fetch_and_parse_feed(&feed.url, Some(&feed.id)).await {
            Ok((_updated_feed, articles)) => {
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
