import SkimCore
import SwiftUI

/// Red error text plus the action that fixes it, if any: "Sign in again" for
/// an expired Claude session, "Open AI Settings" for missing providers or keys.
/// Runs `onResolved` after the fix sheet is dismissed so callers can retry.
struct AIErrorBox: View {
    var message: String
    var remedy: AIErrorRemedy
    var onResolved: (() -> Void)? = nil

    @State private var showReauth = false
    @State private var showAISettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.red.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)

            switch remedy {
            case .reauthenticate:
                actionButton("Sign in again", systemImage: "person.crop.circle") { showReauth = true }
            case .openAISettings:
                actionButton("Open AI Settings", systemImage: "gearshape") { showAISettings = true }
            case .none:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(isPresented: $showReauth, onDismiss: { onResolved?() }) {
            ClaudeReauthSheet()
        }
        .sheet(isPresented: $showAISettings, onDismiss: { onResolved?() }) {
            SettingsSheet(isPresented: $showAISettings, aiOnly: true)
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(SkimStyle.accent)
    }
}
