import Foundation
import SkimInferencePolicy

public struct EvalOptions: Sendable {
    public var fixturePath: String
    public var bridgePath: String
    public var models: [String]
    public var oneShot: Bool
    public var legacyPrompt: Bool
    public var jsonOutPath: String?
    /// Summary faithfulness fixture; nil skips summaries.
    public var summaryFixturePath: String?
    /// Send the article marker so follow-ups reuse the article's model state,
    /// as the app does. Off measures every question cold.
    public var prefixReuse: Bool
    /// After each chat case, ask one unscored follow-up on the same article
    /// to measure a warm question's speed.
    public var followUps: Bool
    public var markdownOutPath: String?

    public init(
        fixturePath: String,
        bridgePath: String,
        models: [String] = EvalOptions.defaultModels,
        oneShot: Bool = false,
        legacyPrompt: Bool = false,
        jsonOutPath: String? = nil,
        summaryFixturePath: String? = nil,
        prefixReuse: Bool = true,
        followUps: Bool = true,
        markdownOutPath: String? = nil
    ) {
        self.fixturePath = fixturePath
        self.bridgePath = bridgePath
        self.models = models
        self.oneShot = oneShot
        self.legacyPrompt = legacyPrompt
        self.jsonOutPath = jsonOutPath
        self.summaryFixturePath = summaryFixturePath
        self.prefixReuse = prefixReuse
        self.followUps = followUps
        self.markdownOutPath = markdownOutPath
    }

    /// The phone-sized repo ids `NativeMLX.modelOptions` ships
    /// (native/SkimNative/SkimIOS/Support/NativeMLX.swift).
    public static let defaultModels = [
        "mlx-community/LFM2.5-1.2B-Instruct-4bit",
        "mlx-community/Qwen3-1.7B-4bit",
        "mlx-community/Qwen3.5-2B-4bit",
        "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        "mlx-community/Qwen3.5-4B-4bit",
        "mlx-community/gemma-4-e2b-it-4bit",
    ]

    /// The unscored follow-up asked after each chat case.
    public static let followUpQuestion = "What is the most important number in the article?"
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
    public var metrics: GenerationMetrics? = nil
    /// The unscored same-article follow-up, which can reuse the article prefix.
    public var followUpMetrics: GenerationMetrics? = nil
}

public struct SummaryEvalCaseResult: Codable, Sendable {
    public let name: String
    public let summary: String
    public let passed: Bool
    public let failures: [ScoreFailure]
    public let error: String?
    public let metrics: GenerationMetrics?
}

/// Medians across a model's generations, so one slow outlier (the first
/// request also loads the model) doesn't skew the picture.
public struct SpeedSummary: Codable, Sendable {
    public let coldTimeToFirstTokenSeconds: Double
    public let warmTimeToFirstTokenSeconds: Double?
    public let prefillTokensPerSecond: Double
    public let decodeTokensPerSecond: Double
    public let peakMemoryMB: Double
    public let medianPromptTokens: Int
    public let medianReusedTokens: Int?

    static func make(cold: [GenerationMetrics], warm: [GenerationMetrics]) -> SpeedSummary? {
        guard !cold.isEmpty else { return nil }
        let all = cold + warm
        return SpeedSummary(
            coldTimeToFirstTokenSeconds: median(cold.map(\.timeToFirstTokenSeconds)),
            warmTimeToFirstTokenSeconds: warm.isEmpty ? nil : median(warm.map(\.timeToFirstTokenSeconds)),
            prefillTokensPerSecond: median(cold.map(\.prefillTokensPerSecond)),
            decodeTokensPerSecond: median(all.map(\.decodeTokensPerSecond)),
            peakMemoryMB: Double(all.map(\.peakMemoryBytes).max() ?? 0) / 1_048_576,
            medianPromptTokens: Int(median(cold.map { Double($0.promptTokens) })),
            medianReusedTokens: warm.isEmpty ? nil : Int(median(warm.map { Double($0.reusedPromptTokens) }))
        )
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

public struct ChatEvalModelRun: Codable, Sendable {
    public let model: String
    public let prompt: String
    public let oneShot: Bool
    public let caseCount: Int
    public let passCount: Int
    public let avgSeconds: Double
    public let cases: [ChatEvalCaseResult]
    public var summaryCaseCount: Int = 0
    public var summaryPassCount: Int = 0
    public var summaryCases: [SummaryEvalCaseResult] = []
    public var speed: SpeedSummary? = nil
}

public struct ChatEvalReport: Codable, Sendable {
    public let generatedAt: String
    public let fixtureNote: String
    public let fixturePath: String
    public let bridgePath: String
    public var prefixReuse: Bool = true
    public let runs: [ChatEvalModelRun]
}

public enum ChatEvalRunner {
    @discardableResult
    public static func run(options: EvalOptions) throws -> ChatEvalReport {
        let fixtureURL = URL(fileURLWithPath: options.fixturePath)
        let fixture = try ChatEvalFixture.load(from: fixtureURL)
        let summaryFixture = try options.summaryFixturePath.map { try SummaryEvalFixture.load(from: URL(fileURLWithPath: $0)) }

        var runs: [ChatEvalModelRun] = []
        for model in options.models {
            let run = runModel(model, fixture: fixture, summaryFixture: summaryFixture, options: options)
            runs.append(run)
            printModelTable(run)
        }

        let report = ChatEvalReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            fixtureNote: fixture.note,
            fixturePath: options.fixturePath,
            bridgePath: options.bridgePath,
            prefixReuse: options.prefixReuse,
            runs: runs
        )

        if let jsonOutPath = options.jsonOutPath {
            try writeJSON(report, to: jsonOutPath)
            print("Wrote \(jsonOutPath)")
        }
        if let markdownOutPath = options.markdownOutPath {
            try EvalMarkdown.render(report).write(toFile: markdownOutPath, atomically: true, encoding: .utf8)
            print("Wrote \(markdownOutPath)")
        }

        return report
    }

    private static func runModel(_ model: String, fixture: ChatEvalFixture, summaryFixture: SummaryEvalFixture?, options: EvalOptions) -> ChatEvalModelRun {
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

        // Fetches the model if it isn't on disk yet (a no-op re-check otherwise).
        do {
            _ = try bridge.send(BridgeRequest(command: "mlx_download", repoId: model))
        } catch {
            print("  download failed: \(error)")
        }

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

        var summaryResults: [SummaryEvalCaseResult] = []
        for summaryCase in summaryFixture?.cases ?? [] {
            let result = runSummaryCase(summaryCase, model: model, fixture: fixture, bridge: bridge)
            summaryResults.append(result)
            var line = "  [\(result.passed ? "PASS" : "FAIL")] summary \(summaryCase.name)"
            if let failure = result.failures.first { line += "\n         \(failure.rule): \(failure.detail)" }
            print(line)
        }

        let passCount = caseResults.filter(\.passed).count
        let avgSeconds = caseResults.isEmpty ? 0 : caseResults.map(\.seconds).reduce(0, +) / Double(caseResults.count)
        // The first request also loads the model; leave it out of speed.
        let cold = Array((caseResults.compactMap(\.metrics) + summaryResults.compactMap(\.metrics)).dropFirst())
        let warm = caseResults.compactMap(\.followUpMetrics)
        var run = ChatEvalModelRun(
            model: model,
            prompt: promptLabel,
            oneShot: options.oneShot,
            caseCount: caseResults.count,
            passCount: passCount,
            avgSeconds: avgSeconds,
            cases: caseResults
        )
        run.summaryCaseCount = summaryResults.count
        run.summaryPassCount = summaryResults.filter(\.passed).count
        run.summaryCases = summaryResults
        run.speed = SpeedSummary.make(cold: cold, warm: warm)
        return run
    }

    private static func runSummaryCase(_ testCase: SummaryEvalCase, model: String, fixture: ChatEvalFixture, bridge: ChatEvalBridge) -> SummaryEvalCaseResult {
        guard let article = fixture.cases.first(where: { $0.name == testCase.article }) else {
            return SummaryEvalCaseResult(name: testCase.name, summary: "", passed: false,
                failures: [ScoreFailure(rule: "fixture", detail: "no chat case named \(testCase.article)")], error: nil, metrics: nil)
        }
        let prompt = SummaryPromptBuilder.build(article: article, length: testCase.length)
        do {
            let reply = try bridge.sendWithMetrics(BridgeRequest(
                command: "mlx_complete",
                repoId: model,
                messages: prompt.messages,
                maxTokens: prompt.maxTokens
            ))
            let summary = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let score = SummaryScorer.score(summary: summary, testCase: testCase, articleBody: article.body, wordCount: prompt.wordCount)
            return SummaryEvalCaseResult(name: testCase.name, summary: summary, passed: score.passed, failures: score.failures, error: nil, metrics: reply.metrics)
        } catch {
            return SummaryEvalCaseResult(name: testCase.name, summary: "", passed: false,
                failures: [ScoreFailure(rule: "bridge_error", detail: "\(error)")], error: "\(error)", metrics: nil)
        }
    }

    /// Asks a second question about the same article, carrying the first
    /// exchange, the way the app's chat sheet does.
    private static func runFollowUp(after testCase: ChatEvalCase, answer: String, model: String, bridge: ChatEvalBridge, options: EvalOptions) -> GenerationMetrics? {
        let followUp = ChatEvalCase(
            name: testCase.name + "_followup",
            title: testCase.title,
            feed: testCase.feed,
            body: testCase.body,
            question: EvalOptions.followUpQuestion,
            priorTurns: [ChatEvalPriorTurn(question: testCase.question, answer: answer)],
            mustContainAny: [],
            mustNotContain: []
        )
        let prompt = ChatEvalPromptBuilder.build(for: followUp, repoId: model, oneShot: options.oneShot, legacyPrompt: options.legacyPrompt)
        let request = BridgeRequest(
            command: "mlx_complete",
            repoId: model,
            messages: prompt.messages,
            maxTokens: prompt.maxTokens,
            temperature: prompt.temperature,
            reusablePrefixMarker: options.prefixReuse ? PromptPrefix.articleMarker : nil
        )
        return try? bridge.sendWithMetrics(request).metrics
    }

    private static func runCase(_ testCase: ChatEvalCase, model: String, bridge: ChatEvalBridge, options: EvalOptions) -> ChatEvalCaseResult {
        let prompt = ChatEvalPromptBuilder.build(for: testCase, repoId: model, oneShot: options.oneShot, legacyPrompt: options.legacyPrompt)
        let request = BridgeRequest(
            command: "mlx_complete",
            repoId: model,
            messages: prompt.messages,
            maxTokens: prompt.maxTokens,
            temperature: prompt.temperature,
            reusablePrefixMarker: options.prefixReuse && !options.legacyPrompt ? PromptPrefix.articleMarker : nil
        )

        let start = Date()
        do {
            let reply = try bridge.sendWithMetrics(request)
            let raw = reply.text
            let seconds = Date().timeIntervalSince(start)
            let cleaned = ChatAnswerCleanup.clean(raw, question: testCase.question)
            let rawScore = ChatAnswerScorer.score(answer: raw, testCase: testCase)
            let cleanedScore = ChatAnswerScorer.score(answer: cleaned, testCase: testCase)
            let primary = options.legacyPrompt ? rawScore : cleanedScore
            let followUpMetrics = options.followUps && !options.legacyPrompt
                ? runFollowUp(after: testCase, answer: cleaned, model: model, bridge: bridge, options: options)
                : nil
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
                error: nil,
                metrics: reply.metrics,
                followUpMetrics: followUpMetrics
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
        var line = "  --- \(run.model) [\(run.prompt)]: chat \(run.passCount)/\(run.caseCount)"
        if run.summaryCaseCount > 0 { line += ", summaries \(run.summaryPassCount)/\(run.summaryCaseCount)" }
        line += ", avg \(String(format: "%.2f", run.avgSeconds))s"
        if let speed = run.speed {
            line += String(format: ", TTFT %.2fs", speed.coldTimeToFirstTokenSeconds)
            if let warm = speed.warmTimeToFirstTokenSeconds { line += String(format: " (follow-up %.2fs)", warm) }
            line += String(format: ", %.0f tok/s, peak %.0f MB", speed.decodeTokensPerSecond, speed.peakMemoryMB)
        }
        print(line + " ---")
    }

    private static func writeJSON(_ report: ChatEvalReport, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
