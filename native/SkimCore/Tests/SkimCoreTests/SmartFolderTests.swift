import Foundation
import Testing
import SkimCore

// Exercise the public package API used by app targets, without @testable access.
private let smartFolderFeed = Feed(
    id: "feed",
    title: "Science Daily",
    url: URL(string: "https://example.com/science.xml")!
)

@Test func smartFoldersEvaluateAnyAndAllRules() {
    let rules = [
        SmartFolderRule(type: .regexTitle, patternOrValue: "Science"),
        SmartFolderRule(type: .regexURL, patternOrValue: "missing")
    ]
    #expect(SmartFolderEval.feedMatches(
        rules: SmartFolderRules(mode: .any, rules: rules), feed: smartFolderFeed
    ))
    #expect(!SmartFolderEval.feedMatches(
        rules: SmartFolderRules(mode: .all, rules: rules), feed: smartFolderFeed
    ))
    #expect(SmartFolderEval.feedMatches(
        rules: SmartFolderRules(mode: .all, rules: [rules[0]]), feed: smartFolderFeed
    ))
}

@Test func smartFoldersRejectEmptyAndInvalidRules() {
    for mode in SmartFolderRules.Mode.allCases {
        #expect(!SmartFolderEval.feedMatches(
            rules: SmartFolderRules(mode: mode), feed: smartFolderFeed
        ))
    }
    for pattern in ["", "["] {
        #expect(!SmartFolderEval.feedMatches(
            rules: SmartFolderRules(rules: [
                SmartFolderRule(type: .regexTitle, patternOrValue: pattern)
            ]), feed: smartFolderFeed
        ))
    }
    for json: String? in [nil, "", "not json", "{}"] {
        #expect(!SmartFolderEval.feedMatches(rulesJSON: json, feed: smartFolderFeed))
    }
}

@Test func smartFoldersPreserveExistingNativeStoredRules() throws {
    let json = #"{"mode":"all","rules":[{"id":"550E8400-E29B-41D4-A716-446655440000","type":"regex_url","pattern_or_value":"science\\.xml$"}]}"#
    let rules = try #require(SmartFolderRules.from(json: json))
    let encoded = try #require(rules.toJSON())
    #expect(SmartFolderRules.from(json: encoded) == rules)
    #expect(SmartFolderEval.feedMatches(rulesJSON: encoded, feed: smartFolderFeed))
}

@Test func smartFoldersDecodeDesktopAndPreserveLegacyCaseBehavior() throws {
    let desktop = #"{"mode":"all","rules":[{"type":"regex_title","pattern":"science"}]}"#
    #expect(!SmartFolderEval.feedMatches(rulesJSON: desktop, feed: smartFolderFeed))
    let legacy = #"{"mode":"all","rules":[{"id":"550E8400-E29B-41D4-A716-446655440000","type":"regex_title","pattern_or_value":"science"}]}"#
    let rules = try #require(SmartFolderRules.from(json: legacy))
    #expect(!rules.rules[0].caseSensitive)
    let migrated = try #require(rules.toJSON())
    #expect(SmartFolderEval.feedMatches(rulesJSON: migrated, feed: smartFolderFeed))
    let object = try #require(JSONSerialization.jsonObject(with: Data(migrated.utf8)) as? [String: Any])
    let encodedRule = try #require((object["rules"] as? [[String: Any]])?.first)
    #expect(encodedRule["pattern"] as? String == "(?i:science)")
    #expect(encodedRule["pattern_or_value"] as? String == "science")
    #expect(encodedRule["case_sensitive"] as? Bool == false)
    for json in [
        #"{"mode":"all","rules":[{"type":"unknown","pattern":"Science"}]}"#,
        #"{"mode":"all","rules":[{"type":"regex_title"}]}"#,
        #"{"mode":"all","rules":[{"type":"regex_title","pattern":4}]}"#
    ] {
        #expect(!SmartFolderEval.feedMatches(rulesJSON: json, feed: smartFolderFeed))
    }
}

@Test func smartFoldersMatchImportedCategoryInsteadOfTitle() throws {
    let xml = #"<opml version="2.0"><body><outline text="Parent"><outline text="Science"><outline text="Different publication" xmlUrl="https://example.com/feed"/></outline><outline text="Sibling" xmlUrl="https://example.com/sibling"/></outline><outline text="Science" xmlUrl="https://example.com/root"/></body></opml>"#
    let imported = try OPMLImportService().parseOPML(data: Data(xml.utf8))
    #expect(imported.first { $0.title == "Different publication" }?.opmlCategory == "Science")
    #expect(imported.first { $0.title == "Sibling" }?.opmlCategory == "Parent")
    #expect(imported.first { $0.title == "Science" }?.opmlCategory == nil)
    let rules = #"{"mode":"any","rules":[{"type":"opml_category","value":"science"}]}"#
    for item in imported {
        let feed = Feed(id: item.title, title: item.title, url: item.xmlURL, opmlCategory: item.opmlCategory)
        #expect(SmartFolderEval.feedMatches(rulesJSON: rules, feed: feed) == (item.title == "Different publication"))
    }
}

@Test func importedCategoriesSurviveStoreReopenAndFeedRefresh() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: path) }
    let store = try SkimStore(databaseURL: path)
    try await store.importFeeds([ImportedFeed(title: "Publication", xmlURL: URL(string: "https://example.com/feed")!, opmlCategory: "Science")])
    var feed = try #require(try await store.listFeeds().first)
    feed.opmlCategory = nil // Fetchers return network fields without import metadata.
    try await store.upsert(feed: feed, articles: [])
    let reopened = try SkimStore(databaseURL: path)
    #expect(try await reopened.listFeeds().first?.opmlCategory == "Science")
}

@Test func smartFoldersMatchSharedDesktopCorpus() throws {
    struct Fixture: Decodable {
        var name: String
        var rules_json: String
        var expected: [String]
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/smart-folder-matches.json")))
    let feeds = [
        Feed(id: "title", title: "Science", url: URL(string: "https://example.com/title")!),
        Feed(id: "category", title: "Different publication", url: URL(string: "https://example.com/category")!, opmlCategory: "Science")
    ]
    for fixture in fixtures {
        let actual = feeds.filter { SmartFolderEval.feedMatches(rulesJSON: fixture.rules_json, feed: $0) }.map(\.id)
        #expect(actual == fixture.expected, "\(fixture.name)")
    }
}

@Test func smartFoldersUseCanonicalFieldsOverConflictingMetadata() throws {
    for rule in [
        #"{"type":"regex_title","pattern":"science","pattern_or_value":"Science","case_sensitive":false}"#,
        #"{"type":"regex_title","pattern":"science","case_sensitive":false}"#,
        #"{"type":"opml_category","value":"Different","pattern_or_value":"Science"}"#
    ] {
        let json = "{\"rules\":[\(rule)]}"
        let rules = try #require(SmartFolderRules.from(json: json))
        #expect(rules.mode == .any)
        #expect(!SmartFolderEval.feedMatches(rules: rules, feed: smartFolderFeed))
    }
    #expect(SmartFolderEval.feedMatches(rulesJSON: #"{"rules":[{"type":"regex_title","pattern":"Science"}]}"#, feed: smartFolderFeed))
    for mode in ["null", "42", "\"invalid\""] {
        #expect(SmartFolderRules.from(json: "{\"mode\":\(mode),\"rules\":[]}") == nil)
    }
}
