import Foundation

/// The Quick Catch-up front page drafted without a model.
///
/// An on-device model needs a long time to read the whole listing and pick the
/// stories, and a small one (Gemma 3 1B) rarely answers that prompt with JSON
/// that can be read at all. The page is drafted from the articles instead,
/// which takes no time, and the model only writes each story's lede, so the
/// stories land one at a time from the first seconds of the run.
///
/// The same link on several aggregators, and headlines plainly about the same
/// thing, are grouped into one story. Stories carried by more outlets lead,
/// then ones with a picture and real text to quote, then the order the
/// articles came in. Each story prints its best article's own headline.
///
/// Mirrors `local_front_page` in `commands::ai` on the desktop side.
public enum CatchUpDraft {
    public struct Item: Equatable, Sendable {
        public var text: String
        /// 1-based indexes into the articles the page was drafted from, the
        /// article the item leads with first.
        public var articleIndexes: [Int]
    }

    public struct Page: Equatable, Sendable {
        public var stories: [Item] = []
        public var briefs: [Item] = []
    }

    /// Articles compared pairwise; the rest of a very long backlog is left out
    /// so drafting stays instant.
    static let maxArticles = 400

    public static func frontPage(
        _ articles: [Article],
        maxStories: Int = 6,
        maxBriefs: Int = 6,
        maxCitationsPerStory: Int = 8,
        maxCitationsPerBrief: Int = 2
    ) -> Page {
        let pool = Array(articles.prefix(maxArticles))
        let terms = pool.map { topicTerms($0.title) }
        let keys = pool.map { CatchUpText.sameStoryKey($0.title) }
        let links = pool.map { CatchUpText.sameStoryURL($0.externalURL ?? $0.url) }

        var parent = Array(pool.indices)
        func root(_ index: Int) -> Int {
            var i = index
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in pool.indices {
            for j in pool.indices where j > i {
                let sameLink = links[i] != nil && links[i] == links[j]
                let sameTitle = keys[i].split(separator: " ").count >= 3 && keys[i] == keys[j]
                guard sameLink || sameTitle || sameTopic(terms[i], terms[j]) else { continue }
                let a = root(i), b = root(j)
                // The earlier article stays the root, so a group keeps the
                // position of its first member.
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }

        var order: [Int] = []
        var members: [Int: [Int]] = [:]
        for i in pool.indices {
            let r = root(i)
            if members[r] == nil { order.append(r) }
            members[r, default: []].append(i)
        }

        let hasText = pool.map { StoryText.excerpt($0.contentText ?? "").split(whereSeparator: \.isWhitespace).count >= 12 }
        let hasImage = pool.map { $0.imageURL != nil }
        let publication = pool.map { PublicationName.of(article: $0) }

        let clusters: [(score: Int, first: Int, members: [Int])] = order.map { r in
            // Within a story, the article that leads: one with a picture and text.
            let sorted = (members[r] ?? []).sorted { a, b in
                let ka = (hasImage[a] && hasText[a] ? 0 : 1, hasText[a] ? 0 : 1, a)
                let kb = (hasImage[b] && hasText[b] ? 0 : 1, hasText[b] ? 0 : 1, b)
                return ka < kb
            }
            let lead = sorted[0]
            let outlets = Set(sorted.map { publication[$0] }).count
            let score = outlets * 3 + min(sorted.count, 4) + (hasImage[lead] ? 2 : 0) + (hasText[lead] ? 1 : 0)
            return (score: score, first: r, members: sorted)
        }
        let ranked = clusters.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.first < b.first
        }

        var page = Page()
        var seen = Set<String>()
        for cluster in ranked {
            let lead = pool[cluster.members[0]]
            let title = lead.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(CatchUpText.sameStoryKey(title)).inserted else { continue }
            let headline = CatchUpText.stripPublicationPrefix(title, publications: cluster.members.map { publication[$0] })
            if page.stories.count < maxStories {
                page.stories.append(Item(text: headline, articleIndexes: cluster.members.prefix(maxCitationsPerStory).map { $0 + 1 }))
            } else if page.briefs.count < maxBriefs {
                page.briefs.append(Item(text: headline, articleIndexes: cluster.members.prefix(maxCitationsPerBrief).map { $0 + 1 }))
            } else {
                break
            }
        }
        return page
    }

    /// Headline words too common to say two articles share a subject.
    private static let stopwords: Set<String> = [
        "about", "after", "again", "against", "also", "back", "been", "before", "being", "best",
        "better", "between", "could", "does", "doing", "down", "every", "first", "from", "have",
        "here", "into", "just", "last", "like", "make", "makes", "more", "most", "much", "need",
        "news", "only", "over", "says", "should", "show", "some", "still", "than", "that", "their",
        "them", "then", "there", "these", "they", "this", "those", "through", "time", "today",
        "under", "until", "update", "very", "want", "were", "what", "when", "where", "which",
        "while", "will", "with", "without", "would", "year", "years", "your", "week", "really",
        "using", "used", "uses", "ways", "why", "how", "new",
    ]

    /// The words of a headline that say what it is about: lowercased, plurals
    /// folded, short and common words dropped. Numbers stay ("GPT 5", "M4").
    static func topicTerms(_ title: String) -> Set<String> {
        let words = title.split(whereSeparator: { $0.isWhitespace })
            .map { word in String(word.filter { $0.isLetter || $0.isNumber }).lowercased() }
            .filter { !$0.isEmpty }
        var terms = Set<String>()
        for word in words {
            let hasDigit = word.contains { $0.isNumber }
            guard word.count >= 4 || (word.count >= 2 && hasDigit), !stopwords.contains(word) else { continue }
            if word.hasSuffix("s") {
                let stem = String(word.dropLast())
                if stem.count >= 4, !stem.hasSuffix("s") {
                    terms.insert(stem)
                    continue
                }
            }
            terms.insert(word)
        }
        return terms
    }

    /// At least three subject words in common, covering half of the shorter
    /// headline. Deliberately strict: tech headlines share vocabulary, and two
    /// unrelated stories under one headline is worse than one printed twice.
    static func sameTopic(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let shared = a.intersection(b).count
        return shared >= 3 && shared * 2 >= min(a.count, b.count)
    }
}
