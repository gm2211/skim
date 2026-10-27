import CryptoKit
import Foundation
import Network
import SkimCore
import SwiftUI
import Synchronization
import UIKit

// MARK: - Connection

/// Whether the phone has a connection, and whether it is one worth spending on
/// downloads (not cellular or a hotspot, not Low Data Mode). Read from any
/// thread through `offlineNow`/`unmeteredNow`; views observe the published
/// copy, which only ever changes on the main actor.
final class NetworkStatus: ObservableObject, @unchecked Sendable {
    static let shared = NetworkStatus()

    @Published private(set) var isOffline = false
    @Published private(set) var isUnmetered = true

    private struct Snapshot {
        var satisfied = true
        var unmetered = true
        /// A request just failed for want of a connection the system still
        /// reports (a dead subway Wi-Fi, say); treated as offline until then.
        var unreachableUntil: Date?
    }

    private let state = Mutex(Snapshot())
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path)
        }
        monitor.start(queue: DispatchQueue(label: "com.gm2211.skim.network-status", qos: .utility))
    }

    var offlineNow: Bool {
        state.withLock { snapshot in
            !snapshot.satisfied || (snapshot.unreachableUntil.map { $0 > Date() } ?? false)
        }
    }

    var unmeteredNow: Bool {
        state.withLock { $0.satisfied && $0.unmetered }
    }

    /// Records that a request failed for want of a connection.
    func markUnreachable(for seconds: TimeInterval = 30) {
        state.withLock { $0.unreachableUntil = Date().addingTimeInterval(seconds) }
        publish()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.publish()
        }
    }

    private func update(_ path: NWPath) {
        state.withLock { snapshot in
            snapshot.satisfied = path.status == .satisfied
            snapshot.unmetered = !path.isExpensive && !path.isConstrained
            // A new network deserves a fresh try.
            snapshot.unreachableUntil = nil
        }
        publish()
    }

    private func publish() {
        let offline = offlineNow
        let unmetered = unmeteredNow
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isOffline != offline { self.isOffline = offline }
            if self.isUnmetered != unmetered { self.isUnmetered = unmetered }
        }
    }
}

// MARK: - AI fallback

/// With no connection a cloud provider can't answer, so requests go to the
/// on-device model instead: Apple Intelligence, or a downloaded MLX model when
/// Apple Intelligence is off. Settings are never changed; the cloud provider
/// answers again as soon as the phone is back online.
enum OfflineAIFallback {
    private static let cloudProviders: Set<String> = [
        "anthropic", "claude-subscription", "chatgpt-subscription", "openai", "xai", "openrouter", "custom",
    ]

    /// Whether `ai` talks to a server off the phone's own network.
    static func needsConnection(_ ai: AISettings) -> Bool {
        guard cloudProviders.contains(ai.provider) else { return false }
        if ["custom", "openrouter"].contains(ai.provider),
           let host = ai.endpoint.flatMap({ URL(string: $0.trimmingCharacters(in: .whitespaces)) })?.host() {
            return !isLocalNetworkHost(host)
        }
        return true
    }

    static func isLocalNetworkHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".local") || host.hasPrefix("127.") || host == "::1" {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 169 && parts[1] == 254)
    }

    /// `ai` pointed at the on-device model that can answer right now, keeping
    /// summary and sampling preferences; nil when none is ready.
    static func onDevice(_ ai: AISettings) -> AISettings? {
        var local = ai
        if NativeAI.appleIntelligenceUnavailableReason() == nil {
            local.provider = "foundation-models"
            local.model = nil
        } else {
            let repoId = NativeMLX.effectiveDefaultRepoId
            guard NativeMLX.isDownloadedSync(repoId) else { return nil }
            local.provider = "mlx"
            local.model = repoId
        }
        local.localModelPath = nil
        local.apiKey = nil
        local.endpoint = nil
        return local
    }

    static func label(for provider: String) -> String {
        provider == "foundation-models" ? "Apple Intelligence" : "On-device model"
    }

    /// The on-device model answering in place of `ai`'s provider, if any.
    static func activeFallback(for ai: AISettings, offline: Bool = NetworkStatus.shared.offlineNow) -> AISettings? {
        guard offline, needsConnection(ai) else { return nil }
        return onDevice(ai)
    }

    static func effective(_ ai: AISettings) -> AISettings {
        activeFallback(for: ai) ?? ai
    }

    static func effective(_ settings: AppSettings) -> AppSettings {
        var settings = settings
        settings.ai = effective(settings.ai)
        return settings
    }

    /// A failure that means the request never reached the provider.
    static func isConnectivityError(_ error: Error) -> Bool {
        let codes: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
        ]
        if let urlError = error as? URLError {
            return codes.contains(urlError.code)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return codes.contains(URLError.Code(rawValue: nsError.code))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isConnectivityError(underlying)
        }
        return false
    }

    /// Runs `request` on the provider in effect, and once more on the
    /// on-device model when a cloud request fails for want of a connection
    /// the system had not noticed was gone.
    static func run<T>(
        _ settings: AppSettings,
        offline: Bool = NetworkStatus.shared.offlineNow,
        local reroute: (AISettings) -> AISettings? = OfflineAIFallback.onDevice,
        _ request: (AppSettings) async throws -> T
    ) async throws -> T {
        var effectiveSettings = settings
        if offline, needsConnection(settings.ai), let local = reroute(settings.ai) {
            effectiveSettings.ai = local
        }
        do {
            return try await request(effectiveSettings)
        } catch {
            guard needsConnection(effectiveSettings.ai), isConnectivityError(error),
                  let local = reroute(effectiveSettings.ai) else { throw error }
            NetworkStatus.shared.markUnreachable()
            var rerouted = effectiveSettings
            rerouted.ai = local
            return try await request(rerouted)
        }
    }
}

// MARK: - Pictures

/// Article pictures saved on disk so lists, stories and link cards still show
/// them with no connection. Pictures seen online are kept too; the oldest go
/// once the folder passes its budget.
final class OfflineImageCache: Sendable {
    static let shared = OfflineImageCache()
    static let budgetBytes = 200 * 1024 * 1024
    static let maxImageBytes = 4 * 1024 * 1024

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
    }

    func contains(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: url).path)
    }

    /// The saved picture, marked as just used so trimming keeps it.
    func data(for url: URL) -> Data? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    func store(_ data: Data, for url: URL) {
        guard !data.isEmpty, data.count <= Self.maxImageBytes else { return }
        try? data.write(to: fileURL(for: url), options: .atomic)
    }

    /// Downloads and saves `url` unless it is already saved. True when the
    /// picture is saved afterwards.
    @discardableResult
    func prefetch(_ url: URL, session: URLSession = .shared) async -> Bool {
        if contains(url) { return true }
        guard let data = await Self.download(url, session: session) else { return false }
        store(data, for: url)
        return contains(url)
    }

    static func download(_ url: URL, session: URLSession = .shared) async -> Data? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        if let mime = response.mimeType?.lowercased(), !mime.hasPrefix("image/") { return nil }
        guard data.count <= maxImageBytes, UIImage(data: data) != nil else { return nil }
        return data
    }

    func totalBytes() -> Int {
        files().reduce(0) { $0 + $1.size }
    }

    /// Deletes the least recently used pictures until the rest fit `budget`.
    func trim(toBytes budget: Int = OfflineImageCache.budgetBytes) {
        var total = 0
        for file in files().sorted(by: { $0.used > $1.used }) {
            total += file.size
            if total > budget {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }

    private func files() -> [(url: URL, size: Int, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }
}

/// `AsyncImage` that reads and fills `OfflineImageCache`, so a picture seen
/// or preloaded once also shows offline.
struct CachedAsyncImage<Content: View>: View {
    var url: URL?
    var content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            phase = .empty
            return
        }
        let cache = OfflineImageCache.shared
        let saved = await Task.detached(priority: .userInitiated) { cache.data(for: url) }.value
        if let saved, let image = UIImage(data: saved) {
            phase = .success(Image(uiImage: image))
            return
        }
        phase = .empty
        guard let data = await OfflineImageCache.download(url), let image = UIImage(data: data) else {
            if !Task.isCancelled { phase = .failure(URLError(.cannotLoadFromNetwork)) }
            return
        }
        Task.detached(priority: .utility) { cache.store(data, for: url) }
        if !Task.isCancelled { phase = .success(Image(uiImage: image)) }
    }
}
