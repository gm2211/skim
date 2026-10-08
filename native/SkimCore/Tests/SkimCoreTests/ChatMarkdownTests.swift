import Foundation
import Testing
@testable import SkimCore

@Test func chatMarkdownBoldsInlineEmphasisAndKeepsLineBreaks() {
    let result = ChatMarkdown.attributed("**Summary:** foo\n\nbar")
    #expect(String(result.characters) == "Summary: foo\n\nbar")

    var foundBold = false
    for run in result.runs {
        let substring = String(result[run.range].characters)
        if substring == "Summary:" {
            #expect(run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
            foundBold = true
        }
    }
    #expect(foundBold)
}

@Test func chatMarkdownFoldsHeadingsToBold() {
    let result = ChatMarkdown.attributed("## Head")
    #expect(String(result.characters) == "Head")

    var foundBold = false
    for run in result.runs {
        let substring = String(result[run.range].characters)
        if substring == "Head" {
            #expect(run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
            foundBold = true
        }
    }
    #expect(foundBold)
}

@Test func chatMarkdownHandlesUnbalancedEmphasisWithoutCrashing() {
    let result = ChatMarkdown.attributed("**bold without close")
    let text = String(result.characters)
    #expect(text.contains("bold without close"))
}

@Test func chatMarkdownPreservesLinks() {
    let result = ChatMarkdown.attributed("See [Example](https://example.com) for details.")
    #expect(String(result.characters) == "See Example for details.")

    var foundLink = false
    for run in result.runs {
        if let link = run.link {
            #expect(link.absoluteString == "https://example.com")
            #expect(String(result[run.range].characters) == "Example")
            foundLink = true
        }
    }
    #expect(foundLink)
}

@Test func chatMarkdownConvertsLeadingBulletMarkersToGlyph() {
    let result = ChatMarkdown.attributed("* first\n- second")
    #expect(String(result.characters) == "• first\n• second")
}

@Test func chatMarkdownKeepsOrderedListsAndRendersFencedCode() {
    let result = ChatMarkdown.attributed("1. first\n2. second\n\n```swift\nlet marker = ```\nlet x = 1\n```")
    let text = String(result.characters)
    #expect(text.contains("1. first"))
    #expect(text.contains("2. second"))
    #expect(text.contains("let marker = ```"))
    #expect(text.contains("let x = 1"))
    #expect(text.components(separatedBy: "```").count == 2) // only the literal code content remains
}

@Test func chatMarkdownRendersQuotesAndTablesWithoutSyntaxNoise() {
    let result = ChatMarkdown.attributed("> quoted text\n\n| Name | Value |\n| --- | --- |\n| Alpha | `x | y` |")
    let text = String(result.characters)
    #expect(text.contains("│ quoted text"))
    #expect(text.contains("Name   ·   Value"))
    #expect(text.contains("Alpha   ·   x | y"))
    #expect(!text.contains("| Name"))
    #expect(!text.contains("| Alpha"))
}

@Test func chatMarkdownPreservesNonTablePipes() {
    let result = ChatMarkdown.attributed("Use `a | b` or x | y.")
    #expect(String(result.characters) == "Use a | b or x | y.")
}

@Test func chatMarkdownKeepsInlineCodeFormatting() {
    let result = ChatMarkdown.attributed("Run `skim doctor` now.")
    #expect(String(result.characters) == "Run skim doctor now.")
    #expect(result.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
}

@Test func chatMarkdownFallsBackToPlainTextNeverCrashesOnArbitraryInput() {
    let inputs = ["", "**", "###", "[broken(", "* \n- \n#", String(repeating: "*", count: 500)]
    for input in inputs {
        let result = ChatMarkdown.attributed(input)
        _ = String(result.characters) // must not crash/trap
    }
}
