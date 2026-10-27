import SkimCore
import SwiftUI
import WebKit

/// Sign-ins to the newspapers in shared/newspapers.json. The sign-in sheet is
/// a WKWebView on the default website data store, so the paper's cookies stay
/// there; the reader sends them, only to that paper, when it loads one of its
/// articles. The article's Web page uses the same store and is signed in too.
@MainActor
final class NewspaperAccounts: ObservableObject {
    nonisolated static let catalog: NewspaperCatalog? = Bundle.main.url(forResource: "newspapers", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? NewspaperCatalog(data: $0) }

    @Published private(set) var signedIn: Set<String> = []

    var newspapers: [Newspaper] { Self.catalog?.newspapers ?? [] }

    private static func finishedKey(_ id: String) -> String { "newspaper_signed_in.\(id)" }

    func refresh() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        signedIn = Set(newspapers.filter { paper in
            let names = cookies.filter { paper.owns(host: $0.domain) }.map(\.name)
            let finished = UserDefaults.standard.bool(forKey: Self.finishedKey(paper.id))
            return paper.isSignedIn(finishedSignIn: finished, cookieNames: names)
        }.map(\.id))
    }

    /// Called when the sign-in sheet closes. `finished` is true when the paper
    /// sent the reader on to its site, which is how a sign-in ends.
    func signInEnded(_ paper: Newspaper, finished: Bool, store: SkimStore) async {
        if finished {
            UserDefaults.standard.set(true, forKey: Self.finishedKey(paper.id))
        }
        await forgetReaderCopies(of: paper, store: store)
        await refresh()
    }

    func signOut(_ paper: Newspaper, store: SkimStore) async {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await cookieStore.allCookies() where paper.owns(host: cookie.domain) {
            await cookieStore.deleteCookie(cookie)
        }
        UserDefaults.standard.removeObject(forKey: Self.finishedKey(paper.id))
        await forgetReaderCopies(of: paper, store: store)
        await refresh()
    }

    /// Reader copies saved before the sign-in changed would keep the paywall.
    private func forgetReaderCopies(of paper: Newspaper, store: SkimStore) async {
        ExtractedContentCache.shared.removeAll()
        let owns: @Sendable (URL) -> Bool = { url in url.host().map(paper.owns(host:)) ?? false }
        try? await store.forgetReaderTexts(where: owns)
    }

    /// The `Cookie` header for a reader fetch of `url`, or nil for any site
    /// that is not a newspaper the reader has cookies for.
    static func cookieHeader(for url: URL) async -> String? {
        guard let catalog, catalog.newspaper(for: url) != nil else { return nil }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return catalog.cookieHeader(for: url, cookies: cookies.map { ($0.domain, $0.name, $0.value) })
    }
}

/// The paper's own login page, in Skim. It closes itself once the paper sends
/// the reader on to its site.
struct NewspaperSignInSheet: View {
    let paper: Newspaper
    let onEnd: (_ finished: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var finished = false

    var body: some View {
        NavigationStack {
            NewspaperSignInWebView(paper: paper) {
                guard !finished else { return }
                finished = true
                // Let the site finish setting its cookies before closing.
                Task {
                    try? await Task.sleep(for: .milliseconds(1500))
                    dismiss()
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(paper.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onDisappear { onEnd(finished) }
    }
}

private struct NewspaperSignInWebView: UIViewRepresentable {
    let paper: Newspaper
    let onFinished: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if let url = paper.signIn {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: NewspaperSignInWebView

        init(parent: NewspaperSignInWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url, parent.paper.finishedSignIn(at: url) else { return }
            parent.onFinished()
        }
    }
}
