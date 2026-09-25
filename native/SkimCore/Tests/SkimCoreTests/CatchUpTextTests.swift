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

@Test func publicationGluedToAHeadlineIsStripped() {
    // Verbatim from the page Giulio sent back.
    #expect(CatchUpText.stripPublicationPrefix(
        "Hacker News back-and-shoulder surgery is often worse than useless",
        publications: ["Hacker News"]) == "Back-and-shoulder surgery is often worse than useless")
    #expect(CatchUpText.stripPublicationPrefix("Lobsters: SourceHut fixes XSS in build logs", publications: [])
        == "SourceHut fixes XSS in build logs")
}

@Test func publicationThatIsTheSubjectStays() {
    #expect(CatchUpText.stripPublicationPrefix("Daemonology.net launches FreeBSD/EC2 desktop AMIs",
        publications: ["daemonology.net"]) == "Daemonology.net launches FreeBSD/EC2 desktop AMIs")
    #expect(CatchUpText.stripPublicationPrefix("Reddit bans third-party API clients", publications: [])
        == "Reddit bans third-party API clients")
    #expect(CatchUpText.stripPublicationPrefix("Redditors revolt over API pricing", publications: [])
        == "Redditors revolt over API pricing")
}

@Test func secondPostingsOfALinkShareAKey() {
    #expect(CatchUpText.sameStoryKey("Show HN: Launching FreeBSD/EC2 desktop AMIs")
        == CatchUpText.sameStoryKey("Launching FreeBSD/EC2 desktop AMIs"))
    #expect(CatchUpText.sameStoryURL(URL(string: "https://www.daemonology.net/blog/amis/?utm=x"))
        == CatchUpText.sameStoryURL(URL(string: "http://daemonology.net/blog/amis")))
}

@Test func fallbackLedeNeverPrintsLinkReferences() {
    let hn = "[Comments][1]\n\n[1]: https://news.ycombinator.com/item?id=49837473"
    #expect(CatchUpText.fallbackLede([hn]) == "")
    let real = "FreeBSD now publishes desktop images for EC2, so a graphical system is one launch away."
    #expect(CatchUpText.fallbackLede([hn, real]) == real)
}
