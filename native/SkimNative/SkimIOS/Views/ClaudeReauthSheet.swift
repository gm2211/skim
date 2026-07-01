import SkimCore
import SwiftUI

/// Standalone Claude sign-in sheet, presentable from any place a Claude auth
/// failure surfaces. Reuses ClaudeOAuthPastePanel and persists via AppModel.
struct ClaudeReauthSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AISettings()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Your Claude session expired. Sign in again to continue.")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)
                    ClaudeOAuthPastePanel(ai: $draft, onSignedIn: { dismiss() }) { url in
                        openURL(url)
                    }
                }
                .padding(24)
            }
            .background(SkimStyle.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle("Sign in with Claude")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { draft = model.settings.ai }
            .onChange(of: draft) { _, newValue in
                Task {
                    var next = model.settings
                    next.ai = newValue
                    await model.saveSettings(next)
                }
            }
        }
    }
}
