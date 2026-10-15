import SkimCore
import SwiftUI

/// Red error text plus the action that fixes it: "Sign in again" for an expired
/// Claude session, "Open AI Settings" for missing providers or keys, and a
/// quieter "AI Settings" button for any other AI failure.
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
                // Any other AI failure may still be a provider or model
                // problem, so settings stay one tap away.
                Button { showAISettings = true } label: {
                    Label("AI Settings", systemImage: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.bordered)
                .tint(SkimStyle.accent)
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


/// A gear for the toolbar or header of any surface that calls AI. It opens AI
/// provider settings in a sheet over that surface, so closing it returns there;
/// `onDismiss` lets the caller retry once settings close.
struct AISettingsButton: View {
    /// Shows "AI Settings" as text, for use beside an error or a Retry button.
    var titled = false
    var onDismiss: (() -> Void)? = nil

    @State private var showAISettings = false

    var body: some View {
        Button {
            showAISettings = true
        } label: {
            if titled {
                Text("AI Settings")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            } else {
                Label("AI Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        // Borderless so it stays its own tap target inside a List row.
        .buttonStyle(.borderless)
        .accessibilityLabel("AI Settings")
        .help("AI Settings")
        .sheet(isPresented: $showAISettings, onDismiss: { onDismiss?() }) {
            SettingsSheet(isPresented: $showAISettings, aiOnly: true)
        }
    }
}
