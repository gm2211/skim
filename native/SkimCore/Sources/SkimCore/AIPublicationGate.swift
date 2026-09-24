import Foundation

/// Serializes cancellation with synchronous cache or UI publication.
/// A queued callback from a cancelled or completed generation cannot publish afterward.
public final class AIPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    public init() {}

    public func cancel() {
        lock.lock()
        active = false
        lock.unlock()
    }

    @discardableResult
    public func publish(_ operation: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return false }
        operation()
        return true
    }
}
