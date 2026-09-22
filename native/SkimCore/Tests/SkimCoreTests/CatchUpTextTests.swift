import Foundation
import Testing
@testable import SkimCore

@Test func placeholderCatchesPromptExamplesTheModelEchoed() {
    // Exactly what the sheet rendered when a weak model returned the prompt's
    // own example instead of writing anything.
    #expect(CatchUpText.isPlaceholder("Short sentence"))
    #expect(CatchUpText.isPlaceholder("Short sentence about the Hacker News article"))
    #expect(CatchUpText.isPlaceholder("Short sentence about the Finance & economics article."))
    #expect(CatchUpText.isPlaceholder("Actor does specific thing"))
    #expect(CatchUpText.isPlaceholder("One concrete sentence about what happened."))
    #expect(CatchUpText.isPlaceholder("   "))
}

@Test func placeholderLeavesRealWritingAlone() {
    #expect(!CatchUpText.isPlaceholder("ByteDance open-sources its RL training stack"))
    #expect(
        !CatchUpText.isPlaceholder(
            "Apple delayed the rebuilt Siri to spring 2026, its second slip this year."
        )
    )
    #expect(
        !CatchUpText.isPlaceholder(
            "Stripe's engineering blog walks through the outage in a detailed article."
        )
    )
}
