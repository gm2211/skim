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
    let local = local_article_text(db, article);
    if visible_len(&local) >= THIN_BODY_CHARS {
        return local;
    }
    let Some(url) = article.url.as_deref() else {
        return local;
    };
    match super::ai::fetch_article_text(url).await {
        Ok(fetched) if visible_len(&fetched) > visible_len(&local) => fetched,
        _ => local,
    }
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
        assert_eq!(local_article_text(&db, &article(Some("blurb"), None)), "blurb");
    }
}
