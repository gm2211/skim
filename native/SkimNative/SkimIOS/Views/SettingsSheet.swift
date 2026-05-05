import SkimCore
import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var draft = AppSettings()

    var onAddFeed: () -> Void
    var onImportOPML: () -> Void
    var onAutoGroup: () -> Void
    var onRefresh: () -> Void

    private var aiStatus: NativeAIAvailabilityStatus {
        NativeAI.availabilityStatus()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    aiSection
                    librarySection
                    aboutSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .background(SkimStyle.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Save") {
                        Task {
                            await model.saveSettings(draft)
                            isPresented = false
                        }
                    }
                    .font(.system(size: 16, weight: .semibold))
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(SkimStyle.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Settings")
                }
            }
            .onAppear {
                draft = model.settings
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.system(size: 31, weight: .heavy))
                .foregroundStyle(SkimStyle.text)

            Text("Local app controls, AI status, and library maintenance.")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(SkimStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    private var aiSection: some View {
        SettingsSection(title: "AI") {
            Picker("Provider", selection: aiProviderBinding) {
                ForEach(nativeAIProviders, id: \.value) { provider in
                    Text(provider.label).tag(provider.value)
                }
            }
            .pickerStyle(.menu)
            .tint(SkimStyle.accent)

            Text(selectedProviderDescription)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(SkimStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 14) {
                Circle()
                    .fill(providerIsReady ? Color.green.opacity(0.82) : Color.orange.opacity(0.9))
                    .frame(width: 10, height: 10)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 6) {
                    Text(providerStatusTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(SkimStyle.text)
                    Text(providerStatusDetail)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if providerNeedsAPIKey {
                SettingsTextField(
                    title: draft.ai.provider == "claude-subscription" ? "Claude OAuth token" : "API key",
                    placeholder: draft.ai.provider == "anthropic" ? "sk-ant-..." : "sk-...",
                    text: aiAPIKeyBinding,
                    isSecure: true
                )
            }

            if draft.ai.provider != "foundation-models" && draft.ai.provider != "none" && draft.ai.provider != "mlx" {
                SettingsTextField(
                    title: "Model",
                    placeholder: defaultModelPlaceholder,
                    text: aiModelBinding
                )
            }

            if draft.ai.provider == "custom" {
                SettingsTextField(
                    title: "Endpoint",
                    placeholder: "https://api.example.com",
                    text: aiEndpointBinding
                )
            }

            if draft.ai.provider == "mlx" {
                MLXSettingsPanel(ai: aiSettingsBinding)
            }

            Divider()
                .overlay(SkimStyle.separator)

            HStack(spacing: 12) {
                Picker("Summary", selection: summaryLengthBinding) {
                    Text("Tiny").tag("tiny")
                    Text("Short").tag("short")
                    Text("Medium").tag("medium")
                    Text("Long").tag("long")
                }
                .pickerStyle(.menu)
                .tint(SkimStyle.accent)

                Picker("Tone", selection: summaryToneBinding) {
                    Text("Concise").tag("concise")
                    Text("Detailed").tag("detailed")
                    Text("Casual").tag("casual")
                    Text("Technical").tag("technical")
                }
                .pickerStyle(.menu)
                .tint(SkimStyle.accent)
            }

            SettingsTextField(
                title: "Summary prompt",
                placeholder: "Focus on risks, implications, and what changed...",
                text: summaryPromptBinding,
                axis: .vertical
            )

            SettingsTextField(
                title: "AI Inbox interests",
                placeholder: "Prioritize distributed systems, Swift, local AI...",
                text: triagePromptBinding,
                axis: .vertical
            )

            Divider()
                .overlay(SkimStyle.separator)

            SettingRow(systemName: "bolt", title: "Quick Catch-up", detail: "Runs on currently visible articles.")
            SettingRow(systemName: "tray", title: "AI Inbox", detail: "Currently generates a ranked triage sheet.")
            SettingRow(systemName: "bubble.left", title: "Chat", detail: "Available for visible articles and single articles.")
        }
    }

    private var librarySection: some View {
        SettingsSection(title: "Library") {
            HStack {
                SettingMetric(value: model.feeds.count.formatted(), label: "Feeds")
                SettingMetric(value: model.totalUnreadCount.formatted(), label: "Unread")
                SettingMetric(value: model.articles.count.formatted(), label: "Visible")
            }

            Divider()
                .overlay(SkimStyle.separator)

            SettingsAction(systemName: "plus", title: "Add RSS Feed", action: onAddFeed)
            SettingsAction(systemName: "square.and.arrow.down", title: "Import OPML", action: onImportOPML)
            SettingsAction(systemName: "folder.badge.plus", title: "Auto-group Feeds", action: onAutoGroup)
            SettingsAction(systemName: "arrow.clockwise", title: model.isLoading ? "Refreshing..." : "Refresh Feeds", action: onRefresh)
                .disabled(model.isLoading)
        }
    }

    private var aboutSection: some View {
        SettingsSection(title: "About") {
            SettingRow(systemName: "app", title: "Skim", detail: appVersionText)
            SettingRow(systemName: "iphone", title: "Native iOS", detail: "SwiftUI reading loop with local SQLite storage.")
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    private var nativeAIProviders: [(value: String, label: String, description: String)] {
        [
            ("foundation-models", "Apple Intelligence", "Apple's on-device model. Requires Apple Intelligence to finish preparing its language model."),
            ("openai", "OpenAI", "Uses api.openai.com with your API key."),
            ("anthropic", "Claude API Key", "Uses api.anthropic.com with an Anthropic API key."),
            ("claude-subscription", "Claude Pro/Max", "Uses a Claude OAuth bearer token. Full sign-in UI is still being ported."),
            ("openrouter", "OpenRouter", "Uses OpenRouter's OpenAI-compatible API."),
            ("custom", "Custom", "Any OpenAI-compatible endpoint."),
            ("mlx", "On-device MLX", "Download and run a small MLX model on this iPhone. Offline after download."),
            ("none", "None", "Disable AI features.")
        ]
    }

    private var selectedProviderDescription: String {
        nativeAIProviders.first(where: { $0.value == draft.ai.provider })?.description ?? ""
    }

    private var providerNeedsAPIKey: Bool {
        ["openai", "anthropic", "claude-subscription", "openrouter", "custom"].contains(draft.ai.provider)
    }

    private var providerIsReady: Bool {
        switch draft.ai.provider {
        case "foundation-models":
            return aiStatus.isAvailable
        case "mlx":
            return NativeMLX.isAvailable && NativeMLX.isDownloadedSync(mlxSelectedRepoId)
        case "none":
            return false
        default:
            return draft.ai.apiKey?.nilIfEmpty != nil || draft.ai.provider == "custom"
        }
    }

    private var providerStatusTitle: String {
        switch draft.ai.provider {
        case "foundation-models":
            return aiStatus.title
        case "none":
            return "AI disabled"
        case "mlx":
            if !NativeMLX.isAvailable {
                return "MLX unavailable here"
            }
            return NativeMLX.isDownloadedSync(mlxSelectedRepoId) ? "On-device MLX ready" : "Download a model"
        default:
            return providerIsReady ? "Provider configured" : "API key needed"
        }
    }

    private var providerStatusDetail: String {
        switch draft.ai.provider {
        case "foundation-models":
            return aiStatus.detail
        case "none":
            return "Choose another provider to use summaries, chat, catch-up, and AI Inbox."
        case "mlx":
            let option = NativeMLX.option(for: mlxSelectedRepoId)
            if !NativeMLX.isAvailable {
                return "MLX inference and downloads require a real iPhone; the Simulator cannot run this backend."
            }
            if NativeMLX.isDownloadedSync(mlxSelectedRepoId) {
                return "\(option.label) is cached locally and ready for summaries, chat, catch-up, and AI Inbox."
            }
            return "Choose a model, download it once, then Skim can run AI locally on-device."
        default:
            return providerIsReady ? "Skim will use this provider for chat, summaries, catch-up, and AI Inbox." : "Paste a token or API key, then save settings."
        }
    }

    private var defaultModelPlaceholder: String {
        switch draft.ai.provider {
        case "anthropic", "claude-subscription":
            return "claude-sonnet-4-5"
        case "openrouter":
            return "openai/gpt-4o-mini"
        default:
            return "gpt-4o-mini"
        }
    }

    private var mlxSelectedRepoId: String {
        draft.ai.localModelPath?.nilIfEmpty
            ?? draft.ai.model?.nilIfEmpty
            ?? NativeMLX.defaultRepoId
    }

    private var aiProviderBinding: Binding<String> {
        Binding(
            get: { draft.ai.provider },
            set: { value in
                updateAI {
                    $0.provider = value
                    if value == "mlx" {
                        let repoId = $0.localModelPath?.nilIfEmpty ?? $0.model?.nilIfEmpty ?? NativeMLX.defaultRepoId
                        $0.localModelPath = repoId
                        $0.model = repoId
                    }
                }
            }
        )
    }

    private var aiSettingsBinding: Binding<AISettings> {
        Binding(
            get: { draft.ai },
            set: { value in
                var next = draft
                next.ai = value
                draft = next
            }
        )
    }

    private var aiAPIKeyBinding: Binding<String> {
        Binding(
            get: { draft.ai.apiKey ?? "" },
            set: { value in updateAI { $0.apiKey = value.nilIfEmpty } }
        )
    }

    private var aiModelBinding: Binding<String> {
        Binding(
            get: { draft.ai.model ?? "" },
            set: { value in updateAI { $0.model = value.nilIfEmpty } }
        )
    }

    private var aiEndpointBinding: Binding<String> {
        Binding(
            get: { draft.ai.endpoint ?? "" },
            set: { value in updateAI { $0.endpoint = value.nilIfEmpty } }
        )
    }

    private var summaryLengthBinding: Binding<String> {
        Binding(
            get: { draft.ai.summaryLength ?? "short" },
            set: { value in updateAI { $0.summaryLength = value } }
        )
    }

    private var summaryToneBinding: Binding<String> {
        Binding(
            get: { draft.ai.summaryTone ?? "concise" },
            set: { value in updateAI { $0.summaryTone = value } }
        )
    }

    private var summaryPromptBinding: Binding<String> {
        Binding(
            get: { draft.ai.summaryCustomPrompt ?? "" },
            set: { value in updateAI { $0.summaryCustomPrompt = value.nilIfEmpty } }
        )
    }

    private var triagePromptBinding: Binding<String> {
        Binding(
            get: { draft.ai.triageUserPrompt ?? "" },
            set: { value in updateAI { $0.triageUserPrompt = value.nilIfEmpty } }
        )
    }

    private func updateAI(_ mutate: (inout AISettings) -> Void) {
        var next = draft
        mutate(&next.ai)
        draft = next
    }
}

private struct MLXSettingsPanel: View {
    @Binding var ai: AISettings
    @State private var isDownloaded = false
    @State private var downloadProgress: Double?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var selectedRepoId: String {
        ai.localModelPath?.nilIfEmpty
            ?? ai.model?.nilIfEmpty
            ?? NativeMLX.defaultRepoId
    }

    private var selectedOption: MLXModelOption {
        NativeMLX.option(for: selectedRepoId)
    }

    private var selectedRepoBinding: Binding<String> {
        Binding(
            get: { selectedRepoId },
            set: { repoId in
                ai.localModelPath = repoId
                ai.model = repoId
                errorMessage = nil
                refreshDownloadState()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Model", selection: selectedRepoBinding) {
                ForEach(NativeMLX.modelOptions) { option in
                    Text(option.label).tag(option.repoId)
                }
            }
            .pickerStyle(.menu)
            .tint(SkimStyle.accent)

            Text("Storage estimate: ~\(storageText(selectedOption.sizeGB)) on disk. Interrupted downloads are cleaned before the next attempt.")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(SkimStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !NativeMLX.isAvailable {
                providerNotice(
                    color: .orange,
                    title: "Real iPhone required",
                    detail: "The Simulator can show settings, but MLX downloads and inference run only on-device."
                )
            }

            if let errorMessage {
                providerNotice(color: .red, title: "MLX error", detail: errorMessage)
            }

            if let downloadProgress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: downloadProgress)
                        .tint(SkimStyle.accent)
                    Text("Downloading \(Int(downloadProgress * 100))%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SkimStyle.secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    Task { await downloadSelectedModel() }
                } label: {
                    Text(isDownloaded ? "Downloaded" : "Download")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(isDownloaded ? Color.green.opacity(0.45) : SkimStyle.accent)
                .disabled(isWorking || isDownloaded || !NativeMLX.isAvailable)

                if isDownloaded {
                    Button(role: .destructive) {
                        Task { await deleteSelectedModel() }
                    } label: {
                        Text("Delete")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                }
            }
        }
        .task(id: selectedRepoId) {
            await refreshDownloadStateAsync()
        }
    }

    private func providerNotice(color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color.opacity(0.88))
                .frame(width: 9, height: 9)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(SkimStyle.text)
                Text(detail)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(SkimStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func storageText(_ size: Double) -> String {
        size > 0 ? String(format: "%.1f GB", size) : "unknown"
    }

    @MainActor
    private func refreshDownloadState() {
        isDownloaded = NativeMLX.isDownloadedSync(selectedRepoId)
    }

    @MainActor
    private func refreshDownloadStateAsync() async {
        isDownloaded = await NativeMLX.isDownloaded(selectedRepoId)
    }

    @MainActor
    private func downloadSelectedModel() async {
        errorMessage = nil
        downloadProgress = 0
        isWorking = true
        let repoId = selectedRepoId
        do {
            try await NativeMLX.download(repoId: repoId) { progress in
                Task { @MainActor in
                    downloadProgress = progress
                }
            }
            ai.localModelPath = repoId
            ai.model = repoId
            isDownloaded = true
            downloadProgress = nil
        } catch {
            errorMessage = error.localizedDescription
            downloadProgress = nil
            isDownloaded = NativeMLX.isDownloadedSync(repoId)
        }
        isWorking = false
    }

    @MainActor
    private func deleteSelectedModel() async {
        errorMessage = nil
        isWorking = true
        let repoId = selectedRepoId
        do {
            try await NativeMLX.delete(repoId: repoId)
            isDownloaded = false
        } catch {
            errorMessage = error.localizedDescription
            isDownloaded = NativeMLX.isDownloadedSync(repoId)
        }
        isWorking = false
    }
}

private struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(SkimStyle.secondary)
                .tracking(1.2)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(SkimStyle.separator, lineWidth: 1)
            }
        }
    }
}

private struct SettingsTextField: View {
    var title: String
    var placeholder: String
    @Binding var text: String
    var isSecure = false
    var axis: Axis = .horizontal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(SkimStyle.secondary)
                .textCase(.uppercase)
                .tracking(0.7)

            if isSecure {
                SecureField(placeholder, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle
            } else {
                TextField(placeholder, text: $text, axis: axis)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(axis == .vertical ? 3...6 : 1...1)
                    .textFieldStyle
            }
        }
    }
}

private struct SettingRow: View {
    var systemName: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(SkimStyle.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SkimStyle.text)
                Text(detail)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(SkimStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension View {
    var textFieldStyle: some View {
        self
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(SkimStyle.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SkimStyle.chrome, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SkimStyle.separator, lineWidth: 1)
            }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct SettingsAction: View {
    var systemName: String
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SkimStyle.secondary.opacity(0.7))
            }
            .foregroundStyle(SkimStyle.text)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingMetric: View {
    var value: String
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 23, weight: .heavy))
                .foregroundStyle(SkimStyle.text)
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(SkimStyle.secondary)
                .tracking(0.8)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
