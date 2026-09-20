import SkimCore
import SwiftUI

/// Native presentation of SkimCore's persisted edition; no ranking or snapshot logic here.
struct TodayEditionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("todayStoryLimit") private var storyLimit = 10

    private let sections: [EditionSectionRole] = [.topStories, .widelyCovered, .updates, .uniqueFinds]

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
                            if edition.items.isEmpty {
                                emptyEdition
                            } else {
                                ForEach(sections, id: \.self) { section in
                                    let items = edition.items.filter { $0.snapshot.section == section.rawValue }
                                    if !items.isEmpty {
                                        VStack(alignment: .leading, spacing: 16) {
                                            Text(sectionTitle(section)).font(.title3.bold())
                                            ForEach(items) { item in
                                                story(item)
                                            }
                                        }
                                    }
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
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

    private func story(_ item: TodayEditionItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let source = item.sourceArticles.first(where: { $0.isRepresentative && $0.liveArticle != nil })
                ?? item.sourceArticles.first(where: { $0.liveArticle != nil }) {
                NavigationLink {
                    ArticleDetailView(articleID: source.articleID)
                } label: {
                    Text(item.snapshot.snapshotTitle).font(.headline)
                        .foregroundStyle(SkimStyle.text)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            } else {
                Text(item.snapshot.snapshotTitle).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.snapshot.snapshotSummary.isEmpty {
                Text(item.snapshot.snapshotSummary).font(.body).foregroundStyle(SkimStyle.secondary)
            }
            DisclosureGroup("\(item.sourceArticles.count) source \(item.sourceArticles.count == 1 ? "article" : "articles")") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(item.sourceArticles, id: \.articleID) { source in
                        if source.liveArticle != nil {
                            NavigationLink {
                                ArticleDetailView(articleID: source.articleID)
                            } label: {
                                sourceLabel(source)
                            }
                        } else if let url = source.url {
                            Link(destination: url) { sourceLabel(source) }
                        } else {
                            sourceLabel(source)
                            Text("Article no longer available").font(.caption).foregroundStyle(SkimStyle.secondary)
                        }
                    }
                }
                .padding(.top, 12)
            }
            .font(.subheadline)
            Button {
                Task { await model.setTodayConsumed(item) }
            } label: {
                Label(item.snapshot.isConsumed ? "Read · Mark unread" : "Mark read",
                      systemImage: item.snapshot.isConsumed ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .disabled(model.isUpdatingToday)
            Divider().overlay(SkimStyle.separator)
        }
    }

    private func sourceLabel(_ source: TodayEditionSourceArticle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.feedTitle).font(.caption.weight(.semibold)).foregroundStyle(SkimStyle.secondary)
            Text(source.articleTitle).multilineTextAlignment(.leading)
            if let article = source.liveArticle, article.isRead {
                Text("Read").font(.caption).foregroundStyle(SkimStyle.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func sectionTitle(_ section: EditionSectionRole) -> String {
        switch section {
        case .topStories: "Top stories"
        case .widelyCovered: "Widely covered"
        case .uniqueFinds: "Unique finds"
        case .updates: "Updates"
        }
    }
}
