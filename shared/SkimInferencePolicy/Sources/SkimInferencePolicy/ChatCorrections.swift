import Foundation

/// In-place corrections. When the model finds that an earlier reply of its own
/// was wrong it adds `<correction><was>…</was><now>…</now></correction>` to its
/// answer instead of writing a correction paragraph. Skim strikes the wrong
/// words through in that earlier reply and puts "[updated]: …" beside them.
/// Mirrors src/lib/chatCorrections.ts and CORRECTION_GUIDE on desktop.
public enum ChatCorrections {
    public struct Correction: Equatable, Sendable {
        public let was: String
        public let now: String

        public init(was: String, now: String) {
            self.was = was
            self.now = now
        }
    }

    /// Prompt text that asks the model to correct itself this way.
    public static let instructions = "If you find that something you said in an earlier reply was wrong, "
        + "fix it in place rather than writing a paragraph about the mistake: add "
        + "<correction><was>the wrong words, copied exactly from your earlier reply</was><now>what is right</now></correction> "
        + "anywhere in your answer, one block per fix. Keep <was> to the shortest phrase or sentence that is wrong, "
        + "and put no citation numbers in <now>. Skim strikes the wrong words through in the earlier reply and shows "
        + "your fix beside them, so do not also explain the correction in prose; answer the new question as usual."

    /// Shown when an answer did nothing but correct earlier replies.
    public static let onlyCorrectionsNote = "*Updated my earlier reply above.*"

    private static let block = try! NSRegularExpression(
        pattern: "<correction>\\s*<was>([\\s\\S]*?)</was>\\s*<now>([\\s\\S]*?)</now>\\s*</correction>",
        options: [.caseInsensitive]
    )

    /// The answer with its correction blocks taken out, and the corrections.
    public static func extract(_ text: String) -> (text: String, corrections: [Correction]) {
        let ns = text as NSString
        let matches = block.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, []) }
        var corrections: [Correction] = []
        var stripped = ""
        var cursor = 0
        for match in matches {
            stripped += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let was = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let now = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !was.isEmpty, !now.isEmpty { corrections.append(Correction(was: was, now: now)) }
        }
        stripped += ns.substring(from: cursor)
        guard !corrections.isEmpty else { return (text, []) }
        stripped = stripped
            .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, corrections)
    }

    /// "~~wrong~~ **[updated]:** right", striking each paragraph of a multi-paragraph quote.
    public static func markdown(_ correction: Correction) -> String {
        let struck = correction.was
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "~~\($0)~~" }
            .joined(separator: "\n\n")
        return "\(struck) **[updated]:** \(correction.now)"
    }

    /// Where `was` sits in `text`: exactly, else ignoring whitespace and case.
    static func locate(_ was: String, in text: String) -> NSRange? {
        let ns = text as NSString
        let exact = ns.range(of: was, options: .backwards)
        if exact.location != NSNotFound { return exact }
        let words = was.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty,
              let regex = try? NSRegularExpression(pattern: words.joined(separator: "\\s+"), options: [.caseInsensitive])
        else { return nil }
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).last?.range
    }

    /// Apply the corrections in a new answer to the earlier messages. `earlier`
    /// holds each earlier message's text, or nil for one that is not the
    /// model's own reply and must not be edited. Each correction edits the
    /// latest earlier reply that contains its wrong words; one that matches
    /// nothing stays visible in the new answer instead of being lost.
    public static func apply(to earlier: [String?], answer: String) -> (earlier: [String?], answer: String, corrected: Int) {
        let (text, corrections) = extract(answer)
        guard !corrections.isEmpty else { return (earlier, answer, 0) }
        var revised = earlier
        var unmatched: [String] = []
        var corrected = 0
        for correction in corrections {
            var applied = false
            for index in revised.indices.reversed() {
                guard let content = revised[index], let range = locate(correction.was, in: content) else { continue }
                let ns = content as NSString
                let replacement = markdown(Correction(was: ns.substring(with: range), now: correction.now))
                revised[index] = ns.replacingCharacters(in: range, with: replacement)
                applied = true
                corrected += 1
                break
            }
            if !applied { unmatched.append(markdown(correction)) }
        }
        let parts = (unmatched + [text]).filter { !$0.isEmpty }
        return (revised, parts.isEmpty ? onlyCorrectionsNote : parts.joined(separator: "\n\n"), corrected)
    }
}
