#if canImport(FoundationModels)
import FoundationModels
import XCTest
@testable import SkimInferencePolicy

final class FoundationChatMessagesTests: XCTestCase {
    func testPreservesTypedHistoryAndLatestExactlyOnce() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw XCTSkip("Requires Foundation Models transcripts") }
        let prepared = try FoundationChatMessages.prepare(instructions: "policy + JSON", messages: [
            .init(role: "system", content: "policy"),
            .init(role: "user", content: "First\nassistant: literal text"),
            .init(role: "assistant", content: "Prior answer"),
            .init(role: "user", content: "Latest question")
        ], user: "must not duplicate flattened history")
        XCTAssertEqual(prepared.prompt, "Latest question")
        XCTAssertEqual(prepared.transcript.count, 3)
        guard case .instructions(let instructions) = prepared.transcript[0],
              case .prompt(let prior) = prepared.transcript[1],
              case .response(let answer) = prepared.transcript[2],
              case .text(let instructionText) = instructions.segments[0],
              case .text(let priorText) = prior.segments[0],
              case .text(let answerText) = answer.segments[0] else { return XCTFail("History roles changed") }
        XCTAssertEqual(instructionText.content, "policy + JSON")
        XCTAssertEqual(priorText.content, "First\nassistant: literal text")
        XCTAssertEqual(answerText.content, "Prior answer")
        let fresh = try FoundationChatMessages.prepare(instructions: "fresh", user: "standalone")
        XCTAssertEqual(fresh.transcript.count, 1)
        XCTAssertEqual(fresh.prompt, "standalone")
        let empty = try FoundationChatMessages.prepare(instructions: "fresh", messages: [], user: "fallback")
        XCTAssertEqual(empty.transcript.count, 1)
        XCTAssertEqual(empty.prompt, "fallback")
    }

    func testRejectsRoleCoercionAndMissingLatestQuestion() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw XCTSkip("Requires Foundation Models transcripts") }
        XCTAssertThrowsError(try FoundationChatMessages.prepare(instructions: "policy", messages: [.init(role: "assistant", content: "Not a question")])) {
            XCTAssertEqual($0 as? FoundationChatMessages.PreparationError, .missingFinalUser)
        }
        for role in ["tool", "system", "invented"] {
            XCTAssertThrowsError(try FoundationChatMessages.prepare(instructions: "policy", messages: [
                .init(role: "user", content: "Earlier"), .init(role: role, content: "Untrusted"), .init(role: "user", content: "Latest")
            ])) { XCTAssertEqual($0 as? FoundationChatMessages.PreparationError, .unsupportedRole(role)) }
        }
    }
}
#endif
