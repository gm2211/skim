import Foundation
import Testing
@testable import SkimInferencePolicy

private actor ControlledInference {
    var started = false
    var calls = 0
    var continuation: CheckedContinuation<Int, Never>?
    func hold() async -> Int {
        started = true
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: 1); continuation = nil }
    func immediate() -> Int { calls += 1; return calls }
}

@Test func localInferenceGateDrainsCancelledWaitersWithoutReleasingActiveComputation() async throws {
    let gate = LocalInferenceGate()
    let work = ControlledInference()
    let active = Task { try await gate.run { await work.hold() } }
    while !(await work.started) { await Task.yield() }
    active.cancel() // Deliberately uncooperative operation remains in flight.
    for _ in 0..<64 {
        let waiter = Task { try await gate.run { await work.immediate() } }
        await Task.yield()
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }
    #expect(await work.calls == 1)
    let next = Task { try await gate.run { await work.immediate() } }
    for _ in 0..<10 { await Task.yield() }
    #expect(await work.calls == 1)
    await work.finish()
    await #expect(throws: CancellationError.self) { try await active.value }
    #expect(try await next.value == 2)
    #expect(try await gate.run { 3 } == 3)
}
