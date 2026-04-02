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

pub fn mark_articles_unread(
    conn: &Connection,
    article_ids: &[String],
) -> Result<(), rusqlite::Error> {
    for id in article_ids {
        conn.execute(
            "UPDATE articles SET is_read = 0 WHERE id = ?1",
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

// Triage queries
pub fn upsert_triage_batch(conn: &Connection, items: &[ArticleTriage]) -> Result<(), rusqlite::Error> {
    let tx = conn.unchecked_transaction()?;
    {
        let mut stmt = tx.prepare(
            "INSERT OR REPLACE INTO article_triage (article_id, priority, reason, provider, model, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)"
        )?;
        for item in items {
            stmt.execute(params![
                item.article_id, item.priority, item.reason,
                item.provider, item.model, item.created_at,
            ])?;
        }
    }
    tx.commit()?;
    Ok(())
}

pub fn get_inbox_articles(
    conn: &Connection,
    min_priority: Option<i32>,
    is_read: Option<bool>,
    limit: i64,
    offset: i64,
) -> Result<Vec<ArticleWithTriage>, rusqlite::Error> {
    let mut sql = String::from(
        "SELECT a.id, a.feed_id, a.title, a.url, a.author, a.content_html, a.content_text,
                a.published_at, a.fetched_at, a.is_read, a.is_starred,
                f.title as feed_title, f.icon_url as feed_icon_url,
                t.priority, t.reason
         FROM articles a
         JOIN feeds f ON a.feed_id = f.id
         JOIN article_triage t ON a.id = t.article_id
         WHERE 1=1"
    );
    let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    if let Some(min_p) = min_priority {
        param_values.push(Box::new(min_p));
        sql.push_str(&format!(" AND t.priority >= ?{}", param_values.len()));
    }
    if let Some(read) = is_read {
        param_values.push(Box::new(read as i32));
        sql.push_str(&format!(" AND a.is_read = ?{}", param_values.len()));
    }

    sql.push_str(" ORDER BY t.priority DESC, COALESCE(a.published_at, a.fetched_at) DESC");
    sql.push_str(&format!(" LIMIT {} OFFSET {}", limit, offset));

    let params_ref: Vec<&dyn rusqlite::types::ToSql> = param_values.iter().map(|p| p.as_ref()).collect();
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt
        .query_map(params_ref.as_slice(), |row| {
            Ok(ArticleWithTriage {
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
                priority: row.get(13)?,
                reason: row.get(14)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub fn get_untriaged_article_ids(conn: &Connection, limit: i64) -> Result<Vec<ArticleWithFeed>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT a.id, a.feed_id, a.title, a.url, a.author, a.content_html, a.content_text,
                a.published_at, a.fetched_at, a.is_read, a.is_starred,
                f.title as feed_title, f.icon_url as feed_icon_url
         FROM articles a
         JOIN feeds f ON a.feed_id = f.id
         LEFT JOIN article_triage t ON a.id = t.article_id
         WHERE a.is_read = 0 AND t.article_id IS NULL
         ORDER BY COALESCE(a.published_at, a.fetched_at) DESC
         LIMIT ?1"
    )?;
    let rows = stmt
        .query_map(params![limit], |row| {
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
    Ok(rows)
}

pub fn get_triage_stats(conn: &Connection) -> Result<TriageStats, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT t.priority, COUNT(*)
         FROM article_triage t
         JOIN articles a ON t.article_id = a.id
         WHERE a.is_read = 0
         GROUP BY t.priority"
    )?;
    let mut by_priority = std::collections::HashMap::new();
    let mut total = 0i64;
    let rows = stmt.query_map([], |row| {
        Ok((row.get::<_, i32>(0)?, row.get::<_, i64>(1)?))
    })?;
    for row in rows {
        let (priority, count) = row?;
        total += count;
        by_priority.insert(priority, count);
    }
    Ok(TriageStats { total, by_priority })
}

pub fn clear_triage(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute("DELETE FROM article_triage", [])?;
    Ok(())
}

// Interaction / learning queries

pub fn record_reading_time(
    conn: &Connection,
    article_id: &str,
    seconds: i64,
    now: i64,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO article_interactions (article_id, reading_time_sec, chat_messages, updated_at)
         VALUES (?1, ?2, 0, ?3)
         ON CONFLICT(article_id) DO UPDATE SET
           reading_time_sec = reading_time_sec + ?2,
           updated_at = ?3",
        params![article_id, seconds, now],
    )?;
    Ok(())
}

pub fn increment_chat_count(
    conn: &Connection,
    article_id: &str,
    now: i64,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO article_interactions (article_id, reading_time_sec, chat_messages, updated_at)
         VALUES (?1, 0, 1, ?2)
         ON CONFLICT(article_id) DO UPDATE SET
           chat_messages = chat_messages + 1,
           updated_at = ?2",
        params![article_id, now],
    )?;
    Ok(())
}

pub fn set_article_feedback(
    conn: &Connection,
    article_id: &str,
    feedback: Option<&str>,
    now: i64,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO article_interactions (article_id, reading_time_sec, chat_messages, feedback, updated_at)
         VALUES (?1, 0, 0, ?2, ?3)
         ON CONFLICT(article_id) DO UPDATE SET
           feedback = ?2,
           updated_at = ?3",
        params![article_id, feedback, now],
    )?;
    Ok(())
}

pub fn set_priority_override(
    conn: &Connection,
    article_id: &str,
    priority: i32,
    now: i64,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO article_interactions (article_id, reading_time_sec, chat_messages, priority_override, updated_at)
         VALUES (?1, 0, 0, ?2, ?3)
         ON CONFLICT(article_id) DO UPDATE SET
           priority_override = ?2,
           updated_at = ?3",
        params![article_id, priority, now],
    )?;
    Ok(())
}

/// Build a preference profile from interaction history.
/// Returns top feeds, preferred/deprioritized topics extracted from article titles.
pub fn build_preference_profile(conn: &Connection) -> Result<UserPreferenceProfile, rusqlite::Error> {
    // Top feeds by engagement (reading_time weighted)
    let mut stmt = conn.prepare(
        "SELECT f.title, SUM(i.reading_time_sec) + SUM(i.chat_messages) * 60 as engagement
         FROM article_interactions i
         JOIN articles a ON i.article_id = a.id
         JOIN feeds f ON a.feed_id = f.id
         WHERE i.reading_time_sec > 10 OR i.chat_messages > 0 OR i.feedback = 'more'
         GROUP BY f.id
         ORDER BY engagement DESC
         LIMIT 10"
    )?;
    let top_feeds: Vec<String> = stmt
        .query_map([], |row| row.get::<_, String>(0))?
        .filter_map(|r| r.ok())
        .collect();

    // Preferred topics: titles of articles with high engagement or "more" feedback
    let mut stmt = conn.prepare(
        "SELECT a.title
         FROM article_interactions i
         JOIN articles a ON i.article_id = a.id
         WHERE i.feedback = 'more' OR i.reading_time_sec > 120 OR i.chat_messages >= 2
             OR i.priority_override >= 4
         ORDER BY i.updated_at DESC
         LIMIT 30"
    )?;
    let preferred_topics: Vec<String> = stmt
        .query_map([], |row| row.get::<_, String>(0))?
        .filter_map(|r| r.ok())
        .collect();

    // Deprioritized: articles with "less" feedback or low priority override
    let mut stmt = conn.prepare(
        "SELECT a.title
         FROM article_interactions i
         JOIN articles a ON i.article_id = a.id
         WHERE i.feedback = 'less' OR i.priority_override <= 1
         ORDER BY i.updated_at DESC
         LIMIT 20"
    )?;
    let deprioritized_topics: Vec<String> = stmt
        .query_map([], |row| row.get::<_, String>(0))?
        .filter_map(|r| r.ok())
        .collect();

    // Stats
    let (avg_reading, total): (f64, i64) = conn.query_row(
        "SELECT COALESCE(AVG(reading_time_sec), 0), COUNT(*) FROM article_interactions WHERE reading_time_sec > 0",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;

    Ok(UserPreferenceProfile {
        top_feeds,
        preferred_topics,
        deprioritized_topics,
        avg_reading_time_sec: avg_reading,
        total_interactions: total,
    })
}

pub fn get_article_interaction(
    conn: &Connection,
    article_id: &str,
) -> Result<Option<ArticleInteraction>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT article_id, reading_time_sec, chat_messages, feedback, priority_override, updated_at
         FROM article_interactions WHERE article_id = ?1"
    )?;
    let mut rows = stmt.query_map(params![article_id], |row| {
        Ok(ArticleInteraction {
            article_id: row.get(0)?,
            reading_time_sec: row.get(1)?,
            chat_messages: row.get(2)?,
            feedback: row.get(3)?,
            priority_override: row.get(4)?,
            updated_at: row.get(5)?,
        })
    })?;
    match rows.next() {
        Some(Ok(i)) => Ok(Some(i)),
        Some(Err(e)) => Err(e),
        None => Ok(None),
    }
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

