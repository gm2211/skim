import Testing
import Foundation
import SkimCore
import SkimInferencePolicy
@testable import Skim
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - NativeAI.parseAnthropicModelsResponse Tests
//
// Settings > AI populates the Claude "Model" dropdown by calling
// `NativeAI.fetchAnthropicModels`, which decodes Anthropic's `/v1/models`
// envelope (`{"data": [{"id": ..., "display_name": ...}, ...]}`) via
// `parseAnthropicModelsResponse`. These tests exercise that parsing directly
// against fixture strings, without touching the network.
@Suite("NativeAI.parseAnthropicModelsResponse")
struct NativeAIModelsResponseTests {

    @Test func decodesModelsPreservingAPIOrder() throws {
        let json = """
        {
          "data": [
            { "id": "claude-opus-4-1", "display_name": "Claude Opus 4.1", "type": "model" },
            { "id": "claude-sonnet-5", "display_name": "Claude Sonnet 5", "type": "model" },
            { "id": "claude-haiku-4-5", "display_name": "Claude Haiku 4.5", "type": "model" }
          ],
          "has_more": false,
          "first_id": "claude-opus-4-1",
          "last_id": "claude-haiku-4-5"
        }
        """
        let data = Data(json.utf8)
        let models = try NativeAI.parseAnthropicModelsResponse(data)

        #expect(models.count == 3)
        #expect(models.map(\.id) == ["claude-opus-4-1", "claude-sonnet-5", "claude-haiku-4-5"])
        #expect(models.map(\.displayName) == ["Claude Opus 4.1", "Claude Sonnet 5", "Claude Haiku 4.5"])
    }

    @Test func decodesEmptyDataArray() throws {
        let json = """
        { "data": [], "has_more": false }
        """
        let models = try NativeAI.parseAnthropicModelsResponse(Data(json.utf8))
        #expect(models.isEmpty)
    }

    @Test func ignoresUnknownExtraFields() throws {
        // Anthropic may add fields (e.g. "created_at") that our model doesn't
        // decode — the parser should tolerate them rather than throwing.
        let json = """
        {
          "data": [
            { "id": "claude-sonnet-5", "display_name": "Claude Sonnet 5", "created_at": "2026-01-01T00:00:00Z" }
          ]
        }
        """
        let models = try NativeAI.parseAnthropicModelsResponse(Data(json.utf8))
        #expect(models == [AIModelInfo(id: "claude-sonnet-5", displayName: "Claude Sonnet 5")])
    }

    @Test func throwsOnMalformedJSON() {
        let malformed = Data("{ this is not valid json".utf8)
        #expect(throws: (any Error).self) {
            try NativeAI.parseAnthropicModelsResponse(malformed)
        }
    }

    @Test func throwsWhenDataFieldIsMissing() {
        let json = """
        { "has_more": false }
        """
        #expect(throws: (any Error).self) {
            try NativeAI.parseAnthropicModelsResponse(Data(json.utf8))
        }
    }

    @Test func openAICompatibleEntriesFallBackToIDAsDisplayName() throws {
        // OpenAI and xAI return only "id" — the picker labels rows with
        // displayName, so it has to fall back rather than failing to decode.
        let json = """
        {
          "data": [
            { "id": "grok-4.5", "object": "model", "owned_by": "xai" },
            { "id": "grok-4.3", "object": "model", "owned_by": "xai" }
          ]
        }
        """
        let models = try NativeAI.parseOpenAICompatibleModelsResponse(Data(json.utf8))
        #expect(models.map(\.displayName) == ["grok-4.3", "grok-4.5"])
    }

    @Test func openAICompatibleModelsAreSortedByID() throws {
        let json = """
        { "data": [ { "id": "gpt-5" }, { "id": "gpt-4o-mini" }, { "id": "gpt-4o" } ] }
        """
        let models = try NativeAI.parseOpenAICompatibleModelsResponse(Data(json.utf8))
        #expect(models.map(\.id) == ["gpt-4o", "gpt-4o-mini", "gpt-5"])
    }

    @Test func openAICompatibleKeepsExplicitDisplayNameWhenPresent() throws {
        // A compatible gateway may include display_name; don't discard it.
        let json = """
        { "data": [ { "id": "grok-4.5", "display_name": "Grok 4.5" } ] }
        """
        let models = try NativeAI.parseOpenAICompatibleModelsResponse(Data(json.utf8))
        #expect(models == [AIModelInfo(id: "grok-4.5", displayName: "Grok 4.5")])
    }

    @Test func throwsWhenModelEntryIsMissingRequiredID() {
        // "id" is non-optional on AIModelInfo — an entry without it
        // should fail to decode rather than silently substituting a default.
        let json = """
        { "data": [ { "display_name": "Claude Sonnet 5" } ] }
        """
        #expect(throws: (any Error).self) {
            try NativeAI.parseAnthropicModelsResponse(Data(json.utf8))
        }
    }
}


@Suite("Native library chat context")
struct NativeLibraryChatTests {
    private func article(_ id: String, body: String = "Reader evidence") -> Article {
        Article(id: id, feedID: "feed", feedTitle: "Feed", title: "Story \(id)", contentText: body)
    }

    @Test func scopeKeysSeparateFiltersAndEmptyFolders() {
        let base = ArticleFilter(readState: .unread)
        let key = LibraryChatScope(filter: base, feedIDs: nil, folderID: nil, listMode: "unread").sessionKey
        #expect(key != LibraryChatScope(filter: ArticleFilter(readState: .all), feedIDs: nil, folderID: nil, listMode: "all").sessionKey)
        #expect(key != LibraryChatScope(filter: base, feedIDs: [], folderID: "empty", listMode: "unread").sessionKey)
        #expect(key != LibraryChatScope(filter: ArticleFilter(searchQuery: "quasar"), feedIDs: nil, folderID: nil, listMode: "search").sessionKey)
        #expect(LibraryChatScope(filter: base, feedIDs: ["b", "a"], folderID: "f", listMode: "unread").sessionKey == LibraryChatScope(filter: base, feedIDs: ["a", "b"], folderID: "f", listMode: "unread").sessionKey)
    }

    @Test func citedHandleSurvivesReorderedFollowupAndNeverPointsOutsidePrompt() throws {
        let sources = [article("a"), article("b"), article("c")]
        let previous = AIChatMessage(role: .assistant, text: "See [3].", referencedArticles: [sources[2]],
            contextArticles: sources, contextHandles: [1, 2, 3])
        let followup = AIChatConversation(latestQuestion: "Explain that", priorMessages: [previous])
        let selected = [sources[2], article("new")]
        let handles = NativeAI.libraryChatHandles(articles: selected, conversation: followup)
        #expect(handles == [3, 4])
        #expect(followup.priorArticleReferences.map(\.id) == ["c"])
        #expect(try NativeAI.libraryChatContext(articles: selected, conversation: followup).contains("[3] Story c"))
        #expect(ArticleReferenceExtractor.references(in: "See [1], [3], and [36]", articles: selected, handles: handles).map(\.id) == ["c"])
        let newTopic = AIChatConversation(latestQuestion: "Find articles about quasar", priorMessages: [previous])
        #expect(NativeAI.libraryChatHandles(articles: selected, conversation: newTopic) == [3, 4])
    }

    @Test func droppedCitationIdentityStaysReservedAcrossLaterTurns() {
        let a = article("old")
        let b = article("new")
        let previous = AIChatMessage(role: .assistant, text: "See [4].", referencedArticles: [b],
            contextArticles: [b], contextHandles: [4], articleHandleRegistry: [a.id: 1, b.id: 4])
        let conversation = AIChatConversation(latestQuestion: "Find another subject", priorMessages: [previous])
        let sources = [article("latest")]
        let handles = NativeAI.libraryChatHandles(articles: sources, conversation: conversation)
        #expect(handles == [5])
        #expect(ArticleReferenceExtractor.references(in: "[1]", articles: sources, handles: handles).isEmpty)
        #expect(NativeAI.libraryChatHandleRegistry(articles: sources, conversation: conversation)[a.id] == 1)
    }

    @Test func libraryPromptIncludesMatchingTailAndEveryProvidedSource() throws {
        let source = article("late", body: String(repeating: "Ordinary background. ", count: 200) + "Quasar launch is scheduled for October 12.")
        let conversation = AIChatConversation(latestQuestion: "Find quasar launch")
        let context = try NativeAI.libraryChatContext(articles: [source], conversation: conversation)
        #expect(context.contains("Quasar launch is scheduled for October 12."))
        #expect(context.contains("[1] Story late"))
        let sources = (1...36).map { article("\($0)") }
        #expect(try NativeAI.libraryChatContext(articles: sources, conversation: conversation).contains("[36] Story 36"))
    }

    @Test func sourceNamedRulingFollowupPreservesHandleButNewQuasarDoesNot() {
        let ruling = article("ruling", body: "The ruling requires the appeal by October 12.")
        let previous = AIChatMessage(role: .assistant, text: "See [3].", referencedArticles: [ruling],
            contextArticles: [ruling], contextHandles: [3])
        let conversation = AIChatConversation(latestQuestion: "What does that ruling require by October 12?", priorMessages: [previous])
        #expect(NativeAI.libraryChatHandles(articles: [ruling], conversation: conversation) == [3])
        let newSubject = AIChatConversation(latestQuestion: "What does that quasar mean?", priorMessages: [previous])
        #expect(NativeAI.libraryChatHandles(articles: [article("quasar")], conversation: newSubject) == [4])
    }

    @MainActor @Test func cachedEvidenceIsRefreshedBeforeClassifyingReadSourceFollowup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SkimStore(databaseURL: directory.appendingPathComponent("chat.sqlite"))
        let feed = Feed(id: "feed", title: "Feed", url: URL(string: "https://example.test/feed")!)
        let source = Article(id: UUID().uuidString, feedID: feed.id, feedTitle: feed.title,
            title: "Court update", contentText: "A new court update.")
        try await store.upsert(feed: feed, articles: [source])
        let previous = AIChatMessage(role: .assistant, text: "See [3].", referencedArticles: [source],
            contextArticles: [source], contextHandles: [3])
        try await store.setArticleRead(id: source.id, isRead: true)
        try await store.cacheReaderText(articleID: source.id, url: nil,
            text: "The lawsuit requires filings by October 12, with a hearing the next day.")
        let scope = LibraryChatScope(filter: ArticleFilter(readState: .unread), feedIDs: nil, folderID: nil, listMode: "unread")
        let conversation = AIChatConversation(latestQuestion: "What does that lawsuit require by October 12?", priorMessages: [previous])
        let selected = try await AppModel.libraryChatArticles(store: store, scope: scope, conversation: conversation)
        #expect(selected.map(\.id) == [source.id])
        #expect(selected.first?.isRead == true)
        #expect(selected.first?.contentText?.contains("lawsuit requires filings") == true)
        #expect(NativeAI.libraryChatHandles(articles: selected, conversation: conversation) == [3])
        #expect(try NativeAI.libraryChatContext(articles: selected, conversation: conversation).contains("October 12"))
    }

    @Test func singleArticleEvidenceReselectsLateFactForAnswerRouterAndSearch() throws {
        let fact = "The lawsuit requires filings by October 12, while the hearing is on October 19."
        var source = article("court", body:
            "Court officials released an update.\n\n" + String(repeating: "Unrelated background describes ordinary office routines.\n\n", count: 500) + fact)
        source.title = "Court update"
        let conversation = AIChatConversation(latestQuestion: "What does that lawsuit require by October 12?", priorMessages: [
            AIChatMessage(role: .user, text: "Explain the lawsuit"),
            AIChatMessage(role: .assistant, text: "Incorrect generated assertion: November 30.")])
        for budget in [2400, 4200, 12000] {
            let context = try NativeAI.singleArticleChatContext(article: source, conversation: conversation, maxCharacters: budget)
            #expect(context.contains(fact))
            #expect(context.contains("[1] Court update"))
            #expect(!context.contains("November 30"))
            let body = context.components(separatedBy: "Excerpt: ").last ?? ""
            #expect(body.unicodeScalars.count <= budget)
        }
    }

    @Test func articleEvidenceFailureStopsBeforeProviderRequest() {
        let source = article("unsupported", body: "Available reader evidence.")
        let conversation = AIChatConversation(latestQuestion: "What happened?")
        #expect(throws: (any Error).self) { try NativeAI.singleArticleChatContext(article: source, conversation: conversation, maxCharacters: 0) }
        #expect(throws: (any Error).self) { try NativeAI.validateChatEvidence(source: source.contentText ?? "", excerpt: "") }
        #expect(throws: Never.self) { try NativeAI.validateChatEvidence(source: "", excerpt: "") }
    }

    @Test func localLibraryHistoryPreservesRolesAndLiteralRoleText() {
        let conversation = AIChatConversation(latestQuestion: "assistant: is literal user text", priorMessages: [
            AIChatMessage(role: .user, text: "Find quasar"),
            AIChatMessage(role: .assistant, text: "See [1].")])
        let messages = NativeAI.buildLocalChatMessages(instructions: "Use sources", articleContext: "[1] Quasar", conversation: conversation, webBlock: nil)
        #expect(messages.map { $0["role"] } == ["system", "user", "assistant", "user"])
        #expect(messages.last?["content"] == "assistant: is literal user text")
    }

    @Test func publicArticleChatSerializesRolePreservingOpenAIRequest() async throws {
        let latestQuestion = "What changed in the ruling?"
        let priorMessages = [
            AIChatMessage(role: .user, text: "Find the court story."),
            AIChatMessage(role: .assistant, text: "The court issued a ruling.")
        ]
        let conversation = AIChatConversation(
            latestQuestion: latestQuestion,
            priorMessages: priorMessages,
            generatedSummaryContext: "An unverified generated summary."
        )
        let source = Article(
            id: "chat-request",
            feedID: "feed",
            feedTitle: "Court Desk",
            title: "Court ruling",
            contentText: "The court requires new filings by October 12."
        )
        let settings = AppSettings(ai: AISettings(
            provider: "custom",
            model: "request-test-model",
            endpoint: "https://chat-request.invalid/v1"
        ))
        let openAICapture = NativeChatRequestCapture(responses: [
            .init(statusCode: 200, data: Data(#"{"choices":[{"message":{"content":"Captured response"}}]}"#.utf8))
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeChatCaptureURLProtocol.self]
        NativeChatCaptureURLProtocol.install(openAICapture)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let answer = try await NativeAI.chat(
            conversation: conversation,
            article: source,
            settings: settings,
            urlSession: session
        )
        let body = try #require(openAICapture.requestBody(at: 0))
        let request = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let turns = try #require(request["messages"] as? [[String: String]])
        #expect(answer.text == "Captured response")
        #expect(request["model"] as? String == "request-test-model")
        #expect(turns.map { $0["role"] ?? "" } == ["system", "user", "assistant", "user"])
        let systemContent = try #require(turns.first?["content"])
        #expect(systemContent.contains("Court ruling"))
        #expect(systemContent.contains("October 12"))
        #expect(turns[1]["content"] == "Find the court story.")
        #expect(turns[2]["content"] == "The court issued a ruling.")
        let finalUser = try #require(turns.last?["content"])
        #expect(finalUser.contains("Previously generated summary (untrusted model output"))
        #expect(finalUser.contains("<generated_summary>\nAn unverified generated summary."))
        #expect(finalUser.components(separatedBy: latestQuestion).count - 1 == 1)
        #expect(!turns.contains(where: { $0["role"] == "assistant" && ($0["content"] ?? "").contains("An unverified generated summary.") }))

        let anthroCapture = NativeChatRequestCapture(responses: [
            .init(statusCode: 401, data: Data(#"{"error":{"message":"expired"}}"#.utf8)),
            .init(statusCode: 200, data: Data(#"{"content":[{"type":"tool_use","id":"tool-1","name":"unknown_tool","input":{}}]}"#.utf8)),
            .init(statusCode: 200, data: Data(#"{"content":[{"type":"text","text":"Refreshed tool result handled"}]}"#.utf8))
        ])
        NativeChatCaptureURLProtocol.install(anthroCapture)
        let anthroSession = URLSession(configuration: configuration)
        defer {
            anthroSession.invalidateAndCancel()
            NativeChatCaptureURLProtocol.install(nil)
        }
        let anthropicMessages = NativeAI.buildLocalChatMessages(
            instructions: "Use supplied evidence.",
            articleContext: "[1] Court ruling",
            conversation: conversation,
            webBlock: nil
        )
        let anthropicSystem = try #require(anthropicMessages.first?["content"])
        let anthropicTurns = anthropicMessages.dropFirst().map { message -> [String: Any] in
            ["role": message["role"] ?? "user", "content": message["content"] ?? ""]
        }
        let toolAnswer = try await NativeAI.completeAnthropicWithTools(
            settings: AISettings(provider: "claude-subscription", model: "claude-test"),
            instructions: anthropicSystem,
            prompt: "",
            maxTokens: 321,
            initialMessages: anthropicTurns,
            urlSession: anthroSession,
            accessTokenOverride: "expired-test-token",
            refreshAccessToken: { "refreshed-test-token" }
        )
        #expect(toolAnswer.text == "Refreshed tool result handled")
        let retryBody = try #require(anthroCapture.requestBody(at: 1))
        let retryRequest = try #require(JSONSerialization.jsonObject(with: retryBody) as? [String: Any])
        #expect(retryRequest["messages"] as? [[String: String]] == Array(anthropicTurns.compactMap { turn in
            guard let role = turn["role"] as? String, let content = turn["content"] as? String else { return nil }
            return ["role": role, "content": content]
        }))
        #expect(anthroCapture.authorization(at: 1) == "Bearer refreshed-test-token")
        let continuationBody = try #require(anthroCapture.requestBody(at: 2))
        let continuation = try #require(JSONSerialization.jsonObject(with: continuationBody) as? [String: Any])
        let continuationTurns = try #require(continuation["messages"] as? [[String: Any]])
        #expect(continuationTurns.compactMap { $0["role"] as? String } == ["user", "assistant", "user", "assistant", "user"])
        let toolResultBlocks = try #require(continuationTurns.last?["content"] as? [[String: Any]])
        #expect(toolResultBlocks.first?["type"] as? String == "tool_result")
        #expect(toolResultBlocks.first?["tool_use_id"] as? String == "tool-1")
        #expect(toolResultBlocks.first?["is_error"] as? Bool == true)
    }

    @Test func anthropicRequestKeepsToolContinuationRolesAndBlocks() throws {
        let conversation = AIChatConversation(latestQuestion: "Search the web for confirmation.", priorMessages: [
            AIChatMessage(role: .user, text: "What did the court order?"),
            AIChatMessage(role: .assistant, text: "It ordered new filings.")
        ])
        let base = NativeAI.buildLocalChatMessages(
            instructions: "Answer from supplied evidence.",
            articleContext: "[1] Court ruling",
            conversation: conversation,
            webBlock: nil
        )
        let system = try #require(base.first?["content"])
        var turns = base.dropFirst().map { [String: Any](uniqueKeysWithValues: $0.map { ($0.key, $0.value) }) }
        NativeAI.appendAnthropicToolContinuation(to: &turns, assistantContent: [
            ["type": "text", "text": "I will check."],
            ["type": "tool_use", "id": "tool-1", "name": "web_search", "input": ["query": "court ruling"]]
        ], resultContent: [
            ["type": "tool_result", "tool_use_id": "tool-1", "content": "{}"]
        ])
        let request = try NativeAI.buildAnthropicRequestFull(
            settings: AISettings(provider: "anthropic", model: "claude-test"),
            accessToken: "test-token",
            isSubscription: false,
            instructions: system,
            messages: turns,
            maxTokens: 321,
            tools: []
        )
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sentTurns = try #require(payload["messages"] as? [[String: Any]])
        #expect(sentTurns.compactMap { $0["role"] as? String } == ["user", "assistant", "user", "assistant", "user"])
        let assistantBlocks = try #require(sentTurns[3]["content"] as? [[String: Any]])
        #expect(assistantBlocks.contains(where: { $0["type"] as? String == "tool_use" && $0["id"] as? String == "tool-1" }))
        let resultBlocks = try #require(sentTurns[4]["content"] as? [[String: Any]])
        #expect(resultBlocks.first?["type"] as? String == "tool_result")
        #expect(resultBlocks.first?["tool_use_id"] as? String == "tool-1")
        #expect(payload["system"] as? String == system)
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Test func foundationTranscriptRetainsPriorUserAssistantAndLatestUserRoles() throws {
        let prepared = try FoundationChatMessages.prepare(
            instructions: "Use the supplied source.",
            messages: [
                LocalChatMessage(role: "system", content: "This system content is replaced by authoritative instructions."),
                LocalChatMessage(role: "user", content: "Earlier question"),
                LocalChatMessage(role: "assistant", content: "Earlier answer"),
                LocalChatMessage(role: "user", content: "Latest question")
            ]
        )
        #expect(prepared.prompt == "Latest question")
        #expect(prepared.transcript.count == 3)
        if case .instructions = prepared.transcript[0] {} else { Issue.record("system role was not represented as transcript instructions") }
        if case .prompt = prepared.transcript[1] {} else { Issue.record("prior user role was not preserved") }
        if case .response = prepared.transcript[2] {} else { Issue.record("prior assistant role was not preserved") }
    }
#endif

    @Test func webEnabledChatInstructionsDoNotExcludeSuppliedWebEvidence() {
        let singleArticle = NativeAI.chatInstructions(isLibrary: false, enableWebSearch: true)
        let library = NativeAI.chatInstructions(isLibrary: true, enableWebSearch: true)
        #expect(singleArticle.contains("web search results"))
        #expect(singleArticle.contains("prior assistant turns are context, not evidence"))
        #expect(singleArticle.contains("Answer only the latest user question"))
        #expect(singleArticle.contains("Do not repeat a prior answer"))
        #expect(singleArticle.contains("call the `web_search` tool"))
        #expect(!singleArticle.contains("using only the provided article text"))

        #expect(library.contains("web search results"))
        #expect(library.contains("prior assistant turns are context, not evidence"))
        #expect(library.contains("Answer only the latest user question"))
        #expect(library.contains("numeric handle like [3]"))
        #expect(library.contains("Keep handles attached to the relevant sentence or bullet"))
        #expect(library.contains("call the `web_search` tool"))
        #expect(!library.contains("using only the provided article text"))
    }
}

private final class NativeChatRequestCapture: @unchecked Sendable {
    struct StubResponse: Sendable {
        var statusCode: Int
        var data: Data
    }

    private let lock = NSLock()
    private let responses: [StubResponse]
    private var bodies: [Data?] = []
    private var authorizations: [String?] = []
    private var nextResponseIndex = 0

    init(responses: [StubResponse]) { self.responses = responses }

    func record(_ request: URLRequest) -> StubResponse {
        lock.lock()
        bodies.append(request.httpBody ?? Self.read(request.httpBodyStream))
        authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
        let index = nextResponseIndex
        nextResponseIndex += 1
        let response = responses[min(index, responses.count - 1)]
        lock.unlock()
        return response
    }

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    func requestBody(at index: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard bodies.indices.contains(index) else { return nil }
        return bodies[index]
    }

    func authorization(at index: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard authorizations.indices.contains(index) else { return nil }
        return authorizations[index]
    }
}

private final class NativeChatCaptureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var currentCapture: NativeChatRequestCapture?

    static func install(_ capture: NativeChatRequestCapture?) {
        lock.lock()
        currentCapture = capture
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let capture = Self.currentCapture
        Self.lock.unlock()
        guard let capture else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let stub = capture.record(request)
        let responseBody = stub.data
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
