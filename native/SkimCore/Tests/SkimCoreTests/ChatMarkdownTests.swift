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

@Test func chatMarkdownFallsBackToPlainTextNeverCrashesOnArbitraryInput() {
    let inputs = ["", "**", "###", "[broken(", "* \n- \n#", String(repeating: "*", count: 500)]
    for input in inputs {
        let result = ChatMarkdown.attributed(input)
        _ = String(result.characters) // must not crash/trap
    }
}
