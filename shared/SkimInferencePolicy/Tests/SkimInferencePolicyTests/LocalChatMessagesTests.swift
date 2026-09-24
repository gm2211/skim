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
    let result = LocalChatMessages.prepare(messages: [
        .init(role: "system", content: "Instructions"),
        .init(role: "system", content: "Additional source context"),
        .init(role: "user", content: "user: literal"),
        .init(role: "assistant", content: "Prior answer"),
    ], jsonMode: true)
    #expect(result[0]["content"] == "Instructions\n\nRespond with a single JSON object. No prose, no code fences.")
    #expect(result[1]["content"] == "Additional source context")
    #expect(result[2]["content"] == "user: literal")
    #expect(result[3]["role"] == "assistant")
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
