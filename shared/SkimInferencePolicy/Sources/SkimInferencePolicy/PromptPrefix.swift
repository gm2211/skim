import Foundation

/// Token-level helpers for reusing the model state of a shared prompt
/// prefix (the article in article chat) across requests.
public enum PromptPrefix {
    /// The marker that ends the article block in `GroundedChatPrompt`; the
    /// question and earlier-turn text that follow it change per request.
    public static let articleMarker = "END OF ARTICLE"

    /// True when `prefix` is non-empty and `tokens` starts with it and goes
    /// on past it (there must be something left to prefill).
    public static func extends(_ tokens: [Int], prefix: [Int]) -> Bool {
        !prefix.isEmpty && tokens.count > prefix.count && tokens.starts(with: prefix)
    }

    /// How many leading tokens `a` and `b` share, capped one short of `a`'s
    /// length so the caller always has at least one token left to prefill.
    public static func commonLength(_ a: [Int], _ b: [Int]) -> Int {
        let limit = min(a.count - 1, b.count)
        var n = 0
        while n < limit, a[n] == b[n] { n += 1 }
        return max(n, 0)
    }

    /// The smallest `n` such that the first `n` tokens decode to text that
    /// contains `marker`, or nil when the marker never appears or ends at
    /// the last token (leaving nothing after it to prefill separately).
    ///
    /// Containment only grows as tokens are added, so this binary-searches
    /// with about log2(count) decodes instead of one per token.
    public static func boundary(in tokens: [Int], marker: String, decode: ([Int]) -> String) -> Int? {
        guard !tokens.isEmpty, !marker.isEmpty, decode(tokens).contains(marker) else { return nil }
        var low = 1
        var high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if decode(Array(tokens[..<mid])).contains(marker) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low < tokens.count ? low : nil
    }
}
