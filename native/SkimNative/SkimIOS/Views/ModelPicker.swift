import SkimCore
import SwiftUI

/// Inline, always-available model picker for AI surfaces outside Settings
/// (Quick Catch-up, Ask Skim chat, Summarize, Today). Lets the user switch
/// which model runs without leaving the flow; a provider change still
/// requires the full Settings sheet, reached via the trailing "AI Settings…"
/// entry.
struct ModelPickerMenu: View {
    @Binding var ai: AISettings
    var isDisabled: Bool = false
    var forChat: Bool = false
    var onOpenSettings: (() -> Void)?

    @State private var choices: ModelChoices = .list([])

    /// The settings actually in effect for display: for chat, a chat
    /// override (different provider and/or model) takes precedence over the
    /// base AI settings, mirroring `AIRequestPolicy.chatSettings`.
    private var effectiveAI: AISettings {
        forChat ? AIRequestPolicy.chatSettings(ai) : ai
    }

    /// Chat pinned to an override can't be changed from this inline menu —
    /// that's configured in Settings' chat override section — so the menu
    /// shows it read-only with just a way back into Settings.
    private var isReadOnlyOverride: Bool {
        forChat && ModelCatalog.hasChatOverride(ai)
    }

    var body: some View {
        Menu {
            if isReadOnlyOverride {
                Text("Chat override: \(ModelCatalog.currentLabel(effectiveAI))")
                Text("Change it in AI Settings.")
            } else {
                choiceItems
            }

            if let onOpenSettings {
                Divider()
                Button {
                    onOpenSettings()
                } label: {
                    Label("AI Settings…", systemImage: "gearshape")
                }
            }
        } label: {
            Label(ModelCatalog.currentLabel(effectiveAI), systemImage: "cpu")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(SkimStyle.secondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(SkimStyle.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel("AI model: \(ModelCatalog.currentLabel(effectiveAI))")
        .task(id: "\(ai.provider)|\(ai.apiKey ?? "")") {
            guard !isReadOnlyOverride else { return }
            choices = await ModelCatalog.choices(for: ai)
        }
    }

    @ViewBuilder
    private var choiceItems: some View {
        switch choices {
        case .list(let items):
            let currentID = ModelCatalog.currentID(effectiveAI)
            ForEach(items) { choice in
                Button {
                    ai = ModelCatalog.applying(choice.id, to: ai, forChat: forChat)
                } label: {
                    if choice.id == currentID {
                        Label(choice.label, systemImage: "checkmark")
                    } else if !choice.isAvailable {
                        Label {
                            Text(choice.label)
                            Text(choice.detail ?? "Download in AI Settings")
                        } icon: {
                            Image(systemName: "arrow.down.circle")
                        }
                    } else {
                        Text(choice.label)
                    }
                }
                .disabled(!choice.isAvailable)
            }
        case .fixed(let label):
            Text(label)
        }
    }
}

/// `ModelPickerMenu` bound directly to `AppModel.settings.ai`, for surfaces
/// that mutate the shared settings in place (Quick Catch-up, chat, Today)
/// rather than a local draft (Summarize's configuration sheet uses
/// `ModelPickerMenu` directly for that reason).
struct AppModelPicker: View {
    @EnvironmentObject private var model: AppModel
    var isDisabled: Bool = false
    var forChat: Bool = false

    @State private var showAISettings = false

    private var aiBinding: Binding<AISettings> {
        Binding(
            get: { model.settings.ai },
            set: { next in
                Task { await model.updateAISettings { $0 = next } }
            }
        )
    }

    var body: some View {
        ModelPickerMenu(
            ai: aiBinding,
            isDisabled: isDisabled,
            forChat: forChat,
            onOpenSettings: { showAISettings = true }
        )
        .sheet(isPresented: $showAISettings) {
            SettingsSheet(isPresented: $showAISettings, aiOnly: true)
                .environmentObject(model)
        }
    }
}
