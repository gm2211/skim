import Foundation

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
    public var caseSensitive: Bool

    public init(id: UUID = UUID(), type: RuleType = .regexTitle, patternOrValue: String = "", caseSensitive: Bool = true) {
        self.id = id
        self.type = type
        self.patternOrValue = patternOrValue
        self.caseSensitive = caseSensitive
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case patternOrValue = "pattern_or_value"
        case pattern, value
        case caseSensitive = "case_sensitive"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        type = try container.decode(RuleType.self, forKey: .type)
        let key: CodingKeys = type == .opmlCategory ? .value : .pattern
        if container.contains(key) {
            let canonical = try container.decode(String.self, forKey: key)
            // Canonical fields govern desktop behavior. Restore native editor state
            // only when its metadata describes exactly the same expression.
            let legacy = try? container.decode(String.self, forKey: .patternOrValue)
            let sensitive = (try? container.decode(Bool.self, forKey: .caseSensitive)) ?? false
            let isRegex = type != .opmlCategory
            let legacyCanonical = legacy.map { isRegex && !sensitive ? "(?i:\($0))" : $0 }
            if let legacy, legacyCanonical == canonical {
                patternOrValue = legacy
                caseSensitive = sensitive
            } else {
                patternOrValue = canonical
                caseSensitive = true
            }
        } else {
            patternOrValue = try container.decode(String.self, forKey: .patternOrValue)
            // Stored native rules historically matched without case sensitivity.
            caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(patternOrValue, forKey: .patternOrValue)
        let canonicalValue = type != .opmlCategory && !caseSensitive ? "(?i:\(patternOrValue))" : patternOrValue
        try container.encode(canonicalValue, forKey: type == .opmlCategory ? .value : .pattern)
        try container.encode(caseSensitive, forKey: .caseSensitive)
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

    enum CodingKeys: String, CodingKey { case mode, rules }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = container.contains(.mode) ? try container.decode(Mode.self, forKey: .mode) : .any
        rules = try container.decode([SmartFolderRule].self, forKey: .rules)
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
        guard !rules.rules.isEmpty, rules.rules.allSatisfy({ rule in
            guard !rule.patternOrValue.isEmpty else { return false }
            if rule.type == .opmlCategory { return true }
            return (try? NSRegularExpression(pattern: rule.patternOrValue, options: rule.caseSensitive ? [] : [.caseInsensitive])) != nil
        }) else { return false }

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
            return regexMatches(pattern: pattern, in: feed.title, caseSensitive: rule.caseSensitive)
        case .regexURL:
            return regexMatches(pattern: pattern, in: feed.url.absoluteString, caseSensitive: rule.caseSensitive)
        case .opmlCategory:
            return feed.opmlCategory?.lowercased() == pattern.lowercased()
        }
    }

    private static func regexMatches(pattern: String, in string: String, caseSensitive: Bool) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else {
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
