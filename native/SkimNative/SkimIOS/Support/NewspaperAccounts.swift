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
        // WebKit can hand the sheet's last cookies to the store a moment after
        // it closes, so look once more before settling on signed out.
        if !signedIn.contains(paper.id) {
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        }
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

/// Tracks the sign-in browser's address. Sign-in is done once the paper sends
/// the reader on to its own site, which some papers do with a script after the
/// login form, so every address change counts, not just finished page loads.
@MainActor
final class NewspaperSignInBrowser: ObservableObject {
    let paper: Newspaper
    @Published private(set) var finished = false
    private var observation: NSKeyValueObservation?

    init(paper: Newspaper) {
        self.paper = paper
    }

    func attach(_ webView: WKWebView) {
        observation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            let url = webView.url
            Task { @MainActor in self?.saw(url) }
        }
    }

    func saw(_ url: URL?) {
        guard !finished, let url, paper.finishedSignIn(at: url) else { return }
        finished = true
    }
}

/// The paper's own login page, in Skim. It closes itself once the paper sends
/// the reader on to its site; closing it there by hand counts as signed in too.
struct NewspaperSignInSheet: View {
    let paper: Newspaper
    let onEnd: (_ finished: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: NewspaperSignInBrowser

    init(paper: Newspaper, onEnd: @escaping (_ finished: Bool) -> Void) {
        self.paper = paper
        self.onEnd = onEnd
        _browser = StateObject(wrappedValue: NewspaperSignInBrowser(paper: paper))
    }

    var body: some View {
        NavigationStack {
            NewspaperSignInWebView(paper: paper, browser: browser)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(paper.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .onChange(of: browser.finished) { _, finished in
            guard finished else { return }
            // Let the site finish setting its cookies before closing.
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                dismiss()
            }
        }
        .onDisappear { onEnd(browser.finished) }
    }
}

private struct NewspaperSignInWebView: UIViewRepresentable {
    let paper: Newspaper
    let browser: NewspaperSignInBrowser

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        browser.attach(webView)
        if let url = paper.signIn {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let browser: NewspaperSignInBrowser

        init(browser: NewspaperSignInBrowser) {
            self.browser = browser
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            browser.saw(webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browser.saw(webView.url)
        }

        /// "Sign in with Google/Apple" and similar buttons open a new window,
        /// which a bare WKWebView drops. Load it in place instead.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
