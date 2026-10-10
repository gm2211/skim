import Foundation
import SkimInferencePolicy

/// One request line sent to the helper, matching `Request` in
/// `plugins/tauri-plugin-skim-ai/ios/MacBridge/main.swift`. Fields the eval
/// tool never needs (`system`, `user`, `jsonMode`) are left out.
public struct BridgeRequest: Encodable, Sendable {
    public let command: String
    public let repoId: String?
    public let messages: [LocalChatMessage]?
    public let maxTokens: Int?
    public let temperature: Float?
    /// Same as the app's article chat: keep the article's model state so a
    /// follow-up on the same article prefills only its question.
    public let reusablePrefixMarker: String?

    public init(command: String, repoId: String? = nil, messages: [LocalChatMessage]? = nil, maxTokens: Int? = nil, temperature: Float? = nil, reusablePrefixMarker: String? = nil) {
        self.command = command
        self.repoId = repoId
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.reusablePrefixMarker = reusablePrefixMarker
    }
}

/// Speed and memory for one generation, as the helper reports them
/// (`SkimGenerationMetrics` in shared/SkimMLXEngine).
public struct GenerationMetrics: Codable, Sendable, Equatable {
    public var promptTokens: Int
    public var reusedPromptTokens: Int
    public var generatedTokens: Int
    public var timeToFirstTokenSeconds: Double
    public var prefillTokensPerSecond: Double
    public var decodeTokensPerSecond: Double
    public var totalSeconds: Double
    public var peakMemoryBytes: Int
}

public struct BridgeReply: Sendable {
    public let text: String
    /// Nil from a helper built before metrics existed.
    public let metrics: GenerationMetrics?
}

private struct BridgeResponse: Decodable {
    let ok: Bool
    let value: String?
    let error: String?
    let metrics: GenerationMetrics?
}

public enum BridgeError: Error, CustomStringConvertible, Sendable {
    case processExited(Int32)
    case invalidResponse(String)
    case requestFailed(String)

    public var description: String {
        switch self {
        case .processExited(let code):
            return "bridge process exited unexpectedly (status \(code))"
        case .invalidResponse(let line):
            return "invalid bridge response line: \(line)"
        case .requestFailed(let message):
            return message
        }
    }
}

/// Reads newline-delimited UTF-8 text from a pipe, blocking on
/// `FileHandle.availableData` until a full line (or EOF) is available.
private final class LineReader {
    private let fileHandle: FileHandle
    private var buffer = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func nextLine() -> String? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                let line = String(data: lineData, encoding: .utf8)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                return line
            }
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                guard !buffer.isEmpty else { return nil }
                let remaining = String(data: buffer, encoding: .utf8)
                buffer.removeAll()
                return remaining
            }
            buffer.append(chunk)
        }
    }
}

/// Talks to the standalone macOS MLX helper
/// (`plugins/tauri-plugin-skim-ai/bin/skim-ai-macos-bridge-aarch64-apple-darwin`)
/// over its newline-delimited JSON stdin/stdout protocol. One process is
/// reused across an entire eval run so a model stays resident across
/// consecutive cases for the same repo id (the helper only reloads its
/// `ModelContainer` when the requested `repoId` changes).
public final class ChatEvalBridge {
    private let process: Process
    private let stdin: FileHandle
    private let reader: LineReader

    public init(binaryPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.standardError
        try process.run()
        self.process = process
        self.stdin = inPipe.fileHandleForWriting
        self.reader = LineReader(fileHandle: outPipe.fileHandleForReading)
    }

    /// Sends one request line and blocks for its matching response,
    /// skipping any intermediate `{"progress": ...}` lines the helper emits
    /// while downloading/loading a model container.
    public func send(_ request: BridgeRequest) throws -> String {
        try sendWithMetrics(request).text
    }

    public func sendWithMetrics(_ request: BridgeRequest) throws -> BridgeReply {
        var data = try JSONEncoder().encode(request)
        data.append(0x0a)
        stdin.write(data)

        while true {
            guard let line = reader.nextLine() else {
                process.waitUntilExit()
                throw BridgeError.processExited(process.terminationStatus)
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            if let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any], object["progress"] != nil {
                continue
            }
            guard let decoded = try? JSONDecoder().decode(BridgeResponse.self, from: lineData) else {
                throw BridgeError.invalidResponse(trimmed)
            }
            if decoded.ok {
                return BridgeReply(text: decoded.value ?? "", metrics: decoded.metrics)
            }
            throw BridgeError.requestFailed(decoded.error ?? "unknown bridge error")
        }
    }

    public func shutdown() {
        try? stdin.close()
        process.terminate()
        process.waitUntilExit()
    }
}
