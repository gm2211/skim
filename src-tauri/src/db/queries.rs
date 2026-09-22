use rusqlite::{params, types::Type, Connection, OptionalExtension};

use super::models::*;

pub fn insert_feed(conn: &Connection, feed: &Feed) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT OR REPLACE INTO feeds (id, title, url, site_url, description, icon_url, feedly_id, created_at, updated_at, last_fetched_at, folder_id, opml_category)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
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
            feed.folder_id,
            feed.opml_category,
        ],
    )?;
    Ok(())
}

pub fn list_feeds(conn: &Connection) -> Result<Vec<Feed>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT id, title, url, site_url, description, icon_url, feedly_id, created_at, updated_at, last_fetched_at, folder_id, opml_category
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
                folder_id: row.get(10)?,
                opml_category: row.get(11)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(feeds)
}

pub fn get_feed_by_id(conn: &Connection, feed_id: &str) -> Result<Option<Feed>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT id, title, url, site_url, description, icon_url, feedly_id, created_at, updated_at, last_fetched_at, folder_id, opml_category
         FROM feeds WHERE id = ?1",
    )?;
    let mut rows = stmt.query_map(params![feed_id], |row| {
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
            folder_id: row.get(10)?,
            opml_category: row.get(11)?,
        })
    })?;
    match rows.next() {
        Some(Ok(feed)) => Ok(Some(feed)),
        Some(Err(e)) => Err(e),
        None => Ok(None),
    }
}

pub fn get_feedly_entry_ids(
    conn: &Connection,
    article_ids: &[String],
) -> Result<Vec<(String, String)>, rusqlite::Error> {
    let mut results = Vec::new();
    for id in article_ids {
        let mut stmt = conn.prepare(
            "SELECT id, feedly_entry_id FROM articles WHERE id = ?1 AND feedly_entry_id IS NOT NULL"
        )?;
        let rows = stmt.query_map(params![id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        for row in rows {
            results.push(row?);
        }
    }
    Ok(results)
}

pub fn delete_feed(conn: &Connection, feed_id: &str) -> Result<(), rusqlite::Error> {
    conn.execute("DELETE FROM feeds WHERE id = ?1", params![feed_id])?;
    Ok(())
}

pub fn rename_feed(
    conn: &Connection,
    feed_id: &str,
    new_title: &str,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE feeds SET title = ?1, updated_at = ?2 WHERE id = ?3",
        params![new_title, chrono::Utc::now().timestamp(), feed_id],
    )?;
    Ok(())
}

pub fn assign_feed_to_folder(
    conn: &Connection,
    feed_id: &str,
    folder_id: Option<&str>,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE feeds SET folder_id = ?1, updated_at = ?2 WHERE id = ?3",
        params![folder_id, chrono::Utc::now().timestamp(), feed_id],
    )?;
    Ok(())
}

// ── Folders ────────────────────────────────────────────────────────

pub fn insert_folder(conn: &Connection, folder: &Folder) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO folders (id, name, sort_order, is_smart, rules_json, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            folder.id,
            folder.name,
            folder.sort_order,
            folder.is_smart as i32,
            folder.rules_json,
            folder.created_at,
        ],
    )?;
    Ok(())
}

pub fn list_folders(conn: &Connection) -> Result<Vec<Folder>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT id, name, sort_order, is_smart, rules_json, created_at
         FROM folders ORDER BY sort_order, name COLLATE NOCASE",
    )?;
    let rows = stmt
        .query_map([], |row| {
            Ok(Folder {
                id: row.get(0)?,
                name: row.get(1)?,
                sort_order: row.get(2)?,
                is_smart: row.get::<_, i32>(3)? != 0,
                rules_json: row.get(4)?,
                created_at: row.get(5)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub fn rename_folder(
    conn: &Connection,
    folder_id: &str,
    new_name: &str,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE folders SET name = ?1 WHERE id = ?2",
        params![new_name, folder_id],
    )?;
    Ok(())
}

pub fn update_folder_rules(
    conn: &Connection,
    folder_id: &str,
    rules_json: &str,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE folders SET rules_json = ?1 WHERE id = ?2",
        params![rules_json, folder_id],
    )?;
    Ok(())
}

/// Atomically changes a folder's mode and snapshots membership when converting
/// a smart folder to a regular one. Validation and membership evaluation happen
/// before this helper is called by the command layer.
pub fn convert_folder_in_place(
    conn: &Connection,
    folder_id: &str,
    to_smart: bool,
    rules_json: Option<&str>,
    name: Option<&str>,
    matching_ids: &[String],
) -> Result<(), rusqlite::Error> {
    let tx = conn.unchecked_transaction()?;
    if to_smart {
        tx.execute(
            "UPDATE folders SET name = COALESCE(?1, name), is_smart = 1, rules_json = ?2 WHERE id = ?3",
            params![name, rules_json, folder_id],
        )?;
    } else {
        tx.execute(
            "UPDATE folders SET name = COALESCE(?1, name), is_smart = 0, rules_json = NULL WHERE id = ?2",
            params![name, folder_id],
        )?;
    }
    tx.execute(
        "UPDATE feeds SET folder_id = NULL, updated_at = ?1 WHERE folder_id = ?2",
        params![chrono::Utc::now().timestamp(), folder_id],
    )?;
    if !to_smart {
        for feed_id in matching_ids {
            tx.execute(
                "UPDATE feeds SET folder_id = ?1, updated_at = ?2 WHERE id = ?3",
                params![folder_id, chrono::Utc::now().timestamp(), feed_id],
            )?;
        }
    }
    tx.commit()
}

pub fn delete_folder(conn: &Connection, folder_id: &str) -> Result<(), rusqlite::Error> {
    // ON DELETE SET NULL on feeds.folder_id handles orphan feeds
    conn.execute("DELETE FROM folders WHERE id = ?1", params![folder_id])?;
    Ok(())
}

pub fn reorder_folders(conn: &Connection, folder_ids: &[String]) -> Result<(), rusqlite::Error> {
    let tx = conn.unchecked_transaction()?;
    for (idx, id) in folder_ids.iter().enumerate() {
        tx.execute(
            "UPDATE folders SET sort_order = ?1 WHERE id = ?2",
            params![idx as i32, id],
        )?;
    }
    tx.commit()?;
    Ok(())
}

pub fn next_folder_sort_order(conn: &Connection) -> Result<i32, rusqlite::Error> {
    let max: Option<i32> = conn
        .query_row("SELECT MAX(sort_order) FROM folders", [], |row| row.get(0))
        .ok()
        .flatten();
    Ok(max.map(|m| m + 1).unwrap_or(0))
}

/// Reassign articles from one feed to another, then delete the source feed.
/// Articles with conflicting IDs (same id in both feeds) are silently dropped
/// from the source — the kept feed already has them.
pub fn merge_feed(
    conn: &Connection,
    from_feed_id: &str,
    into_feed_id: &str,
) -> Result<(), rusqlite::Error> {
    let tx = conn.unchecked_transaction()?;
    tx.execute(
        "UPDATE OR IGNORE articles SET feed_id = ?1 WHERE feed_id = ?2",
        params![into_feed_id, from_feed_id],
    )?;
    // Delete any leftover articles that couldn't be reassigned (ID conflict).
    tx.execute(
        "DELETE FROM articles WHERE feed_id = ?1",
        params![from_feed_id],
    )?;
    tx.execute("DELETE FROM feeds WHERE id = ?1", params![from_feed_id])?;
    tx.commit()?;
    Ok(())
}

pub fn count_articles_in_feed(conn: &Connection, feed_id: &str) -> Result<i64, rusqlite::Error> {
    conn.query_row(
        "SELECT COUNT(*) FROM articles WHERE feed_id = ?1",
        params![feed_id],
        |row| row.get(0),
    )
}

pub fn count_starred_in_feed(conn: &Connection, feed_id: &str) -> Result<i64, rusqlite::Error> {
    conn.query_row(
        "SELECT COUNT(*) FROM articles WHERE feed_id = ?1 AND is_starred = 1",
        params![feed_id],
        |row| row.get(0),
    )
}

pub fn insert_article(conn: &Connection, article: &Article) -> Result<bool, rusqlite::Error> {
    let result = conn.execute(
        "INSERT OR IGNORE INTO articles (id, feed_id, title, url, author, content_html, content_text, published_at, fetched_at, is_read, is_starred, feedly_entry_id, comments_url)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
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
            article.feedly_entry_id,
            article.comments_url,
        ],
    )?;
    Ok(result > 0)
}

pub fn count_articles(conn: &Connection, filter: &ArticleFilter) -> Result<i64, rusqlite::Error> {
    let mut sql = String::from("SELECT COUNT(*) FROM articles a JOIN feeds f ON a.feed_id = f.id");
    let mut conditions = Vec::new();
    let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    if let Some(ref feed_id) = filter.feed_id {
        conditions.push(format!("a.feed_id = ?{}", param_values.len() + 1));
        param_values.push(Box::new(feed_id.clone()));
    }

    if let Some(ref feed_ids) = filter.feed_ids {
        if feed_ids.is_empty() {
            conditions.push("1 = 0".to_string());
        } else {
            let placeholders = (0..feed_ids.len())
                .map(|i| format!("?{}", param_values.len() + i + 1))
                .collect::<Vec<_>>();
            conditions.push(format!("a.feed_id IN ({})", placeholders.join(", ")));
            for feed_id in feed_ids {
                param_values.push(Box::new(feed_id.clone()));
            }
        }
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

    if let Some(ref search) = filter.search {
        let pattern = format!("%{}%", search.to_lowercase());
        conditions.push(format!(
            "(LOWER(a.title) LIKE ?{} OR LOWER(COALESCE(a.content_text, '')) LIKE ?{} OR LOWER(COALESCE(a.url, '')) LIKE ?{} OR LOWER(f.title) LIKE ?{})",
            param_values.len() + 1,
            param_values.len() + 1,
            param_values.len() + 1,
            param_values.len() + 1,
        ));
        param_values.push(Box::new(pattern));
    }

    if !conditions.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&conditions.join(" AND "));
    }

    let params_ref: Vec<&dyn rusqlite::types::ToSql> =
        param_values.iter().map(|p| p.as_ref()).collect();
    conn.query_row(&sql, params_ref.as_slice(), |row| row.get(0))
}

pub fn get_articles(
    conn: &Connection,
    filter: &ArticleFilter,
) -> Result<Vec<ArticleWithFeed>, rusqlite::Error> {
    let mut sql = String::from(
        "SELECT a.id, a.feed_id, a.title, a.url, a.author, a.content_html, a.content_text,
                a.published_at, a.fetched_at, a.is_read, a.is_starred, a.feedly_entry_id, a.comments_url,
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

    if let Some(ref feed_ids) = filter.feed_ids {
        if feed_ids.is_empty() {
            conditions.push("1 = 0".to_string());
        } else {
            let placeholders = (0..feed_ids.len())
                .map(|i| format!("?{}", param_values.len() + i + 1))
                .collect::<Vec<_>>();
            conditions.push(format!("a.feed_id IN ({})", placeholders.join(", ")));
            for feed_id in feed_ids {
                param_values.push(Box::new(feed_id.clone()));
            }
        }
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

    if let Some(ref search) = filter.search {
        let pattern = format!("%{}%", search.to_lowercase());
        conditions.push(format!(
            "(LOWER(a.title) LIKE ?{} OR LOWER(a.content_text) LIKE ?{} OR LOWER(a.url) LIKE ?{} OR LOWER(f.title) LIKE ?{})",
            param_values.len() + 1,
            param_values.len() + 1,
            param_values.len() + 1,
            param_values.len() + 1,
        ));
        param_values.push(Box::new(pattern));
    }

    if let Some(cutoff) = filter.published_after {
        conditions.push(format!(
            "COALESCE(a.published_at, a.fetched_at) >= ?{}",
            param_values.len() + 1
        ));
        param_values.push(Box::new(cutoff));
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

    let params_ref: Vec<&dyn rusqlite::types::ToSql> =
        param_values.iter().map(|p| p.as_ref()).collect();

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
                    feedly_entry_id: row.get(11)?,
                    comments_url: row.get(12)?,
                },
                feed_title: row.get(13)?,
                feed_icon_url: row.get(14)?,
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
                a.published_at, a.fetched_at, a.is_read, a.is_starred, a.feedly_entry_id, a.comments_url,
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
                feedly_entry_id: row.get(11)?,
                comments_url: row.get(12)?,
            },
            feed_title: row.get(13)?,
            feed_icon_url: row.get(14)?,
        })
    })?;
    match rows.next() {
        Some(Ok(article)) => Ok(Some(article)),
        Some(Err(e)) => Err(e),
        None => Ok(None),
    }
}

pub fn get_article_summary(
    conn: &Connection,
    article_id: &str,
    cache_key: &str,
) -> Result<Option<ArticleSummary>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT article_id, bullet_summary, full_summary, provider, model, created_at
         FROM article_summaries
         WHERE article_id = ?1 AND cache_key = ?2
         LIMIT 1",
    )?;
    let mut rows = stmt.query_map(params![article_id, cache_key], |row| {
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
        Some(Ok(summary)) => Ok(Some(summary)),
        Some(Err(e)) => Err(e),
        None => Ok(None),
    }
}

pub fn upsert_article_summary(
    conn: &Connection,
    cache_key: &str,
    summary: &ArticleSummary,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO article_summaries (
            article_id, cache_key, bullet_summary, full_summary, provider, model, created_at
         )
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(article_id, cache_key) DO UPDATE SET
            bullet_summary = excluded.bullet_summary,
            full_summary = excluded.full_summary,
            provider = excluded.provider,
            model = excluded.model,
            created_at = excluded.created_at",
        params![
            summary.article_id,
            cache_key,
            summary.bullet_summary,
            summary.full_summary,
            summary.provider,
            summary.model,
            summary.created_at,
        ],
    )?;
    Ok(())
}

pub fn delete_article_summary(
    conn: &Connection,
    article_id: &str,
    cache_key: &str,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "DELETE FROM article_summaries WHERE article_id = ?1 AND cache_key = ?2",
        params![article_id, cache_key],
    )?;
    Ok(())
}

pub fn mark_articles_read(
    conn: &Connection,
    article_ids: &[String],
) -> Result<(), rusqlite::Error> {
    for id in article_ids {
        conn.execute("UPDATE articles SET is_read = 1 WHERE id = ?1", params![id])?;
    }
    Ok(())
}

pub fn mark_articles_unread(
    conn: &Connection,
    article_ids: &[String],
) -> Result<(), rusqlite::Error> {
    for id in article_ids {
        conn.execute("UPDATE articles SET is_read = 0 WHERE id = ?1", params![id])?;
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

/// Update the star state for existing articles by feedly_entry_id.
/// Used after fetching a Feedly stream so the local DB matches Feedly's
/// "saved" state (articles unsaved on Feedly get unstarred locally).
pub fn sync_star_state_from_feedly(
    conn: &Connection,
    updates: &[(String, bool)], // (feedly_entry_id, is_starred)
) -> Result<i64, rusqlite::Error> {
    let tx = conn.unchecked_transaction()?;
    let mut changed = 0i64;
    for (feedly_id, starred) in updates {
        let n = tx.execute(
            "UPDATE articles SET is_starred = ?1
             WHERE feedly_entry_id = ?2 AND is_starred != ?1",
            params![*starred as i32, feedly_id],
        )?;
        changed += n as i64;
    }
    tx.commit()?;
    Ok(changed)
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

pub fn update_feed_fetched(
    conn: &Connection,
    feed_id: &str,
    timestamp: i64,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE feeds SET last_fetched_at = ?1, updated_at = ?1 WHERE id = ?2",
        params![timestamp, feed_id],
    )?;
    Ok(())
}

// Story, revision, and edition persistence

// TODO(story-consumers): remove these per-function allowances as command/UI phases land.
#[allow(dead_code)]
fn story_from_row(row: &rusqlite::Row<'_>) -> Result<Story, rusqlite::Error> {
    Ok(Story {
        id: row.get(0)?,
        title: row.get(1)?,
        summary: row.get(2)?,
        representative_article_id: row.get(3)?,
        first_seen_at: row.get(4)?,
        last_activity_at: row.get(5)?,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
    })
}

#[allow(dead_code)]
fn membership_type_from_row(
    row: &rusqlite::Row<'_>,
    index: usize,
) -> Result<StoryMembershipType, rusqlite::Error> {
    let raw: String = row.get(index)?;
    StoryMembershipType::try_from(raw.as_str()).map_err(|message| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            Type::Text,
            Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                message,
            )),
        )
    })
}

#[allow(dead_code)]
pub fn upsert_story(conn: &Connection, story: &Story) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO stories (
            id, title, summary, representative_article_id,
            first_seen_at, last_activity_at, created_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            summary = excluded.summary,
            representative_article_id = excluded.representative_article_id,
            first_seen_at = MIN(stories.first_seen_at, excluded.first_seen_at),
            last_activity_at = MAX(stories.last_activity_at, excluded.last_activity_at),
            updated_at = excluded.updated_at",
        params![
            story.id,
            story.title,
            story.summary,
            story.representative_article_id,
            story.first_seen_at,
            story.last_activity_at,
            story.created_at,
            story.updated_at,
        ],
    )?;
    Ok(())
}

#[allow(dead_code)]
pub fn get_story(conn: &Connection, story_id: &str) -> Result<Option<Story>, rusqlite::Error> {
    conn.query_row(
        "SELECT id, title, summary, representative_article_id,
                first_seen_at, last_activity_at, created_at, updated_at
         FROM stories WHERE id = ?1",
        params![story_id],
        story_from_row,
    )
    .optional()
}

/// Stories active at or after `since`, newest activity first. This is the
/// indexed rolling-window lookup used to find clustering candidates.
#[allow(dead_code)]
pub fn list_recent_stories(
    conn: &Connection,
    since: i64,
    limit: i64,
) -> Result<Vec<Story>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT id, title, summary, representative_article_id,
                first_seen_at, last_activity_at, created_at, updated_at
         FROM stories
         WHERE last_activity_at >= ?1
         ORDER BY last_activity_at DESC, id
         LIMIT ?2",
    )?;
    let stories = stmt
        .query_map(params![since, limit], story_from_row)?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(stories)
}

#[allow(dead_code)]
pub fn delete_story(conn: &Connection, story_id: &str) -> Result<bool, rusqlite::Error> {
    Ok(conn.execute("DELETE FROM stories WHERE id = ?1", params![story_id])? > 0)
}

#[allow(dead_code)]
pub fn upsert_story_article(
    conn: &Connection,
    membership: &StoryArticle,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO story_articles (
            story_id, article_id, membership_type, confidence, added_at
         ) VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(article_id) DO UPDATE SET
            story_id = excluded.story_id,
            membership_type = excluded.membership_type,
            confidence = excluded.confidence,
            added_at = excluded.added_at",
        params![
            membership.story_id,
            membership.article_id,
            membership.membership_type.as_str(),
            membership.confidence,
            membership.added_at,
        ],
    )?;
    Ok(())
}

#[allow(dead_code)]
pub fn list_story_articles(
    conn: &Connection,
    story_id: &str,
) -> Result<Vec<StoryArticle>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT story_id, article_id, membership_type, confidence, added_at
         FROM story_articles
         WHERE story_id = ?1
         ORDER BY added_at DESC, article_id",
    )?;
    let memberships = stmt
        .query_map(params![story_id], |row| {
            Ok(StoryArticle {
                story_id: row.get(0)?,
                article_id: row.get(1)?,
                membership_type: membership_type_from_row(row, 2)?,
                confidence: row.get(3)?,
                added_at: row.get(4)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(memberships)
}

#[allow(dead_code)]
pub fn delete_story_article(
    conn: &Connection,
    story_id: &str,
    article_id: &str,
) -> Result<bool, rusqlite::Error> {
    Ok(conn.execute(
        "DELETE FROM story_articles WHERE story_id = ?1 AND article_id = ?2",
        params![story_id, article_id],
    )? > 0)
}

/// Inserts an immutable story revision. Duplicate revision numbers are errors.
#[allow(dead_code)]
pub fn insert_story_revision(
    conn: &Connection,
    revision: &StoryRevision,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO story_revisions (
            story_id, revision_number, title, summary, delta_summary,
            representative_article_id, source_count, content_fingerprint,
            is_material_change, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            revision.story_id,
            revision.revision_number,
            revision.title,
            revision.summary,
            revision.delta_summary,
            revision.representative_article_id,
            revision.source_count,
            revision.content_fingerprint,
            revision.is_material_change as i32,
            revision.created_at,
        ],
    )?;
    Ok(())
}

#[allow(dead_code)]
fn revision_from_row(row: &rusqlite::Row<'_>) -> Result<StoryRevision, rusqlite::Error> {
    Ok(StoryRevision {
        story_id: row.get(0)?,
        revision_number: row.get(1)?,
        title: row.get(2)?,
        summary: row.get(3)?,
        delta_summary: row.get(4)?,
        representative_article_id: row.get(5)?,
        source_count: row.get(6)?,
        content_fingerprint: row.get(7)?,
        is_material_change: row.get::<_, i32>(8)? != 0,
        created_at: row.get(9)?,
    })
}

#[allow(dead_code)]
pub fn get_story_revision(
    conn: &Connection,
    story_id: &str,
    revision_number: i64,
) -> Result<Option<StoryRevision>, rusqlite::Error> {
    conn.query_row(
        "SELECT story_id, revision_number, title, summary, delta_summary,
                representative_article_id, source_count, content_fingerprint,
                is_material_change, created_at
         FROM story_revisions
         WHERE story_id = ?1 AND revision_number = ?2",
        params![story_id, revision_number],
        revision_from_row,
    )
    .optional()
}

#[allow(dead_code)]
pub fn get_latest_story_revision(
    conn: &Connection,
    story_id: &str,
) -> Result<Option<StoryRevision>, rusqlite::Error> {
    conn.query_row(
        "SELECT story_id, revision_number, title, summary, delta_summary,
                representative_article_id, source_count, content_fingerprint,
                is_material_change, created_at
         FROM story_revisions
         WHERE story_id = ?1
         ORDER BY revision_number DESC
         LIMIT 1",
        params![story_id],
        revision_from_row,
    )
    .optional()
}

#[allow(dead_code)]
pub fn upsert_story_user_state(
    conn: &Connection,
    state: &StoryUserState,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO story_user_state (
            story_id, last_seen_revision, last_read_revision,
            is_followed, caught_up_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(story_id) DO UPDATE SET
            last_seen_revision = excluded.last_seen_revision,
            last_read_revision = excluded.last_read_revision,
            is_followed = excluded.is_followed,
            caught_up_at = excluded.caught_up_at,
            updated_at = excluded.updated_at",
        params![
            state.story_id,
            state.last_seen_revision,
            state.last_read_revision,
            state.is_followed as i32,
            state.caught_up_at,
            state.updated_at,
        ],
    )?;
    Ok(())
}

#[allow(dead_code)]
pub fn get_story_user_state(
    conn: &Connection,
    story_id: &str,
) -> Result<Option<StoryUserState>, rusqlite::Error> {
    conn.query_row(
        "SELECT story_id, last_seen_revision, last_read_revision,
                is_followed, caught_up_at, updated_at
         FROM story_user_state WHERE story_id = ?1",
        params![story_id],
        |row| {
            Ok(StoryUserState {
                story_id: row.get(0)?,
                last_seen_revision: row.get(1)?,
                last_read_revision: row.get(2)?,
                is_followed: row.get::<_, i32>(3)? != 0,
                caught_up_at: row.get(4)?,
                updated_at: row.get(5)?,
            })
        },
    )
    .optional()
}

/// Inserts an edition shell. Edition content is added with
/// `insert_edition_items`; neither helper overwrites existing snapshots.
#[allow(dead_code)]
pub fn insert_edition(conn: &Connection, edition: &Edition) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO editions (
            id, title, scope, story_limit, status, starts_at, ends_at,
            generated_at, completed_at, total_source_count
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            edition.id,
            edition.title,
            edition.scope,
            edition.story_limit,
            edition.status.as_str(),
            edition.starts_at,
            edition.ends_at,
            edition.generated_at,
            edition.completed_at,
            edition.total_source_count,
        ],
    )?;
    Ok(())
}

#[allow(dead_code)]
fn edition_status_from_row(
    row: &rusqlite::Row<'_>,
    index: usize,
) -> Result<EditionStatus, rusqlite::Error> {
    let raw: String = row.get(index)?;
    EditionStatus::try_from(raw.as_str()).map_err(|message| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            Type::Text,
            Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                message,
            )),
        )
    })
}

#[allow(dead_code)]
fn edition_from_row(row: &rusqlite::Row<'_>) -> Result<Edition, rusqlite::Error> {
    Ok(Edition {
        id: row.get(0)?,
        title: row.get(1)?,
        scope: row.get(2)?,
        story_limit: row.get(3)?,
        status: edition_status_from_row(row, 4)?,
        starts_at: row.get(5)?,
        ends_at: row.get(6)?,
        generated_at: row.get(7)?,
        completed_at: row.get(8)?,
        total_source_count: row.get(9)?,
    })
}

#[allow(dead_code)]
pub fn get_edition(
    conn: &Connection,
    edition_id: &str,
) -> Result<Option<Edition>, rusqlite::Error> {
    conn.query_row(
        "SELECT id, title, scope, story_limit, status, starts_at, ends_at,
                generated_at, completed_at, total_source_count
         FROM editions WHERE id = ?1",
        params![edition_id],
        edition_from_row,
    )
    .optional()
}

#[allow(dead_code)]
pub fn get_current_edition(
    conn: &Connection,
    scope: &str,
    timestamp: i64,
) -> Result<Option<Edition>, rusqlite::Error> {
    conn.query_row(
        "SELECT id, title, scope, story_limit, status, starts_at, ends_at,
                generated_at, completed_at, total_source_count
         FROM editions
         WHERE scope = ?1
           AND starts_at <= ?2 AND ends_at > ?2
           AND status IN ('ready', 'completed')
         ORDER BY generated_at DESC, id DESC
         LIMIT 1",
        params![scope, timestamp],
        edition_from_row,
    )
    .optional()
}

/// Updates mutable edition lifecycle metadata without touching item snapshots.
#[allow(dead_code)]
pub fn update_edition_progress(
    conn: &Connection,
    edition_id: &str,
    status: EditionStatus,
    completed_at: Option<i64>,
    total_source_count: i64,
) -> Result<bool, rusqlite::Error> {
    Ok(conn.execute(
        "UPDATE editions
         SET status = ?1, completed_at = ?2, total_source_count = ?3
         WHERE id = ?4",
        params![
            status.as_str(),
            completed_at,
            total_source_count,
            edition_id
        ],
    )? > 0)
}

/// Inserts immutable edition snapshots atomically. Every item must reference
/// this edition and an existing story revision.
#[allow(dead_code)]
pub fn insert_edition_items(
    conn: &Connection,
    edition_id: &str,
    items: &[EditionItem],
) -> Result<(), rusqlite::Error> {
    let tx = conn.unchecked_transaction()?;
    {
        let mut stmt = tx.prepare(
            "INSERT INTO edition_items (
                edition_id, story_id, story_revision_number, position, section,
                snapshot_title, snapshot_summary, snapshot_delta_summary,
                snapshot_source_count, snapshot_reason, is_unique_find,
                lede, is_consumed, consumed_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
        )?;
        for item in items {
            if item.edition_id != edition_id {
                return Err(rusqlite::Error::InvalidParameterName(format!(
                    "edition item {} belongs to {}, expected {}",
                    item.story_id, item.edition_id, edition_id
                )));
            }
            stmt.execute(params![
                item.edition_id,
                item.story_id,
                item.story_revision_number,
                item.position,
                item.section,
                item.snapshot_title,
                item.snapshot_summary,
                item.snapshot_delta_summary,
                item.snapshot_source_count,
                item.snapshot_reason,
                item.is_unique_find as i32,
                item.lede,
                item.is_consumed as i32,
                item.consumed_at,
            ])?;
        }
    }
    tx.commit()?;
    Ok(())
}

/// Store the written lede for one story on the page. Separate from the
/// snapshot fields, which the immutability trigger freezes.
pub fn set_edition_item_lede(
    conn: &Connection,
    edition_id: &str,
    story_id: &str,
    lede: &str,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE edition_items SET lede = ?3 WHERE edition_id = ?1 AND story_id = ?2",
        params![edition_id, story_id, lede],
    )?;
    Ok(())
}

#[allow(dead_code)]
pub fn list_edition_items(
    conn: &Connection,
    edition_id: &str,
) -> Result<Vec<EditionItem>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT edition_id, story_id, story_revision_number, position, section,
                snapshot_title, snapshot_summary, snapshot_delta_summary,
                snapshot_source_count, snapshot_reason, is_unique_find,
                lede, is_consumed, consumed_at
         FROM edition_items
         WHERE edition_id = ?1
         ORDER BY position",
    )?;
    let items = stmt
        .query_map(params![edition_id], |row| {
            Ok(EditionItem {
                edition_id: row.get(0)?,
                story_id: row.get(1)?,
                story_revision_number: row.get(2)?,
                position: row.get(3)?,
                section: row.get(4)?,
                snapshot_title: row.get(5)?,
                snapshot_summary: row.get(6)?,
                snapshot_delta_summary: row.get(7)?,
                snapshot_source_count: row.get(8)?,
                snapshot_reason: row.get(9)?,
                is_unique_find: row.get::<_, i32>(10)? != 0,
                lede: row.get(11)?,
                is_consumed: row.get::<_, i32>(12)? != 0,
                consumed_at: row.get(13)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(items)
}

/// Updates only consumption progress; immutable edition snapshot fields are
/// never rewritten.
#[allow(dead_code)]
pub fn set_edition_item_consumed(
    conn: &Connection,
    edition_id: &str,
    story_id: &str,
    is_consumed: bool,
    consumed_at: Option<i64>,
) -> Result<bool, rusqlite::Error> {
    Ok(conn.execute(
        "UPDATE edition_items
         SET is_consumed = ?1, consumed_at = ?2
         WHERE edition_id = ?3 AND story_id = ?4",
        params![is_consumed as i32, consumed_at, edition_id, story_id],
    )? > 0)
}

#[allow(dead_code)]
pub fn delete_edition(conn: &Connection, edition_id: &str) -> Result<bool, rusqlite::Error> {
    Ok(conn.execute("DELETE FROM editions WHERE id = ?1", params![edition_id])? > 0)
}

// Theme queries
pub fn insert_theme(conn: &Connection, theme: &Theme) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT OR REPLACE INTO themes (id, label, summary, created_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            theme.id,
            theme.label,
            theme.summary,
            theme.created_at,
            theme.expires_at
        ],
    )?;
    Ok(())
}

pub fn insert_theme_article(
    conn: &Connection,
    theme_id: &str,
    article_id: &str,
    relevance: f64,
) -> Result<(), rusqlite::Error> {
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

/// Returns a flat list of (article_id, theme_id, theme_label) so the caller
/// can build an article → themes map without N+1 queries.
pub fn list_article_theme_pairs(
    conn: &Connection,
) -> Result<Vec<(String, String, String)>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT ta.article_id, t.id, t.label
         FROM theme_articles ta
         JOIN themes t ON ta.theme_id = t.id
         WHERE t.expires_at > ?1",
    )?;
    let now = chrono::Utc::now().timestamp();
    let rows = stmt
        .query_map(params![now], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

// Triage queries
pub fn upsert_triage_batch(
    conn: &Connection,
    items: &[ArticleTriage],
) -> Result<(), rusqlite::Error> {
    let tx = conn.unchecked_transaction()?;
    {
        let mut stmt = tx.prepare(
            "INSERT OR REPLACE INTO article_triage (article_id, priority, reason, provider, model, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)"
        )?;
        for item in items {
            stmt.execute(params![
                item.article_id,
                item.priority,
                item.reason,
                item.provider,
                item.model,
                item.created_at,
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
    get_inbox_articles_since(conn, min_priority, is_read, None, limit, offset)
}

/// `get_inbox_articles`, additionally bounded to articles published (or, lacking
/// a publish date, fetched) at or after `published_after` — unix seconds.
pub fn get_inbox_articles_since(
    conn: &Connection,
    min_priority: Option<i32>,
    is_read: Option<bool>,
    published_after: Option<i64>,
    limit: i64,
    offset: i64,
) -> Result<Vec<ArticleWithTriage>, rusqlite::Error> {
    let mut sql = String::from(
        "SELECT a.id, a.feed_id, a.title, a.url, a.author, a.content_html, a.content_text,
                a.published_at, a.fetched_at, a.is_read, a.is_starred, a.feedly_entry_id, a.comments_url,
                f.title as feed_title, f.icon_url as feed_icon_url,
                t.priority, t.reason
         FROM articles a
         JOIN feeds f ON a.feed_id = f.id
         LEFT JOIN article_triage t ON a.id = t.article_id
         WHERE 1=1",
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
    if let Some(cutoff) = published_after {
        param_values.push(Box::new(cutoff));
        sql.push_str(&format!(
            " AND COALESCE(a.published_at, a.fetched_at) >= ?{}",
            param_values.len()
        ));
    }

    // Triaged articles first (sorted by priority desc), untriaged below (by date).
    sql.push_str(
        " ORDER BY CASE WHEN t.priority IS NULL THEN 1 ELSE 0 END,
                   t.priority DESC,
                   COALESCE(a.published_at, a.fetched_at) DESC",
    );
    sql.push_str(&format!(" LIMIT {} OFFSET {}", limit, offset));

    let params_ref: Vec<&dyn rusqlite::types::ToSql> =
        param_values.iter().map(|p| p.as_ref()).collect();
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
                    feedly_entry_id: row.get(11)?,
                    comments_url: row.get(12)?,
                },
                feed_title: row.get(13)?,
                feed_icon_url: row.get(14)?,
                priority: row.get(15)?,
                reason: row.get(16)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub fn get_untriaged_article_ids(
    conn: &Connection,
    limit: i64,
) -> Result<Vec<ArticleWithFeed>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT a.id, a.feed_id, a.title, a.url, a.author, a.content_html, a.content_text,
                a.published_at, a.fetched_at, a.is_read, a.is_starred, a.feedly_entry_id, a.comments_url,
                f.title as feed_title, f.icon_url as feed_icon_url
         FROM articles a
         JOIN feeds f ON a.feed_id = f.id
         LEFT JOIN article_triage t ON a.id = t.article_id
         WHERE a.is_read = 0 AND t.article_id IS NULL
         ORDER BY COALESCE(a.published_at, a.fetched_at) DESC
         LIMIT ?1",
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
                    feedly_entry_id: row.get(11)?,
                    comments_url: row.get(12)?,
                },
                feed_title: row.get(13)?,
                feed_icon_url: row.get(14)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub fn get_triage_stats(conn: &Connection) -> Result<TriageStats, rusqlite::Error> {
    // By-priority breakdown covers triaged + unread articles.
    let mut stmt = conn.prepare(
        "SELECT t.priority, COUNT(*)
         FROM article_triage t
         JOIN articles a ON t.article_id = a.id
         WHERE a.is_read = 0
         GROUP BY t.priority",
    )?;
    let mut by_priority = std::collections::HashMap::new();
    let rows = stmt.query_map([], |row| Ok((row.get::<_, i32>(0)?, row.get::<_, i64>(1)?)))?;
    for row in rows {
        let (priority, count) = row?;
        by_priority.insert(priority, count);
    }

    // Total = all unread articles (triaged + untriaged). The AI Inbox view
    // shows all of them now, so the badge should reflect the full count.
    let total: i64 = conn.query_row(
        "SELECT COUNT(*) FROM articles WHERE is_read = 0",
        [],
        |row| row.get(0),
    )?;

    Ok(TriageStats { total, by_priority })
}

pub fn clear_triage(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute("DELETE FROM article_triage", [])?;
    Ok(())
}

/// Drop triage rows whose reason contains pre-fix hallucinations like
/// "tracked topic", "reader's preference", etc. so they get rescored with
/// the new prompt on the next triage run.
pub fn clear_hallucinated_triage(conn: &Connection) -> Result<i64, rusqlite::Error> {
    let patterns = [
        "%tracked topic%",
        "%reader's preference%",
        "%reader preferences%",
        "%user preference%",
        "%reader's history%",
        "%reader history%",
        "%reader's tracked%",
    ];
    let mut removed = 0i64;
    for p in patterns {
        let n = conn.execute(
            "DELETE FROM article_triage WHERE LOWER(reason) LIKE LOWER(?1)",
            params![p],
        )?;
        removed += n as i64;
    }
    Ok(removed)
}

/// Collect signal titles: starred articles + high-engagement articles.
/// Used by the triage reranker to boost articles similar to what the
/// reader has already shown interest in.
pub fn collect_signal_titles(
    conn: &Connection,
    limit: i64,
) -> Result<Vec<String>, rusqlite::Error> {
    let mut titles = Vec::new();
    // Starred
    {
        let mut stmt = conn.prepare(
            "SELECT title FROM articles WHERE is_starred = 1 ORDER BY fetched_at DESC LIMIT ?1",
        )?;
        let rows = stmt
            .query_map(params![limit], |row| row.get::<_, String>(0))?
            .filter_map(|r| r.ok());
        titles.extend(rows);
    }
    // High-engagement (reading_time or chat)
    {
        let mut stmt = conn.prepare(
            "SELECT a.title FROM article_interactions i
             JOIN articles a ON i.article_id = a.id
             WHERE i.reading_time_sec >= 60 OR i.chat_messages > 0 OR i.feedback = 'more'
             ORDER BY i.updated_at DESC
             LIMIT ?1",
        )?;
        let rows = stmt
            .query_map(params![limit], |row| row.get::<_, String>(0))?
            .filter_map(|r| r.ok());
        titles.extend(rows);
    }
    Ok(titles)
}

/// Update just the priority of a triage row.
pub fn update_triage_priority(
    conn: &Connection,
    article_id: &str,
    priority: i32,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE article_triage SET priority = ?1 WHERE article_id = ?2",
        params![priority, article_id],
    )?;
    Ok(())
}

/// List all currently-triaged unread articles (just id + title + priority)
/// for the reranker.
pub fn list_unread_triaged(
    conn: &Connection,
) -> Result<Vec<(String, String, i32)>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT a.id, a.title, t.priority
         FROM article_triage t
         JOIN articles a ON t.article_id = a.id
         WHERE a.is_read = 0",
    )?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i32>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

// Interaction / learning queries

pub fn record_reading_time(
    conn: &Connection,
    article_id: &str,
    seconds: i64,
    now: i64,
) -> Result<(), rusqlite::Error> {
    let canonical = canonical_interaction_id(conn, article_id)?;
    conn.execute(
        "INSERT INTO article_interactions (article_id, reading_time_sec, chat_messages, updated_at)
         VALUES (?1, ?2, 0, ?3)
         ON CONFLICT(article_id) DO UPDATE SET
           reading_time_sec = reading_time_sec + ?2,
           updated_at = ?3",
        params![canonical, seconds, now],
    )?;
    Ok(())
}

/// Resolve the canonical article_id to attribute an interaction to. If any
/// sibling article (same title + feed_title) already has an interaction row,
/// reuse that one so duplicate feed imports don't mint parallel interactions.
/// Otherwise return the passed id unchanged.
fn canonical_interaction_id(
    conn: &Connection,
    article_id: &str,
) -> Result<String, rusqlite::Error> {
    let existing: Option<String> = conn
        .query_row(
            "SELECT a2.id
             FROM articles a1
             JOIN articles a2 ON LOWER(TRIM(a1.title)) = LOWER(TRIM(a2.title))
             JOIN feeds f1 ON a1.feed_id = f1.id
             JOIN feeds f2 ON a2.feed_id = f2.id
                          AND LOWER(TRIM(f1.title)) = LOWER(TRIM(f2.title))
             JOIN article_interactions i ON i.article_id = a2.id
             WHERE a1.id = ?1
             ORDER BY i.updated_at DESC
             LIMIT 1",
            params![article_id],
            |row| row.get(0),
        )
        .ok();
    Ok(existing.unwrap_or_else(|| article_id.to_string()))
}

/// Delete interaction rows for a "Remove from Recent" click. Removes the row
/// for the clicked article *and* any siblings with the same (title, feed_title)
/// pair — duplicate feed imports produce multiple articles with distinct IDs,
/// so deleting only one row leaves clones that re-surface on re-fetch.
pub fn delete_interaction(conn: &Connection, article_id: &str) -> Result<(), rusqlite::Error> {
    conn.execute(
        "DELETE FROM article_interactions
         WHERE article_id IN (
             SELECT a2.id
             FROM articles a1
             JOIN articles a2 ON LOWER(TRIM(a1.title)) = LOWER(TRIM(a2.title))
             JOIN feeds f1 ON a1.feed_id = f1.id
             JOIN feeds f2 ON a2.feed_id = f2.id
                          AND LOWER(TRIM(f1.title)) = LOWER(TRIM(f2.title))
             WHERE a1.id = ?1
         )",
        params![article_id],
    )?;
    Ok(())
}

/// Delete interaction rows beyond the configured cap, oldest first.
pub fn prune_interactions(conn: &Connection, cap: i64) -> Result<(), rusqlite::Error> {
    if cap <= 0 {
        return Ok(());
    }
    conn.execute(
        "DELETE FROM article_interactions
         WHERE article_id NOT IN (
             SELECT article_id FROM article_interactions
             ORDER BY updated_at DESC
             LIMIT ?1
         )",
        params![cap],
    )?;
    Ok(())
}

/// List articles with material interaction (reading_time >= 10s OR chat
/// messages > 0 OR feedback set). Engagement score = reading + chat*60.
pub fn list_recent_articles(
    conn: &Connection,
    order: &str,
    limit: i64,
) -> Result<Vec<ArticleWithInteraction>, rusqlite::Error> {
    let order_clause = match order {
        "recency" => "i.updated_at DESC",
        _ => "(i.reading_time_sec + i.chat_messages * 60) DESC, i.updated_at DESC",
    };
    let sql = format!(
        "SELECT a.id, a.feed_id, a.title, a.url, a.author, a.content_html, a.content_text,
                a.published_at, a.fetched_at, a.is_read, a.is_starred, a.feedly_entry_id, a.comments_url,
                f.title, f.icon_url,
                i.reading_time_sec, i.chat_messages, i.updated_at
         FROM article_interactions i
         JOIN articles a ON i.article_id = a.id
         JOIN feeds f ON a.feed_id = f.id
         WHERE i.reading_time_sec >= 10
            OR i.chat_messages > 0
            OR i.feedback IS NOT NULL
            OR i.priority_override IS NOT NULL
         ORDER BY {}
         LIMIT ?1",
        order_clause
    );

    let mut stmt = conn.prepare(&sql)?;
    // Pull extra to leave room for dedupe. Cap at 3x to bound work.
    let pull_limit = (limit * 3).min(10_000);
    let rows: Vec<ArticleWithInteraction> = stmt
        .query_map(params![pull_limit], |row| {
            let reading_time_sec: i64 = row.get(15)?;
            let chat_messages: i64 = row.get(16)?;
            let engagement_score = (reading_time_sec as f64) + (chat_messages as f64) * 60.0;
            Ok(ArticleWithInteraction {
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
                    feedly_entry_id: row.get(11)?,
                    comments_url: row.get(12)?,
                },
                feed_title: row.get(13)?,
                feed_icon_url: row.get(14)?,
                reading_time_sec,
                chat_messages,
                interaction_at: row.get(17)?,
                engagement_score,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;

    // Dedupe duplicate articles produced by duplicate feeds / reposts. Primary
    // key is (lowercased title, lowercased feed title) since duplicates often
    // differ on URL (different HN item IDs, tracking params, etc). Also track
    // normalized URL as a secondary key to catch same-URL reposts across feeds.
    // List is already sorted, so first-seen wins.
    let mut seen_title: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut seen_url: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut deduped: Vec<ArticleWithInteraction> = Vec::with_capacity(rows.len());
    for r in rows {
        let title_key = format!(
            "{}|{}",
            r.article.title.trim().to_lowercase(),
            r.feed_title.trim().to_lowercase()
        );
        let url_key = r
            .article
            .url
            .as_deref()
            .map(|u| normalize_for_dedup(u))
            .filter(|s| !s.is_empty());

        if !seen_title.insert(title_key) {
            continue;
        }
        if let Some(uk) = url_key {
            if !seen_url.insert(uk) {
                continue;
            }
        }
        deduped.push(r);
        if deduped.len() as i64 >= limit {
            break;
        }
    }
    Ok(deduped)
}

fn normalize_for_dedup(url: &str) -> String {
    let lower = url.trim().to_lowercase();
    let without_scheme = lower
        .strip_prefix("https://")
        .or_else(|| lower.strip_prefix("http://"))
        .unwrap_or(&lower);
    let without_www = without_scheme
        .strip_prefix("www.")
        .unwrap_or(without_scheme);
    let no_hash = without_www.split('#').next().unwrap_or("");
    // Strip query string entirely for dedup purposes — tracking params vary.
    let no_query = no_hash.split('?').next().unwrap_or("");
    no_query.trim_end_matches('/').to_string()
}

/// Count read articles whose title or content contains the query. Used to
/// offer a "N more matches in read articles" hint on the search bar.
pub fn count_read_matches(conn: &Connection, query: &str) -> Result<i64, rusqlite::Error> {
    let pattern = format!("%{}%", query.to_lowercase());
    conn.query_row(
        "SELECT COUNT(*) FROM articles
         WHERE is_read = 1
           AND (LOWER(title) LIKE ?1 OR LOWER(COALESCE(content_text, '')) LIKE ?1)",
        params![pattern],
        |row| row.get(0),
    )
}

pub fn increment_chat_count(
    conn: &Connection,
    article_id: &str,
    now: i64,
) -> Result<(), rusqlite::Error> {
    let canonical = canonical_interaction_id(conn, article_id)?;
    conn.execute(
        "INSERT INTO article_interactions (article_id, reading_time_sec, chat_messages, updated_at)
         VALUES (?1, 0, 1, ?2)
         ON CONFLICT(article_id) DO UPDATE SET
           chat_messages = chat_messages + 1,
           updated_at = ?2",
        params![canonical, now],
    )?;
    Ok(())
}

pub fn set_article_feedback(
    conn: &Connection,
    article_id: &str,
    feedback: Option<&str>,
    now: i64,
) -> Result<(), rusqlite::Error> {
    let canonical = canonical_interaction_id(conn, article_id)?;
    conn.execute(
        "INSERT INTO article_interactions (article_id, reading_time_sec, chat_messages, feedback, updated_at)
         VALUES (?1, 0, 0, ?2, ?3)
         ON CONFLICT(article_id) DO UPDATE SET
           feedback = ?2,
           updated_at = ?3",
        params![canonical, feedback, now],
    )?;
    Ok(())
}

pub fn set_priority_override(
    conn: &Connection,
    article_id: &str,
    priority: i32,
    now: i64,
) -> Result<(), rusqlite::Error> {
    let canonical = canonical_interaction_id(conn, article_id)?;
    conn.execute(
        "INSERT INTO article_interactions (article_id, reading_time_sec, chat_messages, priority_override, updated_at)
         VALUES (?1, 0, 0, ?2, ?3)
         ON CONFLICT(article_id) DO UPDATE SET
           priority_override = ?2,
           updated_at = ?3",
        params![canonical, priority, now],
    )?;
    Ok(())
}

/// Build a preference profile from interaction history.
/// Returns top feeds, preferred/deprioritized topics extracted from article titles.
pub fn build_preference_profile(
    conn: &Connection,
) -> Result<UserPreferenceProfile, rusqlite::Error> {
    // Top feeds by engagement (reading_time weighted)
    let mut stmt = conn.prepare(
        "SELECT f.title, SUM(i.reading_time_sec) + SUM(i.chat_messages) * 60 as engagement
         FROM article_interactions i
         JOIN articles a ON i.article_id = a.id
         JOIN feeds f ON a.feed_id = f.id
         WHERE i.reading_time_sec > 10 OR i.chat_messages > 0 OR i.feedback = 'more'
         GROUP BY f.id
         ORDER BY engagement DESC
         LIMIT 10",
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
         LIMIT 30",
    )?;
    let preferred_topics: Vec<String> = stmt
        .query_map([], |row| row.get::<_, String>(0))?
        .filter_map(|r| r.ok())
        .collect();

    // Deprioritized: articles with "less" feedback
    let mut stmt = conn.prepare(
        "SELECT a.title
         FROM article_interactions i
         JOIN articles a ON i.article_id = a.id
         WHERE i.feedback = 'less'
         ORDER BY i.updated_at DESC
         LIMIT 20",
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

pub fn get_reader_cache(
    conn: &Connection,
    article_id: &str,
) -> Result<Option<(String, String)>, rusqlite::Error> {
    let mut stmt =
        conn.prepare("SELECT html, raw_html FROM article_reader_cache WHERE article_id = ?1")?;
    let mut rows = stmt.query([article_id])?;
    rows.next()?
        .map(|row| Ok((row.get(0)?, row.get(1)?)))
        .transpose()
}

pub fn put_reader_cache(
    conn: &Connection,
    article_id: &str,
    url: Option<&str>,
    html: &str,
    raw_html: &str,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO article_reader_cache (article_id, url, html, raw_html, cached_at)
         VALUES (?1, ?2, ?3, ?4, strftime('%s','now'))
         ON CONFLICT(article_id) DO UPDATE SET url=excluded.url, html=excluded.html,
           raw_html=excluded.raw_html, cached_at=excluded.cached_at",
        params![article_id, url, html, raw_html],
    )?;
    Ok(())
}

pub fn count_reader_cache(conn: &Connection) -> Result<i64, rusqlite::Error> {
    conn.query_row("SELECT COUNT(*) FROM article_reader_cache", [], |row| {
        row.get(0)
    })
}

pub fn offline_preload_candidates(
    conn: &Connection,
    limit: i64,
) -> Result<Vec<(String, String, Option<String>, Option<String>)>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT id, title, url, content_text FROM articles
         ORDER BY COALESCE(published_at, fetched_at) DESC LIMIT ?1",
    )?;
    let rows = stmt.query_map([limit], |row| {
        Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
    })?;
    rows.collect()
}

#[cfg(test)]
mod story_persistence_tests {
    use super::*;
    use crate::db::migrations;

    fn setup() -> Connection {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        conn.execute_batch("PRAGMA foreign_keys=ON;")
            .expect("enable foreign keys");
        migrations::run_migrations(&conn).expect("run migrations");
        // Running migrations again must be harmless.
        migrations::run_migrations(&conn).expect("rerun migrations");

        insert_feed(
            &conn,
            &Feed {
                id: "feed-1".into(),
                title: "Example".into(),
                url: "https://example.com/feed".into(),
                site_url: Some("https://example.com".into()),
                description: None,
                icon_url: None,
                feedly_id: None,
                created_at: 10,
                updated_at: 10,
                last_fetched_at: None,
                folder_id: None,
                opml_category: None,
            },
        )
        .expect("insert feed");

        for (id, published_at, is_read, is_starred) in [
            ("article-1", 100, false, true),
            ("article-2", 300, true, false),
            ("article-3", 200, false, false),
        ] {
            insert_article(
                &conn,
                &Article {
                    id: id.into(),
                    feed_id: "feed-1".into(),
                    title: format!("Title {id}"),
                    url: Some(format!("https://example.com/{id}")),
                    author: None,
                    content_html: None,
                    content_text: Some(format!("Content {id}")),
                    published_at: Some(published_at),
                    fetched_at: published_at,
                    is_read,
                    is_starred,
                    feedly_entry_id: None,
                    comments_url: None,
                },
            )
            .expect("insert article");
        }
        conn
    }

    fn raw_article_state(conn: &Connection) -> Vec<(String, bool, bool)> {
        get_articles(
            conn,
            &ArticleFilter {
                feed_id: None,
                feed_ids: None,
                search: None,
                theme_id: None,
                is_read: None,
                is_starred: None,
                limit: Some(100),
                published_after: None,
                offset: None,
            },
        )
        .expect("list raw articles")
        .into_iter()
        .map(|row| (row.article.id, row.article.is_read, row.article.is_starred))
        .collect()
    }

    #[test]
    fn published_after_keeps_only_articles_at_or_after_the_cutoff() {
        let conn = setup();

        let recent = get_articles(
            &conn,
            &ArticleFilter {
                published_after: Some(200),
                limit: Some(100),
                ..Default::default()
            },
        )
        .expect("filter by cutoff");

        let mut ids: Vec<String> = recent.into_iter().map(|r| r.article.id).collect();
        ids.sort();
        assert_eq!(ids, vec!["article-2", "article-3"]);
    }

    #[test]
    fn inbox_cutoff_and_priority_narrow_independently() {
        let conn = setup();
        let now = 1_000;
        for (article_id, priority) in [("article-1", 5), ("article-3", 2)] {
            conn.execute(
                "INSERT INTO article_triage (article_id, priority, reason, created_at)
                 VALUES (?1, ?2, 'because', ?3)",
                rusqlite::params![article_id, priority, now],
            )
            .expect("insert triage");
        }

        // article-1 is unread and priority 5, but published at 100.
        let high = get_inbox_articles_since(&conn, Some(4), Some(false), None, 100, 0)
            .expect("high priority");
        assert_eq!(
            high.iter().map(|a| a.article.id.as_str()).collect::<Vec<_>>(),
            vec!["article-1"]
        );

        // The same scope, bounded to articles from 150 onwards, drops it.
        let high_and_recent = get_inbox_articles_since(&conn, Some(4), Some(false), Some(150), 100, 0)
            .expect("high priority, recent");
        assert!(high_and_recent.is_empty());
    }

    #[test]
    fn article_filter_feed_ids_supports_empty_and_multiple_feeds() {
        let conn = setup();
        insert_feed(
            &conn,
            &Feed {
                id: "feed-2".into(),
                title: "Second".into(),
                url: "https://second.example/feed".into(),
                site_url: None,
                description: None,
                icon_url: None,
                feedly_id: None,
                created_at: 11,
                updated_at: 11,
                last_fetched_at: None,
                folder_id: None,
                opml_category: None,
            },
        )
        .expect("insert second feed");
        insert_article(
            &conn,
            &Article {
                id: "article-4".into(),
                feed_id: "feed-2".into(),
                title: "Second feed article".into(),
                url: Some("https://second.example/article".into()),
                author: None,
                content_html: None,
                content_text: Some("Second content".into()),
                published_at: Some(400),
                fetched_at: 400,
                is_read: false,
                is_starred: false,
                feedly_entry_id: None,
                comments_url: None,
            },
        )
        .expect("insert second article");

        let empty = get_articles(
            &conn,
            &ArticleFilter {
                feed_id: None,
                feed_ids: Some(vec![]),
                search: None,
                theme_id: None,
                is_read: None,
                is_starred: None,
                limit: Some(100),
                published_after: None,
                offset: None,
            },
        )
        .expect("query empty folder");
        assert!(empty.is_empty());

        let multiple = get_articles(
            &conn,
            &ArticleFilter {
                feed_id: None,
                feed_ids: Some(vec!["feed-1".into(), "feed-2".into()]),
                search: None,
                theme_id: None,
                is_read: None,
                is_starred: None,
                limit: Some(100),
                published_after: None,
                offset: None,
            },
        )
        .expect("query multiple folder feeds");
        assert_eq!(multiple.len(), 4);
        assert!(multiple.iter().all(|article| {
            article.article.feed_id == "feed-1" || article.article.feed_id == "feed-2"
        }));
    }

    #[test]
    fn article_comments_url_survives_migration_and_roundtrip() {
        let conn = setup();
        let mut article = get_article_by_id(&conn, "article-1").unwrap().unwrap().article;
        article.comments_url = Some("https://news.ycombinator.com/item?id=123".into());
        conn.execute("DELETE FROM articles WHERE id = ?1", [&article.id]).unwrap();
        insert_article(&conn, &article).expect("insert article with discussion URL");
        let loaded = get_article_by_id(&conn, &article.id).unwrap().unwrap();
        assert_eq!(loaded.article.url.as_deref(), Some("https://example.com/article-1"));
        assert_eq!(loaded.article.comments_url.as_deref(), Some("https://news.ycombinator.com/item?id=123"));
    }

    #[test]
    fn convert_folder_in_place_roundtrips_identity_and_membership_atomically() {
        let conn = setup();
        let folder = Folder {
            id: "folder-1".into(),
            name: "Saved feeds".into(),
            sort_order: 7,
            is_smart: false,
            rules_json: None,
            created_at: 42,
        };
        insert_folder(&conn, &folder).expect("insert folder");
        assign_feed_to_folder(&conn, "feed-1", Some(&folder.id)).expect("assign feed");
        let rules_json = r#"{"mode":"any","rules":[{"type":"regex_title","pattern":"Example"}]}"#;

        convert_folder_in_place(
            &conn,
            &folder.id,
            true,
            Some(rules_json),
            Some("Smart saved feeds"),
            &[],
        )
        .expect("convert to smart");
        let smart = list_folders(&conn).expect("list smart folder").remove(0);
        assert_eq!((smart.id.as_str(), smart.name.as_str(), smart.sort_order), ("folder-1", "Smart saved feeds", 7));
        assert!(smart.is_smart);
        assert_eq!(get_feed_by_id(&conn, "feed-1").unwrap().unwrap().folder_id, None);

        convert_folder_in_place(
            &conn,
            &folder.id,
            false,
            None,
            Some("Regular saved feeds"),
            &["feed-1".into()],
        )
        .expect("convert to regular");
        let regular = list_folders(&conn).expect("list regular folder").remove(0);
        assert_eq!((regular.id.as_str(), regular.name.as_str(), regular.sort_order), ("folder-1", "Regular saved feeds", 7));
        assert!(!regular.is_smart);
        assert_eq!(get_feed_by_id(&conn, "feed-1").unwrap().unwrap().folder_id.as_deref(), Some("folder-1"));
    }

    fn story_fixture() -> Story {
        Story {
            id: "story-stable-1".into(),
            title: "Stable story".into(),
            summary: Some("Current summary".into()),
            representative_article_id: Some("article-2".into()),
            first_seen_at: 100,
            last_activity_at: 300,
            created_at: 310,
            updated_at: 310,
        }
    }

    fn revision_fixture(number: i64) -> StoryRevision {
        StoryRevision {
            story_id: "story-stable-1".into(),
            revision_number: number,
            title: format!("Revision {number}"),
            summary: format!("Summary {number}"),
            delta_summary: (number > 1).then(|| "New confirmed facts".into()),
            representative_article_id: Some("article-2".into()),
            source_count: number + 1,
            content_fingerprint: Some(format!("fingerprint-{number}")),
            is_material_change: number > 1,
            created_at: 310 + number,
        }
    }

    #[test]
    fn story_and_edition_crud_preserve_the_raw_feed() {
        let conn = setup();
        let raw_before = raw_article_state(&conn);
        assert_eq!(
            raw_before,
            vec![
                ("article-2".into(), true, false),
                ("article-3".into(), false, false),
                ("article-1".into(), false, true),
            ]
        );

        let mut story = story_fixture();
        upsert_story(&conn, &story).expect("insert story");
        story.title = "Stable story, updated title".into();
        story.first_seen_at = 200;
        story.last_activity_at = 400;
        story.updated_at = 400;
        upsert_story(&conn, &story).expect("update story");
        let stored_story = get_story(&conn, &story.id)
            .expect("get story")
            .expect("story exists");
        assert_eq!(stored_story.id, "story-stable-1");
        assert_eq!(stored_story.first_seen_at, 100);
        assert_eq!(stored_story.last_activity_at, 400);
        assert_eq!(
            list_recent_stories(&conn, 350, 10)
                .expect("rolling-window stories")
                .len(),
            1
        );

        for membership in [
            StoryArticle {
                story_id: story.id.clone(),
                article_id: "article-1".into(),
                membership_type: StoryMembershipType::Duplicate,
                confidence: Some(0.99),
                added_at: 320,
            },
            StoryArticle {
                story_id: story.id.clone(),
                article_id: "article-2".into(),
                membership_type: StoryMembershipType::Coverage,
                confidence: Some(0.85),
                added_at: 321,
            },
            StoryArticle {
                story_id: story.id.clone(),
                article_id: "article-3".into(),
                membership_type: StoryMembershipType::Update,
                confidence: None,
                added_at: 322,
            },
        ] {
            upsert_story_article(&conn, &membership).expect("upsert membership");
        }
        let members = list_story_articles(&conn, &story.id).expect("list story members");
        assert_eq!(members.len(), 3);
        assert_eq!(members[0].membership_type, StoryMembershipType::Update);

        insert_story_revision(&conn, &revision_fixture(1)).expect("insert first revision");
        insert_story_revision(&conn, &revision_fixture(2)).expect("insert second revision");
        assert!(insert_story_revision(&conn, &revision_fixture(2)).is_err());
        assert!(conn
            .execute(
                "UPDATE story_revisions SET summary = 'rewritten'
                 WHERE story_id = ?1 AND revision_number = 1",
                params![story.id],
            )
            .is_err());
        assert_eq!(
            get_story_revision(&conn, &story.id, 1)
                .expect("get first revision")
                .expect("revision exists")
                .revision_number,
            1
        );
        let latest = get_latest_story_revision(&conn, &story.id)
            .expect("latest revision")
            .expect("revision exists");
        assert_eq!(latest.revision_number, 2);
        assert_eq!(latest.content_fingerprint.as_deref(), Some("fingerprint-2"));
        assert!(latest.is_material_change);

        upsert_story_user_state(
            &conn,
            &StoryUserState {
                story_id: story.id.clone(),
                last_seen_revision: Some(2),
                last_read_revision: Some(1),
                is_followed: true,
                caught_up_at: Some(500),
                updated_at: 500,
            },
        )
        .expect("upsert story state");
        let state = get_story_user_state(&conn, &story.id)
            .expect("get story state")
            .expect("state exists");
        assert_eq!(state.last_seen_revision, Some(2));
        assert_eq!(state.last_read_revision, Some(1));
        assert!(state.is_followed);

        let edition = Edition {
            id: "edition-1".into(),
            title: "Today".into(),
            scope: "all".into(),
            story_limit: 10,
            status: EditionStatus::Ready,
            starts_at: 400,
            ends_at: 1_000,
            generated_at: 450,
            completed_at: None,
            total_source_count: 3,
        };
        insert_edition(&conn, &edition).expect("insert edition");
        let item = EditionItem {
            edition_id: edition.id.clone(),
            story_id: story.id.clone(),
            story_revision_number: 2,
            position: 0,
            section: "top_stories".into(),
            snapshot_title: "Frozen title".into(),
            snapshot_summary: "Frozen summary".into(),
            snapshot_delta_summary: Some("Frozen delta".into()),
            snapshot_source_count: 3,
            snapshot_reason: Some("Widely covered".into()),
            is_unique_find: false,
            lede: None,
            is_consumed: false,
            consumed_at: None,
        };
        insert_edition_items(&conn, &edition.id, &[item]).expect("insert edition items");
        assert!(conn
            .execute(
                "UPDATE edition_items SET snapshot_title = 'rewritten'
                 WHERE edition_id = ?1 AND story_id = ?2",
                params![edition.id, story.id],
            )
            .is_err());
        assert!(insert_edition_items(
            &conn,
            &edition.id,
            &[EditionItem {
                snapshot_title: "Attempted overwrite".into(),
                ..list_edition_items(&conn, &edition.id)
                    .expect("load item")
                    .remove(0)
            }]
        )
        .is_err());

        let current = get_current_edition(&conn, "all", 500)
            .expect("current edition")
            .expect("edition exists");
        assert_eq!(current.id, edition.id);
        assert!(
            set_edition_item_consumed(&conn, &edition.id, &story.id, true, Some(550))
                .expect("mark item consumed")
        );
        let consumed = list_edition_items(&conn, &edition.id)
            .expect("list edition items")
            .remove(0);
        assert_eq!(consumed.snapshot_title, "Frozen title");
        assert!(consumed.is_consumed);
        assert_eq!(consumed.consumed_at, Some(550));

        assert!(update_edition_progress(
            &conn,
            &edition.id,
            EditionStatus::Completed,
            Some(600),
            3
        )
        .expect("complete edition"));
        let completed = get_edition(&conn, &edition.id)
            .expect("get edition")
            .expect("edition exists");
        assert_eq!(completed.status, EditionStatus::Completed);
        assert_eq!(completed.completed_at, Some(600));

        assert!(
            delete_story_article(&conn, &story.id, "article-1").expect("delete story membership")
        );
        assert!(delete_edition(&conn, &edition.id).expect("delete edition"));
        assert!(delete_story(&conn, &story.id).expect("delete story"));
        assert_eq!(raw_article_state(&conn), raw_before);
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM articles", [], |row| row
                .get::<_, i64>(0))
                .expect("count articles"),
            3
        );
    }

    #[test]
    fn deleting_representative_feed_nulls_revision_reference() {
        let conn = setup();
        let story = story_fixture();
        upsert_story(&conn, &story).expect("insert story");
        insert_story_revision(&conn, &revision_fixture(1)).expect("insert revision");

        delete_feed(&conn, "feed-1").expect("delete representative feed");

        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM articles", [], |row| row
                .get::<_, i64>(0))
                .expect("count remaining articles"),
            0
        );
        assert_eq!(
            get_story(&conn, &story.id)
                .expect("get story")
                .expect("story survives")
                .representative_article_id,
            None
        );
        let revision = get_story_revision(&conn, &story.id, 1)
            .expect("get revision")
            .expect("revision survives");
        assert_eq!(revision.representative_article_id, None);
        assert_eq!(revision.summary, "Summary 1");
    }

    #[test]
    fn story_schema_rejects_invalid_domain_values() {
        let conn = setup();
        let story = story_fixture();
        upsert_story(&conn, &story).expect("insert story");
        insert_story_revision(&conn, &revision_fixture(1)).expect("insert revision");

        assert!(conn
            .execute(
                "INSERT INTO story_articles
                    (story_id, article_id, membership_type, confidence, added_at)
                 VALUES (?1, ?2, 'representative', 0.9, 1)",
                params![story.id, "article-1"],
            )
            .is_err());
        assert!(conn
            .execute(
                "INSERT INTO story_articles
                    (story_id, article_id, membership_type, confidence, added_at)
                 VALUES (?1, ?2, 'coverage', 1.1, 1)",
                params![story.id, "article-1"],
            )
            .is_err());
        assert!(conn
            .execute(
                "INSERT INTO editions (
                    id, title, scope, story_limit, status, starts_at, ends_at,
                    generated_at, total_source_count
                 ) VALUES ('bad-edition', 'Bad', 'all', 10, 'unknown', 1, 2, 1, 1)",
                [],
            )
            .is_err());
        assert!(upsert_story_user_state(
            &conn,
            &StoryUserState {
                story_id: story.id,
                last_seen_revision: Some(99),
                last_read_revision: None,
                is_followed: false,
                caught_up_at: None,
                updated_at: 1,
            }
        )
        .is_err());
    }
}
