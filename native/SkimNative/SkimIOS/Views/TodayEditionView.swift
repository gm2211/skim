import SkimCore
import SwiftUI

/// Native presentation of SkimCore's persisted edition; no ranking or snapshot logic here.
struct TodayEditionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("todayStoryLimit") private var storyLimit = 10

    /// Stories that get a written lede and full-size setting; the rest of the
    /// page runs as one-line briefs.
    private static let leadCount = 6

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Label("Articles", systemImage: "chevron.left")
                        .frame(minHeight: 44)
                }
                Spacer()
                Text("Today").font(.headline)
                Spacer()
                AppModelPicker(isDisabled: model.isUpdatingToday || model.todayLedeStatus != nil)
                Menu {
                    Picker("Stories per edition", selection: $storyLimit) {
                        Text("5 stories").tag(5)
                        Text("10 stories").tag(10)
                        Text("20 stories").tag(20)
                    }
                } label: {
                    Label("\(storyLimit)", systemImage: "line.3.horizontal.decrease")
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("Stories per edition: \(storyLimit)")
                .disabled(model.isUpdatingToday)
            }
            .padding(.horizontal, 16)
            .background(SkimStyle.chrome)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if model.isLoadingToday {
                        ProgressView("Loading today’s edition…")
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        if let error = model.todayError {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Couldn’t load Today").font(.headline)
                                Text(error).font(.subheadline).foregroundStyle(SkimStyle.secondary)
                                Button("Try again") { Task { await load() } }
                                    .frame(minHeight: 44)
                            }
                        }
                        if let edition = model.todayEdition {
                            editionHeader(edition)
                            preparationStatus
                            if edition.items.isEmpty {
                                emptyEdition
                            } else {
                                if let status = model.todayLedeStatus {
                                    TodayWritingRule(status: status)
                                } else if model.todayLedeNeedsRetry {
                                    Button("Retry missing summaries") { Task { await model.retryTodayLedes() } }
                                        .font(.subheadline)
                                        .frame(minHeight: 44)
                                }
                                // The edition is already ordered by importance,
                                // so position is all the page needs: the first
                                // story leads, the next few run as stories, the
                                // tail becomes briefs.
                                ForEach(Array(edition.items.enumerated()), id: \.element.id) { position, item in
                                    if position == Self.leadCount {
                                        Text("ALSO")
                                            .font(.system(size: 11, weight: .bold))
                                            .kerning(1.2)
                                            .foregroundStyle(SkimStyle.secondary.opacity(0.8))
                                            .padding(.top, 8)
                                    }
                                    TodayStoryView(
                                        item: item,
                                        rank: Self.rank(for: position),
                                        isWritingLede: model.todayLedeStatus != nil
                                            && position < Self.leadCount,
                                        isUpdating: model.isUpdatingToday,
                                        onToggleConsumed: { Task { await model.setTodayConsumed(item) } }
                                    )
                                }
                                if edition.consumedItemCount == edition.totalItemCount {
                                    Label("You’re all caught up for today.", systemImage: "checkmark.circle.fill")
                                        .font(.headline)
                                        .foregroundStyle(SkimStyle.accent)
                                        .padding(.vertical, 12)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await load() }
        }
        .background(SkimStyle.background.ignoresSafeArea())
        .foregroundStyle(SkimStyle.text)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: storyLimit) {
            if ![5, 10, 20].contains(storyLimit) { storyLimit = 10; return }
            await load()
            // Renew the local-day window even if Today stays open across midnight.
            while !Task.isCancelled {
                let start = Calendar.current.startOfDay(for: Date())
                let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
                do { try await Task.sleep(for: .seconds(max(1, end.timeIntervalSinceNow + 1))) }
                catch { return }
                await load()
            }
        }
        .onDisappear { model.cancelTodayWork() }
        .onChange(of: NativeAI.todayPreparationIdentity(settings: model.settings)) { _, _ in
            model.startTodayPreparation(storyLimit: storyLimit)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
    }

    @ViewBuilder private var preparationStatus: some View {
        if let status = model.todayPreparation, status.state != "disabled", status.state != "empty" {
            VStack(alignment: .leading, spacing: 8) {
                if status.state == "preparing" {
                    Label("Preparing today’s update", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                } else if status.canPublish {
                    Text("Updated edition ready").font(.subheadline.weight(.semibold))
                }
                if status.assessedCount < status.eligibleCount {
                    Text("\(status.assessedCount) of \(status.eligibleCount) stories reviewed · Reviewing stories")
                        .font(.footnote).foregroundStyle(SkimStyle.secondary)
                } else if status.state == "preparing" {
                    Text("\(status.assessedCount) of \(status.eligibleCount) stories reviewed · Checking related reports")
                        .font(.footnote).foregroundStyle(SkimStyle.secondary)
                }
                if let error = model.todayPreparationError {
                    Text(error).font(.footnote).foregroundStyle(SkimStyle.secondary)
                }
                if status.state == "failed" || model.todayPreparationError != nil {
                    Text(status.assessmentFailedCount > 0 ? "Some stories could not be reviewed." : "Related-report checks need another look.").font(.footnote)
                    Button("Retry preparation") { model.startTodayPreparation(storyLimit: storyLimit, retryFailed: true) }
                        .frame(minHeight: 44)
                }
                if status.canPublish {
                    Button("Open updated edition") { Task { await model.openPreparedTodayEdition() } }
                        .frame(minHeight: 44).disabled(model.isUpdatingToday)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SkimStyle.chrome, in: RoundedRectangle(cornerRadius: 14))
        } else if let error = model.todayPreparationError {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(.footnote)
                Button("Retry preparation") { model.startTodayPreparation(storyLimit: storyLimit, retryFailed: true) }
                    .frame(minHeight: 44)
            }
        }
    }

    private func load() async { await model.loadTodayEdition(storyLimit: storyLimit) }

    private func editionHeader(_ edition: TodayEditionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(edition.edition.startsAt.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.title2.bold())
            if edition.totalItemCount > 0 {
                HStack {
                    Text("\(edition.consumedItemCount) of \(edition.totalItemCount) read")
                    Spacer()
                    Text(edition.progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(SkimStyle.secondary)
                ProgressView(value: edition.progress)
                    .accessibilityLabel("Edition progress")
            }
            Text("Saved at \(edition.edition.generatedAt.formatted(date: .omitted, time: .shortened)). Stories stay fixed for this edition.")
                .font(.footnote)
                .foregroundStyle(SkimStyle.secondary)
        }
    }

    private var emptyEdition: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sun.max").font(.largeTitle).foregroundStyle(SkimStyle.accent)
            Text("No stories in this edition").font(.title3.bold())
            Text("This saved edition has no stories. Refresh feeds in Articles to read new coverage. Tomorrow brings a new edition.")
                .font(.body).foregroundStyle(SkimStyle.secondary)
            Button("Browse articles") { dismiss() }.frame(minHeight: 44)
        }
        .padding(.vertical, 28)
    }

    /// Where a story sits on the page, from its position in the edition.
    static func rank(for position: Int) -> TodayStoryRank {
        if position == 0 { return .lead }
        if position < leadCount { return .story }
        return .brief
    }
}

enum TodayStoryRank {
    case lead, story, brief
}

// MARK: - One story on the page

private struct TodayStoryView: View {
    var item: TodayEditionItem
    var rank: TodayStoryRank
    var isWritingLede: Bool
    var isUpdating: Bool
    var onToggleConsumed: () -> Void
    @State private var referencesExpanded = false

    private var lead: Bool { rank == .lead }
    private var brief: Bool { rank == .brief }

    /// A written lede is the story; the mechanical excerpt is the stand-in
    /// until one arrives, and briefs never get one.
    private var ledeOrExcerpt: String {
        if let lede = item.snapshot.lede?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lede.isEmpty {
            return lede
        }
        return brief ? "" : item.snapshot.snapshotSummary
    }

    private var awaitingLede: Bool {
        !brief && (item.snapshot.lede ?? "").isEmpty && isWritingLede
    }

    private var openable: TodayEditionSourceArticle? {
        item.sourceArticles.first(where: { $0.isRepresentative && $0.liveArticle != nil })
            ?? item.sourceArticles.first(where: { $0.liveArticle != nil })
    }

    private var ledeSource: TodayEditionSourceArticle? {
        guard !(item.snapshot.lede?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              let sourceID = item.snapshot.ledeSourceArticleID else { return nil }
        return item.sourceArticles.first(where: { $0.articleID == sourceID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: lead ? 10 : 7) {
            Divider().overlay(SkimStyle.separator.opacity(0.6))
                .padding(.bottom, lead ? 6 : 4)

            headline

            if awaitingLede {
                TodayLedeSkeleton(lead: lead)
            } else if !ledeOrExcerpt.isEmpty {
                Text(ledeOrExcerpt)
                    .font(.system(size: lead ? 17 : 15, weight: .regular))
                    .foregroundStyle(SkimStyle.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let source = ledeSource {
                sourceLink(source)
            }

            if let delta = item.materialDelta, !brief {
                Text("What's new: \(delta)")
                    .font(.system(size: 14))
                    .foregroundStyle(SkimStyle.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !item.sourceArticles.isEmpty {
                DisclosureGroup(isExpanded: $referencesExpanded) {
                    ForEach(item.sourceArticles, id: \.articleID) { source in
                        VStack(alignment: .leading, spacing: 0) {
                            TodayByline(source: source)
                            if source.membershipType == .duplicate {
                                Text("Syndicated report")
                                    .font(.caption)
                                    .foregroundStyle(SkimStyle.secondary)
                            }
                        }
                    }
                } label: {
                    Text("\(item.sourceArticles.count) \(item.sourceArticles.count == 1 ? "report" : "reports")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SkimStyle.secondary)
                        .frame(minHeight: 44)
                }
                .tint(SkimStyle.secondary)
            }

            Button(action: onToggleConsumed) {
                Text(item.snapshot.isConsumed ? "Mark unread" : "Mark read")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SkimStyle.secondary)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .disabled(isUpdating)
        }
        .opacity(item.snapshot.isConsumed ? 0.55 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headlineText: some View {
        Text(item.snapshot.snapshotTitle)
            .font(.system(
                size: lead ? 26 : brief ? 16 : 19,
                weight: brief ? .semibold : .bold
            ))
            .foregroundStyle(SkimStyle.text)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    @ViewBuilder
    private var headline: some View {
        if let source = openable {
            NavigationLink {
                ArticleDetailView(articleID: source.articleID)
            } label: {
                headlineText
            }
            .buttonStyle(.plain)
        } else {
            headlineText
        }
    }

    @ViewBuilder
    private func sourceLink(_ source: TodayEditionSourceArticle) -> some View {
        let publication = PublicationName.of(feedTitle: source.feedTitle, url: source.url)
        let published = source.publishedAt.map { "Published \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Published: unknown"
        let label = VStack(alignment: .leading, spacing: 3) {
            Text("Report preview · \(publication)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SkimStyle.accent)
            Text(source.articleTitle)
                .font(.system(size: 12, weight: .medium))
                .underline()
                .foregroundStyle(SkimStyle.accent)
                .fixedSize(horizontal: false, vertical: true)
            Text(published)
                .font(.system(size: 11))
                .foregroundStyle(SkimStyle.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel("Report preview from \(publication): \(source.articleTitle), \(source.publishedAt.map { "published \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "published time unknown")")

        if source.liveArticle != nil {
            NavigationLink {
                ArticleDetailView(articleID: source.articleID)
            } label: {
                label
            }
            .buttonStyle(.plain)
        } else if let url = source.url {
            Link(destination: url) { label }
        } else {
            label
        }
    }
}

/// The articles a story was built from, printed the way a byline is.
private struct TodayByline: View {
    var source: TodayEditionSourceArticle

    var body: some View {
        Group {
            if source.liveArticle != nil {
                NavigationLink {
                    ArticleDetailView(articleID: source.articleID)
                } label: { label }
                .buttonStyle(.plain)
            } else if let url = source.url {
                Link(destination: url) { label }
            } else {
                label
            }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(PublicationName.of(feedTitle: source.feedTitle, url: source.url))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SkimStyle.accent)
                    .fixedSize()

                Text(source.articleTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(SkimStyle.secondary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(source.publishedAt.map { "Published \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Published: unknown")
                .font(.system(size: 11))
                .foregroundStyle(SkimStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel("\(source.articleTitle), \(PublicationName.of(feedTitle: source.feedTitle, url: source.url))")
    }
}

// MARK: - Waiting

/// Shimmering rules where a lede is about to land.
private struct TodayLedeSkeleton: View {
    var lead: Bool
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                Capsule()
                    .fill(SkimStyle.separator)
                    .frame(height: 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: width, y: 1, anchor: .leading)
            }
        }
        .opacity(pulse ? 0.95 : 0.4)
        .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityElement()
        .accessibilityLabel("Writing this story")
    }

    private var widths: [CGFloat] {
        lead ? [1.0, 0.92, 0.68] : [1.0, 0.78]
    }
}

/// A live rule under the status line while the page is still being written.
private struct TodayWritingRule: View {
    var status: String
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SkimStyle.secondary.opacity(0.9))

            Capsule()
                .fill(SkimStyle.accent)
                .frame(height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(pulse ? 0.85 : 0.25)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
