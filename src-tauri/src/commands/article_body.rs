//! Resolving the text of an article for the AI features.
//!
//! The reader pane and the AI features used to disagree about what "the
//! article" is. Summary-only feeds (Stratechery, Hacker News, most
//! newsletters) ship a one-line blurb in the RSS body; the reader replaces it
//! with a full extraction and caches that under `article_reader_cache`. Chat
//! read the blurb, so asking a question about a paragraph on screen got an
//! answer drawn from two sentences that never mentioned it.
//!
//! Everything that needs an article's prose resolves it here, in the same
//! order the reader does: the extraction the reader already cached, then the
//! feed's own body, then a live fetch of the linked page.

use crate::db::models::Article;
use crate::db::{queries, Database};
use futures_util::{stream, StreamExt};
use std::{future::Future, time::Duration};

/// Below this, a feed body is a teaser rather than an article, and it is worth
/// going to the network for the real thing.
const THIN_BODY_CHARS: usize = 400;

/// Width html2text wraps to. Wide enough that paragraphs are not shredded into
/// short lines before the model sees them.
const TEXT_WIDTH: usize = 10000;

/// The article body as the feed delivered it, preferring whichever of the two
/// representations carries more text.
pub fn feed_body_text(article: &Article) -> String {
    let content_text = article.content_text.as_deref().unwrap_or("");
    let html_as_text = article
        .content_html
        .as_deref()
        .map(|html| html2text::from_read(html.as_bytes(), TEXT_WIDTH))
        .unwrap_or_default();
    if html_as_text.len() > content_text.len() {
        html_as_text
    } else {
        content_text.to_string()
    }
}

/// The reader's own extraction, if it has been made for this article. Takes and
/// releases the database lock, so it is safe to call before an await.
fn cached_reader_text(db: &Database, article_id: &str) -> Option<String> {
    let conn = db.conn.lock().ok()?;
    let (html, _raw_html) = queries::get_reader_cache(&conn, article_id).ok()??;
    drop(conn);
    let text = html2text::from_read(html.as_bytes(), TEXT_WIDTH);
    if text.trim().is_empty() {
        None
    } else {
        Some(text)
    }
}

fn visible_len(text: &str) -> usize {
    text.trim().chars().count()
}

/// The fullest text available for `article`, without going to the network.
/// Use this on paths that must stay offline-safe.
pub fn local_article_text(db: &Database, article: &Article) -> String {
    let feed_text = feed_body_text(article);
    match cached_reader_text(db, &article.id) {
        Some(cached) if visible_len(&cached) > visible_len(&feed_text) => cached,
        _ => feed_text,
    }
}

/// The fullest text available for `article`, fetching the linked page when
/// neither the reader cache nor the feed has enough to work with.
pub async fn resolve_article_text(db: &Database, article: &Article) -> String {
    resolve_article_with(db, article, |url| async move {
        super::articles::fetch_article_content(&url).await
    })
    .await
}

async fn resolve_article_with<F, Fut>(db: &Database, article: &Article, fetch: F) -> String
where
    F: FnOnce(String) -> Fut,
    Fut: Future<Output = Result<super::articles::FullArticleContent, String>>,
{
    let local = local_article_text(db, article);
    // A successful extraction can legitimately be short. Do not repeatedly
    // download it just because it remains below the feed teaser threshold.
    if cached_reader_text(db, &article.id).is_some() {
        return local;
    }
    resolve_local_text(local, article.url.clone(), |url| async move {
        tokio::time::timeout(Duration::from_secs(20), async {
            let content = fetch(url.clone()).await?;
            cache_reader_evidence(db, &article.id, &url, content)
        })
        .await
        .map_err(|_| "Article fetch timed out".to_string())?
    })
    .await
}

fn cache_reader_evidence(
    db: &Database,
    article_id: &str,
    url: &str,
    content: super::articles::FullArticleContent,
) -> Result<String, String> {
    // Only the reader extractor's HTML is evidence. raw_html may be a page
    // shell or navigation chrome when extraction failed; never promote it.
    let text = html2text::from_read(content.html.as_bytes(), TEXT_WIDTH);
    if text.trim().is_empty() {
        return Err("No article text extracted".into());
    }
    if let Ok(conn) = db.conn.lock() {
        let existing = queries::get_reader_cache(&conn, article_id).ok().flatten();
        let existing_len = existing
            .as_ref()
            .map(|(html, _)| visible_len(&html2text::from_read(html.as_bytes(), TEXT_WIDTH)))
            .unwrap_or(0);
        if visible_len(&text) > existing_len {
            // Cache failure must not discard successfully fetched evidence.
            if let Err(error) = queries::put_reader_cache(
                &conn,
                article_id,
                Some(url),
                &content.html,
                &content.raw_html,
            ) {
                log::warn!("Could not cache AI reader evidence: {}", error);
            }
        }
    }
    Ok(text)
}

async fn resolve_local_text<F, Fut>(local: String, url: Option<String>, fetch: F) -> String
where
    F: FnOnce(String) -> Fut,
    Fut: Future<Output = Result<String, String>>,
{
    if visible_len(&local) >= THIN_BODY_CHARS {
        return local;
    }
    let Some(url) = url else {
        return local;
    };
    match fetch(url).await {
        Ok(fetched) if visible_len(&fetched) > visible_len(&local) => fetched,
        _ => local,
    }
}

/// Resolve only the retrieved sources, preserving their input order/citation IDs.
/// Four concurrent requests, two seconds per source, five seconds total; any
/// unavailable or unfinished source keeps its fullest cached/feed body.
pub async fn resolve_selected_article_texts(db: &Database, articles: &[Article]) -> Vec<String> {
    resolve_selected_with(
        db,
        articles,
        4,
        Duration::from_secs(2),
        Duration::from_secs(5),
        |article_id, url| async move {
            let content = super::articles::fetch_article_content(&url).await?;
            cache_reader_evidence(db, &article_id, &url, content)
        },
    )
    .await
}

async fn resolve_selected_with<F, Fut>(
    db: &Database,
    articles: &[Article],
    concurrency: usize,
    source_timeout: Duration,
    total_timeout: Duration,
    fetch: F,
) -> Vec<String>
where
    F: Fn(String, String) -> Fut,
    Fut: Future<Output = Result<String, String>>,
{
    let mut texts: Vec<String> = articles
        .iter()
        .map(|article| local_article_text(db, article))
        .collect();
    let deadline = tokio::time::Instant::now() + total_timeout;
    let fetch = &fetch;
    let work: Vec<_> = articles
        .iter()
        .zip(&texts)
        .enumerate()
        .filter(|(_, (article, local))| {
            article.url.is_some()
                && visible_len(local) < THIN_BODY_CHARS
                && cached_reader_text(db, &article.id).is_none()
        })
        .map(|(index, (article, local))| {
            (
                index,
                article.id.clone(),
                article.url.clone(),
                local.clone(),
            )
        })
        .collect();
    let mut pending = stream::iter(work)
        .map(|(index, article_id, url, local)| async move {
            if tokio::time::Instant::now() >= deadline {
                return (index, local);
            }
            let source_deadline = (tokio::time::Instant::now() + source_timeout).min(deadline);
            let resolved = tokio::time::timeout_at(
                source_deadline,
                resolve_local_text(local.clone(), url, |url| fetch(article_id, url)),
            )
            .await
            .unwrap_or(local);
            (index, resolved)
        })
        .buffer_unordered(concurrency.max(1));
    while let Ok(Some((index, text))) = tokio::time::timeout_at(deadline, pending.next()).await {
        texts[index] = text;
    }
    texts
}

#[cfg(test)]
mod tests {
    use super::*;

    fn article(content_text: Option<&str>, content_html: Option<&str>) -> Article {
        Article {
            id: "article".into(),
            feed_id: "feed".into(),
            title: "Title".into(),
            url: None,
            author: None,
            content_html: content_html.map(str::to_string),
            content_text: content_text.map(str::to_string),
            published_at: None,
            fetched_at: 0,
            is_read: false,
            is_starred: false,
            feedly_entry_id: None,
            comments_url: None,
        }
    }

    /// A database holding one feed and one article, so the reader cache's
    /// foreign key has something to point at.
    fn database() -> Database {
        let dir = std::env::temp_dir().join(format!("skim-body-{}", uuid::Uuid::new_v4()));
        let db = Database::new(dir).unwrap();
        {
            let conn = db.conn.lock().unwrap();
            conn.execute_batch(
                "INSERT INTO feeds (id, title, url, created_at, updated_at)
                   VALUES ('feed', 'Feed', 'https://feed.test', 0, 0);
                 INSERT INTO articles (id, feed_id, title, fetched_at)
                   VALUES ('article', 'feed', 'Title', 0);",
            )
            .unwrap();
        }
        db
    }

    #[tokio::test]
    async fn selected_sources_use_full_text_without_reordering_slow_or_failed_sources() {
        let db = database();
        let mut sources = Vec::new();
        for name in ["slow", "battery", "failed", "other"] {
            let mut source = article(Some(name), None);
            source.id = name.into();
            source.url = Some(name.into());
            sources.push(source);
        }
        let started = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let active = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let maximum = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        struct Active(std::sync::Arc<std::sync::atomic::AtomicUsize>);
        impl Drop for Active {
            fn drop(&mut self) {
                self.0.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            }
        }
        let result = resolve_selected_with(
            &db,
            &sources,
            2,
            Duration::from_millis(40),
            Duration::from_millis(100),
            |_article_id, url| {
                let started = started.clone();
                let active = active.clone();
                let maximum = maximum.clone();
                async move {
                    use std::sync::atomic::Ordering::SeqCst;
                    started.fetch_add(1, SeqCst);
                    maximum.fetch_max(active.fetch_add(1, SeqCst) + 1, SeqCst);
                    let _guard = Active(active);
                    match url.as_str() {
                        "slow" => std::future::pending().await,
                        "failed" => Err("offline".into()),
                        "battery" => Ok("The laptop lasted nine hours in the battery test.".into()),
                        _ => Ok("Other complete article details.".into()),
                    }
                }
            },
        )
        .await;
        assert_eq!(
            result,
            vec![
                "slow",
                "The laptop lasted nine hours in the battery test.",
                "failed",
                "Other complete article details."
            ]
        );
        assert_eq!(started.load(std::sync::atomic::Ordering::SeqCst), 4);
        assert!(maximum.load(std::sync::atomic::Ordering::SeqCst) <= 2);
        assert_eq!(active.load(std::sync::atomic::Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn selected_sources_bound_total_latency_and_cancel_unfinished_work() {
        let db = database();
        let mut source = article(Some("offline teaser"), None);
        source.url = Some("slow".into());
        let sources = vec![source; 15];
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let start = std::time::Instant::now();
        let result = resolve_selected_with(
            &db,
            &sources,
            4,
            Duration::from_secs(1),
            Duration::from_millis(20),
            |_, _| async {
                calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                std::future::pending().await
            },
        )
        .await;
        assert_eq!(result, vec!["offline teaser"; 15]);
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 4);
        assert!(start.elapsed() < Duration::from_millis(500));
    }

    #[tokio::test]
    async fn selected_cached_or_complete_feed_text_needs_no_network() {
        let db = database();
        let cached = format!(
            "<p>The battery lasted nine hours. {}</p>",
            "Useful cached text. ".repeat(30)
        );
        queries::put_reader_cache(&db.conn.lock().unwrap(), "article", None, &cached, &cached)
            .unwrap();
        let mut source = article(Some("teaser"), None);
        source.url = Some("cached".into());
        let mut feed = article(Some(&"Full feed body. ".repeat(50)), None);
        feed.id = "full-feed".into();
        feed.url = Some("full".into());
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let result = resolve_selected_with(
            &db,
            &[source, feed.clone()],
            4,
            Duration::from_secs(1),
            Duration::from_secs(1),
            |_, _| async {
                calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Err("network should not be needed".into())
            },
        )
        .await;
        assert!(result[0].contains("nine hours"));
        assert_eq!(result[1], feed.content_text.unwrap());
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn fetched_reader_html_is_retained_for_repeat_and_offline_requests() {
        let db = database();
        let mut source = article(Some("teaser"), None);
        source.url = Some("https://example.test/review".into());
        let html = "<article><p>The battery lasted nine hours.</p></article>";
        let raw = "<html><nav>Subscribe</nav><article><p>The battery lasted nine hours.</p></article></html>";
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let first = resolve_article_with(&db, &source, |_| async {
            calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(super::super::articles::FullArticleContent {
                html: html.into(),
                raw_html: raw.into(),
            })
        })
        .await;
        assert!(first.contains("nine hours"));
        assert!(!first.contains("Subscribe"));
        assert_eq!(
            queries::get_reader_cache(&db.conn.lock().unwrap(), &source.id)
                .unwrap()
                .unwrap(),
            (html.into(), raw.into())
        );
        for _ in 0..2 {
            let offline = resolve_article_with(&db, &source, |_| async {
                calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Err("offline".into())
            })
            .await;
            assert_eq!(offline, first);
        }
        let selected = resolve_selected_with(
            &db,
            &[source],
            4,
            Duration::from_secs(2),
            Duration::from_secs(5),
            |_, _| async {
                calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Err("offline".into())
            },
        )
        .await;
        assert_eq!(selected, vec![first]);
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn failed_extraction_does_not_cache_page_chrome_and_keeps_feed_fallback() {
        let db = database();
        let mut source = article(Some("feed evidence"), None);
        source.url = Some("https://example.test/review".into());
        let result = resolve_article_with(&db, &source, |_| async {
            Ok(super::super::articles::FullArticleContent {
                html: String::new(),
                raw_html: "<nav>Subscribe and sign in</nav>".into(),
            })
        })
        .await;
        assert_eq!(result, "feed evidence");
        assert!(
            queries::get_reader_cache(&db.conn.lock().unwrap(), &source.id)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn feed_body_prefers_the_longer_representation() {
        assert_eq!(feed_body_text(&article(Some("short"), None)), "short");
        let both = feed_body_text(&article(Some("short"), Some("<p>a much longer body</p>")));
        assert!(both.contains("much longer body"));
    }

    #[test]
    fn reader_extraction_wins_over_a_feed_blurb() {
        let db = database();
        let article = article(Some("The probe matters less than what it opens up."), None);
        let body = "<p>The interesting part is the IAM model your org chart is encoded in.</p>";
        {
            let conn = db.conn.lock().unwrap();
            queries::put_reader_cache(&conn, &article.id, None, body, body).unwrap();
        }
        assert!(local_article_text(&db, &article).contains("IAM model"));
    }

    #[test]
    fn a_full_feed_body_is_kept_when_the_reader_cache_is_thinner() {
        let db = database();
        let full = "word ".repeat(200);
        let article = article(Some(&full), None);
        {
            let conn = db.conn.lock().unwrap();
            queries::put_reader_cache(&conn, &article.id, None, "<p>tiny</p>", "<p>tiny</p>")
                .unwrap();
        }
        assert_eq!(local_article_text(&db, &article).trim(), full.trim());
    }

    #[test]
    fn an_article_with_nothing_cached_falls_back_to_the_feed() {
        let db = database();
        assert_eq!(
            local_article_text(&db, &article(Some("blurb"), None)),
            "blurb"
        );
    }
}
