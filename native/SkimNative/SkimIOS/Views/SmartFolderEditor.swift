import SwiftUI
import SkimCore

/// Sheet for editing smart folder rules on a folder.
/// Presented when the user taps "Convert to Smart Folder" or "Edit Rules" from
/// the folder context menu in FeedPickerSheet.
struct SmartFolderEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool

    let folder: FeedFolder

    @State private var mode: SmartFolderRules.Mode = .any
    @State private var rules: [SmartFolderRule] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var previewFeeds: [Feed] {
        let currentRules = SmartFolderRules(mode: mode, rules: rules)
        return model.feeds.filter { SmartFolderEval.feedMatches(rules: currentRules, feed: $0) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SkimStyle.chrome.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Mode picker
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Match Feeds When")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SkimStyle.secondary)
                                .textCase(.uppercase)
                                .tracking(0.8)

                            Picker("Mode", selection: $mode) {
                                ForEach(SmartFolderRules.Mode.allCases, id: \.self) { m in
                                    Text(m.displayName).tag(m)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 20)

                        // Rules list
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Rules")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SkimStyle.secondary)
                                    .textCase(.uppercase)
                                    .tracking(0.8)

                                Spacer()

                                Button {
                                    withAnimation(.smooth(duration: 0.18)) {
                                        rules.append(SmartFolderRule())
                                    }
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(SkimStyle.accent)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 20)

                            if rules.isEmpty {
                                Text("No rules yet. Tap + to add one.")
                                    .font(.system(size: 15))
                                    .foregroundStyle(SkimStyle.secondary)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 8)
                            } else {
                                VStack(spacing: 10) {
                                    ForEach($rules) { $rule in
                                        RuleRow(rule: $rule, onRemove: {
                                            withAnimation(.smooth(duration: 0.18)) {
                                                rules.removeAll { $0.id == rule.id }
                                            }
                                        })
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                        .padding(.bottom, 24)

                        // Live preview
                        if !rules.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Matching Feeds (\(previewFeeds.count))")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SkimStyle.secondary)
                                    .textCase(.uppercase)
                                    .tracking(0.8)
                                    .padding(.horizontal, 20)

                                if previewFeeds.isEmpty {
                                    Text("No feeds match the current rules.")
                                        .font(.system(size: 15))
                                        .foregroundStyle(SkimStyle.secondary)
                                        .padding(.horizontal, 20)
                                        .padding(.top, 4)
                                } else {
                                    VStack(spacing: 0) {
                                        ForEach(previewFeeds) { feed in
                                            HStack(spacing: 12) {
                                                Image(systemName: "dot.radiowaves.up.forward")
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(SkimStyle.accent)
                                                    .frame(width: 24, height: 24)
                                                Text(feed.title)
                                                    .font(.system(size: 15))
                                                    .foregroundStyle(SkimStyle.text)
                                                    .lineLimit(1)
                                                Spacer()
                                            }
                                            .padding(.horizontal, 20)
                                            .frame(minHeight: 38)
                                        }
                                    }
                                    .background(SkimStyle.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .padding(.horizontal, 20)
                                }
                            }
                            .padding(.bottom, 32)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 14))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 16)
                        }
                    }
                }
            }
            .navigationTitle("Smart Folder: \(folder.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .foregroundStyle(SkimStyle.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                    .foregroundStyle(SkimStyle.accent)
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            loadExistingRules()
        }
    }

    private func loadExistingRules() {
        if let decoded = SmartFolderRules.from(json: folder.rulesJSON) {
            mode = decoded.mode
            rules = decoded.rules
        } else {
            mode = .any
            rules = []
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let updatedRules = SmartFolderRules(mode: mode, rules: rules)
        let json = updatedRules.toJSON()

        var updated = folder
        updated.isSmart = true
        updated.rulesJSON = json

        do {
            try await model.store.upsertFolder(updated)
            model.folders = try await model.store.listFolders()
            await model.reloadArticles()
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Rule Row

private struct RuleRow: View {
    @Binding var rule: SmartFolderRule
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(SmartFolderRule.RuleType.allCases, id: \.self) { ruleType in
                        Button(ruleType.displayName) {
                            rule.type = ruleType
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(rule.type.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(SkimStyle.text)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SkimStyle.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(SkimStyle.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            TextField(placeholderText, text: $rule.patternOrValue)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(SkimStyle.text)
                .padding(10)
                .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(12)
        .background(SkimStyle.chrome, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SkimStyle.separator.opacity(0.5), lineWidth: 1)
        )
    }

    private var placeholderText: String {
        switch rule.type {
        case .regexTitle: return "e.g. Swift|Apple|Xcode"
        case .regexURL: return "e.g. github\\.com|hacker"
        case .opmlCategory: return "e.g. Technology"
        }
    }
}
