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
