import SwiftUI
import SafariServices

struct SignInWithClaudeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authorizeURL: URL?
    @State private var pasteBuffer = ""
    @State private var isExchanging = false
    @State private var errorMessage: String?
    @State private var showSafari = false

    var onSignedIn: () -> Void = {}

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Sign in with your Claude Pro or Max account — no API key needed. Your subscription usage applies.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Step 1 — Open the sign-in page") {
                    Button {
                        Task { await startFlow() }
                    } label: {
                        Label("Open Claude sign-in", systemImage: "safari")
                    }
                    .disabled(authorizeURL != nil)

                    if authorizeURL != nil {
                        Text("After signing in, copy the code shown on the success page.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Step 2 — Paste the code") {
                    TextField("Paste code#state", text: $pasteBuffer, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                        .font(.system(.body, design: .monospaced))

                    Button {
                        Task { await exchange() }
                    } label: {
                        if isExchanging {
                            HStack { ProgressView(); Text("Exchanging…") }
                        } else {
                            Text("Finish sign-in")
                        }
                    }
                    .disabled(pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isExchanging)
                }

                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("Sign in with Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showSafari) {
                if let url = authorizeURL {
                    SafariView(url: url)
                }
            }
        }
    }

    private func startFlow() async {
        let (url, _) = await ClaudeOAuth.shared.beginAuthorization()
        authorizeURL = url
        showSafari = true
    }

    private func exchange() async {
        errorMessage = nil
        isExchanging = true
        defer { isExchanging = false }
        do {
            _ = try await ClaudeOAuth.shared.exchange(pastedCode: pasteBuffer)
            onSignedIn()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#if canImport(UIKit)
import UIKit

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#else
struct SafariView: View {
    let url: URL
    var body: some View {
        Link("Open sign-in", destination: url)
    }
}
#endif
