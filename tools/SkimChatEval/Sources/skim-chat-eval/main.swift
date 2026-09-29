import Foundation
import SkimChatEvalCore

/// Resolves a default path relative to the repo root, assuming this tool is
/// invoked as `swift run --package-path tools/SkimChatEval skim-chat-eval`
/// (or the built binary run directly) from the repo root. `--fixture` /
/// `--bridge-path` override these if the tool is run from elsewhere.
func repoRootRelative(_ path: String) -> String {
    FileManager.default.fileExists(atPath: path)
        ? path
        : URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // main.swift -> skim-chat-eval/
            .deletingLastPathComponent() // skim-chat-eval/ -> Sources/
            .deletingLastPathComponent() // Sources/ -> SkimChatEval/
            .deletingLastPathComponent() // SkimChatEval/ -> tools/
            .deletingLastPathComponent() // tools/ -> repo root
            .appendingPathComponent(path)
            .path
}

func printUsage() {
    print("""
    Usage: skim-chat-eval [options]

    Options:
      --models <ids>         Comma-separated MLX repo ids (default: gemma-3-1b-it-4bit, Qwen3-1.7B-4bit, Qwen3-4B-Instruct-2507-4bit)
      --one-shot             Append the one-shot example to the new prompt's system message
      --legacy-prompt        Reproduce the pre-existing production message layout instead of GroundedChatPrompt
      --fixture <path>       Path to the eval fixture JSON (default: shared/fixtures/chat-answer-quality.json)
      --bridge-path <path>   Path to the skim-ai-macos-bridge helper binary
      --json-out <path>      Write the full report as JSON to this path
      --help                 Show this message
    """)
}

var models = EvalOptions.defaultModels
var oneShot = false
var legacyPrompt = false
var fixturePath = repoRootRelative("shared/fixtures/chat-answer-quality.json")
var bridgePath = repoRootRelative("plugins/tauri-plugin-skim-ai/bin/skim-ai-macos-bridge-aarch64-apple-darwin")
var jsonOutPath: String?

var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let arg = arguments[index]
    switch arg {
    case "--models":
        index += 1
        guard index < arguments.count else { print("--models requires a value"); exit(1) }
        models = arguments[index].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    case "--one-shot":
        oneShot = true
    case "--legacy-prompt":
        legacyPrompt = true
    case "--fixture":
        index += 1
        guard index < arguments.count else { print("--fixture requires a value"); exit(1) }
        fixturePath = arguments[index]
    case "--bridge-path":
        index += 1
        guard index < arguments.count else { print("--bridge-path requires a value"); exit(1) }
        bridgePath = arguments[index]
    case "--json-out":
        index += 1
        guard index < arguments.count else { print("--json-out requires a value"); exit(1) }
        jsonOutPath = arguments[index]
    case "--help", "-h":
        printUsage()
        exit(0)
    default:
        print("Unknown argument: \(arg)")
        printUsage()
        exit(1)
    }
    index += 1
}

guard FileManager.default.fileExists(atPath: fixturePath) else {
    print("Fixture not found at \(fixturePath). Pass --fixture <path>.")
    exit(1)
}
guard FileManager.default.fileExists(atPath: bridgePath) else {
    print("Bridge helper not found at \(bridgePath). Pass --bridge-path <path>, or build it with plugins/tauri-plugin-skim-ai/build-macos-bridge.sh.")
    exit(1)
}

let options = EvalOptions(
    fixturePath: fixturePath,
    bridgePath: bridgePath,
    models: models,
    oneShot: oneShot,
    legacyPrompt: legacyPrompt,
    jsonOutPath: jsonOutPath
)

do {
    let report = try ChatEvalRunner.run(options: options)
    let anyFailed = report.runs.contains { $0.passCount < $0.caseCount }
    exit(anyFailed ? 1 : 0)
} catch {
    print("skim-chat-eval failed: \(error)")
    exit(1)
}
