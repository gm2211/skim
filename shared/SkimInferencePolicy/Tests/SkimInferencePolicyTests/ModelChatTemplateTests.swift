import Foundation
import Testing
@testable import SkimInferencePolicy

private func withTemplateDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func writeTemplateFile(_ text: String, _ name: String, in directory: URL) throws {
    try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

@Test func embeddedStringAndDefaultNamedArrayAreSupported() throws {
    try withTemplateDirectory { directory in
        for config in [
            #"{"chat_template":"{{ messages }}"}"#,
            #"{"chat_template":[{"name":"tool_use","template":"tools"},{"name":"default","template":"{{ messages }}"}]}"#,
            #"{"chat_template":[{},null,{"name":"default","template":"{{ messages }}"}]}"#
        ] {
            try writeTemplateFile(config, "tokenizer_config.json", in: directory)
            #expect(ModelChatTemplate.isUsable(in: directory))
        }
    }
}

@Test func missingEmptyMalformedAndUnsupportedEmbeddedTemplatesAreRejected() throws {
    try withTemplateDirectory { directory in
        #expect(!ModelChatTemplate.isUsable(in: directory))
        for config in [
            "", "not JSON", "{}", #"{"chat_template":" \n "}"#,
            #"{"chat_template":null}"#, #"{"chat_template":false}"#,
            #"{"chat_template":{"default":"{{ messages }}"}}"#,
            #"{"chat_template":[{"name":"tool_use","template":"tools"}]}"#,
            #"{"chat_template":[{"name":"default","template":""}]}"#,
            #"{"chat_template":[{"name":"default","template":"one"},{"name":"default","template":"two"}]}"#
        ] {
            try writeTemplateFile(config, "tokenizer_config.json", in: directory)
            #expect(!ModelChatTemplate.isUsable(in: directory))
        }
    }
}

@Test func standaloneJinjaAndJSONFormatsFollowLoaderPrecedence() throws {
    try withTemplateDirectory { directory in
        try writeTemplateFile("{{ messages }}", "chat_template.jinja", in: directory)
        #expect(ModelChatTemplate.isUsable(in: directory))
        try writeTemplateFile(#"{"chat_template":"embedded"}"#, "tokenizer_config.json", in: directory)
        try writeTemplateFile(" \n ", "chat_template.jinja", in: directory)
        #expect(!ModelChatTemplate.isUsable(in: directory))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("chat_template.jinja"))
        #expect(ModelChatTemplate.isUsable(in: directory))
        try writeTemplateFile(#"{"chat_template":""}"#, "chat_template.json", in: directory)
        #expect(!ModelChatTemplate.isUsable(in: directory))
        try writeTemplateFile(#"{"chat_template":"{{ messages }}"}"#, "chat_template.json", in: directory)
        #expect(ModelChatTemplate.isUsable(in: directory))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("tokenizer_config.json"))
        #expect(ModelChatTemplate.isUsable(in: directory))
    }
}

@Test func malformedTokenizerConfigCannotBeOverriddenByStandaloneTemplate() throws {
    try withTemplateDirectory { directory in
        try writeTemplateFile("{{ messages }}", "chat_template.jinja", in: directory)
        try writeTemplateFile("malformed", "tokenizer_config.json", in: directory)
        #expect(!ModelChatTemplate.isUsable(in: directory))
    }
}

@Test func standaloneMustBeReadableRegularUTF8Text() throws {
    try withTemplateDirectory { directory in
        let template = directory.appendingPathComponent("chat_template.jinja")
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: false)
        #expect(!ModelChatTemplate.isUsable(in: directory))
        try FileManager.default.removeItem(at: template)
        try Data([0xff, 0xfe, 0xff]).write(to: template)
        #expect(!ModelChatTemplate.isUsable(in: directory))
        // Loader ignores a failed standalone read and retains embedded content.
        try writeTemplateFile(#"{"chat_template":"embedded"}"#, "tokenizer_config.json", in: directory)
        #expect(ModelChatTemplate.isUsable(in: directory))
    }
}
