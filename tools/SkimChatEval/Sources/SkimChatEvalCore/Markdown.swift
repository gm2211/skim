import Foundation

/// A one-table comparison of every model in a report, for docs/releases.
public enum EvalMarkdown {
    public static func render(_ report: ChatEvalReport) -> String {
        var lines: [String] = [
            "# On-device model eval",
            "",
            "Generated \(report.generatedAt). Article prefix reuse: \(report.prefixReuse ? "on" : "off").",
            "",
            "| Model | Chat answers | Faithful summaries | First token | Follow-up first token | Prefill tok/s | Decode tok/s | Peak memory |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for run in report.runs {
            let name = run.model.replacingOccurrences(of: "mlx-community/", with: "")
            let summaries = run.summaryCaseCount > 0 ? "\(run.summaryPassCount)/\(run.summaryCaseCount)" : "-"
            if let speed = run.speed {
                let warm = speed.warmTimeToFirstTokenSeconds.map { String(format: "%.2f s", $0) } ?? "-"
                lines.append(String(
                    format: "| %@ | %d/%d | %@ | %.2f s | %@ | %.0f | %.0f | %.0f MB |",
                    name, run.passCount, run.caseCount, summaries,
                    speed.coldTimeToFirstTokenSeconds, warm,
                    speed.prefillTokensPerSecond, speed.decodeTokensPerSecond, speed.peakMemoryMB
                ))
            } else {
                lines.append("| \(name) | \(run.passCount)/\(run.caseCount) | \(summaries) | - | - | - | - | - |")
            }
        }

        let failures = report.runs.flatMap { run in
            run.cases.filter { !$0.passed }.map { "- \(run.model) chat `\($0.name)`: \($0.firstFailingRule ?? "?") \($0.firstFailingDetail ?? "")" }
                + run.summaryCases.filter { !$0.passed }.map { "- \(run.model) summary `\($0.name)`: \($0.failures.map { "\($0.rule) \($0.detail)" }.joined(separator: "; "))" }
        }
        if !failures.isEmpty {
            lines += ["", "## Failures", ""] + failures
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
