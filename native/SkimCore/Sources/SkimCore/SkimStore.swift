import Foundation
import SQLite3

public actor SkimStore: FeedStore, ArticleStore, SettingsStore, FolderStore {
    private let db: SQLiteDatabase

    public init(databaseURL: URL) throws {
        self.db = try SQLiteDatabase(url: databaseURL)
        try db.migrate()
    }

    public func listFolders() async throws -> [FeedFolder] {
        try db.listFolders()
    }

    public func upsertFolder(_ folder: FeedFolder) async throws {
        try db.upsertFolder(folder)
    }

    public func deleteFolder(id: String) async throws {
        try db.execute("UPDATE feeds SET folder_id = NULL WHERE folder_id = ?", [.text(id)])
        try db.execute("DELETE FROM folders WHERE id = ?", [.text(id)])
    }

    public func setFeedFolder(feedID: String, folderID: String?) async throws {
        if let folderID {
            try db.execute("UPDATE feeds SET folder_id = ? WHERE id = ?", [.text(folderID), .text(feedID)])
        } else {
            try db.execute("UPDATE feeds SET folder_id = NULL WHERE id = ?", [.text(feedID)])
        }
    }

    public func listFeeds() async throws -> [Feed] {
        try db.listFeeds()
    }

    public func importFeeds(_ feeds: [ImportedFeed]) async throws {
        try db.transaction {
            for imported in feeds {
                let feed = Feed(
                    id: stableID(prefix: "feed", value: imported.xmlURL.absoluteString),
                    title: imported.title,
                    url: imported.xmlURL,
                    siteURL: imported.htmlURL
                )
                try db.upsertFeed(feed)
            }
        }
    }

    public func upsert(feed: Feed, articles: [Article]) async throws {
        try db.transaction {
            try db.upsertFeed(feed)
            for article in articles {
                try db.upsertArticle(article)
            }
        }
    }

    public func listArticles(filter: ArticleFilter) async throws -> [Article] {
        try db.listArticles(filter: filter)
    }

    public func countUnread(feedID: String?) async throws -> Int {
        try db.countUnread(feedID: feedID)
    }

    public func article(id: String) async throws -> Article {
        guard let article = try db.article(id: id) else {
            throw SkimCoreError.articleNotFound
        }
        return article
    }

    public func setArticleRead(id: String, isRead: Bool) async throws {
        try db.execute("UPDATE articles SET is_read = ? WHERE id = ?", [.bool(isRead), .text(id)])
    }

    public func toggleStar(id: String) async throws {
        try db.execute("UPDATE articles SET is_starred = CASE is_starred WHEN 0 THEN 1 ELSE 0 END WHERE id = ?", [.text(id)])
    }

    public func cachedReaderText(articleID: String) async throws -> String? {
        try db.cachedReaderText(articleID: articleID)
    }

    public func cacheReaderText(articleID: String, url: URL?, text: String) async throws {
        try db.cacheReaderText(articleID: articleID, url: url, text: text, cachedAt: Date())
    }

    public func countCachedReaderTexts() async throws -> Int {
        try db.countCachedReaderTexts()
    }

    public func loadSettings() async throws -> AppSettings {
        guard let json = try db.setting(key: "app_settings"), let data = json.data(using: .utf8) else {
            return AppSettings()
        }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func saveSettings(_ settings: AppSettings) async throws {
        let data = try JSONEncoder().encode(settings)
        let value = String(decoding: data, as: UTF8.self)
        try db.setSetting(key: "app_settings", value: value)
    }

    public func upsertStory(_ story: Story) async throws {
        try db.upsertStory(story)
    }

    public func story(id: String) async throws -> Story? {
        try db.story(id: id)
    }

    public func listStories(limit: Int = 100) async throws -> [Story] {
        try db.listStories(limit: limit)
    }

    public func deleteStory(id: String) async throws {
        try db.execute("DELETE FROM stories WHERE id = ?", [.text(id)])
    }

    public func upsertStoryMembership(_ membership: StoryArticleMembership) async throws {
        try db.upsertStoryMembership(membership)
    }

    public func storyMembership(articleID: String) async throws -> StoryArticleMembership? {
        try db.storyMembership(articleID: articleID)
    }

    public func listStoryMemberships(storyID: String) async throws -> [StoryArticleMembership] {
        try db.listStoryMemberships(storyID: storyID)
    }

    /// Inserts an immutable revision. Repeating the same revision is a no-op;
    /// an existing revision is never rewritten.
    public func insertStoryRevision(_ revision: StoryRevision) async throws {
        try db.insertStoryRevision(revision)
    }

    public func storyRevision(storyID: String, revisionNumber: Int) async throws -> StoryRevision? {
        try db.storyRevision(storyID: storyID, revisionNumber: revisionNumber)
    }

    public func listStoryRevisions(storyID: String) async throws -> [StoryRevision] {
        try db.listStoryRevisions(storyID: storyID)
    }

    public func latestStoryRevision(storyID: String) async throws -> StoryRevision? {
        try db.latestStoryRevision(storyID: storyID)
    }

    public func upsertStoryUserState(_ state: StoryUserState) async throws {
        try db.upsertStoryUserState(state)
    }

    public func storyUserState(storyID: String) async throws -> StoryUserState? {
        try db.storyUserState(storyID: storyID)
    }

    /// Advances the story-level revision ledger without touching any article's
    /// `is_read` value. The ledger never moves backwards.
    public func markStoryCaughtUp(
        storyID: String,
        throughRevision revisionNumber: Int,
        at date: Date = Date()
    ) async throws {
        guard try db.storyRevision(storyID: storyID, revisionNumber: revisionNumber) != nil else {
            throw SkimCoreError.database("Story revision \(storyID):\(revisionNumber) does not exist")
        }
        try db.markStoryCaughtUp(storyID: storyID, throughRevision: revisionNumber, at: date)
    }

    public func hasUnseenStoryRevision(storyID: String) async throws -> Bool {
        guard let latest = try db.latestStoryRevision(storyID: storyID) else {
            return false
        }
        let lastSeen = try db.storyUserState(storyID: storyID)?.lastSeenRevision ?? 0
        return latest.revisionNumber > lastSeen
    }

    /// Persists an edition and its frozen story snapshots transactionally.
    /// Repeating an edition/item identity is idempotent and preserves the
    /// original snapshot fields.
    public func persistEdition(_ edition: Edition, items: [EditionItem]) async throws {
        guard items.allSatisfy({ $0.editionID == edition.id }) else {
            throw SkimCoreError.database("Edition items must match edition \(edition.id)")
        }
        try db.transaction {
            try db.insertEdition(edition)
            for item in items {
                try db.insertEditionItem(item)
            }
        }
    }

    public func edition(id: String) async throws -> Edition? {
        try db.edition(id: id)
    }

    public func listEditions(limit: Int = 30) async throws -> [Edition] {
        try db.listEditions(limit: limit)
    }

    public func updateEditionProgress(
        id: String,
        status: EditionStatus,
        completedAt: Date?,
        totalSourceCount: Int
    ) async throws {
        try db.updateEditionProgress(
            id: id,
            status: status,
            completedAt: completedAt,
            totalSourceCount: totalSourceCount
        )
    }

    public func listEditionItems(editionID: String) async throws -> [EditionItem] {
        try db.listEditionItems(editionID: editionID)
    }

    public func setEditionItemConsumed(
        editionID: String,
        storyID: String,
        isConsumed: Bool,
        at date: Date? = Date()
    ) async throws {
        try db.setEditionItemConsumed(
            editionID: editionID,
            storyID: storyID,
            isConsumed: isConsumed,
            at: isConsumed ? date : nil
        )
    }

    public func deleteEdition(id: String) async throws {
        try db.execute("DELETE FROM editions WHERE id = ?", [.text(id)])
    }
}

private enum SQLiteValue {
    case text(String)
    case optionalText(String?)
    case int(Int)
    case optionalInt(Int?)
    case optionalDouble(Double?)
    case bool(Bool)
    case date(Date?)
}

private final class SQLiteDatabase: @unchecked Sendable {
    private let handle: OpaquePointer

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw SkimCoreError.database("Could not open \(url.path)")
        }
        self.handle = db
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
    }

    deinit {
        sqlite3_close(handle)
    }

    func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS folders (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS feeds (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            url TEXT NOT NULL UNIQUE,
            site_url TEXT,
            icon_url TEXT,
            fetched_at REAL
        )
        """)

        // Migration: add folder_id column if it doesn't exist (safe no-op if already present)
        try? execute("ALTER TABLE feeds ADD COLUMN folder_id TEXT REFERENCES folders(id) ON DELETE SET NULL")

        // Migration: add smart folder columns if they don't exist (safe no-op if already present)
        try? execute("ALTER TABLE folders ADD COLUMN is_smart INTEGER NOT NULL DEFAULT 0")
        try? execute("ALTER TABLE folders ADD COLUMN rules_json TEXT")

        try execute("""
        CREATE TABLE IF NOT EXISTS articles (
            id TEXT PRIMARY KEY,
            feed_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
            feed_title TEXT NOT NULL,
            title TEXT NOT NULL,
            url TEXT,
            author TEXT,
            content_text TEXT,
            content_html TEXT,
            image_url TEXT,
            published_at REAL,
            fetched_at REAL NOT NULL,
            is_read INTEGER NOT NULL DEFAULT 0,
            is_starred INTEGER NOT NULL DEFAULT 0
        )
        """)

        try? execute("ALTER TABLE articles ADD COLUMN aggregator_kind TEXT")
        try? execute("ALTER TABLE articles ADD COLUMN external_url TEXT")
        try? execute("ALTER TABLE articles ADD COLUMN comments_url TEXT")

        try execute("CREATE INDEX IF NOT EXISTS idx_articles_feed ON articles(feed_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_articles_read ON articles(is_read)")
        try execute("CREATE INDEX IF NOT EXISTS idx_articles_starred ON articles(is_starred)")

        try execute("""
        CREATE TABLE IF NOT EXISTS article_reader_cache (
            article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
            url TEXT,
            text TEXT NOT NULL,
            cached_at REAL NOT NULL
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_article_reader_cache_cached_at ON article_reader_cache(cached_at)")

        try execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")

        // Durable story clustering lives beside articles. Existing article
        // rows and their read state remain the source of truth for All Articles.
        try execute("""
        CREATE TABLE IF NOT EXISTS stories (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            summary TEXT,
            representative_article_id TEXT REFERENCES articles(id) ON DELETE SET NULL,
            first_seen_at REAL NOT NULL,
            last_activity_at REAL NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_stories_last_activity ON stories(last_activity_at DESC)")

        try execute("""
        CREATE TABLE IF NOT EXISTS story_articles (
            story_id TEXT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
            article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
            membership_type TEXT NOT NULL
                CHECK (membership_type IN ('duplicate', 'coverage', 'update')),
            confidence REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
            added_at REAL NOT NULL,
            PRIMARY KEY (story_id, article_id),
            UNIQUE (article_id)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_story_articles_story_added ON story_articles(story_id, added_at DESC)")

        try execute("""
        CREATE TABLE IF NOT EXISTS story_revisions (
            story_id TEXT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
            revision_number INTEGER NOT NULL CHECK (revision_number > 0),
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            delta_summary TEXT,
            representative_article_id TEXT REFERENCES articles(id) ON DELETE SET NULL,
            source_count INTEGER NOT NULL DEFAULT 1 CHECK (source_count >= 1),
            content_fingerprint TEXT,
            is_material_change INTEGER NOT NULL DEFAULT 1 CHECK (is_material_change IN (0, 1)),
            created_at REAL NOT NULL,
            PRIMARY KEY (story_id, revision_number)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_story_revisions_created ON story_revisions(story_id, created_at DESC)")

        try execute("""
        CREATE TABLE IF NOT EXISTS story_user_state (
            story_id TEXT PRIMARY KEY REFERENCES stories(id) ON DELETE CASCADE,
            last_seen_revision INTEGER CHECK (last_seen_revision IS NULL OR last_seen_revision > 0),
            last_read_revision INTEGER CHECK (last_read_revision IS NULL OR last_read_revision > 0),
            is_followed INTEGER NOT NULL DEFAULT 0 CHECK (is_followed IN (0, 1)),
            is_hidden INTEGER NOT NULL DEFAULT 0 CHECK (is_hidden IN (0, 1)),
            caught_up_at REAL,
            updated_at REAL NOT NULL,
            FOREIGN KEY (story_id, last_seen_revision)
                REFERENCES story_revisions(story_id, revision_number) ON DELETE RESTRICT,
            FOREIGN KEY (story_id, last_read_revision)
                REFERENCES story_revisions(story_id, revision_number) ON DELETE RESTRICT
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS editions (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            scope TEXT NOT NULL,
            story_limit INTEGER NOT NULL CHECK (story_limit > 0),
            status TEXT NOT NULL CHECK (status IN ('draft', 'ready', 'completed', 'failed')),
            starts_at REAL NOT NULL,
            ends_at REAL NOT NULL CHECK (ends_at > starts_at),
            generated_at REAL NOT NULL,
            completed_at REAL,
            total_source_count INTEGER NOT NULL CHECK (total_source_count >= 1)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_editions_current ON editions(starts_at, ends_at, generated_at DESC)")

        try execute("""
        CREATE TABLE IF NOT EXISTS edition_items (
            edition_id TEXT NOT NULL REFERENCES editions(id) ON DELETE CASCADE,
            story_id TEXT NOT NULL REFERENCES stories(id) ON DELETE RESTRICT,
            story_revision_number INTEGER NOT NULL,
            position INTEGER NOT NULL CHECK (position >= 0),
            section TEXT NOT NULL,
            snapshot_title TEXT NOT NULL,
            snapshot_summary TEXT NOT NULL,
            snapshot_delta_summary TEXT,
            snapshot_source_count INTEGER NOT NULL CHECK (snapshot_source_count >= 1),
            snapshot_reason TEXT,
            is_unique_find INTEGER NOT NULL DEFAULT 0 CHECK (is_unique_find IN (0, 1)),
            is_consumed INTEGER NOT NULL DEFAULT 0 CHECK (is_consumed IN (0, 1)),
            consumed_at REAL,
            PRIMARY KEY (edition_id, story_id),
            UNIQUE (edition_id, position),
            FOREIGN KEY (story_id, story_revision_number)
                REFERENCES story_revisions(story_id, revision_number) ON DELETE RESTRICT
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_edition_items_order ON edition_items(edition_id, position)")
        try execute("CREATE INDEX IF NOT EXISTS idx_edition_items_story ON edition_items(story_id)")
    }

    func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func upsertFolder(_ folder: FeedFolder) throws {
        try execute(
            """
            INSERT INTO folders (id, name, sort_order, is_smart, rules_json)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                sort_order = excluded.sort_order,
                is_smart = excluded.is_smart,
                rules_json = excluded.rules_json
            """,
            [
                .text(folder.id),
                .text(folder.name),
                .int(folder.sortOrder),
                .bool(folder.isSmart),
                .optionalText(folder.rulesJSON)
            ]
        )
    }

    func listFolders() throws -> [FeedFolder] {
        try query("SELECT id, name, sort_order, is_smart, rules_json FROM folders ORDER BY sort_order ASC, name COLLATE NOCASE ASC") { statement in
            FeedFolder(
                id: columnText(statement, 0),
                name: columnText(statement, 1),
                sortOrder: Int(sqlite3_column_int(statement, 2)),
                isSmart: sqlite3_column_int(statement, 3) != 0,
                rulesJSON: columnOptionalText(statement, 4)
            )
        }
    }

    func upsertFeed(_ feed: Feed) throws {
        try execute(
            """
            INSERT INTO feeds (id, title, url, site_url, icon_url, fetched_at, folder_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                url = excluded.url,
                site_url = excluded.site_url,
                icon_url = excluded.icon_url,
                fetched_at = excluded.fetched_at
            """,
            [
                .text(feed.id),
                .text(feed.title),
                .text(feed.url.absoluteString),
                .optionalText(feed.siteURL?.absoluteString),
                .optionalText(feed.iconURL?.absoluteString),
                .date(feed.fetchedAt),
                .optionalText(feed.folderID)
            ]
        )
    }

    func upsertArticle(_ article: Article) throws {
        try execute(
            """
            INSERT INTO articles (
                id, feed_id, feed_title, title, url, author, content_text, content_html,
                image_url, published_at, fetched_at, is_read, is_starred,
                aggregator_kind, external_url, comments_url
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                feed_title = excluded.feed_title,
                title = excluded.title,
                url = excluded.url,
                author = excluded.author,
                content_text = excluded.content_text,
                content_html = excluded.content_html,
                image_url = excluded.image_url,
                published_at = excluded.published_at,
                fetched_at = excluded.fetched_at,
                aggregator_kind = excluded.aggregator_kind,
                external_url = excluded.external_url,
                comments_url = excluded.comments_url
            """,
            [
                .text(article.id),
                .text(article.feedID),
                .text(article.feedTitle),
                .text(article.title),
                .optionalText(article.url?.absoluteString),
                .optionalText(article.author),
                .optionalText(article.contentText),
                .optionalText(article.contentHTML),
                .optionalText(article.imageURL?.absoluteString),
                .date(article.publishedAt),
                .date(article.fetchedAt),
                .bool(article.isRead),
                .bool(article.isStarred),
                .optionalText(article.aggregatorKind?.rawValue),
                .optionalText(article.externalURL?.absoluteString),
                .optionalText(article.commentsURL?.absoluteString)
            ]
        )
    }

    func listFeeds() throws -> [Feed] {
        try query("SELECT id, title, url, site_url, icon_url, fetched_at, folder_id FROM feeds ORDER BY title COLLATE NOCASE") { statement in
            Feed(
                id: columnText(statement, 0),
                title: columnText(statement, 1),
                url: URL(string: columnText(statement, 2))!,
                siteURL: columnURL(statement, 3),
                iconURL: columnURL(statement, 4),
                fetchedAt: columnDate(statement, 5),
                folderID: columnOptionalText(statement, 6)
            )
        }
    }

    func listArticles(filter: ArticleFilter) throws -> [Article] {
        var clauses: [String] = []
        var values: [SQLiteValue] = []

        if let feedID = filter.feedID {
            clauses.append("feed_id = ?")
            values.append(.text(feedID))
        }
        switch filter.readState {
        case .all: break
        case .unread: clauses.append("is_read = 0")
        case .read: clauses.append("is_read = 1")
        }
        if filter.starredOnly {
            clauses.append("is_starred = 1")
        }
        if let search = filter.searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            clauses.append("(title LIKE ? OR feed_title LIKE ? OR author LIKE ?)")
            let pattern = "%\(search)%"
            values.append(.text(pattern))
            values.append(.text(pattern))
            values.append(.text(pattern))
        }

        let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
        values.append(.int(filter.limit))

        return try query(
            """
            SELECT id, feed_id, feed_title, title, url, author, content_text, content_html,
                   image_url, published_at, fetched_at, is_read, is_starred,
                   aggregator_kind, external_url, comments_url
            FROM articles
            \(whereClause)
            ORDER BY COALESCE(published_at, fetched_at) DESC
            LIMIT ?
            """,
            values
        ) { statement in
            makeArticle(from: statement)
        }
    }

    func article(id: String) throws -> Article? {
        try query(
            """
            SELECT id, feed_id, feed_title, title, url, author, content_text, content_html,
                   image_url, published_at, fetched_at, is_read, is_starred,
                   aggregator_kind, external_url, comments_url
            FROM articles
            WHERE id = ?
            LIMIT 1
            """,
            [.text(id)]
        ) { statement in
            makeArticle(from: statement)
        }.first
    }

    func countUnread(feedID: String?) throws -> Int {
        var sql = "SELECT COUNT(*) FROM articles WHERE is_read = 0"
        var values: [SQLiteValue] = []
        if let feedID {
            sql += " AND feed_id = ?"
            values.append(.text(feedID))
        }
        return try query(sql, values) { statement in
            Int(sqlite3_column_int(statement, 0))
        }.first ?? 0
    }

    func cachedReaderText(articleID: String) throws -> String? {
        try query(
            "SELECT text FROM article_reader_cache WHERE article_id = ? LIMIT 1",
            [.text(articleID)]
        ) { statement in
            columnText(statement, 0)
        }.first
    }

    func cacheReaderText(articleID: String, url: URL?, text: String, cachedAt: Date) throws {
        try execute(
            """
            INSERT INTO article_reader_cache (article_id, url, text, cached_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(article_id) DO UPDATE SET
                url = excluded.url,
                text = excluded.text,
                cached_at = excluded.cached_at
            """,
            [
                .text(articleID),
                .optionalText(url?.absoluteString),
                .text(text),
                .date(cachedAt)
            ]
        )
    }

    func countCachedReaderTexts() throws -> Int {
        try query("SELECT COUNT(*) FROM article_reader_cache") { statement in
            Int(sqlite3_column_int(statement, 0))
        }.first ?? 0
    }

    func setting(key: String) throws -> String? {
        try query("SELECT value FROM settings WHERE key = ? LIMIT 1", [.text(key)]) { statement in
            columnText(statement, 0)
        }.first
    }

    func setSetting(key: String, value: String) throws {
        try execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)]
        )
    }

    func upsertStory(_ story: Story) throws {
        try execute(
            """
            INSERT INTO stories (
                id, title, summary, representative_article_id,
                first_seen_at, last_activity_at, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                summary = excluded.summary,
                representative_article_id = excluded.representative_article_id,
                first_seen_at = excluded.first_seen_at,
                last_activity_at = excluded.last_activity_at,
                updated_at = excluded.updated_at
            """,
            [
                .text(story.id),
                .text(story.title),
                .optionalText(story.summary),
                .optionalText(story.representativeArticleID),
                .date(story.firstSeenAt),
                .date(story.lastActivityAt),
                .date(story.createdAt),
                .date(story.updatedAt)
            ]
        )
    }

    func story(id: String) throws -> Story? {
        try query(
            """
            SELECT id, title, summary, representative_article_id,
                   first_seen_at, last_activity_at, created_at, updated_at
            FROM stories
            WHERE id = ?
            LIMIT 1
            """,
            [.text(id)]
        ) { makeStory(from: $0) }.first
    }

    func listStories(limit: Int) throws -> [Story] {
        try query(
            """
            SELECT id, title, summary, representative_article_id,
                   first_seen_at, last_activity_at, created_at, updated_at
            FROM stories
            ORDER BY last_activity_at DESC, id ASC
            LIMIT ?
            """,
            [.int(limit)]
        ) { makeStory(from: $0) }
    }

    func upsertStoryMembership(_ membership: StoryArticleMembership) throws {
        try execute(
            """
            INSERT INTO story_articles (
                story_id, article_id, membership_type, confidence, added_at
            )
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(article_id) DO UPDATE SET
                story_id = excluded.story_id,
                membership_type = excluded.membership_type,
                confidence = excluded.confidence,
                added_at = excluded.added_at
            """,
            [
                .text(membership.storyID),
                .text(membership.articleID),
                .text(membership.membershipType.rawValue),
                .optionalDouble(membership.confidence),
                .date(membership.addedAt)
            ]
        )
    }

    func storyMembership(articleID: String) throws -> StoryArticleMembership? {
        try query(
            """
            SELECT story_id, article_id, membership_type, confidence, added_at
            FROM story_articles
            WHERE article_id = ?
            LIMIT 1
            """,
            [.text(articleID)]
        ) { try makeStoryMembership(from: $0) }.first
    }

    func listStoryMemberships(storyID: String) throws -> [StoryArticleMembership] {
        try query(
            """
            SELECT story_id, article_id, membership_type, confidence, added_at
            FROM story_articles
            WHERE story_id = ?
            ORDER BY added_at ASC, article_id ASC
            """,
            [.text(storyID)]
        ) { try makeStoryMembership(from: $0) }
    }

    func insertStoryRevision(_ revision: StoryRevision) throws {
        try execute(
            """
            INSERT INTO story_revisions (
                story_id, revision_number, title, summary, delta_summary,
                representative_article_id, source_count, content_fingerprint,
                is_material_change, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(story_id, revision_number) DO NOTHING
            """,
            [
                .text(revision.storyID),
                .int(revision.revisionNumber),
                .text(revision.title),
                .text(revision.summary),
                .optionalText(revision.deltaSummary),
                .optionalText(revision.representativeArticleID),
                .int(revision.sourceCount),
                .optionalText(revision.contentFingerprint),
                .bool(revision.isMaterialChange),
                .date(revision.createdAt)
            ]
        )
    }

    func storyRevision(storyID: String, revisionNumber: Int) throws -> StoryRevision? {
        try query(
            """
            SELECT story_id, revision_number, title, summary, delta_summary,
                   representative_article_id, source_count, content_fingerprint,
                   is_material_change, created_at
            FROM story_revisions
            WHERE story_id = ? AND revision_number = ?
            LIMIT 1
            """,
            [.text(storyID), .int(revisionNumber)]
        ) { makeStoryRevision(from: $0) }.first
    }

    func listStoryRevisions(storyID: String) throws -> [StoryRevision] {
        try query(
            """
            SELECT story_id, revision_number, title, summary, delta_summary,
                   representative_article_id, source_count, content_fingerprint,
                   is_material_change, created_at
            FROM story_revisions
            WHERE story_id = ?
            ORDER BY revision_number ASC
            """,
            [.text(storyID)]
        ) { makeStoryRevision(from: $0) }
    }

    func latestStoryRevision(storyID: String) throws -> StoryRevision? {
        try query(
            """
            SELECT story_id, revision_number, title, summary, delta_summary,
                   representative_article_id, source_count, content_fingerprint,
                   is_material_change, created_at
            FROM story_revisions
            WHERE story_id = ?
            ORDER BY revision_number DESC
            LIMIT 1
            """,
            [.text(storyID)]
        ) { makeStoryRevision(from: $0) }.first
    }

    func upsertStoryUserState(_ state: StoryUserState) throws {
        try execute(
            """
            INSERT INTO story_user_state (
                story_id, last_seen_revision, last_read_revision, is_followed,
                is_hidden, caught_up_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(story_id) DO UPDATE SET
                last_seen_revision = excluded.last_seen_revision,
                last_read_revision = excluded.last_read_revision,
                is_followed = excluded.is_followed,
                is_hidden = excluded.is_hidden,
                caught_up_at = excluded.caught_up_at,
                updated_at = excluded.updated_at
            """,
            [
                .text(state.storyID),
                .optionalInt(state.lastSeenRevision),
                .optionalInt(state.lastReadRevision),
                .bool(state.isFollowed),
                .bool(state.isHidden),
                .date(state.caughtUpAt),
                .date(state.updatedAt)
            ]
        )
    }

    func storyUserState(storyID: String) throws -> StoryUserState? {
        try query(
            """
            SELECT story_id, last_seen_revision, last_read_revision, is_followed,
                   is_hidden, caught_up_at, updated_at
            FROM story_user_state
            WHERE story_id = ?
            LIMIT 1
            """,
            [.text(storyID)]
        ) { makeStoryUserState(from: $0) }.first
    }

    func markStoryCaughtUp(storyID: String, throughRevision revisionNumber: Int, at date: Date) throws {
        try execute(
            """
            INSERT INTO story_user_state (
                story_id, last_seen_revision, last_read_revision, is_followed,
                is_hidden, caught_up_at, updated_at
            )
            VALUES (?, ?, ?, 0, 0, ?, ?)
            ON CONFLICT(story_id) DO UPDATE SET
                last_seen_revision = CASE
                    WHEN story_user_state.last_seen_revision IS NULL
                      OR story_user_state.last_seen_revision < excluded.last_seen_revision
                    THEN excluded.last_seen_revision
                    ELSE story_user_state.last_seen_revision
                END,
                last_read_revision = CASE
                    WHEN story_user_state.last_read_revision IS NULL
                      OR story_user_state.last_read_revision < excluded.last_read_revision
                    THEN excluded.last_read_revision
                    ELSE story_user_state.last_read_revision
                END,
                caught_up_at = excluded.caught_up_at,
                updated_at = excluded.updated_at
            """,
            [
                .text(storyID),
                .int(revisionNumber),
                .int(revisionNumber),
                .date(date),
                .date(date)
            ]
        )
    }

    func insertEdition(_ edition: Edition) throws {
        try execute(
            """
            INSERT INTO editions (
                id, title, scope, story_limit, status, starts_at, ends_at,
                generated_at, completed_at, total_source_count
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            [
                .text(edition.id),
                .text(edition.title),
                .text(edition.scope),
                .int(edition.storyLimit),
                .text(edition.status.rawValue),
                .date(edition.startsAt),
                .date(edition.endsAt),
                .date(edition.generatedAt),
                .date(edition.completedAt),
                .int(edition.totalSourceCount)
            ]
        )
    }

    func edition(id: String) throws -> Edition? {
        try query(
            """
            SELECT id, title, scope, story_limit, status, starts_at, ends_at,
                   generated_at, completed_at, total_source_count
            FROM editions
            WHERE id = ?
            LIMIT 1
            """,
            [.text(id)]
        ) { try makeEdition(from: $0) }.first
    }

    func listEditions(limit: Int) throws -> [Edition] {
        try query(
            """
            SELECT id, title, scope, story_limit, status, starts_at, ends_at,
                   generated_at, completed_at, total_source_count
            FROM editions
            ORDER BY starts_at DESC, generated_at DESC, id ASC
            LIMIT ?
            """,
            [.int(limit)]
        ) { try makeEdition(from: $0) }
    }

    func updateEditionProgress(
        id: String,
        status: EditionStatus,
        completedAt: Date?,
        totalSourceCount: Int
    ) throws {
        try execute(
            """
            UPDATE editions
            SET status = ?, completed_at = ?, total_source_count = ?
            WHERE id = ?
            """,
            [
                .text(status.rawValue),
                .date(completedAt),
                .int(totalSourceCount),
                .text(id)
            ]
        )
    }

    func insertEditionItem(_ item: EditionItem) throws {
        try execute(
            """
            INSERT INTO edition_items (
                edition_id, story_id, story_revision_number, position, section,
                snapshot_title, snapshot_summary, snapshot_delta_summary,
                snapshot_source_count, snapshot_reason, is_unique_find,
                is_consumed, consumed_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(edition_id, story_id) DO NOTHING
            """,
            [
                .text(item.editionID),
                .text(item.storyID),
                .int(item.storyRevisionNumber),
                .int(item.position),
                .text(item.section),
                .text(item.snapshotTitle),
                .text(item.snapshotSummary),
                .optionalText(item.snapshotDeltaSummary),
                .int(item.snapshotSourceCount),
                .optionalText(item.snapshotReason),
                .bool(item.isUniqueFind),
                .bool(item.isConsumed),
                .date(item.consumedAt)
            ]
        )
    }

    func listEditionItems(editionID: String) throws -> [EditionItem] {
        try query(
            """
            SELECT edition_id, story_id, story_revision_number, position, section,
                   snapshot_title, snapshot_summary, snapshot_delta_summary,
                   snapshot_source_count, snapshot_reason, is_unique_find,
                   is_consumed, consumed_at
            FROM edition_items
            WHERE edition_id = ?
            ORDER BY position ASC, story_id ASC
            """,
            [.text(editionID)]
        ) { makeEditionItem(from: $0) }
    }

    func setEditionItemConsumed(
        editionID: String,
        storyID: String,
        isConsumed: Bool,
        at date: Date?
    ) throws {
        try execute(
            """
            UPDATE edition_items
            SET is_consumed = ?, consumed_at = ?
            WHERE edition_id = ? AND story_id = ?
            """,
            [
                .bool(isConsumed),
                .date(date),
                .text(editionID),
                .text(storyID)
            ]
        )
    }

    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error()
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE {
                break
            }
            if code != SQLITE_ROW {
                throw error()
            }
        }
    }

    func query<T>(_ sql: String, _ values: [SQLiteValue] = [], map: (OpaquePointer) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error()
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)

        var rows: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                rows.append(try map(statement))
            } else if code == SQLITE_DONE {
                break
            } else {
                throw error()
            }
        }
        return rows
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .text(let text):
                sqlite3_bind_text(statement, i, text, -1, SQLITE_TRANSIENT)
            case .optionalText(let text):
                if let text {
                    sqlite3_bind_text(statement, i, text, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(statement, i)
                }
            case .int(let int):
                sqlite3_bind_int64(statement, i, sqlite3_int64(int))
            case .optionalInt(let int):
                if let int {
                    sqlite3_bind_int64(statement, i, sqlite3_int64(int))
                } else {
                    sqlite3_bind_null(statement, i)
                }
            case .optionalDouble(let double):
                if let double {
                    sqlite3_bind_double(statement, i, double)
                } else {
                    sqlite3_bind_null(statement, i)
                }
            case .bool(let bool):
                sqlite3_bind_int(statement, i, bool ? 1 : 0)
            case .date(let date):
                if let date {
                    sqlite3_bind_double(statement, i, date.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, i)
                }
            }
        }
    }

    private func error() -> SkimCoreError {
        let message = sqlite3_errmsg(handle).map { String(cString: $0) } ?? "Unknown SQLite error"
        return .database(message)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func makeArticle(from statement: OpaquePointer) -> Article {
    Article(
        id: columnText(statement, 0),
        feedID: columnText(statement, 1),
        feedTitle: columnText(statement, 2),
        title: columnText(statement, 3),
        url: columnURL(statement, 4),
        author: columnOptionalText(statement, 5),
        contentText: columnOptionalText(statement, 6),
        contentHTML: columnOptionalText(statement, 7),
        imageURL: columnURL(statement, 8),
        publishedAt: columnDate(statement, 9),
        fetchedAt: columnDate(statement, 10) ?? Date(),
        isRead: sqlite3_column_int(statement, 11) != 0,
        isStarred: sqlite3_column_int(statement, 12) != 0,
        aggregatorKind: columnOptionalText(statement, 13).flatMap(AggregatorKind.init(rawValue:)),
        externalURL: columnURL(statement, 14),
        commentsURL: columnURL(statement, 15)
    )
}

private func makeStory(from statement: OpaquePointer) -> Story {
    Story(
        id: columnText(statement, 0),
        title: columnText(statement, 1),
        summary: columnOptionalText(statement, 2),
        representativeArticleID: columnOptionalText(statement, 3),
        firstSeenAt: columnDate(statement, 4)!,
        lastActivityAt: columnDate(statement, 5)!,
        createdAt: columnDate(statement, 6)!,
        updatedAt: columnDate(statement, 7)!
    )
}

private func makeStoryMembership(from statement: OpaquePointer) throws -> StoryArticleMembership {
    let rawType = columnText(statement, 2)
    guard let membershipType = StoryMembershipType(rawValue: rawType) else {
        throw SkimCoreError.database("Invalid story membership type: \(rawType)")
    }
    return StoryArticleMembership(
        storyID: columnText(statement, 0),
        articleID: columnText(statement, 1),
        membershipType: membershipType,
        confidence: columnOptionalDouble(statement, 3),
        addedAt: columnDate(statement, 4)!
    )
}

private func makeStoryRevision(from statement: OpaquePointer) -> StoryRevision {
    StoryRevision(
        storyID: columnText(statement, 0),
        revisionNumber: Int(sqlite3_column_int64(statement, 1)),
        title: columnText(statement, 2),
        summary: columnText(statement, 3),
        deltaSummary: columnOptionalText(statement, 4),
        representativeArticleID: columnOptionalText(statement, 5),
        sourceCount: Int(sqlite3_column_int64(statement, 6)),
        contentFingerprint: columnOptionalText(statement, 7),
        isMaterialChange: sqlite3_column_int(statement, 8) != 0,
        createdAt: columnDate(statement, 9)!
    )
}

private func makeStoryUserState(from statement: OpaquePointer) -> StoryUserState {
    StoryUserState(
        storyID: columnText(statement, 0),
        lastSeenRevision: columnOptionalInt(statement, 1),
        lastReadRevision: columnOptionalInt(statement, 2),
        isFollowed: sqlite3_column_int(statement, 3) != 0,
        isHidden: sqlite3_column_int(statement, 4) != 0,
        caughtUpAt: columnDate(statement, 5),
        updatedAt: columnDate(statement, 6)!
    )
}

private func makeEdition(from statement: OpaquePointer) throws -> Edition {
    let rawStatus = columnText(statement, 4)
    guard let status = EditionStatus(rawValue: rawStatus) else {
        throw SkimCoreError.database("Invalid edition status: \(rawStatus)")
    }
    return Edition(
        id: columnText(statement, 0),
        title: columnText(statement, 1),
        scope: columnText(statement, 2),
        storyLimit: Int(sqlite3_column_int64(statement, 3)),
        status: status,
        startsAt: columnDate(statement, 5)!,
        endsAt: columnDate(statement, 6)!,
        generatedAt: columnDate(statement, 7)!,
        completedAt: columnDate(statement, 8),
        totalSourceCount: Int(sqlite3_column_int64(statement, 9))
    )
}

private func makeEditionItem(from statement: OpaquePointer) -> EditionItem {
    EditionItem(
        editionID: columnText(statement, 0),
        storyID: columnText(statement, 1),
        storyRevisionNumber: Int(sqlite3_column_int64(statement, 2)),
        position: Int(sqlite3_column_int64(statement, 3)),
        section: columnText(statement, 4),
        snapshotTitle: columnText(statement, 5),
        snapshotSummary: columnText(statement, 6),
        snapshotDeltaSummary: columnOptionalText(statement, 7),
        snapshotSourceCount: Int(sqlite3_column_int64(statement, 8)),
        snapshotReason: columnOptionalText(statement, 9),
        isUniqueFind: sqlite3_column_int(statement, 10) != 0,
        isConsumed: sqlite3_column_int(statement, 11) != 0,
        consumedAt: columnDate(statement, 12)
    )
}

private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let text = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: text)
}

private func columnOptionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return columnText(statement, index)
}

private func columnURL(_ statement: OpaquePointer, _ index: Int32) -> URL? {
    columnOptionalText(statement, index).flatMap(URL.init(string:))
}

private func columnDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
}

private func columnOptionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(statement, index)
}

private func columnOptionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int64(statement, index))
}
