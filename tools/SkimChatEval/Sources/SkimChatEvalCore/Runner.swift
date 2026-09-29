import Foundation
import SkimInferencePolicy

public struct EvalOptions: Sendable {
    public var fixturePath: String
    public var bridgePath: String
    public var models: [String]
    public var oneShot: Bool
    public var legacyPrompt: Bool
    public var jsonOutPath: String?

    public init(
        fixturePath: String,
        bridgePath: String,
        models: [String] = EvalOptions.defaultModels,
        oneShot: Bool = false,
        legacyPrompt: Bool = false,
        jsonOutPath: String? = nil
    ) {
        self.fixturePath = fixturePath
        self.bridgePath = bridgePath
        self.models = models
        self.oneShot = oneShot
        self.legacyPrompt = legacyPrompt
        self.jsonOutPath = jsonOutPath
    }

    /// The exact repo ids `NativeMLX.modelOptions` ships
    /// (native/SkimNative/SkimIOS/Support/NativeMLX.swift).
    public static let defaultModels = [
        "mlx-community/gemma-3-1b-it-4bit",
        "mlx-community/Qwen3-1.7B-4bit",
        "mlx-community/Qwen3-4B-Instruct-2507-4bit",
    ]
}

public struct ChatEvalCaseResult: Codable, Sendable {
    public let name: String
    public let seconds: Double
    public let rawAnswer: String
    public let cleanedAnswer: String
    public let rawPassed: Bool
    public let cleanedPassed: Bool
    /// The score actually counted toward `ChatEvalModelRun.passCount`:
    /// `rawPassed` under `--legacy-prompt` (cleanup skipped to show raw
    /// behavior), `cleanedPassed` otherwise.
    public let passed: Bool
    public let firstFailingRule: String?
    public let firstFailingDetail: String?
    public let error: String?
}

public struct ChatEvalModelRun: Codable, Sendable {
    public let model: String
    public let prompt: String
    public let oneShot: Bool
    public let caseCount: Int
    public let passCount: Int
    public let avgSeconds: Double
    public let cases: [ChatEvalCaseResult]
}

public struct ChatEvalReport: Codable, Sendable {
    public let generatedAt: String
    public let fixtureNote: String
    public let fixturePath: String
    public let bridgePath: String
    public let runs: [ChatEvalModelRun]
}

public enum ChatEvalRunner {
    @discardableResult
    public static func run(options: EvalOptions) throws -> ChatEvalReport {
        let fixtureURL = URL(fileURLWithPath: options.fixturePath)
        let fixture = try ChatEvalFixture.load(from: fixtureURL)

        var runs: [ChatEvalModelRun] = []
        for model in options.models {
            let run = runModel(model, fixture: fixture, options: options)
            runs.append(run)
            printModelTable(run)
        }

        let report = ChatEvalReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            fixtureNote: fixture.note,
            fixturePath: options.fixturePath,
            bridgePath: options.bridgePath,
            runs: runs
        )

        if let jsonOutPath = options.jsonOutPath {
            try writeJSON(report, to: jsonOutPath)
            print("Wrote \(jsonOutPath)")
        }

        return report
    }

    private static func runModel(_ model: String, fixture: ChatEvalFixture, options: EvalOptions) -> ChatEvalModelRun {
        let promptLabel = options.legacyPrompt ? "legacy" : "new"
        print("\n=== \(model)  [\(promptLabel)\(options.oneShot ? ", one-shot" : "")] ===")

        guard let bridge = try? ChatEvalBridge(binaryPath: options.bridgePath) else {
            let failure = ChatEvalCaseResult(
                name: "<bridge-startup>",
                seconds: 0,
                rawAnswer: "",
                cleanedAnswer: "",
                rawPassed: false,
                cleanedPassed: false,
                passed: false,
                firstFailingRule: "bridge_startup",
                firstFailingDetail: "could not launch helper at \(options.bridgePath)",
                error: "could not launch helper at \(options.bridgePath)"
            )
            print("  FAILED TO START: \(options.bridgePath)")
            return ChatEvalModelRun(model: model, prompt: promptLabel, oneShot: options.oneShot, caseCount: 0, passCount: 0, avgSeconds: 0, cases: [failure])
        }
        defer { bridge.shutdown() }

        var caseResults: [ChatEvalCaseResult] = []
        for testCase in fixture.cases {
            let result = runCase(testCase, model: model, bridge: bridge, options: options)
            caseResults.append(result)
            let mark = result.passed ? "PASS" : "FAIL"
            var line = "  [\(mark)] \(testCase.name)  (\(String(format: "%.2f", result.seconds))s)"
            if let rule = result.firstFailingRule, let detail = result.firstFailingDetail {
                line += "\n         \(rule): \(detail)"
            }
            print(line)
        }

        let passCount = caseResults.filter(\.passed).count
        let avgSeconds = caseResults.isEmpty ? 0 : caseResults.map(\.seconds).reduce(0, +) / Double(caseResults.count)
        return ChatEvalModelRun(
            model: model,
            prompt: promptLabel,
            oneShot: options.oneShot,
            caseCount: caseResults.count,
            passCount: passCount,
            avgSeconds: avgSeconds,
            cases: caseResults
        )
    }

    private static func runCase(_ testCase: ChatEvalCase, model: String, bridge: ChatEvalBridge, options: EvalOptions) -> ChatEvalCaseResult {
        let prompt = ChatEvalPromptBuilder.build(for: testCase, repoId: model, oneShot: options.oneShot, legacyPrompt: options.legacyPrompt)
        let request = BridgeRequest(
            command: "mlx_complete",
            repoId: model,
            messages: prompt.messages,
            maxTokens: prompt.maxTokens,
            temperature: prompt.temperature
        )

        let start = Date()
        do {
            let raw = try bridge.send(request)
            let seconds = Date().timeIntervalSince(start)
            let cleaned = ChatAnswerCleanup.clean(raw, question: testCase.question)
            let rawScore = ChatAnswerScorer.score(answer: raw, testCase: testCase)
            let cleanedScore = ChatAnswerScorer.score(answer: cleaned, testCase: testCase)
            let primary = options.legacyPrompt ? rawScore : cleanedScore
            return ChatEvalCaseResult(
                name: testCase.name,
                seconds: seconds,
                rawAnswer: raw,
                cleanedAnswer: cleaned,
                rawPassed: rawScore.passed,
                cleanedPassed: cleanedScore.passed,
                passed: primary.passed,
                firstFailingRule: primary.firstFailure?.rule,
                firstFailingDetail: primary.firstFailure?.detail,
                error: nil
            )
        } catch {
            let seconds = Date().timeIntervalSince(start)
            return ChatEvalCaseResult(
                name: testCase.name,
                seconds: seconds,
                rawAnswer: "",
                cleanedAnswer: "",
                rawPassed: false,
                cleanedPassed: false,
                passed: false,
                firstFailingRule: "bridge_error",
                firstFailingDetail: "\(error)",
                error: "\(error)"
            )
        }
    }

    private static func printModelTable(_ run: ChatEvalModelRun) {
        print("  --- \(run.model) [\(run.prompt)]: \(run.passCount)/\(run.caseCount) passed, avg \(String(format: "%.2f", run.avgSeconds))s ---")
    }

    private static func writeJSON(_ report: ChatEvalReport, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
