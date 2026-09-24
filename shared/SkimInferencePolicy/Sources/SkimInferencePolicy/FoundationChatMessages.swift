#if canImport(FoundationModels)
import FoundationModels

/// Build a fresh, role-preserving transcript without generating historical replies.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public enum FoundationChatMessages {
    public struct Prepared {
        public let transcript: Transcript
        public let prompt: String
    }

    public enum PreparationError: Error, Equatable {
        case unsupportedRole(String)
        case missingFinalUser
    }

    /// `instructions` is authoritative, including caller JSON or guardrail additions.
    /// An initial system turn is represented by those instructions, exactly once.
    public static func prepare(instructions: String, messages: [LocalChatMessage]? = nil, user: String = "") throws -> Prepared {
        var entries: [Transcript.Entry] = [
            .instructions(.init(segments: [.text(.init(content: instructions))], toolDefinitions: []))
        ]
        guard var turns = messages, !turns.isEmpty else {
            return Prepared(transcript: Transcript(entries: entries), prompt: user)
        }
        if turns.first?.role == "system" { turns.removeFirst() }
        guard let latest = turns.last, latest.role == "user" else {
            throw PreparationError.missingFinalUser
        }
        turns.removeLast()
        for turn in turns {
            let segments: [Transcript.Segment] = [.text(.init(content: turn.content))]
            switch turn.role {
            case "user": entries.append(.prompt(.init(segments: segments)))
            case "assistant": entries.append(.response(.init(assetIDs: [], segments: segments)))
            default: throw PreparationError.unsupportedRole(turn.role)
            }
        }
        return Prepared(transcript: Transcript(entries: entries), prompt: latest.content)
    }
}
#endif
