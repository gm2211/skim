import SwiftUI
import WebKit

struct WebViewSnapshot: Equatable {
    var url: URL?
    var title: String?
    var text: String?
}

struct WebView: UIViewRepresentable {
    let url: URL?
    @Binding var snapshot: WebViewSnapshot

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.backgroundColor = UIColor(SkimStyle.background)
        webView.isOpaque = false
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard let url else { return }
        if context.coordinator.requestedURL != url {
            context.coordinator.requestedURL = url
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        var requestedURL: URL?

        init(parent: WebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            updateSnapshot(from: webView, text: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let script = """
            (() => {
              return {
                url: window.location.href || '',
                title: document.title || '',
                text: document.body ? document.body.innerText : ''
              };
            })();
            """
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
                guard let self, let webView else { return }
                if let payload = result as? [String: Any] {
                    let urlText = payload["url"] as? String
                    let title = payload["title"] as? String
                    let text = payload["text"] as? String
                    self.updateSnapshot(
                        url: urlText.flatMap(URL.init(string:)) ?? webView.url,
                        title: title ?? webView.title,
                        text: text
                    )
                } else {
                    self.updateSnapshot(from: webView, text: nil)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            updateSnapshot(from: webView, text: nil)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            updateSnapshot(from: webView, text: nil)
        }

        private func updateSnapshot(from webView: WKWebView, text: String?) {
            updateSnapshot(url: webView.url, title: webView.title, text: text)
        }

        private func updateSnapshot(url: URL?, title: String?, text: String?) {
            DispatchQueue.main.async {
                self.parent.snapshot = WebViewSnapshot(
                    url: url,
                    title: title?.nilIfEmpty,
                    text: text?.nilIfEmpty
                )
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
