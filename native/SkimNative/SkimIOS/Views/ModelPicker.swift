import SkimCore
import SwiftUI
import UIKit

/// Inline, always-available model picker for AI surfaces outside Settings
/// (Ask Skim chat, Summarize, Today). Lets the user switch
/// which model runs without leaving the flow; a provider change still
/// requires the full Settings sheet, reached via the leading "AI Settings…"
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
            // First, so it is one tap away however many models follow
            // (OpenRouter lists hundreds).
            if let onOpenSettings {
                Button {
                    onOpenSettings()
                } label: {
                    Label("AI Settings…", systemImage: "gearshape")
                }
                Divider()
            }

            if isReadOnlyOverride {
                Text("Chat override: \(ModelCatalog.currentLabel(effectiveAI))")
                Text("Change it in AI Settings.")
            } else {
                choiceItems
            }
        } label: {
            PickerChipLabel(title: ModelCatalog.currentLabel(effectiveAI), systemImage: "cpu")
        }
        // Keep the written order even when the menu opens upward, which
        // would otherwise put the first item at the bottom.
        .menuOrder(.fixed)
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
                        Label {
                            menuTitle(choice.label)
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else if !choice.isAvailable {
                        Label {
                            menuTitle(choice.label)
                            Text(choice.detail ?? "Download in AI Settings")
                        } icon: {
                            Image(systemName: "arrow.down.circle")
                        }
                    } else {
                        menuTitle(choice.label)
                    }
                }
                .disabled(!choice.isAvailable)
                .accessibilityLabel(choice.label)
            }
        case .fixed(let label):
            menuTitle(label)
        }
    }

    /// One line per model, eliding the middle of long ids
    /// ("openai/gpt-6-…pro:batch") instead of wrapping them onto two lines.
    /// Menu rows are drawn by UIKit, which ignores `lineLimit`, so the string
    /// itself is shortened; VoiceOver still reads the full id.
    private func menuTitle(_ label: String) -> some View {
        Text(Self.singleLineTitle(label, font: .preferredFont(forTextStyle: .body)))
    }

    /// Text width a menu row fits on one line at the 17pt body size, beside
    /// the checkmark column; on an iPhone longer ids wrap. Scaled with the
    /// font for Dynamic Type.
    static let menuRowTextWidth: CGFloat = 150

    /// `label` unchanged if it fits one menu row in `font`. Otherwise an id
    /// such as "liquid/lfm-2.5-24b-a2b" keeps its provider prefix whole and
    /// loses the middle of the model name, favoring its tail, where the size,
    /// variant or ":free" that tells models apart sits ("liquid/lfm…24b-a2b").
    /// Ids without a short prefix lose their middle evenly.
    static func singleLineTitle(_ label: String, font: UIFont) -> String {
        let maxWidth = menuRowTextWidth * font.pointSize / 17
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        guard width(label) > maxWidth else { return label }

        if let slash = label.firstIndex(of: "/") {
            let prefix = String(label[...slash])
            let model = Array(label[label.index(after: slash)...])
            if width(prefix) <= maxWidth * 0.4 {
                var keep = model.count - 1
                while keep > 1 {
                    let head = keep * 2 / 5
                    let candidate = prefix + String(model.prefix(head)) + "…" + String(model.suffix(keep - head))
                    if width(candidate) <= maxWidth { return candidate }
                    keep -= 1
                }
            }
        }

        let characters = Array(label)
        var keep = characters.count - 1
        while keep > 1 {
            let head = String(characters.prefix((keep + 1) / 2))
            let tail = String(characters.suffix(keep / 2))
            let candidate = head + "…" + tail
            if width(candidate) <= maxWidth { return candidate }
            keep -= 1
        }
        return String(characters.prefix(1)) + "…"
    }
}

/// The capsule face shared by the inline pickers (model, Catch-up range):
/// one line, a trailing chevron so it reads as tappable, never wrapping.
struct PickerChipLabel: View {
    var title: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .opacity(0.7)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(SkimStyle.secondary)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(SkimStyle.surface, in: Capsule())
        .contentShape(Capsule())
    }
}

/// `ModelPickerMenu` bound directly to `AppModel.settings.ai`, for surfaces
/// that mutate the shared settings in place (chat, Today)
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
