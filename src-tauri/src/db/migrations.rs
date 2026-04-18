use rusqlite::Connection;

pub fn run_migrations(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS feeds (
            id          TEXT PRIMARY KEY,
            title       TEXT NOT NULL,
            url         TEXT NOT NULL UNIQUE,
            site_url    TEXT,
            description TEXT,
            icon_url    TEXT,
            feedly_id   TEXT,
            created_at  INTEGER NOT NULL,
            updated_at  INTEGER NOT NULL,
            last_fetched_at INTEGER
        );

        CREATE TABLE IF NOT EXISTS articles (
            id           TEXT PRIMARY KEY,
            feed_id      TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
            title        TEXT NOT NULL,
            url          TEXT,
            author       TEXT,
            content_html TEXT,
            content_text TEXT,
            published_at INTEGER,
            fetched_at   INTEGER NOT NULL,
            is_read      INTEGER NOT NULL DEFAULT 0,
            is_starred   INTEGER NOT NULL DEFAULT 0,
            UNIQUE(feed_id, url)
        );

        CREATE INDEX IF NOT EXISTS idx_articles_feed_id ON articles(feed_id);
        CREATE INDEX IF NOT EXISTS idx_articles_published_at ON articles(published_at);
        CREATE INDEX IF NOT EXISTS idx_articles_is_read ON articles(is_read);

        CREATE TABLE IF NOT EXISTS themes (
            id          TEXT PRIMARY KEY,
            label       TEXT NOT NULL,
            summary     TEXT,
            created_at  INTEGER NOT NULL,
            expires_at  INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS theme_articles (
            theme_id    TEXT NOT NULL REFERENCES themes(id) ON DELETE CASCADE,
            article_id  TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
            relevance   REAL,
            PRIMARY KEY (theme_id, article_id)
        );

        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS article_triage (
            article_id  TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
            priority    INTEGER NOT NULL,
            reason      TEXT NOT NULL,
            provider    TEXT,
            model       TEXT,
            created_at  INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_triage_priority ON article_triage(priority DESC);

        -- Learning system: track user engagement signals
        CREATE TABLE IF NOT EXISTS article_interactions (
            article_id       TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
            reading_time_sec INTEGER NOT NULL DEFAULT 0,
            chat_messages    INTEGER NOT NULL DEFAULT 0,
            feedback         TEXT,   -- 'more' | 'less' | NULL
            priority_override INTEGER,  -- user-corrected priority (1-5) or NULL
            updated_at       INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_interactions_feedback ON article_interactions(feedback);
        CREATE INDEX IF NOT EXISTS idx_interactions_reading ON article_interactions(reading_time_sec);
        ",
    )?;

    // Add feedly_entry_id column to articles (idempotent)
    let has_feedly_entry_id: bool = conn
        .prepare("PRAGMA table_info(articles)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .filter_map(|r| r.ok())
        .any(|name| name == "feedly_entry_id");

    if !has_feedly_entry_id {
        conn.execute_batch(
            "ALTER TABLE articles ADD COLUMN feedly_entry_id TEXT;
             CREATE INDEX IF NOT EXISTS idx_articles_feedly_entry_id ON articles(feedly_entry_id);",
        )?;
    }

    // Backfill missing feed icons using Google's favicon service
    backfill_feed_icons(conn)?;

    Ok(())
}

fn backfill_feed_icons(conn: &Connection) -> Result<(), rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT id, site_url, url FROM feeds WHERE icon_url IS NULL OR icon_url = ''",
    )?;
    let rows: Vec<(String, Option<String>, String)> = stmt
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
        .filter_map(|r| r.ok())
        .collect();

    for (id, site_url, feed_url) in rows {
        let source = site_url.as_deref().unwrap_or(&feed_url);
        if let Some(icon) = crate::feed::fetcher::favicon_url(source) {
            conn.execute(
                "UPDATE feeds SET icon_url = ?1 WHERE id = ?2",
                rusqlite::params![icon, id],
            )?;
        }
    }

    Ok(())
}
