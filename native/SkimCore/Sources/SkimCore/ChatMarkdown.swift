import Foundation

/// Best-effort inline Markdown rendering for on-device chat replies. Small
/// local models frequently emit `**bold**`, `# heading`, and `* bullet`
/// markup meant for a renderer, not for display as raw text.
public enum ChatMarkdown {
    /// Renders `text` as an `AttributedString`. Headings (`#` through `######`
    /// followed by a space) are folded to bold text, since chat bubbles have
    /// no block-level heading style; leading `* `/`- ` bullet markers become a
    /// `•` glyph. The result is then parsed as inline-only Markdown so plain
    /// whitespace and line breaks are preserved rather than reflowed as
    /// block structure. Malformed Markdown never crashes: partial parses are
    /// accepted, and if parsing still fails the original text is returned
    /// unstyled.
    public static func attributed(_ text: String) -> AttributedString {
        let preprocessed = preprocess(text)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: preprocessed, options: options) {
            return parsed
        }
        return AttributedString(text)
    }

    private static func preprocess(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { preprocessLine(String($0)) }
            .joined(separator: "\n")
    }

    private static func preprocessLine(_ line: String) -> String {
        var line = foldHeading(line)
        if line.hasPrefix("* ") {
            line = "• " + line.dropFirst(2)
        } else if line.hasPrefix("- ") {
            line = "• " + line.dropFirst(2)
        }
        return line
    }

    /// Converts a leading `#{1,6} ` heading marker to `**content**`.
    private static func foldHeading(_ line: String) -> String {
        var hashCount = 0
        var index = line.startIndex
        while index < line.endIndex, hashCount < 6, line[index] == "#" {
            hashCount += 1
            index = line.index(after: index)
        }
        guard hashCount > 0, index < line.endIndex, line[index] == " " else { return line }
        let content = line[line.index(after: index)...]
        return "**\(content)**"
    }
}
