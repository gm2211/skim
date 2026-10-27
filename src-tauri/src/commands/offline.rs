use crate::commands::articles::{fetch_article_content, reader_http_client, FullArticleContent};
use crate::db::{queries, Database};
use base64::Engine;
use regex::Regex;
use serde::Serialize;
use crate::AppHandle;
use tauri::{Emitter, Manager, State};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

/// Pictures saved with reader copies share this many bytes; the oldest go
/// first when a new one doesn't fit.
const OFFLINE_IMAGE_BUDGET_BYTES: i64 = 300 * 1024 * 1024;
const MAX_IMAGE_BYTES: usize = 3 * 1024 * 1024;
const MAX_IMAGES_PER_ARTICLE: usize = 12;
/// Reader copies kept beyond this many (starred ones aside) are dropped,
/// oldest first.
const READER_CACHE_KEEP: i64 = 2_000;

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
    pub image_bytes: i64,
}

#[tauri::command]
pub fn get_offline_cache_stats(db: State<'_, Database>) -> Result<OfflineCacheStats, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    Ok(OfflineCacheStats {
        extracted_articles: queries::count_reader_cache(&conn).map_err(|e| e.to_string())?,
        image_bytes: queries::offline_image_bytes(&conn).map_err(|e| e.to_string())?,
    })
}

fn img_tag() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?is)<img\b[^>]*>").unwrap())
}

fn source_tag() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?is)<source\b[^>]*>").unwrap())
}

/// The attributes that pick an image's address, which an inlined copy replaces.
fn image_source_attributes() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"(?is)\s(?:src|srcset|sizes|data-src|data-srcset|data-lazy-src|loading)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#).unwrap()
    })
}

fn attribute(tag: &str, name: &str) -> Option<String> {
    let re = Regex::new(&format!(r#"(?is)\s{name}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)).ok()?;
    let captures = re.captures(tag)?;
    let value = captures.get(1).or_else(|| captures.get(2)).or_else(|| captures.get(3))?.as_str();
    Some(value.replace("&amp;", "&").trim().to_string())
}

/// The address an `<img>` loads, absolute, when it is a web image.
fn image_url(tag: &str, base: Option<&url::Url>) -> Option<String> {
    let src = ["src", "data-src", "data-lazy-src"]
        .iter()
        .filter_map(|name| attribute(tag, name))
        .find(|src| !src.is_empty() && !src.starts_with("data:"))?;
    let resolved = match base {
        Some(base) => base.join(&src).ok()?,
        None => url::Url::parse(&src).ok()?,
    };
    matches!(resolved.scheme(), "http" | "https").then(|| resolved.to_string())
}

/// The web images a reader copy shows, in order, without repeats.
fn article_image_urls(html: &str, base: Option<&str>) -> Vec<String> {
    let base = base.and_then(|base| url::Url::parse(base).ok());
    let mut urls = Vec::new();
    for tag in img_tag().find_iter(html) {
        if let Some(url) = image_url(tag.as_str(), base.as_ref()) {
            if !urls.contains(&url) {
                urls.push(url);
            }
        }
        if urls.len() >= MAX_IMAGES_PER_ARTICLE {
            break;
        }
    }
    urls
}

async fn download_image(url: &str) -> Option<(String, Vec<u8>)> {
    let response = reader_http_client().ok()?.get(url).send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    let mime = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(|value| value.split(';').next().unwrap_or_default().trim().to_ascii_lowercase())
        .filter(|mime| mime.starts_with("image/"))?;
    if response.content_length().is_some_and(|length| length as usize > MAX_IMAGE_BYTES) {
        return None;
    }
    let bytes = response.bytes().await.ok()?;
    (!bytes.is_empty() && bytes.len() <= MAX_IMAGE_BYTES).then(|| (mime, bytes.to_vec()))
}

/// Saves the pictures in a reader copy so it still shows them offline.
/// Returns how many were newly saved.
pub(crate) async fn cache_article_images(db: &Database, html: &str, base: Option<&str>) -> usize {
    let mut saved = 0;
    for url in article_image_urls(html, base) {
        let known = db
            .conn
            .lock()
            .ok()
            .and_then(|conn| queries::has_offline_image(&conn, &url).ok())
            .unwrap_or(true);
        if known {
            continue;
        }
        if let Some((mime, data)) = download_image(&url).await {
            if let Some(conn) = db.conn.lock().ok() {
                if queries::put_offline_image(&conn, &url, &mime, &data).is_ok() {
                    saved += 1;
                }
            }
        }
    }
    if saved > 0 {
        if let Some(conn) = db.conn.lock().ok() {
            let _ = queries::prune_offline_images(&conn, OFFLINE_IMAGE_BUDGET_BYTES);
        }
    }
    saved
}

/// Swaps each picture Skim saved into the reader copy itself, so it shows
/// with no connection. Responsive variants go too: the browser would pick
/// one of those over the saved copy and fail offline.
fn inline_cached_images(conn: &rusqlite::Connection, html: &str, base: Option<&str>) -> String {
    let base = base.and_then(|base| url::Url::parse(base).ok());
    let mut inlined = false;
    let out = img_tag().replace_all(html, |captures: &regex::Captures| {
        let tag = &captures[0];
        let Some((mime, data)) = image_url(tag, base.as_ref())
            .and_then(|url| queries::get_offline_image(conn, &url).ok().flatten())
        else {
            return tag.to_string();
        };
        inlined = true;
        let stripped = image_source_attributes().replace_all(tag, "");
        let encoded = base64::engine::general_purpose::STANDARD.encode(data);
        format!("<img src=\"data:{mime};base64,{encoded}\"{}", &stripped[4..])
    });
    if inlined {
        source_tag().replace_all(&out, "").into_owned()
    } else {
        out.into_owned()
    }
}

fn spawn_image_caching(app: &AppHandle, html: String, base: String) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let db = app.state::<Database>();
        cache_article_images(db.inner(), &html, Some(&base)).await;
    });
}

#[tauri::command]
pub fn get_cached_reader_content(
    db: State<'_, Database>,
    article_id: String,
) -> Result<Option<FullArticleContent>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let base = queries::get_reader_cache_url(&conn, &article_id).map_err(|e| e.to_string())?;
    Ok(queries::get_reader_cache(&conn, &article_id)
        .map_err(|e| e.to_string())?
        .map(|(html, raw_html)| FullArticleContent {
            html: inline_cached_images(&conn, &html, base.as_deref()),
            raw_html,
        }))
}

#[tauri::command]
pub async fn get_or_fetch_reader_content(
    app: AppHandle,
    db: State<'_, Database>,
    article_id: String,
    url: String,
    force_refresh: Option<bool>,
) -> Result<FullArticleContent, String> {
    if !force_refresh.unwrap_or(false) {
        if let Some((html, raw_html)) = {
            let conn = db.conn.lock().map_err(|e| e.to_string())?;
            // A copy fetched from a different page (say a Reddit post before
            // Skim learned to read the story it links to) is not this one.
            let cached_url = queries::get_reader_cache_url(&conn, &article_id).map_err(|e| e.to_string())?;
            if cached_url.is_some_and(|cached| cached != url) {
                None
            } else {
                queries::get_reader_cache(&conn, &article_id)
                    .map_err(|e| e.to_string())?
                    .map(|(html, raw_html)| (inline_cached_images(&conn, &html, Some(&url)), raw_html))
            }
        } {
            return Ok(FullArticleContent { html, raw_html });
        }
    }
    let content = fetch_article_content(&url).await?;
    // The page itself downloaded fine even when readability found no body, so
    // hand the raw HTML back: the embedded web view can still render it and
    // the UI shows its own "couldn't extract" notice over the feed preview.
    // Failing here instead would blank out both panes at once.
    if content.html.trim().is_empty() {
        if content.raw_html.trim().is_empty() {
            return Err("Could not extract readable article content.".to_string());
        }
        // Don't cache an empty extraction: a later retry may do better.
        return Ok(content);
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
    drop(conn);
    // Save its pictures in the background, so opening it later works offline.
    spawn_image_caching(&app, content.html.clone(), url);
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
            let base = queries::get_reader_cache_url(&conn, &article_id).map_err(|e| e.to_string())?;
            queries::get_reader_cache(&conn, &article_id)
                .map_err(|e| e.to_string())?
                .map(|(html, _)| (html, base.or_else(|| url.clone())))
        };
        if let Some((html, base)) = cached {
            // Copies saved before Skim kept pictures get theirs now.
            cache_article_images(db.inner(), &html, base.as_deref()).await;
            progress.already_ready += 1;
        } else if rss_text
            .as_deref()
            .is_some_and(|text| text.trim().len() >= 1_000)
        {
            progress.already_ready += 1;
        } else if let Some(url) = url {
            match fetch_article_content(&url).await {
                Ok(content) if !content.html.trim().is_empty() => {
                    let saved = {
                        let conn = db.conn.lock().map_err(|e| e.to_string())?;
                        queries::put_reader_cache(
                            &conn,
                            &article_id,
                            Some(&url),
                            &content.html,
                            &content.raw_html,
                        )
                        .is_ok()
                    };
                    if saved {
                        cache_article_images(db.inner(), &content.html, Some(&url)).await;
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
    if let Some(conn) = db.conn.lock().ok() {
        let _ = queries::prune_reader_cache(&conn, READER_CACHE_KEEP.max(limit * 2));
    }
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
    fn article_images_resolve_against_the_page_and_skip_repeats() {
        let html = r#"<p><img src="/a.jpg"><img data-src="https://cdn.example/b.png" src="data:image/gif;base64,R0lGOD"><img src="/a.jpg"><img src="ftp://x/c.jpg"></p>"#;
        assert_eq!(
            article_image_urls(html, Some("https://news.example/story/1")),
            vec!["https://news.example/a.jpg".to_string(), "https://cdn.example/b.png".to_string()]
        );
    }

    #[test]
    fn saved_images_are_inlined_and_responsive_variants_dropped() {
        let conn = Connection::open_in_memory().unwrap();
        migrations::run_migrations(&conn).unwrap();
        queries::put_offline_image(&conn, "https://news.example/a.jpg", "image/jpeg", &[1, 2, 3]).unwrap();
        let html = r#"<picture><source srcset="/a-2x.webp 2x"><img class="hero" src="/a.jpg" srcset="/a-2x.jpg 2x" loading="lazy" alt="A"></picture><img src="/missing.jpg">"#;
        let out = inline_cached_images(&conn, html, Some("https://news.example/story"));
        assert_eq!(
            out,
            r#"<picture><img src="data:image/jpeg;base64,AQID" class="hero" alt="A"></picture><img src="/missing.jpg">"#
        );
    }

    #[test]
    fn image_budget_drops_the_oldest_first() {
        let conn = Connection::open_in_memory().unwrap();
        migrations::run_migrations(&conn).unwrap();
        for (url, at) in [("old", 1), ("mid", 2), ("new", 3)] {
            queries::put_offline_image(&conn, url, "image/png", &[0; 10]).unwrap();
            conn.execute("UPDATE offline_images SET cached_at = ?1 WHERE url = ?2", rusqlite::params![at, url]).unwrap();
        }
        queries::prune_offline_images(&conn, 20).unwrap();
        assert!(!queries::has_offline_image(&conn, "old").unwrap());
        assert!(queries::has_offline_image(&conn, "mid").unwrap());
        assert_eq!(queries::offline_image_bytes(&conn).unwrap(), 20);
    }

    #[test]
    fn reader_cache_pruning_keeps_newest_and_starred() {
        let conn = Connection::open_in_memory().unwrap();
        migrations::run_migrations(&conn).unwrap();
        conn.execute("INSERT INTO feeds (id,title,url,created_at,updated_at) VALUES ('f','Feed','https://f',1,1)", []).unwrap();
        conn.execute("INSERT INTO articles (id,feed_id,title,fetched_at,is_starred) VALUES ('a','f','A',1,1),('b','f','B',1,0),('c','f','C',1,0)", []).unwrap();
        for (id, at) in [("a", 1), ("b", 2), ("c", 3)] {
            queries::put_reader_cache(&conn, id, None, "x", "y").unwrap();
            conn.execute("UPDATE article_reader_cache SET cached_at = ?1 WHERE article_id = ?2", rusqlite::params![at, id]).unwrap();
        }
        queries::prune_reader_cache(&conn, 1).unwrap();
        assert!(queries::get_reader_cache(&conn, "a").unwrap().is_some(), "starred stays");
        assert!(queries::get_reader_cache(&conn, "b").unwrap().is_none());
        assert!(queries::get_reader_cache(&conn, "c").unwrap().is_some());
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
