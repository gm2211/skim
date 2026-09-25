import Foundation

/// Serializes expensive local inference. Cancellation removes waiting work, but
/// never releases an active operation's permit before that operation has returned.
public actor LocalInferenceGate {
    private var occupied = false
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    public init() {}

    public func run<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        try await acquire()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !occupied { occupied = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                order.append(id)
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }

    private func release() {
        while !order.isEmpty {
            let id = order.removeFirst()
            if let continuation = waiters.removeValue(forKey: id) {
                continuation.resume()
                return
            }
        }
        occupied = false
    }
}
