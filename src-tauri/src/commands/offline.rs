use crate::commands::articles::{fetch_article_content, FullArticleContent};
use crate::db::{queries, Database};
use serde::Serialize;
use crate::AppHandle;
use tauri::{Emitter, State};
use std::sync::atomic::{AtomicBool, Ordering};

pub const OFFLINE_PRELOAD_PROGRESS_EVENT: &str = "skim-reader://offline-preload-progress";
static PRELOAD_RUNNING: AtomicBool = AtomicBool::new(false);

struct PreloadGuard;
impl Drop for PreloadGuard {
    fn drop(&mut self) { PRELOAD_RUNNING.store(false, Ordering::Release); }
}

#[derive(Clone, Debug, Serialize)]
pub struct OfflinePreloadProgress {
    pub completed: usize,
    pub total: usize,
    pub cached: usize,
    pub already_ready: usize,
    pub failed: usize,
    pub current_title: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct OfflineCacheStats {
    pub extracted_articles: i64,
}

#[tauri::command]
pub fn get_offline_cache_stats(db: State<'_, Database>) -> Result<OfflineCacheStats, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    Ok(OfflineCacheStats {
        extracted_articles: queries::count_reader_cache(&conn).map_err(|e| e.to_string())?,
    })
}

#[tauri::command]
pub fn get_cached_reader_content(
    db: State<'_, Database>,
    article_id: String,
) -> Result<Option<FullArticleContent>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    Ok(queries::get_reader_cache(&conn, &article_id)
        .map_err(|e| e.to_string())?
        .map(|(html, raw_html)| FullArticleContent { html, raw_html }))
}

#[tauri::command]
pub async fn get_or_fetch_reader_content(
    db: State<'_, Database>,
    article_id: String,
    url: String,
    force_refresh: Option<bool>,
) -> Result<FullArticleContent, String> {
    if !force_refresh.unwrap_or(false) {
        if let Some((html, raw_html)) = {
            let conn = db.conn.lock().map_err(|e| e.to_string())?;
            queries::get_reader_cache(&conn, &article_id).map_err(|e| e.to_string())?
        } {
            return Ok(FullArticleContent { html, raw_html });
        }
    }
    let content = fetch_article_content(&url).await?;
    if content.html.trim().is_empty() {
        return Err("Could not extract readable article content.".to_string());
    }
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::put_reader_cache(
        &conn,
        &article_id,
        Some(&url),
        &content.html,
        &content.raw_html,
    )
    .map_err(|e| e.to_string())?;
    Ok(content)
}

#[tauri::command]
pub async fn preload_articles_for_offline(
    app: AppHandle,
    db: State<'_, Database>,
    limit: i64,
) -> Result<OfflinePreloadProgress, String> {
    if PRELOAD_RUNNING.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_err() {
        return Err("Offline preload is already running.".to_string());
    }
    let _guard = PreloadGuard;
    let limit = limit.clamp(1, 2_000);
    let candidates = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::offline_preload_candidates(&conn, limit).map_err(|e| e.to_string())?
    };
    let mut progress = OfflinePreloadProgress {
        completed: 0,
        total: candidates.len(),
        cached: 0,
        already_ready: 0,
        failed: 0,
        current_title: candidates.first().map(|c| c.1.clone()),
    };
    let _ = app.emit(OFFLINE_PRELOAD_PROGRESS_EVENT, &progress);
    for (article_id, title, url, rss_text) in candidates {
        progress.current_title = Some(title);
        let cached = {
            let conn = db.conn.lock().map_err(|e| e.to_string())?;
            queries::get_reader_cache(&conn, &article_id)
                .map_err(|e| e.to_string())?
                .is_some()
        };
        if rss_text
            .as_deref()
            .is_some_and(|text| text.trim().len() >= 1_000)
            || cached
        {
            progress.already_ready += 1;
        } else if let Some(url) = url {
            match fetch_article_content(&url).await {
                Ok(content) if !content.html.trim().is_empty() => {
                    let conn = db.conn.lock().map_err(|e| e.to_string())?;
                    if queries::put_reader_cache(
                        &conn,
                        &article_id,
                        Some(&url),
                        &content.html,
                        &content.raw_html,
                    )
                    .is_ok()
                    {
                        progress.cached += 1;
                    } else {
                        progress.failed += 1;
                    }
                }
                _ => progress.failed += 1,
            }
        } else {
            progress.failed += 1;
        }
        progress.completed += 1;
        let _ = app.emit(OFFLINE_PRELOAD_PROGRESS_EVENT, &progress);
    }
    progress.current_title = None;
    Ok(progress)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::migrations;
    use rusqlite::Connection;

    #[test]
    fn reader_cache_round_trips_and_updates_without_growing() {
        let conn = Connection::open_in_memory().unwrap();
        migrations::run_migrations(&conn).unwrap();
        conn.execute("INSERT INTO feeds (id,title,url,created_at,updated_at) VALUES ('f','Feed','https://f',1,1)", []).unwrap();
        conn.execute(
            "INSERT INTO articles (id,feed_id,title,fetched_at) VALUES ('a','f','Article',1)",
            [],
        )
        .unwrap();
        queries::put_reader_cache(&conn, "a", Some("https://a"), "first", "raw").unwrap();
        queries::put_reader_cache(&conn, "a", Some("https://a"), "updated", "raw2").unwrap();
        assert_eq!(
            queries::get_reader_cache(&conn, "a").unwrap(),
            Some(("updated".into(), "raw2".into()))
        );
        assert_eq!(queries::count_reader_cache(&conn).unwrap(), 1);
    }

    #[test]
    fn preload_candidates_are_newest_first_and_respect_limit() {
        let conn = Connection::open_in_memory().unwrap();
        migrations::run_migrations(&conn).unwrap();
        conn.execute("INSERT INTO feeds (id,title,url,created_at,updated_at) VALUES ('f','Feed','https://f',1,1)", []).unwrap();
        conn.execute("INSERT INTO articles (id,feed_id,title,fetched_at) VALUES ('old','f','Old',1),('new','f','New',3),('mid','f','Mid',2)", []).unwrap();
        let candidates = queries::offline_preload_candidates(&conn, 2).unwrap();
        assert_eq!(candidates.iter().map(|row| row.0.as_str()).collect::<Vec<_>>(), vec!["new", "mid"]);
    }
}
