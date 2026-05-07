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
}

private enum SQLiteValue {
    case text(String)
    case optionalText(String?)
    case int(Int)
    case double(Double)
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

        try execute("CREATE INDEX IF NOT EXISTS idx_articles_feed ON articles(feed_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_articles_read ON articles(is_read)")
        try execute("CREATE INDEX IF NOT EXISTS idx_articles_starred ON articles(is_starred)")
        try execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
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
                image_url, published_at, fetched_at, is_read, is_starred
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                feed_title = excluded.feed_title,
                title = excluded.title,
                url = excluded.url,
                author = excluded.author,
                content_text = excluded.content_text,
                content_html = excluded.content_html,
                image_url = excluded.image_url,
                published_at = excluded.published_at,
                fetched_at = excluded.fetched_at
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
                .bool(article.isStarred)
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
                   image_url, published_at, fetched_at, is_read, is_starred
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
                   image_url, published_at, fetched_at, is_read, is_starred
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
            case .double(let double):
                sqlite3_bind_double(statement, i, double)
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
        isStarred: sqlite3_column_int(statement, 12) != 0
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
