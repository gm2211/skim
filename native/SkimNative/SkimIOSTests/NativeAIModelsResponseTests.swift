import Testing
import Foundation
@testable import Skim

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
