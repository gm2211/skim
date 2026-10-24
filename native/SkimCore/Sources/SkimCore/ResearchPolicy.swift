import Foundation

/// Deep research: a slower, fuller answer to a question about a topic. It reads
/// the reader's own feeds first, works out what they leave open, fills those
/// gaps from the web, and writes a briefing that cites both, [n] for an article
/// and [wN] for a web source. Desktop runs the same steps in
/// src-tauri/src/commands/research.rs with the same prompts.
public enum ResearchPolicy {
    /// Articles from the library the briefing may cite.
    public static let libraryArticles = 14
    /// Of those, how many are read in full rather than from their feed text.
    public static let readArticles = 8
    public static let libraryQueries = 5
    public static let webQueries = 3
    public static let webResultsPerQuery = 5
    /// Web results whose pages are read, beyond their search snippet.
    public static let webPagesRead = 4
    public static let briefingTokens = 3000

    public static let planPrompt = "You plan research in a reader's RSS library. Given their question, name the topic and write keyword searches that would find articles about it: the main names and terms, synonyms, and closely related angles. Each search is 1 to 4 words, not a sentence. Reply with JSON only: {\"topic\": \"the topic in a few words\", \"library_queries\": [\"...\", \"...\"]} with 3 to 5 searches."

    public static let gapsPrompt = "You review what a reader's own articles say about their question and decide what a complete briefing still needs from the web: background they assume, developments newer than the newest article, missing perspectives, figures or primary sources. Ignore gaps that do not matter to the question. Reply with JSON only: {\"gaps\": [\"short phrase\", ...], \"web_queries\": [\"web search query\", ...]} with at most 3 web queries, each a plain search-engine query. If the articles cover the question well, still give 1 query that checks for the latest news. If there are no articles, plan queries that cover the whole question."

    public static func briefingPrompt(today: String) -> String {
        """
        You are Skim's research desk. Write a briefing that answers the reader's question in full, from the sources below. Today is \(today).

        Format, in Markdown:
        - Open with a bottom line of 2 to 3 sentences that answers the question directly. No heading above it and no title.
        - Then sections with ## headings. Pick the ones that fit, such as What's happening, Background, Key facts and figures, Where sources differ, What to watch.
        - Short paragraphs and bullets. About 400 to 700 words in all.

        Citations: put [n] right after each claim from the reader's articles and [wN] after each claim from a web source, e.g. [2] or [w1]. Cite every factual claim. Lean on the reader's articles first and use the web for what they lack. Where a point rests only on the web, the [wN] citation shows it. Say plainly what remains unknown or disputed. Never invent sources, numbers or quotes. No emoji. Do not list the sources at the end: Skim shows them as cards under the briefing.
        """
    }

    public struct Plan: Equatable, Sendable {
        public var topic: String
        public var libraryQueries: [String]
    }

    public struct Gaps: Equatable, Sendable {
        public var gaps: [String]
        public var webQueries: [String]
    }

    /// The first JSON object in a model reply, which may wrap it in prose or a fence.
    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// The plan, falling back to the question itself when the reply has none.
    public static func plan(from reply: String, question: String) -> Plan {
        let json = jsonObject(reply)
        let topic = (json?["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var queries = cleanQueries(strings(json?["library_queries"]), limit: libraryQueries)
        if queries.isEmpty { queries = [question] }
        return Plan(topic: topic.isEmpty ? question : topic, libraryQueries: queries)
    }

    /// What to look up on the web, falling back to the topic when the reply has none.
    public static func gaps(from reply: String, topic: String) -> Gaps {
        let json = jsonObject(reply)
        var queries = cleanQueries(strings(json?["web_queries"]), limit: webQueries)
        if queries.isEmpty { queries = [topic] }
        return Gaps(gaps: strings(json?["gaps"]), webQueries: queries)
    }

    public static func cleanQueries(_ queries: [String], limit: Int) -> [String] {
        var out: [String] = []
        for raw in queries {
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, query.count <= 120,
                  !out.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame })
            else { continue }
            out.append(query)
            if out.count == limit { break }
        }
        return out
    }

    /// Merge several ranked searches: an item found by more of them, or nearer
    /// the top of one, ranks higher (reciprocal rank fusion). `pinned` items,
    /// what the reader has on screen, come first.
    public static func fuse<Item>(pinned: [Item], searches: [[Item]], id: (Item) -> String, limit: Int) -> [Item] {
        var scores: [String: Double] = [:]
        var firstSeen: [Item] = []
        for found in searches {
            for (rank, item) in found.enumerated() {
                let key = id(item)
                if scores[key] == nil { firstSeen.append(item) }
                scores[key, default: 0] += 1 / (Double(rank) + 4)
            }
        }
        let ranked = firstSeen.enumerated().sorted { lhs, rhs in
            let (a, b) = (scores[id(lhs.element)] ?? 0, scores[id(rhs.element)] ?? 0)
            return a == b ? lhs.offset < rhs.offset : a > b
        }.map(\.element)
        var out: [Item] = []
        var seen = Set<String>()
        for item in pinned + ranked where seen.insert(id(item)).inserted {
            out.append(item)
            if out.count == limit { break }
        }
        return out
    }

    /// The site a web result came from, for the reader and the model.
    public static func domain(_ url: String) -> String {
        let afterScheme = url.components(separatedBy: "://").dropFirst().first ?? url
        let host = afterScheme.split(separator: "/").first.map(String.init) ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The web sources a briefing cites, as 1-based [wN] numbers in the order
    /// the reader first meets them. Numbers past `count` are dropped.
    public static func citedWebOrder(in text: String, count: Int) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"\[[wW](\d{1,3})\]"#) else { return [] }
        let ns = text as NSString
        var order: [Int] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let n = Int(ns.substring(with: match.range(at: 1))), (1...count).contains(n), !order.contains(n) else { continue }
            order.append(n)
        }
        return order
    }

    /// Renumbers [wN] citations by `order` (from `citedWebOrder`), so [w1] is the
    /// first web source the reader meets; a citation of a source that does not
    /// exist is removed rather than left pointing nowhere.
    public static func renumberWeb(_ text: String, order: [Int]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #" ?\[[wW](\d{1,3})\]"#) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = NSMaxRange(match.range)
            guard let n = Int(ns.substring(with: match.range(at: 1))), let position = order.firstIndex(of: n) else { continue }
            let lead = ns.substring(with: match.range).hasPrefix(" ") ? " " : ""
            result += "\(lead)[w\(position + 1)]"
        }
        return result + ns.substring(from: cursor)
    }
}
