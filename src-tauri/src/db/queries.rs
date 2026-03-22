use rusqlite::{params, Connection};

use super::models::*;

pub fn insert_feed(conn: &Connection, feed: &Feed) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT OR REPLACE INTO feeds (id, title, url, site_url, description, icon_url, feedly_id, created_at, updated_at, last_fetched_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            feed.id,
            feed.title,
            feed.url,
            feed.site_url,
            feed.description,
            feed.icon_url,
            feed.feedly_id,
            feed.created_at,
            feed.updated_at,
            feed.last_fetched_at,
        ],
    )?;
    Ok(())
}

pub fn list_feeds(conn: &Connection) -> Result<Vec<Feed>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT id, title, url, site_url, description, icon_url, feedly_id, created_at, updated_at, last_fetched_at
         FROM feeds ORDER BY title COLLATE NOCASE",
    )?;
    let feeds = stmt
        .query_map([], |row| {
            Ok(Feed {
                id: row.get(0)?,
                title: row.get(1)?,
                url: row.get(2)?,
                site_url: row.get(3)?,
                description: row.get(4)?,
                icon_url: row.get(5)?,
                feedly_id: row.get(6)?,
                created_at: row.get(7)?,
                updated_at: row.get(8)?,
                last_fetched_at: row.get(9)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(feeds)
}

pub fn delete_feed(conn: &Connection, feed_id: &str) -> Result<(), rusqlite::Error> {
    conn.execute("DELETE FROM feeds WHERE id = ?1", params![feed_id])?;
    Ok(())
}

pub fn insert_article(conn: &Connection, article: &Article) -> Result<bool, rusqlite::Error> {
    let result = conn.execute(
        "INSERT OR IGNORE INTO articles (id, feed_id, title, url, author, content_html, content_text, published_at, fetched_at, is_read, is_starred)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        params![
            article.id,
            article.feed_id,
            article.title,
            article.url,
            article.author,
            article.content_html,
            article.content_text,
            article.published_at,
            article.fetched_at,
            article.is_read as i32,
            article.is_starred as i32,
        ],
    )?;
    Ok(result > 0)
}

pub fn get_articles(
    conn: &Connection,
    filter: &ArticleFilter,
) -> Result<Vec<ArticleWithFeed>, rusqlite::Error> {
    let mut sql = String::from(
        "SELECT a.id, a.feed_id, a.title, a.url, a.author, a.content_html, a.content_text,
                a.published_at, a.fetched_at, a.is_read, a.is_starred,
                f.title as feed_title, f.icon_url as feed_icon_url
         FROM articles a
         JOIN feeds f ON a.feed_id = f.id",
    );

    let mut conditions = Vec::new();
    let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    if let Some(ref feed_id) = filter.feed_id {
        conditions.push(format!("a.feed_id = ?{}", param_values.len() + 1));
        param_values.push(Box::new(feed_id.clone()));
    }

    if let Some(ref theme_id) = filter.theme_id {
        sql.push_str(" JOIN theme_articles ta ON a.id = ta.article_id");
        conditions.push(format!("ta.theme_id = ?{}", param_values.len() + 1));
        param_values.push(Box::new(theme_id.clone()));
    }

    if let Some(is_read) = filter.is_read {
        conditions.push(format!("a.is_read = ?{}", param_values.len() + 1));
        param_values.push(Box::new(is_read as i32));
    }

    if let Some(is_starred) = filter.is_starred {
        conditions.push(format!("a.is_starred = ?{}", param_values.len() + 1));
        param_values.push(Box::new(is_starred as i32));
    }

    if !conditions.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&conditions.join(" AND "));
    }

    sql.push_str(" ORDER BY COALESCE(a.published_at, a.fetched_at) DESC");

    if let Some(limit) = filter.limit {
        sql.push_str(&format!(" LIMIT {}", limit));
    } else {
        sql.push_str(" LIMIT 200");
    }

    if let Some(offset) = filter.offset {
        sql.push_str(&format!(" OFFSET {}", offset));
    }

    let params_ref: Vec<&dyn rusqlite::types::ToSql> = param_values.iter().map(|p| p.as_ref()).collect();

    let mut stmt = conn.prepare(&sql)?;
    let articles = stmt
        .query_map(params_ref.as_slice(), |row| {
            Ok(ArticleWithFeed {
                article: Article {
                    id: row.get(0)?,
                    feed_id: row.get(1)?,
                    title: row.get(2)?,
                    url: row.get(3)?,
                    author: row.get(4)?,
                    content_html: row.get(5)?,
                    content_text: row.get(6)?,
                    published_at: row.get(7)?,
                    fetched_at: row.get(8)?,
                    is_read: row.get::<_, i32>(9)? != 0,
                    is_starred: row.get::<_, i32>(10)? != 0,
                },
                feed_title: row.get(11)?,
                feed_icon_url: row.get(12)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(articles)
}

pub fn get_article_by_id(
    conn: &Connection,
    article_id: &str,
) -> Result<Option<ArticleWithFeed>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT a.id, a.feed_id, a.title, a.url, a.author, a.content_html, a.content_text,
                a.published_at, a.fetched_at, a.is_read, a.is_starred,
                f.title as feed_title, f.icon_url as feed_icon_url
         FROM articles a
         JOIN feeds f ON a.feed_id = f.id
         WHERE a.id = ?1",
    )?;
    let mut rows = stmt.query_map(params![article_id], |row| {
        Ok(ArticleWithFeed {
            article: Article {
                id: row.get(0)?,
                feed_id: row.get(1)?,
                title: row.get(2)?,
                url: row.get(3)?,
                author: row.get(4)?,
                content_html: row.get(5)?,
                content_text: row.get(6)?,
                published_at: row.get(7)?,
                fetched_at: row.get(8)?,
                is_read: row.get::<_, i32>(9)? != 0,
                is_starred: row.get::<_, i32>(10)? != 0,
            },
            feed_title: row.get(11)?,
            feed_icon_url: row.get(12)?,
        })
    })?;
    match rows.next() {
        Some(Ok(article)) => Ok(Some(article)),
        Some(Err(e)) => Err(e),
        None => Ok(None),
    }
}

pub fn mark_articles_read(
    conn: &Connection,
    article_ids: &[String],
) -> Result<(), rusqlite::Error> {
    for id in article_ids {
        conn.execute(
            "UPDATE articles SET is_read = 1 WHERE id = ?1",
            params![id],
        )?;
    }
    Ok(())
}

pub fn toggle_read(conn: &Connection, article_id: &str) -> Result<bool, rusqlite::Error> {
    let is_read: bool = conn.query_row(
        "SELECT is_read FROM articles WHERE id = ?1",
        params![article_id],
        |row| row.get(0),
    )?;
    let new_state = !is_read;
    conn.execute(
        "UPDATE articles SET is_read = ?1 WHERE id = ?2",
        params![new_state, article_id],
    )?;
    Ok(new_state)
}

pub fn mark_all_read(conn: &Connection, feed_id: Option<&str>) -> Result<(), rusqlite::Error> {
    match feed_id {
        Some(fid) => {
            conn.execute(
                "UPDATE articles SET is_read = 1 WHERE feed_id = ?1",
                params![fid],
            )?;
        }
        None => {
            conn.execute("UPDATE articles SET is_read = 1", [])?;
        }
    }
    Ok(())
}

pub fn toggle_star(conn: &Connection, article_id: &str) -> Result<bool, rusqlite::Error> {
    conn.execute(
        "UPDATE articles SET is_starred = CASE WHEN is_starred = 0 THEN 1 ELSE 0 END WHERE id = ?1",
        params![article_id],
    )?;
    let starred: bool = conn.query_row(
        "SELECT is_starred FROM articles WHERE id = ?1",
        params![article_id],
        |row| row.get::<_, i32>(0).map(|v| v != 0),
    )?;
    Ok(starred)
}

pub fn get_unread_count(conn: &Connection, feed_id: &str) -> Result<i64, rusqlite::Error> {
    conn.query_row(
        "SELECT COUNT(*) FROM articles WHERE feed_id = ?1 AND is_read = 0",
        params![feed_id],
        |row| row.get(0),
    )
}

pub fn get_total_unread_count(conn: &Connection) -> Result<i64, rusqlite::Error> {
    conn.query_row(
        "SELECT COUNT(*) FROM articles WHERE is_read = 0",
        [],
        |row| row.get(0),
    )
}

pub fn update_feed_fetched(conn: &Connection, feed_id: &str, timestamp: i64) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE feeds SET last_fetched_at = ?1, updated_at = ?1 WHERE id = ?2",
        params![timestamp, feed_id],
    )?;
    Ok(())
}

// Theme queries
pub fn insert_theme(conn: &Connection, theme: &Theme) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT OR REPLACE INTO themes (id, label, summary, created_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![theme.id, theme.label, theme.summary, theme.created_at, theme.expires_at],
    )?;
    Ok(())
}

pub fn insert_theme_article(conn: &Connection, theme_id: &str, article_id: &str, relevance: f64) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT OR REPLACE INTO theme_articles (theme_id, article_id, relevance)
         VALUES (?1, ?2, ?3)",
        params![theme_id, article_id, relevance],
    )?;
    Ok(())
}

pub fn get_themes(conn: &Connection) -> Result<Vec<Theme>, rusqlite::Error> {
    let now = chrono::Utc::now().timestamp();
    let mut stmt = conn.prepare(
        "SELECT t.id, t.label, t.summary, t.created_at, t.expires_at,
                (SELECT COUNT(*) FROM theme_articles ta WHERE ta.theme_id = t.id) as article_count
         FROM themes t
         WHERE t.expires_at > ?1
         ORDER BY article_count DESC",
    )?;
    let themes = stmt
        .query_map(params![now], |row| {
            Ok(Theme {
                id: row.get(0)?,
                label: row.get(1)?,
                summary: row.get(2)?,
                created_at: row.get(3)?,
                expires_at: row.get(4)?,
                article_count: row.get(5)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(themes)
}

pub fn clear_themes(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute("DELETE FROM theme_articles", [])?;
    conn.execute("DELETE FROM themes", [])?;
    Ok(())
}

// Settings queries
pub fn get_setting(conn: &Connection, key: &str) -> Result<Option<String>, rusqlite::Error> {
    let mut stmt = conn.prepare("SELECT value FROM settings WHERE key = ?1")?;
    let mut rows = stmt.query_map(params![key], |row| row.get::<_, String>(0))?;
    match rows.next() {
        Some(Ok(value)) => Ok(Some(value)),
        Some(Err(e)) => Err(e),
        None => Ok(None),
    }
}

pub fn set_setting(conn: &Connection, key: &str, value: &str) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT OR REPLACE INTO settings (key, value) VALUES (?1, ?2)",
        params![key, value],
    )?;
    Ok(())
}

// Summary queries
pub fn insert_article_summary(conn: &Connection, summary: &ArticleSummary) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT OR REPLACE INTO article_summaries (article_id, bullet_summary, full_summary, provider, model, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            summary.article_id,
            summary.bullet_summary,
            summary.full_summary,
            summary.provider,
            summary.model,
            summary.created_at,
        ],
    )?;
    Ok(())
}

pub fn get_article_summary(conn: &Connection, article_id: &str) -> Result<Option<ArticleSummary>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT article_id, bullet_summary, full_summary, provider, model, created_at
         FROM article_summaries WHERE article_id = ?1",
    )?;
    let mut rows = stmt.query_map(params![article_id], |row| {
        Ok(ArticleSummary {
            article_id: row.get(0)?,
            bullet_summary: row.get(1)?,
            full_summary: row.get(2)?,
            provider: row.get(3)?,
            model: row.get(4)?,
            created_at: row.get(5)?,
        })
    })?;
    match rows.next() {
        Some(Ok(s)) => Ok(Some(s)),
        Some(Err(e)) => Err(e),
        None => Ok(None),
    }
}
