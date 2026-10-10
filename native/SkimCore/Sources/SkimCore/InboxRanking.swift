import Foundation
import SkimStoryPolicy

/// AI Inbox ranking shared with the desktop app through `SkimStoryPolicy`.
/// The model rates importance and relevance; taste is learned on device.
public enum InboxRanking {
    public static var triagePrompt: String { String(cString: skim_inbox_triage_prompt()) }

    public struct Signal: Equatable, Sendable {
        public var dwellSeconds: Double
        public var opened: Bool
        public var starred: Bool
        public var pinned: Bool
        /// -1 less, 0 none, +1 more.
        public var feedback: Int
        /// An inbox article dismissed without being opened.
        public var readUnopened: Bool

        public init(dwellSeconds: Double = 0, opened: Bool = false, starred: Bool = false,
                    pinned: Bool = false, feedback: Int = 0, readUnopened: Bool = false) {
            self.dwellSeconds = dwellSeconds
            self.opened = opened
            self.starred = starred
            self.pinned = pinned
            self.feedback = feedback
            self.readUnopened = readUnopened
        }
    }

    public static func weight(_ signal: Signal) -> Double {
        skim_inbox_signal_weight(signal.dwellSeconds, signal.opened ? 1 : 0, signal.starred ? 1 : 0,
                                 signal.pinned ? 1 : 0, Int32(signal.feedback.signum()),
                                 signal.readUnopened ? 1 : 0)
    }

    public static func affinity(positive: Double, negative: Double) -> Double {
        skim_inbox_affinity(positive, negative)
    }

    public static func learningStrength(signals: Int) -> Double {
        skim_inbox_learning_strength(Int64(signals))
    }

    /// importance/relevance are 1-5, nil until the model has rated the article.
    public static func score(importance: Int?, relevance: Int?, affinity: Double, strength: Double,
                             pinned: Bool, ageHours: Double) -> Double {
        let hasAI = importance != nil && relevance != nil
        return skim_inbox_score(Double(importance ?? 0), Double(relevance ?? 0), hasAI ? 1 : 0,
                                affinity, strength, pinned ? 1 : 0, ageHours)
    }

    public static func priority(importance: Int, relevance: Int) -> Int {
        Int(skim_inbox_priority(Double(importance), Double(relevance)))
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "your", "about", "into", "over",
        "have", "has", "been", "were", "was", "are", "not", "how", "why", "when", "what", "who",
        "which", "will", "just", "its", "they", "them", "their", "there", "these", "those", "then",
        "than", "because", "also", "some", "more", "most", "like", "between", "against", "upon",
        "after", "before", "during", "only", "such", "any", "all", "but", "can", "you", "our",
        "says", "said", "new",
    ]

    /// Distinct lowercase title words of four or more letters, in title order.
    public static func terms(_ title: String) -> [String] {
        var out: [String] = []
        let words = title.lowercased().split { !($0.isLetter || $0.isNumber) }
        for word in words.map(String.init) {
            guard word.count >= 4, !stopwords.contains(word),
                  !word.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !out.contains(word)
            else { continue }
            out.append(word)
        }
        return out
    }
}

/// What the reader has taught the inbox, learned only from local history.
public struct InboxTaste: Sendable {
    private struct Tally: Sendable {
        var positive = 0.0
        var negative = 0.0
        mutating func add(_ weight: Double) {
            if weight >= 0 { positive += weight } else { negative -= weight }
        }
        var affinity: Double { InboxRanking.affinity(positive: positive, negative: negative) }
    }

    private var feeds: [String: Tally] = [:]
    private var terms: [String: Tally] = [:]
    public private(set) var signalCount = 0

    public init() {}

    public mutating func learn(feedID: String, title: String, signal: InboxRanking.Signal) {
        let weight = InboxRanking.weight(signal)
        guard weight != 0 else { return }
        signalCount += 1
        feeds[feedID, default: Tally()].add(weight)
        for term in InboxRanking.terms(title) {
            terms[term, default: Tally()].add(weight)
        }
    }

    public var strength: Double { InboxRanking.learningStrength(signals: signalCount) }

    /// Feed and title-term affinity, -1...1.
    public func affinity(feedID: String, title: String) -> Double {
        let feed = feeds[feedID]?.affinity ?? 0
        let known = InboxRanking.terms(title).compactMap { terms[$0]?.affinity }
        guard !known.isEmpty else { return feed }
        return 0.5 * feed + 0.5 * (known.reduce(0, +) / Double(known.count))
    }
}
