import Foundation
import Testing
@testable import Skim

private final class BusyStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var headers: [String: String] = [:]; var body = #"{"content":[{"type":"text","text":"ok"}]}"# }
    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        let reply = Self.replies.isEmpty ? Reply(status: 200) : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Cloud AI pacing", .serialized)
struct CloudAIPacerTests {
    private static let rateLimitBody = #"{"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed your account's rate limit. Please try again later."}}"#

    private func session(_ replies: [BusyStubURLProtocol.Reply]) -> URLSession {
        BusyStubURLProtocol.replies = replies
        BusyStubURLProtocol.requests = 0
        NativeAI.busyRetryBackoff = [0, 0]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BusyStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private var request: URLRequest { URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!) }

    @Test func aForegroundRequestIsAskedAgainAfterARateLimit() async throws {
        let pacer = CloudAIPacer()
        let session = session([.init(status: 429, body: Self.rateLimitBody), .init(status: 200)])
        let (_, response) = try await NativeAI.sendPaced(request, provider: "claude-subscription", session: session, pacer: pacer)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(BusyStubURLProtocol.requests == 2)
        #expect(await pacer.limit(for: "claude-subscription") == nil)
    }

    @Test func persistentRateLimitStartsACooldownThatStopsBackgroundWork() async throws {
        let pacer = CloudAIPacer()
        let busy = BusyStubURLProtocol.Reply(status: 429, body: Self.rateLimitBody)
        let session = session([busy, busy, busy])
        let (_, response) = try await NativeAI.sendPaced(request, provider: "claude-subscription", session: session, pacer: pacer)
        #expect((response as? HTTPURLResponse)?.statusCode == 429)
        #expect(BusyStubURLProtocol.requests == 3)
        let limit = try #require(await pacer.limit(for: "claude-subscription"))
        #expect(limit.until > Date().addingTimeInterval(30))

        await #expect(throws: NativeAIError.self) {
            try await NativeAI.inBackground {
                try await NativeAI.sendPaced(self.request, provider: "claude-subscription", session: session, pacer: pacer)
            }
        }
        #expect(BusyStubURLProtocol.requests == 3, "a background request during the cooldown never reaches the network")
    }

    @Test func backgroundRequestsAreNotRetried() async throws {
        let pacer = CloudAIPacer()
        let session = session([.init(status: 429, headers: ["retry-after": "5"], body: Self.rateLimitBody), .init(status: 200)])
        let (_, response) = try await NativeAI.inBackground {
            try await NativeAI.sendPaced(request, provider: "anthropic", session: session, pacer: pacer)
        }
        #expect((response as? HTTPURLResponse)?.statusCode == 429)
        #expect(BusyStubURLProtocol.requests == 1)
    }

    @Test func aClosedPlanWindowIsNotRetried() async throws {
        let pacer = CloudAIPacer()
        let reset = String(Int(Date().addingTimeInterval(3 * 3600).timeIntervalSince1970))
        let session = session([.init(status: 429, headers: [
            "anthropic-ratelimit-unified-status": "rejected",
            "anthropic-ratelimit-unified-reset": reset,
        ], body: Self.rateLimitBody)])
        _ = try await NativeAI.sendPaced(request, provider: "claude-subscription", session: session, pacer: pacer)
        #expect(BusyStubURLProtocol.requests == 1)
        let limit = try #require(await pacer.limit(for: "claude-subscription"))
        #expect(limit.message.hasPrefix("You've reached your Claude plan's usage limit. It resets "))
        #expect(limit.until > Date().addingTimeInterval(2 * 3600))
    }

    @Test func claudesBareRefusalIsNeitherRetriedNorACooldown() async throws {
        let pacer = CloudAIPacer()
        let session = session([.init(status: 429, body: #"{"type":"error","error":{"type":"rate_limit_error","message":"Error"}}"#)])
        _ = try await NativeAI.sendPaced(request, provider: "claude-subscription", session: session, pacer: pacer)
        #expect(BusyStubURLProtocol.requests == 1)
        #expect(await pacer.limit(for: "claude-subscription") == nil)
    }

    @Test func backgroundWorkWaitsForTheReadersRequest() async throws {
        let pacer = CloudAIPacer()
        await pacer.start(.foreground)
        let background = Task { await pacer.start(.background); await pacer.finish(.background); return true }
        var spins = 0
        while await pacer.waitingInBackground == 0, spins < 100 {
            await Task.yield()
            spins += 1
        }
        #expect(await pacer.waitingInBackground == 1)
        await pacer.finish(.foreground)
        #expect(await background.value)
        #expect(await pacer.waitingInBackground == 0)
    }

    @Test func rateLimitErrorsOfferTryAgain() {
        let data = Data(Self.rateLimitBody.utf8)
        let signal = ProviderBusySignal(retryAfter: nil, resetsAt: nil, planLimitReached: false)
        let message = NativeAI.friendlyErrorMessage(status: 429, data: data, provider: "Claude subscription", signal: signal)
        #expect(message == "Claude has hit your account's rate limit for the moment. Try again in a minute.")
        #expect(AIErrorRemedy.classify(NativeAIError.providerBusy(message)) == .retry)
    }
}
