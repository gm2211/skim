import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @StateObject private var router = ModelRouter.shared
    @State private var showSignIn = false
    @State private var claudeSignedIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section("AI tier") {
                    Picker("Preferred", selection: Binding(
                        get: { router.preferredTier },
                        set: { router.preferredTier = $0; appState.aiProvider = $0.rawValue }
                    )) {
                        ForEach(AITier.allCases) { tier in
                            Text(tier.displayName).tag(tier)
                        }
                    }
                    Text(description(for: router.preferredTier))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if router.preferredTier == .claudeSubscription {
                    Section("Claude subscription") {
                        if claudeSignedIn {
                            Label("Signed in", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Sign out", role: .destructive) {
                                Task {
                                    await ClaudeOAuth.shared.signOut()
                                    refreshAuthState()
                                }
                            }
                        } else {
                            Button {
                                showSignIn = true
                            } label: {
                                Label("Sign in with Claude", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                        Text("Uses your Claude Pro/Max subscription via OAuth. No API key needed.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("Model") {
                        TextField("claude-sonnet-4-6", text: $appState.aiModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if router.preferredTier == .anthropicApiKey {
                    Section("Anthropic API key") {
                        SecureField("sk-ant-…", text: Binding(
                            get: { KeychainStore.get(.anthropicApiKey) ?? "" },
                            set: { KeychainStore.set($0.isEmpty ? nil : $0, for: .anthropicApiKey) }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        TextField("Model", text: $appState.aiModel)
                    }
                }

                if router.preferredTier == .mlx {
                    Section("On-device MLX") {
                        Text(router.mlxModelAvailable ? "Model downloaded" : "No model downloaded")
                            .foregroundStyle(router.mlxModelAvailable ? .green : .secondary)
                        NavigationLink("Manage models") {
                            MLXModelsView()
                        }
                    }
                }

                if router.preferredTier == .foundationModels {
                    Section("Apple Intelligence") {
                        HStack {
                            Image(systemName: router.foundationModelsAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle")
                                .foregroundStyle(router.foundationModelsAvailable ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(router.foundationModelsAvailable ? "Available" : "Not available on this device")
                                    .foregroundStyle(router.foundationModelsAvailable ? .green : .secondary)
                                if router.foundationModelsAvailable {
                                    Text("Active: Apple system language model (on-device)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text(router.foundationModelsAvailable
                             ? "Runs entirely on this device. No network, no account. Requires iOS 26 or later on an Apple Intelligence-capable device."
                             : "Requires iOS 26 or later on an Apple Intelligence-capable device (iPhone 15 Pro / 16+, iPad with M1+) with Apple Intelligence enabled in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.appVersion).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showSignIn) {
                SignInWithClaudeView(onSignedIn: { refreshAuthState() })
            }
            .task {
                refreshAuthState()
                if appState.aiModel.isEmpty, router.preferredTier == .claudeSubscription {
                    appState.aiModel = "claude-sonnet-4-6"
                }
            }
        }
    }

    private func refreshAuthState() {
        Task {
            claudeSignedIn = await ClaudeOAuth.shared.isSignedIn
        }
    }

    private func description(for tier: AITier) -> String {
        switch tier {
        case .foundationModels: return "Apple-managed on-device model. Best privacy; needs Apple Intelligence device."
        case .mlx: return "Local MLX model on your device. Offline, downloads ~2GB."
        case .claudeSubscription: return "Claude Pro/Max via OAuth. Recommended if you have a subscription."
        case .anthropicApiKey: return "Anthropic API key — billed per request."
        case .openai: return "OpenAI API."
        case .ollama: return "Ollama running on your LAN."
        }
    }
}

extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
