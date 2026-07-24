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

        CREATE TABLE IF NOT EXISTS article_summaries (
            article_id     TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
            cache_key      TEXT NOT NULL,
            bullet_summary TEXT,
            full_summary   TEXT,
            provider       TEXT,
            model          TEXT,
            created_at     INTEGER NOT NULL,
            PRIMARY KEY (article_id, cache_key)
        );

        CREATE INDEX IF NOT EXISTS idx_article_summaries_created_at ON article_summaries(created_at);

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

        -- Durable story layer. Articles remain the source-of-truth feed rows;
        -- these tables add stable clustering, revision, and edition identity.
        -- All timestamps are caller-supplied Unix epoch seconds in UTC.
        CREATE TABLE IF NOT EXISTS stories (
            id                        TEXT PRIMARY KEY,
            title                     TEXT NOT NULL,
            summary                   TEXT,
            representative_article_id TEXT REFERENCES articles(id) ON DELETE SET NULL,
            first_seen_at             INTEGER NOT NULL,
            last_activity_at          INTEGER NOT NULL,
            created_at                INTEGER NOT NULL,
            updated_at                INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_stories_last_activity
            ON stories(last_activity_at DESC);

        CREATE TABLE IF NOT EXISTS story_articles (
            story_id       TEXT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
            article_id     TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
            membership_type TEXT NOT NULL
                CHECK (membership_type IN ('duplicate', 'coverage', 'update')),
            confidence     REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
            added_at       INTEGER NOT NULL,
            PRIMARY KEY (story_id, article_id),
            UNIQUE (article_id)
        );

        CREATE INDEX IF NOT EXISTS idx_story_articles_story_added
            ON story_articles(story_id, added_at DESC);

        -- Offline lexical features are cached separately so incremental
        -- clustering never rewrites or filters the raw article feed.
        CREATE TABLE IF NOT EXISTS article_story_features (
            article_id        TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
            canonical_url     TEXT,
            normalized_title  TEXT NOT NULL,
            normalized_lead   TEXT NOT NULL,
            tokens_json       TEXT NOT NULL,
            entities_json     TEXT NOT NULL,
            content_hash      TEXT NOT NULL,
            feature_version   INTEGER NOT NULL,
            computed_at       INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_story_features_url
            ON article_story_features(canonical_url);
        CREATE INDEX IF NOT EXISTS idx_story_features_title
            ON article_story_features(normalized_title);

        CREATE TABLE IF NOT EXISTS story_borderline_matches (
            article_id         TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
            candidate_story_id TEXT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
            confidence         REAL NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
            feature_version    INTEGER NOT NULL,
            created_at         INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_story_borderlines_candidate
            ON story_borderline_matches(candidate_story_id, confidence DESC);

        CREATE TABLE IF NOT EXISTS story_revisions (
            story_id                 TEXT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
            revision_number          INTEGER NOT NULL CHECK (revision_number > 0),
            title                    TEXT NOT NULL,
            summary                  TEXT NOT NULL,
            delta_summary            TEXT,
            representative_article_id TEXT REFERENCES articles(id) ON DELETE SET NULL,
            source_count             INTEGER NOT NULL DEFAULT 1 CHECK (source_count >= 1),
            content_fingerprint       TEXT,
            is_material_change        INTEGER NOT NULL DEFAULT 1
                CHECK (is_material_change IN (0, 1)),
            created_at               INTEGER NOT NULL,
            PRIMARY KEY (story_id, revision_number)
        );

        CREATE INDEX IF NOT EXISTS idx_story_revisions_created
            ON story_revisions(story_id, created_at DESC);

        CREATE TABLE IF NOT EXISTS story_user_state (
            story_id                 TEXT PRIMARY KEY REFERENCES stories(id) ON DELETE CASCADE,
            last_seen_revision       INTEGER CHECK (last_seen_revision IS NULL OR last_seen_revision > 0),
            last_read_revision       INTEGER CHECK (last_read_revision IS NULL OR last_read_revision > 0),
            is_followed              INTEGER NOT NULL DEFAULT 0 CHECK (is_followed IN (0, 1)),
            is_hidden                INTEGER NOT NULL DEFAULT 0 CHECK (is_hidden IN (0, 1)),
            caught_up_at             INTEGER,
            updated_at               INTEGER NOT NULL,
            FOREIGN KEY (story_id, last_seen_revision)
                REFERENCES story_revisions(story_id, revision_number),
            FOREIGN KEY (story_id, last_read_revision)
                REFERENCES story_revisions(story_id, revision_number)
        );

        CREATE TABLE IF NOT EXISTS editions (
            id                 TEXT PRIMARY KEY,
            title              TEXT NOT NULL,
            scope              TEXT NOT NULL,
            story_limit        INTEGER NOT NULL CHECK (story_limit > 0),
            status             TEXT NOT NULL
                CHECK (status IN ('draft', 'ready', 'completed', 'failed')),
            starts_at          INTEGER NOT NULL,
            ends_at            INTEGER NOT NULL CHECK (ends_at > starts_at),
            generated_at       INTEGER NOT NULL,
            completed_at       INTEGER,
            total_source_count INTEGER NOT NULL DEFAULT 1 CHECK (total_source_count >= 1)
        );

        CREATE INDEX IF NOT EXISTS idx_editions_current
            ON editions(scope, starts_at, ends_at, status, generated_at DESC);

        CREATE TABLE IF NOT EXISTS edition_items (
            edition_id                 TEXT NOT NULL REFERENCES editions(id) ON DELETE CASCADE,
            story_id                   TEXT NOT NULL REFERENCES stories(id) ON DELETE RESTRICT,
            story_revision_number      INTEGER NOT NULL,
            position                   INTEGER NOT NULL CHECK (position >= 0),
            section                    TEXT NOT NULL,
            snapshot_title             TEXT NOT NULL,
            snapshot_summary           TEXT NOT NULL,
            snapshot_delta_summary     TEXT,
            snapshot_source_count      INTEGER NOT NULL CHECK (snapshot_source_count >= 1),
            snapshot_reason            TEXT,
            is_unique_find             INTEGER NOT NULL DEFAULT 0 CHECK (is_unique_find IN (0, 1)),
            is_consumed                INTEGER NOT NULL DEFAULT 0 CHECK (is_consumed IN (0, 1)),
            consumed_at                INTEGER,
            PRIMARY KEY (edition_id, story_id),
            UNIQUE (edition_id, position),
            FOREIGN KEY (story_id, story_revision_number)
                REFERENCES story_revisions(story_id, revision_number) ON DELETE RESTRICT
        );

        CREATE INDEX IF NOT EXISTS idx_edition_items_order
            ON edition_items(edition_id, position);
        CREATE INDEX IF NOT EXISTS idx_edition_items_story
            ON edition_items(story_id);

        DROP TRIGGER IF EXISTS trg_story_revisions_immutable;
        CREATE TRIGGER trg_story_revisions_immutable
        BEFORE UPDATE ON story_revisions
        WHEN NOT (
            OLD.representative_article_id IS NOT NULL
            AND NEW.representative_article_id IS NULL
            AND NEW.story_id IS OLD.story_id
            AND NEW.revision_number IS OLD.revision_number
            AND NEW.title IS OLD.title
            AND NEW.summary IS OLD.summary
            AND NEW.delta_summary IS OLD.delta_summary
            AND NEW.source_count IS OLD.source_count
            AND NEW.content_fingerprint IS OLD.content_fingerprint
            AND NEW.is_material_change IS OLD.is_material_change
            AND NEW.created_at IS OLD.created_at
        )
        BEGIN
            SELECT RAISE(ABORT, 'story revisions are immutable');
        END;

        CREATE TRIGGER IF NOT EXISTS trg_edition_snapshot_immutable
        BEFORE UPDATE OF
            edition_id, story_id, story_revision_number, position, section,
            snapshot_title, snapshot_summary, snapshot_delta_summary,
            snapshot_source_count, snapshot_reason, is_unique_find
        ON edition_items
        BEGIN
            SELECT RAISE(ABORT, 'edition snapshot fields are immutable');
        END;
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

    // Folders (manual + smart)
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS folders (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            sort_order  INTEGER NOT NULL DEFAULT 0,
            is_smart    INTEGER NOT NULL DEFAULT 0,
            rules_json  TEXT,
            created_at  INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_folders_sort_order ON folders(sort_order);",
    )?;

    // Add folder_id + opml_category columns to feeds (idempotent)
    let feed_cols: Vec<String> = conn
        .prepare("PRAGMA table_info(feeds)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .filter_map(|r| r.ok())
        .collect();

    if !feed_cols.iter().any(|c| c == "folder_id") {
        conn.execute(
            "ALTER TABLE feeds ADD COLUMN folder_id TEXT REFERENCES folders(id) ON DELETE SET NULL",
            [],
        )?;
        conn.execute_batch("CREATE INDEX IF NOT EXISTS idx_feeds_folder_id ON feeds(folder_id);")?;
    }
    if !feed_cols.iter().any(|c| c == "opml_category") {
        conn.execute("ALTER TABLE feeds ADD COLUMN opml_category TEXT", [])?;
    }

    // Backfill missing feed icons using Google's favicon service
    backfill_feed_icons(conn)?;

    // One-time: collapse duplicate article_interactions rows produced by
    // duplicate feed imports (same title + feed_title, distinct article IDs).
    consolidate_duplicate_interactions(conn)?;

    Ok(())
}

/// Merge interaction rows for sibling articles (same title + feed_title) onto
/// the oldest-updated row and delete the others. Needed because past writes
/// minted parallel rows before canonical resolution was added.
fn consolidate_duplicate_interactions(conn: &Connection) -> Result<(), rusqlite::Error> {
    // Find (title_lower, feed_title_lower) groups with 2+ interaction rows.
    let mut stmt = conn.prepare(
        "SELECT LOWER(TRIM(a.title)), LOWER(TRIM(f.title))
         FROM article_interactions i
         JOIN articles a ON a.id = i.article_id
         JOIN feeds f ON f.id = a.feed_id
         GROUP BY LOWER(TRIM(a.title)), LOWER(TRIM(f.title))
         HAVING COUNT(*) > 1",
    )?;
    let groups: Vec<(String, String)> = stmt
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
        .filter_map(|r| r.ok())
        .collect();
    drop(stmt);

    for (title, feed_title) in groups {
        // Pull all rows in this dup group with their stats.
        let mut s = conn.prepare(
            "SELECT i.article_id, i.reading_time_sec, i.chat_messages,
                    i.feedback, i.priority_override, i.updated_at
             FROM article_interactions i
             JOIN articles a ON a.id = i.article_id
             JOIN feeds f ON f.id = a.feed_id
             WHERE LOWER(TRIM(a.title)) = ?1 AND LOWER(TRIM(f.title)) = ?2",
        )?;
        let rows: Vec<(String, i64, i64, Option<String>, Option<i32>, i64)> = s
            .query_map(rusqlite::params![title, feed_title], |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            })?
            .filter_map(|r| r.ok())
            .collect();
        drop(s);

        if rows.len() < 2 {
            continue;
        }

        // Canonical = most recently updated.
        let canonical = rows
            .iter()
            .max_by_key(|r| r.5)
            .expect("non-empty")
            .0
            .clone();
        let total_reading: i64 = rows.iter().map(|r| r.1).sum();
        let total_chat: i64 = rows.iter().map(|r| r.2).sum();
        let feedback: Option<String> = rows.iter().find_map(|r| r.3.clone());
        let priority: Option<i32> = rows.iter().find_map(|r| r.4);
        let updated_at: i64 = rows.iter().map(|r| r.5).max().unwrap_or(0);

        conn.execute(
            "DELETE FROM article_interactions WHERE article_id IN (
                SELECT i.article_id
                FROM article_interactions i
                JOIN articles a ON a.id = i.article_id
                JOIN feeds f ON f.id = a.feed_id
                WHERE LOWER(TRIM(a.title)) = ?1 AND LOWER(TRIM(f.title)) = ?2
                  AND i.article_id != ?3
            )",
            rusqlite::params![title, feed_title, canonical],
        )?;
        conn.execute(
            "UPDATE article_interactions
             SET reading_time_sec = ?1,
                 chat_messages = ?2,
                 feedback = ?3,
                 priority_override = ?4,
                 updated_at = ?5
             WHERE article_id = ?6",
            rusqlite::params![
                total_reading,
                total_chat,
                feedback,
                priority,
                updated_at,
                canonical
            ],
        )?;
    }
    Ok(())
}

fn backfill_feed_icons(conn: &Connection) -> Result<(), rusqlite::Error> {
    let mut stmt = conn
        .prepare("SELECT id, site_url, url FROM feeds WHERE icon_url IS NULL OR icon_url = ''")?;
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

    #[cfg(target_os = "ios")]
    {
        // Migrate desktop-only AI providers to claude-subscription on iOS.
        for stale in ["claude-cli", "local", "ollama"] {
            let pat = format!("\"provider\":\"{}\"", stale);
            let _ = conn.execute(
                "UPDATE settings SET value = replace(value, ?1, '\"provider\":\"claude-subscription\"') WHERE key='app_settings' AND value LIKE '%' || ?1 || '%'",
                rusqlite::params![pat],
            );
        }
    }

    Ok(())
}
