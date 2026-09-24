import Foundation
import Testing
@testable import SkimCore

@Test func cancelledSummaryCannotPublishCacheOrQueuedToken() {
    let gate = AIPublicationGate()
    var cache = ""
    var display = ""
    #expect(gate.publish { display += "Initial" })
    gate.cancel()
    #expect(!gate.publish { cache = "Late completion" })
    #expect(!gate.publish { display += " queued token" })
    #expect(cache.isEmpty)
    #expect(display == "Initial")
}

@Test func finishedSummaryCannotAppendQueuedTokenToCanonicalResult() {
    let gate = AIPublicationGate()
    var display = "Partial"
    #expect(gate.publish { display = "Canonical result" })
    gate.cancel()
    #expect(!gate.publish { display += " duplicate tail" })
    #expect(display == "Canonical result")
}

@Test func replacedSummaryGenerationCannotOverwriteNewResult() {
    let old = AIPublicationGate()
    let replacement = AIPublicationGate()
    var display = ""
    old.cancel()
    #expect(replacement.publish { display = "New result" })
    #expect(!old.publish { display = "Stale result" })
    #expect(display == "New result")
}

@Test func cancellationHandlerBlocksUncooperativeSummaryCompletion() async throws {
    actor Rendezvous {
        var waiting: CheckedContinuation<Void, Never>?
        var entered = false
        func suspend() async {
            entered = true
            await withCheckedContinuation { waiting = $0 }
        }
        func finish() { waiting?.resume(); waiting = nil }
    }
    let rendezvous = Rendezvous()
    let gate = AIPublicationGate()
    let generation = Task {
        await withTaskCancellationHandler {
            await rendezvous.suspend() // Provider ignores cancellation and returns later.
            return gate.publish { Issue.record("Cancelled completion published") }
        } onCancel: { gate.cancel() }
    }
    while !(await rendezvous.entered) { await Task.yield() }
    generation.cancel()
    await rendezvous.finish()
    #expect(await generation.value == false)
}
