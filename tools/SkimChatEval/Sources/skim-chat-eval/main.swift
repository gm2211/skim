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
      --models <ids>         Comma-separated MLX repo ids (default: the phone-sized models Skim offers)
      --one-shot             Append the one-shot example to the new prompt's system message
      --legacy-prompt        Reproduce the pre-existing production message layout instead of GroundedChatPrompt
      --fixture <path>       Path to the eval fixture JSON (default: shared/fixtures/chat-answer-quality.json)
      --bridge-path <path>   Path to the skim-ai-macos-bridge helper binary
      --summaries <path>     Summary faithfulness fixture (default: shared/fixtures/summary-faithfulness.json)
      --no-summaries         Skip the summary cases
      --no-prefix-reuse      Prefill every question from scratch (A/B for article prefix reuse)
      --no-follow-ups        Skip the unscored same-article follow-up questions
      --json-out <path>      Write the full report as JSON to this path
      --markdown-out <path>  Write a comparison table as Markdown to this path
      --help                 Show this message
    """)
}

var models = EvalOptions.defaultModels
var oneShot = false
var legacyPrompt = false
var fixturePath = repoRootRelative("shared/fixtures/chat-answer-quality.json")
var bridgePath = repoRootRelative("plugins/tauri-plugin-skim-ai/bin/skim-ai-macos-bridge-aarch64-apple-darwin")
var jsonOutPath: String?
var summaryFixturePath: String? = repoRootRelative("shared/fixtures/summary-faithfulness.json")
var prefixReuse = true
var followUps = true
var markdownOutPath: String?

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
    case "--summaries":
        index += 1
        guard index < arguments.count else { print("--summaries requires a value"); exit(1) }
        summaryFixturePath = arguments[index]
    case "--no-summaries":
        summaryFixturePath = nil
    case "--no-prefix-reuse":
        prefixReuse = false
    case "--no-follow-ups":
        followUps = false
    case "--markdown-out":
        index += 1
        guard index < arguments.count else { print("--markdown-out requires a value"); exit(1) }
        markdownOutPath = arguments[index]
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
    jsonOutPath: jsonOutPath,
    summaryFixturePath: summaryFixturePath,
    prefixReuse: prefixReuse,
    followUps: followUps,
    markdownOutPath: markdownOutPath
)

do {
    let report = try ChatEvalRunner.run(options: options)
    let anyFailed = report.runs.contains { $0.passCount < $0.caseCount || $0.summaryPassCount < $0.summaryCaseCount }
    exit(anyFailed ? 1 : 0)
} catch {
    print("skim-chat-eval failed: \(error)")
    exit(1)
}
