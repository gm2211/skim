import Foundation
import SkimCore

// MARK: - Smart Folder Rule Types

/// A single rule that can be applied to a feed.
public struct SmartFolderRule: Codable, Hashable, Identifiable, Sendable {
    public enum RuleType: String, Codable, CaseIterable, Sendable {
        case regexTitle = "regex_title"
        case regexURL = "regex_url"
        case opmlCategory = "opml_category"

        public var displayName: String {
            switch self {
            case .regexTitle: "Title matches"
            case .regexURL: "URL matches"
            case .opmlCategory: "Category equals"
            }
        }
    }

    public var id: UUID
    public var type: RuleType
    public var patternOrValue: String

    public init(id: UUID = UUID(), type: RuleType = .regexTitle, patternOrValue: String = "") {
        self.id = id
        self.type = type
        self.patternOrValue = patternOrValue
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case patternOrValue = "pattern_or_value"
    }
}

/// The top-level rules container stored as rules_json in the folders table.
public struct SmartFolderRules: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case any
        case all

        public var displayName: String {
            switch self {
            case .any: "Any rule matches"
            case .all: "All rules match"
            }
        }
    }

    public var mode: Mode
    public var rules: [SmartFolderRule]

    public init(mode: Mode = .any, rules: [SmartFolderRule] = []) {
        self.mode = mode
        self.rules = rules
    }
}

// MARK: - Evaluation

/// Evaluates whether a feed matches a set of smart folder rules.
/// This is a pure function — no side effects.
public enum SmartFolderEval {
    /// Decodes rules from a JSON string and evaluates them against the given feed.
    /// Returns `false` if JSON is nil, empty, or invalid.
    public static func feedMatches(rulesJSON: String?, feed: Feed) -> Bool {
        guard let json = rulesJSON,
              !json.isEmpty,
              let data = json.data(using: .utf8),
              let rules = try? JSONDecoder().decode(SmartFolderRules.self, from: data)
        else { return false }
        return feedMatches(rules: rules, feed: feed)
    }

    /// Evaluates a decoded `SmartFolderRules` object against the given feed.
    public static func feedMatches(rules: SmartFolderRules, feed: Feed) -> Bool {
        guard !rules.rules.isEmpty else { return false }

        switch rules.mode {
        case .any:
            return rules.rules.contains { ruleMatches($0, feed: feed) }
        case .all:
            return rules.rules.allSatisfy { ruleMatches($0, feed: feed) }
        }
    }

    // MARK: Private helpers

    private static func ruleMatches(_ rule: SmartFolderRule, feed: Feed) -> Bool {
        let pattern = rule.patternOrValue
        guard !pattern.isEmpty else { return false }

        switch rule.type {
        case .regexTitle:
            return regexMatches(pattern: pattern, in: feed.title)
        case .regexURL:
            return regexMatches(pattern: pattern, in: feed.url.absoluteString)
        case .opmlCategory:
            // opml_category compares against the folderID stored on the feed by OPML import.
            // Since OPML categories are mapped to folder names, we compare against folder name if available.
            // In practice, the category value is matched case-insensitively against the feed title prefix.
            // For now: compare against the category embedded in feed title via OPML conventions.
            return feed.title.localizedCaseInsensitiveCompare(pattern) == .orderedSame
        }
    }

    private static func regexMatches(pattern: String, in string: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(string.startIndex..., in: string)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }
}

// MARK: - JSON helpers

extension SmartFolderRules {
    /// Encodes these rules to a compact JSON string, or nil on failure.
    public func toJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes from a JSON string, or returns nil on failure.
    public static func from(json: String?) -> SmartFolderRules? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SmartFolderRules.self, from: data)
    }
}
