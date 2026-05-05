import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool

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
            HStack(alignment: .top, spacing: 14) {
                Circle()
                    .fill(aiStatus.isAvailable ? Color.green.opacity(0.82) : Color.orange.opacity(0.9))
                    .frame(width: 10, height: 10)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 6) {
                    Text(aiStatus.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(SkimStyle.text)
                    Text(aiStatus.detail)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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
