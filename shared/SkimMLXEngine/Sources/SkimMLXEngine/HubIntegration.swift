import Foundation
import Hub
import MLXLMCommon
import Tokenizers

// mlx-swift-lm 3.x no longer ships a downloader or tokenizer. These adapters
// plug swift-transformers in, matching what the library's `#hubDownloader()`
// and `#huggingFaceTokenizerLoader()` macros expand to, without pulling the
// macro plugin (and its swift-syntax build) into every target.

/// Loads a swift-transformers tokenizer from a local model folder.
public struct SkimTokenizerLoader: MLXLMCommon.TokenizerLoader {
    public init() {}

    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return SkimTokenizerBridge(upstream)
    }
}

struct SkimTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers spells it `decode(tokens:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Downloads Hugging Face snapshots into `Documents/huggingface/models/<org>/<repo>`,
/// the layout every Skim build has used, so models downloaded by older
/// builds keep working.
public struct SkimHubDownloader: MLXLMCommon.Downloader {
    /// Everything a model needs offline: weights, configs, tokenizer, and
    /// the standalone `chat_template.jinja` newer repos ship.
    public static let modelFilePatterns = ["*.safetensors", "*.json", "*.jinja", "tokenizer.model"]

    private let hub: HubApi

    /// `useBackgroundSession` lets iOS keep (or resume) a multi-GB download
    /// while the app is suspended. The Hub client's own blob cache is off:
    /// on a phone it would keep a second copy of every weight file.
    public init(useBackgroundSession: Bool) {
        hub = HubApi(cache: nil, useBackgroundSession: useBackgroundSession)
    }

    public func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await hub.snapshot(
            from: Hub.Repo(id: id),
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: progressHandler
        )
    }

    /// Fetches every file a model needs and returns its local folder.
    public func downloadModel(
        repoId: String,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await download(
            id: repoId,
            revision: nil,
            matching: Self.modelFilePatterns,
            useLatest: false,
            progressHandler: progressHandler
        )
    }
}
