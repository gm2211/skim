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
        // Explicit multi-turn conversations get normalized for template
        // compliance (role alternation, no empty/duplicate turns). The
        // single-turn legacy fallback below is constructed by this function
        // itself and is always already valid, so it is left untouched -
        // callers of that path may deliberately pass an empty `system`
        // string and expect a system slot to remain for the JSON-mode edit.
        var turns = messages.map(normalizedTurns) ?? [LocalChatMessage(role: "system", content: system), LocalChatMessage(role: "user", content: user)]
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

    /// Normalizes a raw turn sequence so it satisfies chat templates that
    /// require strict role alternation (e.g. Gemma's "Conversation roles
    /// must alternate" error):
    /// - Keeps at most one leading system turn, merging any extra leading
    ///   system turns into it with a blank-line join.
    /// - Drops assistant turns that appear before the first user turn (e.g.
    ///   an injected article summary shown as the opening assistant turn).
    /// - Merges consecutive same-role turns with a blank-line join.
    /// - Drops empty-content turns.
    /// A turn sequence that already alternates correctly passes through
    /// byte-identical. If the last turn is not a user turn, it is left as-is.
    public static func normalizedTurns(_ turns: [LocalChatMessage]) -> [LocalChatMessage] {
        let nonEmpty = turns.filter { !$0.content.isEmpty }
        guard !nonEmpty.isEmpty else { return [] }

        // Merge the leading run of system turns into a single system turn.
        var index = 0
        var leadingSystem: LocalChatMessage?
        while index < nonEmpty.count, nonEmpty[index].role == "system" {
            if let existing = leadingSystem {
                leadingSystem = LocalChatMessage(role: "system", content: existing.content + "\n\n" + nonEmpty[index].content)
            } else {
                leadingSystem = nonEmpty[index]
            }
            index += 1
        }

        var working: [LocalChatMessage] = []
        if let leadingSystem { working.append(leadingSystem) }
        working.append(contentsOf: nonEmpty[index...])

        // Drop assistant turns that precede the first user turn.
        var sawUser = false
        var afterDrop: [LocalChatMessage] = []
        for turn in working {
            if turn.role == "user" { sawUser = true }
            if turn.role == "assistant" && !sawUser { continue }
            afterDrop.append(turn)
        }

        // Merge any remaining consecutive same-role turns.
        var merged: [LocalChatMessage] = []
        for turn in afterDrop {
            if let last = merged.last, last.role == turn.role {
                merged[merged.count - 1] = LocalChatMessage(role: last.role, content: last.content + "\n\n" + turn.content)
            } else {
                merged.append(turn)
            }
        }
        return merged
    }
}
