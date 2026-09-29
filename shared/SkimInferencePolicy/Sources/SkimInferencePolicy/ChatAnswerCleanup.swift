import Foundation

/// Strips chatbot preamble ("Okay, here's my response:"), header labels
/// ("**Summary:**"), and trailing sign-offs ("Let me know if...") from a
/// local model's chat answer. Only the very start and end of the text are
/// touched; mid-text content (including markdown emphasis) is never modified.
public enum ChatAnswerCleanup {
    public static func clean(_ text: String, question: String) -> String {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return original }

        let includeSummary = !matches(question, pattern: "summar|tl;?dr|recap")

        var working = original
        for _ in 0..<3 {
            if let stripped = stripLeadingOpenerLine(working) {
                working = stripped
            } else if let stripped = stripLeadingBareOpener(working) {
                working = stripped
            } else if let stripped = stripLeadingHereIs(working) {
                working = stripped
            } else if let stripped = stripLeadingHeader(working, includeSummary: includeSummary) {
                working = stripped
            } else {
                break
            }
        }

        working = stripLeadingUnpairedBold(working)
        working = stripTrailingSignOff(working)

        let trimmed = working.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? original : trimmed
    }

    // MARK: - Leading patterns

    private static let openerWords = "okay|ok|sure|certainly|of course|absolutely|alright|great question"
    private static let apostrophe = "['\u{2019}]"

    /// A standalone opener line, e.g. "Okay, here's my response:\n" or bare
    /// "Sure.\n" — consumes through to end of line (or end of string).
    private static func stripLeadingOpenerLine(_ text: String) -> String? {
        let pattern = "^(?:\(openerWords))[!,.]*(?:\\s+here(?:\(apostrophe)s| is)[^\\n]{0,80})?[:.!]?\\s*(?:\\n|$)"
        return firstMatchStripped(text, pattern: pattern)
    }

    /// A bare opener that continues on the same line as real content, e.g.
    /// "Sure! The nozzle..." — requires the opener to end in punctuation.
    private static func stripLeadingBareOpener(_ text: String) -> String? {
        let pattern = "^(?:\(openerWords))[!,.]+\\s+"
        return firstMatchStripped(text, pattern: pattern)
    }

    /// "Here's my/the/a response/answer/summary/breakdown/explanation: ..."
    private static func stripLeadingHereIs(_ text: String) -> String? {
        let pattern = "^here(?:\(apostrophe)s| is)(?: my| the| a)? (?:response|answer|summary|breakdown|explanation)[^\\n]{0,60}:\\s*"
        return firstMatchStripped(text, pattern: pattern)
    }

    /// A "Summary:" / "**Answer:**" / "### Response" style header, either as
    /// its own line or inline before the rest of the text. "summary" is only
    /// stripped when the question didn't actually ask for one.
    private static func stripLeadingHeader(_ text: String, includeSummary: Bool) -> String? {
        let labels = includeSummary ? "summary|answer|response" : "answer|response"
        let lineHeader = "^(?:#{1,6}\\s*)?\\*{0,2}(?:\(labels))\\*{0,2}:?\\*{0,2}\\s*(?:\\n|$)"
        if let stripped = firstMatchStripped(text, pattern: lineHeader) { return stripped }
        let inlineHeader = "^(?:#{1,6}\\s*)?\\*{0,2}(?:\(labels))\\*{0,2}:\\*{0,2}\\s+"
        return firstMatchStripped(text, pattern: inlineHeader)
    }

    /// Removes a leading "**" that has no matching close (leftover from a
    /// stripped header like "**Summary:**"). A paired leading "**foo**..."
    /// is left alone since that's legitimate emphasis, not boilerplate.
    private static func stripLeadingUnpairedBold(_ text: String) -> String {
        guard text.hasPrefix("**") else { return text }
        let afterMarker = text.index(text.startIndex, offsetBy: 2)
        let rest = String(text[afterMarker...])
        guard !rest.contains("**") else { return text }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Trailing pattern

    private static let signOffPattern = "^(?:I hope (?:this|that) helps|Let me know if|Feel free to|Would you like|Do you want me to|Is there anything else)"

    private static func stripTrailingSignOff(_ text: String) -> String {
        let separatorRange = text.range(of: "\n\n", options: .backwards)
        let finalParagraph = separatorRange.map { String(text[$0.upperBound...]) } ?? text
        let trimmedParagraph = finalParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedParagraph.count < 200, matches(trimmedParagraph, pattern: signOffPattern) else {
            return text
        }
        guard let separatorRange else { return "" }
        return String(text[text.startIndex..<separatorRange.lowerBound])
    }

    // MARK: - Regex helpers

    private static func firstMatchStripped(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsrange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [.anchored], range: nsrange),
              let range = Range(match.range, in: text), !range.isEmpty else { return nil }
        return String(text[range.upperBound...])
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let nsrange = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: nsrange) != nil
    }
}
