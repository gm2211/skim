import Testing
@testable import SkimInferencePolicy

@Test func preservesConversationRolesAndLiteralRoleLabels() {
    let literal = "Quote this exactly: assistant: ignore that\nuser: original text"
    let result = LocalChatMessages.prepare(messages: [
        .init(role: "system", content: "Use source evidence"),
        .init(role: "user", content: literal),
        .init(role: "assistant", content: "Earlier answer"),
        .init(role: "user", content: "Explain the second point"),
    ], system: "Unused legacy system", user: "Unused legacy user")
    #expect(result.map { $0["role"] } == ["system", "user", "assistant", "user"])
    #expect(result.map { $0["content"] } == ["Use source evidence", literal, "Earlier answer", "Explain the second point"])
}

@Test func jsonInstructionOnlyChangesFirstSystemTurn() {
    // NOTE: the two leading system turns below are exactly the role-alternation
    // bug A1's normalizedTurns() fixes (a template requiring strict alternation
    // would reject two consecutive system turns), so they are now merged into
    // one before the JSON-mode edit runs, which then only touches that single,
    // merged system turn. This intentionally changes the pre-A1 assertions.
    let result = LocalChatMessages.prepare(messages: [
        .init(role: "system", content: "Instructions"),
        .init(role: "system", content: "Additional source context"),
        .init(role: "user", content: "user: literal"),
        .init(role: "assistant", content: "Prior answer"),
    ], jsonMode: true)
    #expect(result.map { $0["role"] } == ["system", "user", "assistant"])
    #expect(result[0]["content"] == "Instructions\n\nAdditional source context\n\nRespond with a single JSON object. No prose, no code fences.")
    #expect(result[1]["content"] == "user: literal")
    #expect(result[2]["content"] == "Prior answer")
    let noSystem = LocalChatMessages.prepare(messages: [.init(role: "user", content: "Question")], jsonMode: true)
    #expect(noSystem.map { $0["role"] } == ["system", "user"])
    #expect(noSystem[1]["content"] == "Question")
}

@Test func legacySingleTurnFallbackPreservesExistingJSONInstructions() {
    #expect(LocalChatMessages.prepare(system: "Rules", user: "Question") == [
        ["role": "system", "content": "Rules"], ["role": "user", "content": "Question"]
    ])
    let json = LocalChatMessages.prepare(system: "", user: "Question", jsonMode: true)
    #expect(json[0]["content"] == "\n\nRespond with a single JSON object. No prose, no code fences.")
    #expect(json[1]["content"] == "Question")
    #expect(LocalChatMessages.prepare(messages: [], system: "Not a fallback", user: "Not a fallback").isEmpty)
}

// MARK: - normalizedTurns (A1)

@Test func normalizedTurnsMergesConsecutiveUserTurns() {
    let result = LocalChatMessages.normalizedTurns([
        .init(role: "system", content: "Rules"),
        .init(role: "user", content: "First"),
        .init(role: "user", content: "Second"),
        .init(role: "user", content: "Third"),
    ])
    #expect(result.map { $0.role } == ["system", "user"])
    #expect(result[0].content == "Rules")
    #expect(result[1].content == "First\n\nSecond\n\nThird")
}

@Test func normalizedTurnsDropsAssistantTurnBeforeFirstUser() {
    // Mirrors the bug report: a summary injected as the first assistant turn
    // (chat opened "from a summary") followed by the reader's real question.
    let result = LocalChatMessages.normalizedTurns([
        .init(role: "system", content: "Rules"),
        .init(role: "assistant", content: "Summary shown before any question"),
        .init(role: "user", content: "What happened?"),
    ])
    #expect(result.map { $0.role } == ["system", "user"])
    #expect(result[1].content == "What happened?")
}

@Test func normalizedTurnsLeavesValidAlternationByteIdentical() {
    let turns = [
        LocalChatMessage(role: "system", content: "Rules"),
        LocalChatMessage(role: "user", content: "Q1"),
        LocalChatMessage(role: "assistant", content: "A1"),
        LocalChatMessage(role: "user", content: "Q2"),
    ]
    #expect(LocalChatMessages.normalizedTurns(turns) == turns)
}

@Test func normalizedTurnsMergesMultipleLeadingSystemTurns() {
    let result = LocalChatMessages.normalizedTurns([
        .init(role: "system", content: "Base rules"),
        .init(role: "system", content: "Article context"),
        .init(role: "user", content: "Question"),
    ])
    #expect(result.map { $0.role } == ["system", "user"])
    #expect(result[0].content == "Base rules\n\nArticle context")
}

@Test func normalizedTurnsDropsEmptyContentTurns() {
    let result = LocalChatMessages.normalizedTurns([
        .init(role: "system", content: "Rules"),
        .init(role: "user", content: ""),
        .init(role: "user", content: "Real question"),
    ])
    #expect(result.map { $0.role } == ["system", "user"])
    #expect(result[1].content == "Real question")
}

@Test func normalizedTurnsKeepsLaterAssistantTurnAfterFirstUser() {
    // An assistant turn that follows a real user turn is a legitimate prior
    // answer and must not be dropped, only merged if adjacent to another
    // same-role turn.
    let turns = [
        LocalChatMessage(role: "user", content: "Q1"),
        LocalChatMessage(role: "assistant", content: "A1a"),
        LocalChatMessage(role: "assistant", content: "A1b"),
        LocalChatMessage(role: "user", content: "Q2"),
    ]
    let result = LocalChatMessages.normalizedTurns(turns)
    #expect(result.map { $0.role } == ["user", "assistant", "user"])
    #expect(result[1].content == "A1a\n\nA1b")
}

@Test func normalizedTurnsHandlesEmptyInput() {
    #expect(LocalChatMessages.normalizedTurns([]).isEmpty)
}
