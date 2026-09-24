import Foundation

/// Resolves a bounded set of reports without changing their stored feed content.
public enum TodayReaderEvidence {
    public static func resolve(
        articles: [Article], limit: Int = TodayLedePolicy.maxArticles, timeout: Duration = .seconds(6),
        cached: @escaping @Sendable (Article) async -> String?,
        fetch: @escaping @Sendable (Article) async throws -> String?
    ) async throws -> [Article] {
        try await withThrowingTaskGroup(of: (Int, Article).self) { group in
            for (index, article) in articles.prefix(max(0, min(limit, TodayLedePolicy.maxArticles))).enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    let feed = article.contentText ?? ""
                    let cache = await cached(article)
                    try Task.checkCancellation()
                    var best = fullest(feed, cache)
                    // Match desktop evidence hydration: either substantial local source avoids a fetch.
                    if best.count < 400 {
                        let loaded = try await boundedFetch(article, timeout: timeout, fetch: fetch)
                        best = fullest(best, loaded)
                    }
                    try Task.checkCancellation()
                    var resolved = article
                    resolved.contentText = best
                    return (index, resolved)
                }
            }
            var resolved: [(Int, Article)] = []
            for try await value in group { resolved.append(value) }
            return resolved.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func fullest(_ first: String, _ second: String?) -> String {
        let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = second?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return second.count > first.count ? second : first
    }

    private static func boundedFetch(_ article: Article, timeout: Duration,
                                     fetch: @escaping @Sendable (Article) async throws -> String?) async throws -> String? {
        let completion = EvidenceCompletion()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                completion.retain(Task {
                    do { completion.finish(.success(try await fetch(article))) }
                    catch is CancellationError { completion.finish(.failure(CancellationError())) }
                    catch { completion.finish(.success(nil)) }
                })
                completion.retain(Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    completion.finish(.success(nil))
                })
            }
        } onCancel: { completion.finish(.failure(CancellationError())) }
        try Task.checkCancellation()
        return result
    }
}

/// A timed-out loader can finish later, but cannot write application state.
private final class EvidenceCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Error>?
    private var outcome: Result<String?, Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<String?, Error>) {
        lock.lock()
        if let outcome { lock.unlock(); continuation.resume(with: outcome) }
        else { self.continuation = continuation; lock.unlock() }
    }

    func retain(_ task: Task<Void, Never>) {
        lock.lock()
        if outcome != nil { lock.unlock(); task.cancel() }
        else { tasks.append(task); lock.unlock() }
    }

    func finish(_ result: Result<String?, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let continuation = continuation
        self.continuation = nil
        let tasks = tasks
        self.tasks = []
        lock.unlock()
        continuation?.resume(with: result)
        tasks.forEach { $0.cancel() }
    }
}
