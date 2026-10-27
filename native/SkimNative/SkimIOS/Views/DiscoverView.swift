import SkimCore
import SwiftUI

/// Follow state shared by every page pushed inside Discover, so following a
/// feed on its page also shows on the topic list behind it.
@MainActor
final class DiscoverFollowState: ObservableObject {
    enum State: Equatable {
        case adding
        case following
        case failed(String)
    }

    @Published var states: [String: State] = [:]

    func follow(_ feed: DiscoveredFeed, model: AppModel) async {
        states[feed.id] = .adding
        do {
            try await model.subscribe(to: feed)
            states[feed.id] = .following
        } catch {
            states[feed.id] = .failed(error.localizedDescription)
        }
    }
}

/// A Feedly-style place to find feeds: browse topics, open a feed to read its
/// latest posts, and follow it. Pasting a site lists the feeds found on it;
/// typing words searches feeds by topic or name.
struct DiscoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var follow = DiscoverFollowState()
    @State private var query = ""
    @State private var results: [DiscoveredFeed]?
    @State private var resultsQuery = ""
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var showImport = false
    @FocusState private var isFocused: Bool

    var onImportOPML: () -> Void

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isURLQuery: Bool { FeedDiscoveryService.looksLikeURL(trimmedQuery) }
    private var topics: [FeedCatalog.Topic] { model.feedCatalog?.topics ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            DiscoverHeader(backTitle: "Articles", onBack: { dismiss() }) {
                Button("Import") { showImport = true }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(SkimStyle.accent)
                    .frame(minHeight: 44)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Discover")
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(SkimStyle.text)
                    Text("Follow sites, blogs, subreddits and channels.")
                        .font(.system(size: 15))
                        .foregroundStyle(SkimStyle.secondary)
                        .padding(.top, 2)
                        .padding(.bottom, 16)

                    searchField

                    if trimmedQuery.count >= 2 {
                        searchResults
                    } else {
                        featured
                        topicList
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(SkimStyle.background)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .environmentObject(follow)
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onDisappear { searchTask?.cancel() }
        .sheet(isPresented: $showImport) {
            ImportFeedsSheet(isPresented: $showImport, onImportOPML: onImportOPML)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(SkimStyle.chrome)
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SkimStyle.secondary)
            TextField("Type a name, topic, or paste a URL", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.search)
                .font(.system(size: 17))
                .foregroundStyle(SkimStyle.text)
                .focused($isFocused)
                .onSubmit { runSearch(immediately: true) }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SkimStyle.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 50)
        .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isFocused ? SkimStyle.accent.opacity(0.6) : SkimStyle.separator, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let settled = resultsQuery == trimmedQuery && !isSearching
        Text(statusText(settled: settled))
            .font(.system(size: 14))
            .foregroundStyle(SkimStyle.secondary)
            .padding(.top, 18)
            .padding(.bottom, 4)
        if let searchError, settled {
            DiscoverErrorBox(message: searchError)
        }
        if isSearching && results == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
        if let results, !results.isEmpty {
            DiscoverFeedList(feeds: results)
                .opacity(settled ? 1 : 0.5)
        }
    }

    private func statusText(settled: Bool) -> String {
        if !settled {
            if isURLQuery {
                let host = FeedDiscoveryService.normalizedInputURL(trimmedQuery)?.host() ?? trimmedQuery
                return "Looking for feeds on \(host)…"
            }
            return "Searching for \u{201C}\(trimmedQuery)\u{201D}…"
        }
        guard searchError == nil, let results else { return "" }
        if results.isEmpty { return "No feeds found for \u{201C}\(trimmedQuery)\u{201D}." }
        if isURLQuery { return "\(results.count) feed\(results.count == 1 ? "" : "s") found" }
        return "Feeds matching \u{201C}\(trimmedQuery)\u{201D}"
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchError = nil
        guard trimmedQuery.count >= 2 else {
            isSearching = false
            results = nil
            resultsQuery = ""
            return
        }
        runSearch(immediately: false)
    }

    private func runSearch(immediately: Bool) {
        let q = trimmedQuery
        guard q.count >= 2 else { return }
        let isURL = FeedDiscoveryService.looksLikeURL(q)
        searchTask?.cancel()
        isSearching = true
        searchTask = Task {
            if !immediately {
                try? await Task.sleep(for: .milliseconds(isURL ? 650 : 350))
            }
            guard !Task.isCancelled else { return }
            var found: [DiscoveredFeed] = []
            var failure: String?
            if isURL {
                do {
                    found = try await model.discovery.discover(q)
                } catch {
                    failure = error.localizedDescription
                }
            } else {
                found = await model.discovery.search(q, catalog: model.feedCatalog)
            }
            guard !Task.isCancelled else { return }
            results = found
            searchError = failure
            resultsQuery = q
            isSearching = false
        }
    }

    // MARK: Browse

    @ViewBuilder
    private var featured: some View {
        DiscoverSectionLabel("Featured")
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(topics.prefix(3)) { topic in
                    NavigationLink {
                        DiscoverTopicView(topicID: topic.id)
                        // Pushed views don't inherit objects set below the stack.
                        .environmentObject(model)
                        .environmentObject(follow)
                    } label: {
                        FeaturedTopicCard(topic: topic)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var topicList: some View {
        DiscoverSectionLabel("Topics")
        VStack(spacing: 0) {
            ForEach(topics) { topic in
                NavigationLink {
                    DiscoverTopicView(topicID: topic.id)
                        // Pushed views don't inherit objects set below the stack.
                        .environmentObject(model)
                        .environmentObject(follow)
                } label: {
                    HStack(spacing: 14) {
                        TopicTile(id: topic.id, size: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(topic.name)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(SkimStyle.text)
                            Text(topic.feeds.prefix(3).map(\.title).joined(separator: ", "))
                                .font(.system(size: 13))
                                .foregroundStyle(SkimStyle.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SkimStyle.secondary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: Topic

struct DiscoverTopicView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var topicID: String
    @State private var more: [DiscoveredFeed] = []
    @State private var isLoadingMore = false

    private var topics: [FeedCatalog.Topic] { model.feedCatalog?.topics ?? [] }
    private var topic: FeedCatalog.Topic? { topics.first { $0.id == topicID } }
    private var feeds: [DiscoveredFeed] {
        guard let topic else { return [] }
        var seen = Set(topic.feeds.map { FeedDiscoveryService.key($0.url) })
        return topic.feeds + more.filter { seen.insert(FeedDiscoveryService.key($0.url)).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            DiscoverHeader(backTitle: "Discover", onBack: { dismiss() }) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let topic {
                        HStack(spacing: 14) {
                            TopicTile(id: topic.id, size: 60)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(topic.name)
                                    .font(.system(size: 28, weight: .heavy))
                                    .foregroundStyle(SkimStyle.text)
                                Text("\(feeds.count) feeds to follow")
                                    .font(.system(size: 14))
                                    .foregroundStyle(SkimStyle.secondary)
                            }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(topics.filter { $0.id != topic.id }) { other in
                                    Button {
                                        topicID = other.id
                                    } label: {
                                        Text("# \(other.name.lowercased())")
                                            .font(.system(size: 15))
                                            .foregroundStyle(SkimStyle.text.opacity(0.85))
                                            .padding(.horizontal, 14)
                                            .frame(height: 36)
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                    .stroke(SkimStyle.separator, lineWidth: 1)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                        .scrollClipDisabled()
                        .padding(.top, 16)

                        DiscoverSectionLabel("Top feeds")
                        DiscoverFeedList(feeds: feeds)
                        if isLoadingMore {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(SkimStyle.background)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: topicID) {
            // Feedly's index adds more feeds on the topic beyond the curated few.
            guard let name = topic?.name else { return }
            more = []
            isLoadingMore = true
            more = await model.discovery.search(name, catalog: nil)
            isLoadingMore = false
        }
    }
}

// MARK: Feed

struct DiscoverFeedView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var follow: DiscoverFollowState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let feed: DiscoveredFeed
    let backTitle: String
    @State private var loaded: DiscoveredFeed?
    @State private var loadError: String?

    private var items: [DiscoveredFeed.Item] {
        if let loaded, !loaded.items.isEmpty { return loaded.items }
        return feed.items
    }

    var body: some View {
        VStack(spacing: 0) {
            DiscoverHeader(backTitle: backTitle, onBack: { dismiss() }) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if loaded == nil && loadError == nil && items.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if let loadError, items.isEmpty {
                        DiscoverErrorBox(message: loadError).padding(.top, 20)
                    } else if items.isEmpty {
                        Text("No recent posts.")
                            .foregroundStyle(SkimStyle.secondary)
                            .padding(.top, 24)
                    }
                    ForEach(groups, id: \.label) { group in
                        DiscoverSectionLabel(group.label)
                        ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                            Button {
                                if let url = item.url { openURL(url) }
                            } label: {
                                DiscoverPostRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .disabled(item.url == nil)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(SkimStyle.background)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task {
            do {
                loaded = try await model.discovery.preview(feed.url)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                DiscoverFeedIcon(feed: feed, size: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feed.title)
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(SkimStyle.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(feedMeta(feed))
                        .font(.system(size: 14))
                        .foregroundStyle(SkimStyle.secondary)
                        .lineLimit(1)
                }
            }
            if let summary = feed.summary ?? loaded?.summary {
                Text(summary)
                    .font(.system(size: 15))
                    .foregroundStyle(SkimStyle.text.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            FollowButton(feed: feed, large: true)
        }
    }

    private struct DayGroup {
        var label: String
        var items: [DiscoveredFeed.Item]
    }

    private var groups: [DayGroup] {
        var out: [DayGroup] = []
        for item in items {
            let label = dayLabel(item.publishedAt)
            if out.last?.label == label {
                out[out.count - 1].items.append(item)
            } else {
                out.append(DayGroup(label: label, items: [item]))
            }
        }
        return out
    }

    private func dayLabel(_ date: Date?) -> String {
        guard let date else { return "Earlier" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct DiscoverPostRow: View {
    let item: DiscoveredFeed.Item

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SkimStyle.text)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 13))
                        .foregroundStyle(SkimStyle.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let imageURL = item.imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        SkimStyle.surface
                    }
                }
                .frame(width: 112, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var meta: String {
        [item.author.map { "by \($0)" }, item.publishedAt.map(shortAge)].compactMap { $0 }.joined(separator: " / ")
    }
}

// MARK: Shared pieces

/// A list of feeds, each opening its page and carrying a Follow button.
struct DiscoverFeedList: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var follow: DiscoverFollowState
    let feeds: [DiscoveredFeed]
    var backTitle = "Back"

    var body: some View {
        VStack(spacing: 0) {
            ForEach(feeds) { feed in
                HStack(spacing: 12) {
                    NavigationLink {
                        DiscoverFeedView(feed: feed, backTitle: backTitle)
                            .environmentObject(model)
                            .environmentObject(follow)
                    } label: {
                        HStack(spacing: 12) {
                            DiscoverFeedIcon(feed: feed, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feed.title)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(SkimStyle.text)
                                    .lineLimit(1)
                                Text(feedMeta(feed))
                                    .font(.system(size: 13))
                                    .foregroundStyle(SkimStyle.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    FollowButton(feed: feed)
                }
                .padding(.vertical, 9)
            }
        }
    }
}

struct FollowButton: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var follow: DiscoverFollowState
    let feed: DiscoveredFeed
    var large = false
    @State private var unfollowing: Feed?

    var body: some View {
        let state = follow.states[feed.id]
        VStack(alignment: .trailing, spacing: 4) {
            if state == .following || model.isSubscribed(feed.url) {
                // Tapping Following asks to unfollow, so a stray tap loses nothing.
                Button {
                    unfollowing = model.libraryFeed(for: feed)
                } label: {
                    Label("Following", systemImage: "checkmark")
                        .font(.system(size: large ? 16 : 14, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(maxWidth: large ? .infinity : nil)
                        .frame(minWidth: 104, minHeight: large ? 44 : 34)
                        .background(Color.green.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Following \(feed.title)")
                .accessibilityHint("Unfollow")
            } else {
                Button {
                    Task { await follow.follow(feed, model: model) }
                } label: {
                    HStack(spacing: 5) {
                        if state == .adding {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "plus")
                        }
                        Text("Follow")
                    }
                    .font(.system(size: large ? 16 : 14, weight: .semibold))
                    .foregroundStyle(SkimStyle.accent)
                    .frame(maxWidth: large ? .infinity : nil)
                    .frame(minWidth: 104, minHeight: large ? 44 : 34)
                    .overlay { Capsule().stroke(SkimStyle.accent.opacity(0.6), lineWidth: 1) }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(state == .adding)
                .accessibilityLabel("Follow \(feed.title)")
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    // In a list row, wrap under the button rather than widen it and squeeze the title.
                    .frame(maxWidth: large ? 220 : 104, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .unfollowConfirmation(model: model, feed: $unfollowing) { _ in
            follow.states[feed.id] = nil
        }
    }
}

private struct DiscoverHeader<Trailing: View>: View {
    let backTitle: String
    let onBack: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Button(action: onBack) {
                Label(backTitle, systemImage: "chevron.left")
                    .lineLimit(1)
                    .frame(minHeight: 44)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .background(SkimStyle.background)
    }
}

private struct DiscoverSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(SkimStyle.accent)
            .padding(.top, 26)
            .padding(.bottom, 8)
    }
}

private struct DiscoverErrorBox: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 15))
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct DiscoverFeedIcon: View {
    let feed: DiscoveredFeed
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(SkimStyle.surface)
            AsyncImage(url: feed.iconURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().frame(width: size * 0.6, height: size * 0.6)
                } else {
                    Text(feed.title.prefix(1).uppercased())
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(SkimStyle.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A colour and SF Symbol per catalog topic; matches the desktop cards.
private enum TopicLook {
    static func colors(_ id: String) -> [Color] {
        switch id {
        case "tech": [Color(red: 0.95, green: 0.44, blue: 0.42), Color(red: 0.77, green: 0.24, blue: 0.35)]
        case "programming": [Color(red: 0.23, green: 0.51, blue: 0.96), Color(red: 0.12, green: 0.23, blue: 0.54)]
        case "ai": [Color(red: 0.65, green: 0.55, blue: 0.98), Color(red: 0.36, green: 0.13, blue: 0.71)]
        case "science": [Color(red: 0.20, green: 0.83, blue: 0.60), Color(red: 0.02, green: 0.47, blue: 0.34)]
        case "space": [Color(red: 0.39, green: 0.40, blue: 0.95), Color(red: 0.06, green: 0.09, blue: 0.16)]
        case "news": [Color(red: 0.96, green: 0.62, blue: 0.04), Color(red: 0.71, green: 0.33, blue: 0.04)]
        case "business": [Color(red: 0.08, green: 0.72, blue: 0.65), Color(red: 0.07, green: 0.37, blue: 0.35)]
        case "design": [Color(red: 0.96, green: 0.45, blue: 0.71), Color(red: 0.75, green: 0.09, blue: 0.36)]
        case "apple": [Color(red: 0.58, green: 0.64, blue: 0.72), Color(red: 0.20, green: 0.25, blue: 0.33)]
        case "gaming": [Color(red: 0.94, green: 0.27, blue: 0.27), Color(red: 0.50, green: 0.11, blue: 0.11)]
        case "security": [Color(red: 0.39, green: 0.45, blue: 0.55), Color(red: 0.06, green: 0.46, blue: 0.43)]
        case "android": [Color(red: 0.29, green: 0.87, blue: 0.50), Color(red: 0.08, green: 0.50, blue: 0.24)]
        case "climate": [Color(red: 0.53, green: 0.94, blue: 0.67), Color(red: 0.09, green: 0.40, blue: 0.20)]
        case "startups": [Color(red: 0.98, green: 0.57, blue: 0.24), Color(red: 0.76, green: 0.25, blue: 0.05)]
        case "finance": [Color(red: 0.18, green: 0.83, blue: 0.75), Color(red: 0.05, green: 0.45, blue: 0.56)]
        case "crypto": [Color(red: 0.98, green: 0.75, blue: 0.14), Color(red: 0.63, green: 0.38, blue: 0.03)]
        case "photography": [Color(red: 0.66, green: 0.64, blue: 0.62), Color(red: 0.27, green: 0.25, blue: 0.24)]
        case "film-tv": [Color(red: 0.97, green: 0.44, blue: 0.44), Color(red: 0.60, green: 0.11, blue: 0.11)]
        case "music": [Color(red: 0.91, green: 0.47, blue: 0.98), Color(red: 0.53, green: 0.10, blue: 0.56)]
        case "books": [Color(red: 0.84, green: 0.65, blue: 0.42), Color(red: 0.49, green: 0.29, blue: 0.12)]
        case "history": [Color(red: 0.77, green: 0.64, blue: 0.52), Color(red: 0.34, green: 0.33, blue: 0.31)]
        case "food": [Color(red: 0.99, green: 0.65, blue: 0.65), Color(red: 0.76, green: 0.25, blue: 0.05)]
        case "travel": [Color(red: 0.22, green: 0.74, blue: 0.97), Color(red: 0.01, green: 0.41, blue: 0.63)]
        case "sports": [Color(red: 0.64, green: 0.90, blue: 0.21), Color(red: 0.25, green: 0.38, blue: 0.07)]
        case "cars": [Color(red: 0.58, green: 0.77, blue: 0.99), Color(red: 0.12, green: 0.25, blue: 0.69)]
        case "diy": [Color(red: 0.99, green: 0.73, blue: 0.45), Color(red: 0.60, green: 0.20, blue: 0.07)]
        case "style": [Color(red: 0.98, green: 0.66, blue: 0.83), Color(red: 0.62, green: 0.09, blue: 0.30)]
        default: [SkimStyle.accent, Color(red: 0.12, green: 0.29, blue: 0.56)]
        }
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "tech": "desktopcomputer"
        case "programming": "chevron.left.forwardslash.chevron.right"
        case "ai": "sparkles"
        case "science": "flask"
        case "space": "moon.stars"
        case "news": "globe"
        case "business": "chart.bar"
        case "design": "paintpalette"
        case "apple": "apple.logo"
        case "gaming": "gamecontroller"
        case "security": "lock.shield"
        case "android": "smartphone"
        case "climate": "leaf"
        case "startups": "chart.line.uptrend.xyaxis"
        case "finance": "banknote"
        case "crypto": "bitcoinsign.circle"
        case "photography": "camera"
        case "film-tv": "film"
        case "music": "music.note"
        case "books": "books.vertical"
        case "history": "building.columns"
        case "food": "fork.knife"
        case "travel": "airplane"
        case "sports": "sportscourt"
        case "cars": "car"
        case "diy": "hammer"
        case "style": "tshirt"
        default: "dot.radiowaves.up.forward"
        }
    }

    static func gradient(_ id: String) -> LinearGradient {
        LinearGradient(colors: colors(id), startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct TopicTile: View {
    let id: String
    let size: CGFloat

    var body: some View {
        Image(systemName: TopicLook.symbol(id))
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(TopicLook.gradient(id), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct FeaturedTopicCard: View {
    let topic: FeedCatalog.Topic

    var body: some View {
        ZStack(alignment: .topLeading) {
            TopicLook.gradient(topic.id)
            Image(systemName: TopicLook.symbol(topic.id))
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(16)
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.name)
                    .font(.system(size: 22, weight: .bold))
                Text("\(topic.feeds.count) feeds")
                    .font(.system(size: 13))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(width: 220, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Feedly OPML import, reachable from Discover's Import button.
struct ImportFeedsSheet: View {
    @Binding var isPresented: Bool
    var onImportOPML: () -> Void

    private let feedlyExportURL = URL(string: "https://feedly.com/i/back?nextUri=%2Fopml")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Text("Import feeds")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(SkimStyle.text)
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SkimStyle.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }

                Text("Sign in to Feedly, download your Feedly OPML, then choose the file here. Any OPML file from another reader works too.")
                    .font(.system(size: 15))
                    .foregroundStyle(SkimStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: feedlyExportURL) {
                    Label("Open Feedly export", systemImage: SkimIcon.openExternal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(SkimStyle.accent)
                .accessibilityHint("Opens Feedly's export page")

                Button("Choose OPML file") {
                    isPresented = false
                    onImportOPML()
                }
                .buttonStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SkimStyle.accent)
                .frame(minHeight: 44, alignment: .leading)

                Text("Sign in with Feedly is coming later: Feedly developer access costs $96/year.")
                    .font(.footnote)
                    .foregroundStyle(SkimStyle.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
    }
}

private func feedMeta(_ feed: DiscoveredFeed) -> String {
    let host = (feed.siteURL ?? feed.url).host()?.replacingOccurrences(of: "www.", with: "") ?? ""
    let followers = feed.subscribers.map { "\(compactCount($0)) followers" }
    return [host, followers].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
}

private func compactCount(_ n: Int) -> String {
    if n >= 1_000_000 {
        return String(format: n >= 10_000_000 ? "%.0fM" : "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
    }
    if n >= 1_000 {
        return String(format: n >= 10_000 ? "%.0fK" : "%.1fK", Double(n) / 1_000).replacingOccurrences(of: ".0K", with: "K")
    }
    return String(n)
}

private func shortAge(_ date: Date) -> String {
    let minutes = max(1, Int(Date().timeIntervalSince(date) / 60))
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 7 { return "\(days)d" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}
