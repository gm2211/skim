public struct LocalChatMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Preserve template-level conversation roles; legacy callers still supply one turn.
public enum LocalChatMessages {
    public static func prepare(messages: [LocalChatMessage]? = nil, system: String = "", user: String = "", jsonMode: Bool = false) -> [[String: String]] {
        var turns = messages ?? [LocalChatMessage(role: "system", content: system), LocalChatMessage(role: "user", content: user)]
        if jsonMode {
            let instruction = "Respond with a single JSON object. No prose, no code fences."
            if let index = turns.firstIndex(where: { $0.role == "system" }) {
                turns[index] = LocalChatMessage(role: "system", content: turns[index].content + "\n\n" + instruction)
            } else {
                turns.insert(LocalChatMessage(role: "system", content: instruction), at: 0)
            }
        }
        return turns.map { ["role": $0.role, "content": $0.content] }
    }
}
