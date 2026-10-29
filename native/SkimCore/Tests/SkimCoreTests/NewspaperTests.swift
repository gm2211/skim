import Foundation
import Testing
@testable import SkimCore

struct NewspaperTests {
    private func catalog() throws -> NewspaperCatalog {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "shared/newspapers.json")
        return try NewspaperCatalog(data: Data(contentsOf: url))
    }

    @Test func catalogListsFivePapersWithSections() throws {
        let papers = try catalog().newspapers
        #expect(papers.map(\.id) == ["nyt", "wsj", "wapo", "ft", "guardian"])
        for paper in papers {
            #expect(paper.sections.count >= 5)
            #expect((paper.signIn != nil) == !paper.isFree)
        }
    }

    @Test func cookiesGoOnlyToTheirOwnPaper() throws {
        let catalog = try catalog()
        let cookies: [(domain: String, name: String, value: String)] = [
            (".nytimes.com", "NYT-S", "abc"),
            ("www.nytimes.com", "nyt-a", "1"),
            (".ft.com", "FTSession_s", "xyz"),
            (".example.com", "tracker", "no"),
        ]
        #expect(catalog.cookieHeader(for: URL(string: "https://www.nytimes.com/2026/10/27/world/x.html")!, cookies: cookies) == "NYT-S=abc; nyt-a=1")
        #expect(catalog.cookieHeader(for: URL(string: "https://www.ft.com/content/1")!, cookies: cookies) == "FTSession_s=xyz")
        #expect(catalog.cookieHeader(for: URL(string: "https://www.wsj.com/articles/x")!, cookies: cookies) == nil)
        #expect(catalog.cookieHeader(for: URL(string: "https://notnytimes.com/a")!, cookies: cookies) == nil)
    }

    @Test func signInStateNeedsTheLoginCookieWhenKnown() throws {
        let papers = try catalog().newspapers
        let nyt = papers.first { $0.id == "nyt" }!
        let wsj = papers.first { $0.id == "wsj" }!
        let guardian = papers.first { $0.id == "guardian" }!
        #expect(!nyt.isSignedIn(finishedSignIn: true, cookieNames: ["nyt-a"]))
        #expect(nyt.isSignedIn(finishedSignIn: false, cookieNames: ["NYT-S"]))
        #expect(wsj.isSignedIn(finishedSignIn: true, cookieNames: ["wsjregion"]))
        #expect(!wsj.isSignedIn(finishedSignIn: false, cookieNames: ["wsjregion"]))
        #expect(!guardian.isSignedIn(finishedSignIn: true, cookieNames: ["GU_U"]))
    }

    @Test func signInFinishesOnThePapersSite() throws {
        let wsj = try catalog().newspapers.first { $0.id == "wsj" }!
        #expect(!wsj.finishedSignIn(at: URL(string: "https://accounts.wsj.com/login")!))
        #expect(!wsj.finishedSignIn(at: URL(string: "https://www.wsj.com/client/login")!))
        #expect(!wsj.finishedSignIn(at: URL(string: "https://sso.accounts.dowjones.com/authorize")!))
        #expect(!wsj.finishedSignIn(at: URL(string: "https://www.wsj.com/client/auth?code=1")!))
        #expect(wsj.finishedSignIn(at: URL(string: "https://www.wsj.com/")!))
        #expect(wsj.finishedSignIn(at: URL(string: "https://wsj.com/?mod=login")!))
        #expect(wsj.finishedSignIn(at: URL(string: "https://www.wsj.com/news/world")!))
        let nyt = try catalog().newspapers.first { $0.id == "nyt" }!
        #expect(!nyt.finishedSignIn(at: URL(string: "https://myaccount.nytimes.com/auth/login")!))
        #expect(nyt.finishedSignIn(at: URL(string: "https://www.nytimes.com/")!))
    }
}
