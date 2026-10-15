import Foundation
import Testing
@testable import SkimCore

private let reports = [
    TodayEditorialPolicy.Report(articleID: "a1", body: "The council voted on Tuesday to close the old bridge to traffic. Repairs will cost 40 million dollars and take a year."),
    TodayEditorialPolicy.Report(articleID: "a2", body: "Residents welcomed the closure of the bridge, which engineers said was unsafe after the spring floods."),
]

private func response(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

nonisolated(unsafe) private let validObject: [String: Any] = [
    "theme": "Infrastructure",
    "summary": "The council closed the old bridge after engineers found it unsafe. Repairs will take a year.",
    "sources": [
        ["article_id": "a1", "quote": "The council voted on Tuesday to close the old bridge to traffic."],
        ["article_id": "a2", "quote": "engineers said was unsafe after the spring floods"],
    ],
    "figure": ["value": "$40M", "label": "repair cost"],
]

@Test func todayEditorialAcceptsASummaryQuotingEveryReport() throws {
    let editorial = try TodayEditorialPolicy.validate(response(validObject), reports: reports)
    #expect(editorial.theme == "Infrastructure")
    #expect(editorial.summary.hasPrefix("The council closed"))
    #expect(editorial.sources.map(\.articleID) == ["a1", "a2"])
    #expect(editorial.figure == TodayEditorial.Figure(value: "$40M", label: "repair cost"))
    #expect(try TodayEditorialPolicy.validate("```json\n\(response(validObject))\n```", reports: reports).summary == editorial.summary)
}

@Test func todayEditorialRejectsUnsupportedOrMalformedAnswers() {
    func rejects(_ change: (inout [String: Any]) -> Void) -> Bool {
        var object = validObject
        change(&object)
        return (try? TodayEditorialPolicy.validate(response(object), reports: reports)) == nil
    }
    #expect(rejects { $0["summary"] = "" })
    #expect(rejects { $0["summary"] = String(repeating: "word ", count: 181) })
    #expect(rejects { $0["extra"] = "data" })
    #expect(rejects { $0["sources"] = [["article_id": "a1", "quote": "The council voted on Tuesday to close the old bridge to traffic."]] })
    #expect(rejects { $0["sources"] = [["article_id": "a1", "quote": "The council voted on Monday to close the old bridge to traffic."],
                                       ["article_id": "a2", "quote": "engineers said was unsafe after the spring floods"]] })
    #expect(rejects { $0["sources"] = [["article_id": "a1", "quote": "The council voted on Tuesday to close the old bridge to traffic."],
                                       ["article_id": "outside", "quote": "engineers said was unsafe after the spring floods"]] })
    #expect(rejects { $0["sources"] = [["article_id": "a1", "quote": "The council voted on Tuesday to close the old bridge to traffic."],
                                       ["article_id": "a1", "quote": "Repairs will cost 40 million dollars and take a year."]] })
    #expect((try? TodayEditorialPolicy.validate("Here is the summary", reports: reports)) == nil)
    #expect((try? TodayEditorialPolicy.validate(response(validObject), reports: [])) == nil)
}

@Test func todayEditorialDropsAFigureTheReportsDoNotState() throws {
    var object = validObject
    object["figure"] = ["value": "4M", "label": "repair cost"]
    let editorial = try TodayEditorialPolicy.validate(response(object), reports: reports)
    #expect(editorial.figure == nil)
    #expect(!editorial.summary.isEmpty)
}

@Test func todayEditorialSkipsReportsWithoutText() {
    #expect(TodayEditorialPolicy.usable(reports[0].body))
    #expect(!TodayEditorialPolicy.usable("Comments"))
    #expect(!TodayEditorialPolicy.usable("Access denied. You do not have permission to view this page on this server."))
}
