import Foundation

/// Turning a feed's own title into something printable as a publication name.
///
/// Feed titles are whatever the publisher put in the XML. Some are the format
/// ("RSS 2.0", "Atom"), some are a name plus a paragraph of description
/// ("Java News/Tech/Discussion/etc. No programming help, no learning Java").
/// Neither reads as a byline, so the front page derives a short name instead.
public enum PublicationName {
    /// Feed titles that name the syndication format rather than the publication.
    private static let formatTitles: Set<String> = [
        "rss", "rss 1.0", "rss 2.0", "rss feed", "atom", "atom 1.0", "atom feed",
        "feed", "xml", "index", "untitled", "no title", "rdf",
    ]

    /// Separators after which a feed title has stopped naming itself and
    /// started describing itself.
    private static let separators = [" - ", " – ", " — ", " | ", " :: ", " · ", ". "]

    private static let maxLength = 32

    /// A short publication name, derived from the feed title and, when that
    /// title is useless, the article's own URL.
    public static func of(feedTitle: String, url: URL? = nil) -> String {
        let trimmed = feedTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty || formatTitles.contains(trimmed.lowercased()) {
            if let host = displayHost(url) {
                return host
            }
            if trimmed.isEmpty {
                return "Unknown source"
            }
        }

        return truncated(head(of: trimmed))
    }

    /// Convenience for an article, which knows both.
    public static func of(article: Article) -> String {
        of(feedTitle: article.feedTitle, url: article.externalURL ?? article.url)
    }

    /// The part of a title before it turns into a description.
    private static func head(of title: String) -> String {
        var best = title
        for separator in separators {
            guard let range = title.range(of: separator) else { continue }
            let candidate = String(title[title.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A two-character head is an artifact of the split, not a name.
            if candidate.count >= 3 && candidate.count < best.count {
                best = candidate
            }
        }
        return best.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The host of a URL, without the `www.` that no masthead prints.
    private static func displayHost(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), host.contains(".") else { return nil }
        if host.hasPrefix("www.") {
            let stripped = String(host.dropFirst(4))
            return stripped.contains(".") ? stripped : host
        }
        return host
    }

    /// Cap the name, cutting on a word boundary where there is one nearby.
    private static func truncated(_ name: String) -> String {
        guard name.count > maxLength else { return name }
        let clipped = String(name.prefix(maxLength))
        guard let space = clipped.lastIndex(of: " "),
              clipped.distance(from: clipped.startIndex, to: space) >= maxLength / 2
        else {
            return clipped + "…"
        }
        let cut = String(clipped[clipped.startIndex..<space])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cut + "…"
    }
}
