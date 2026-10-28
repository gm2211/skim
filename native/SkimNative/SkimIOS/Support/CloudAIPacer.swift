import Foundation

/// Whether an AI request was asked for by the reader (a summary, a chat
/// answer) or runs on its own (Smart sort ratings, Today's write-ups, learned
/// preferences). Set with `NativeAI.inBackground`; requests default to the
/// foreground.
enum AIRequestLane: Sendable {
    case foreground
    case background

    @TaskLocal static var current: AIRequestLane = .foreground
}

/// Paces requests to cloud AI providers so the reader's own requests come
/// first. Background work runs one request at a time and waits while a
/// foreground request is in flight, so Today and Smart sort can't fill a rate
/// limit with a burst just before the reader asks for a summary. After a 429
/// the provider gets a cooldown: background work stops asking until it ends,
/// and a foreground request either waits out a short one or stops right away
/// with a clear message instead of asking again into a closed window.
actor CloudAIPacer {
    static let shared = CloudAIPacer()

    /// Longest cooldown a foreground request waits out before asking anyway.
    static let foregroundWaitLimit: TimeInterval = 20
    /// Cooldown after a 429 that doesn't say how long to wait.
    static let defaultCooldown: TimeInterval = 60

    struct Limit: Sendable, Equatable {
        var until: Date
        var message: String
    }

    private var limits: [String: Limit] = [:]
    private var foregroundInFlight = 0
    private var backgroundBusy = false
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []

    /// The cooldown `provider` is in, if one is still running.
    func limit(for provider: String, now: Date = Date()) -> Limit? {
        guard let limit = limits[provider] else { return nil }
        if limit.until <= now {
            limits[provider] = nil
            return nil
        }
        return limit
    }

    func recordLimit(_ limit: Limit, for provider: String) {
        if let existing = limits[provider], existing.until > limit.until { return }
        limits[provider] = limit
    }

    func clearLimit(for provider: String) {
        limits[provider] = nil
    }

    /// Waits for a slot in `lane`. Pair every call with `finish(_:)`.
    func start(_ lane: AIRequestLane) async {
        switch lane {
        case .foreground:
            foregroundInFlight += 1
        case .background:
            if !backgroundBusy, foregroundInFlight == 0 {
                backgroundBusy = true
                return
            }
            await withCheckedContinuation { backgroundWaiters.append($0) }
        }
    }

    func finish(_ lane: AIRequestLane) {
        switch lane {
        case .foreground: foregroundInFlight = max(0, foregroundInFlight - 1)
        case .background: backgroundBusy = false
        }
        resumeNextBackground()
    }

    private func resumeNextBackground() {
        guard !backgroundBusy, foregroundInFlight == 0, !backgroundWaiters.isEmpty else { return }
        backgroundBusy = true
        backgroundWaiters.removeFirst().resume()
    }

    var waitingInBackground: Int { backgroundWaiters.count }

    /// Clears all state; for tests.
    func reset() {
        limits = [:]
        foregroundInFlight = 0
        backgroundBusy = false
        let waiters = backgroundWaiters
        backgroundWaiters = []
        waiters.forEach { $0.resume() }
    }
}

/// What a provider's 429 or overload response says about when to ask again.
struct ProviderBusySignal: Equatable {
    /// Seconds to wait before asking again, when the provider said.
    var retryAfter: TimeInterval?
    /// When the plan's usage window reopens (Claude sign-in), when it said.
    var resetsAt: Date?
    /// The plan's window is closed rather than the request being too fast.
    var planLimitReached: Bool

    /// Reads `retry-after` and, for Claude sign-in, the
    /// `anthropic-ratelimit-unified-*` headers the subscription API returns.
    static func from(_ response: HTTPURLResponse, now: Date = Date()) -> ProviderBusySignal {
        let retryAfter = response.value(forHTTPHeaderField: "retry-after")
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            .flatMap { $0 >= 0 ? $0 : nil }
        let reset = response.value(forHTTPHeaderField: "anthropic-ratelimit-unified-reset")
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            .map { Date(timeIntervalSince1970: $0) }
            .flatMap { $0 > now ? $0 : nil }
        let status = response.value(forHTTPHeaderField: "anthropic-ratelimit-unified-status")?.lowercased()
        return ProviderBusySignal(retryAfter: retryAfter, resetsAt: reset, planLimitReached: status == "rejected")
    }

    /// How long to wait before asking again, if the provider said.
    func wait(now: Date = Date()) -> TimeInterval? {
        if planLimitReached, let resetsAt { return resetsAt.timeIntervalSince(now) }
        return retryAfter ?? resetsAt.map { $0.timeIntervalSince(now) }
    }
}
