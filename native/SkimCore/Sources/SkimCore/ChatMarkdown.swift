import Foundation

/// Best-effort Markdown rendering for compact chat replies. Headings are
/// folded to bold lines, lists keep visible markers, and fenced code is
/// rendered as indented code lines. Inline emphasis, code, and links use
/// Foundation's Markdown parser.
public enum ChatMarkdown {
    public static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: preprocess(text), options: options) {
            return parsed
        }
        return AttributedString(text)
    }

    private static func preprocess(_ text: String) -> String {
        var activeFence: (marker: Character, length: Int)?
        var inTable = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var renderedLines: [String] = []
        for (index, line) in lines.enumerated() {
                if let fence = fenceMarker(in: line) {
                    if let currentFence = activeFence,
                       fence.marker == currentFence.marker,
                       fence.length >= currentFence.length,
                       fence.trailingText.trimmingCharacters(in: .whitespaces).isEmpty {
                        activeFence = nil
                        renderedLines.append("")
                        continue
                    }
                    if activeFence == nil {
                        activeFence = (fence.marker, fence.length)
                        renderedLines.append("")
                        continue
                    }
                }
                if activeFence != nil {
                    let delimiter = String(repeating: "`", count: maxBacktickRun(in: line) + 1)
                    renderedLines.append("\(delimiter) \(line) \(delimiter)")
                    continue
                }
                if !inTable, line.contains("|"), lines.dropFirst(index + 1).first.map(isTableSeparator) == true {
                    inTable = true
                    let cells = splitTableCells(line)
                    renderedLines.append("**\(cells.joined(separator: "   ·   "))**")
                    continue
                }
                if inTable, isTableSeparator(line) {
                    continue
                }
                if inTable, line.contains("|") {
                    let cells = splitTableCells(line)
                    renderedLines.append(cells.joined(separator: "   ·   "))
                    continue
                }
                inTable = false
                renderedLines.append(preprocessLine(line))
        }
        return renderedLines.joined(separator: "\n")
    }

    private static func preprocessLine(_ line: String) -> String {
        if line.hasPrefix("> ") {
            return "*│ \(line.dropFirst(2))*"
        }
        var line = foldHeading(line)
        if line.hasPrefix("* ") || line.hasPrefix("- ") || line.hasPrefix("+ ") {
            line = "• " + line.dropFirst(2)
        }
        return line
    }

    private static func fenceMarker(in line: String) -> (marker: Character, length: Int, trailingText: String)? {
        let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        let indentation = line.distance(from: line.startIndex, to: line.drop(while: { $0 == " " || $0 == "\t" }).startIndex)
        guard indentation <= 3, let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        return (marker, length, String(trimmed.dropFirst(length)))
    }

    private static func maxBacktickRun(in line: String) -> Int {
        var maximum = 0
        var current = 0
        for character in line {
            if character == "`" {
                current += 1
                maximum = max(maximum, current)
            } else {
                current = 0
            }
        }
        return maximum
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == ":" || $0 == "-" || $0.isWhitespace }
    }

    private static func splitTableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var inlineCodeTicks = 0
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "`" {
                var runLength = 0
                while index < characters.count, characters[index] == "`" {
                    runLength += 1
                    index += 1
                }
                if inlineCodeTicks == 0 {
                    inlineCodeTicks = runLength
                } else if inlineCodeTicks == runLength {
                    inlineCodeTicks = 0
                }
                cell += String(repeating: "`", count: runLength)
                continue
            }
            let escapedPipe = character == "|" && index > 0 && characters[index - 1] == "\\"
            if character == "|", inlineCodeTicks == 0, !escapedPipe {
                let trimmed = cell.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { cells.append(trimmed) }
                cell = ""
            } else {
                cell.append(character)
            }
            index += 1
        }
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { cells.append(trimmed) }
        return cells
    }

    /// Converts a leading `#{1,6} ` heading marker to bold text.
    private static func foldHeading(_ line: String) -> String {
        var hashCount = 0
        var index = line.startIndex
        while index < line.endIndex, hashCount < 6, line[index] == "#" {
            hashCount += 1
            index = line.index(after: index)
        }
        guard hashCount > 0, index < line.endIndex, line[index] == " " else { return line }
        return "**\(line[line.index(after: index)...])**"
    }
}
