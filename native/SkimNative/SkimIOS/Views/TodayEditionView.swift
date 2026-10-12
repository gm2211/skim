import SkimCore
import SwiftUI

/// Native presentation of SkimCore's persisted edition; no ranking or snapshot logic here.
///
/// A magazine front page: the lead runs as a full-bleed hero, the next stories
/// as cards, the tail as a two-up grid of briefs. Every slot has a text
/// treatment (the lede set as a pull quote, a story accent colour) so the page
/// stays full when the reports publish no pictures; a picture is used when the
/// report has one.
struct TodayEditionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("todayStoryLimit") private var storyLimit = 10
    @State private var showSettings = false

    /// Stories that get a written lede and a full card; the rest of the page
    /// runs as two-up briefs.
    private static let leadCount = 6

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Label("Articles", systemImage: "chevron.left")
                        .frame(minHeight: 44)
                }
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Today settings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .background(SkimStyle.background)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                                if let status = model.todayLedeStatus {
                                    TodayWritingRule(status: status)
                                }
                                frontPage(edition.items)
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
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await load() }
        }
        .background(SkimStyle.background.ignoresSafeArea())
        .foregroundStyle(SkimStyle.text)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSettings) { settingsSheet }
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
    }

    private func load() async { await model.loadTodayEdition(storyLimit: storyLimit) }

    /// The edition is already ordered by importance, so position is all the
    /// page needs: the first story leads, the next few run as cards, the tail
    /// becomes briefs.
    @ViewBuilder
    private func frontPage(_ items: [TodayEditionItem]) -> some View {
        let writing = model.todayLedeStatus != nil
        ForEach(Array(items.prefix(Self.leadCount).enumerated()), id: \.element.id) { position, item in
            TodayStoryView(
                item: item,
                rank: Self.rank(for: position),
                isWritingLede: writing,
                isUpdating: model.isUpdatingToday,
                onToggleConsumed: { Task { await model.setTodayConsumed(item) } }
            )
            .padding(.horizontal, position == 0 ? -18 : 0)
        }
        if items.count > Self.leadCount {
            Text("IN BRIEF")
                .font(.system(size: 11, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(SkimStyle.secondary)
                .padding(.top, 8)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(Array(items.dropFirst(Self.leadCount))) { item in
                    TodayStoryView(
                        item: item,
                        rank: .brief,
                        isWritingLede: false,
                        isUpdating: model.isUpdatingToday,
                        onToggleConsumed: { Task { await model.setTodayConsumed(item) } }
                    )
                }
            }
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Summaries") {
                    AppModelPicker(isDisabled: model.isUpdatingToday || model.todayLedeStatus != nil)
                    if model.todayLedeNeedsRetry {
                        Button("Retry missing summaries") {
                            showSettings = false
                            Task { await model.retryTodayLedes() }
                        }
                    }
                }
                Section("Edition") {
                    Picker("Stories per edition", selection: $storyLimit) {
                        Text("5 stories").tag(5)
                        Text("10 stories").tag(10)
                        Text("20 stories").tag(20)
                    }
                    .disabled(model.isUpdatingToday)
                }
            }
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSettings = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// The masthead: the nameplate, then a dateline whose double rule doubles
    /// as the day's reading progress.
    private func editionHeader(_ edition: TodayEditionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today")
                .font(.system(size: 38, weight: .bold, design: .serif))
                .foregroundStyle(SkimStyle.text)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            VStack(spacing: 2) {
                Rectangle().fill(SkimStyle.text.opacity(0.28)).frame(height: 1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(edition.edition.startsAt.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                    .foregroundStyle(SkimStyle.secondary)
                Spacer(minLength: 8)
                if edition.totalItemCount > 0 {
                    HStack(spacing: 8) {
                        Text(edition.consumedItemCount == edition.totalItemCount
                             ? "ALL CAUGHT UP"
                             : "\(edition.consumedItemCount) OF \(edition.totalItemCount) READ")
                        Text(edition.progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .opacity(0.7)
                    }
                    .foregroundStyle(SkimStyle.secondary.opacity(0.8))
                }
            }
            .font(.system(size: 10.5, weight: .bold))
            .kerning(1.0)
            .lineLimit(1)
            .minimumScaleFactor(0.85)

            VStack(spacing: 2) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(SkimStyle.text.opacity(0.28))
                        if edition.totalItemCount > 0 {
                            Rectangle()
                                .fill(edition.consumedItemCount == edition.totalItemCount ? Color.green : SkimStyle.accent)
                                .frame(width: proxy.size.width * CGFloat(edition.progress))
                                .animation(.easeOut(duration: 0.3), value: edition.progress)
                        }
                    }
                }
                .frame(height: 2)
                .accessibilityLabel("Edition progress")
                .accessibilityValue(Text(edition.progress, format: .percent.precision(.fractionLength(0))))
                Rectangle().fill(SkimStyle.text.opacity(0.11)).frame(height: 1)
            }

            if model.todayLedeNeedsRetry && model.todayLedeStatus == nil {
                HStack(spacing: 6) {
                    Text("Some summaries are missing.")
                        .foregroundStyle(Color.orange)
                    Button("Retry") { Task { await model.retryTodayLedes() } }
                        .foregroundStyle(SkimStyle.accent)
                        .frame(minHeight: 44)
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(.bottom, 6)
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

/// A stable accent per story, from its lead publication, so a page with no
/// pictures still has colour and rhythm.
enum TodayAccent {
    private static let palette: [Color] = [
        Color(red: 0.36, green: 0.49, blue: 0.98), Color(red: 0.59, green: 0.46, blue: 0.98),
        Color(red: 0.13, green: 0.72, blue: 0.81), Color(red: 0.32, green: 0.81, blue: 0.40),
        Color(red: 0.85, green: 0.47, blue: 0.95), Color(red: 1.0, green: 0.57, blue: 0.17),
        Color(red: 0.99, green: 0.77, blue: 0.10), Color(red: 0.22, green: 0.85, blue: 0.66),
        Color(red: 1.0, green: 0.42, blue: 0.42),
    ]

    static func color(for key: String) -> Color {
        var hash: UInt32 = 0
        for scalar in key.lowercased().unicodeScalars { hash = hash &* 31 &+ scalar.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

/// Feed excerpts that are only a link stub ("Comments") are left off the page.
enum TodayExcerpt {
    static func isReadable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("article url:") || lowered.hasPrefix("comments url:") || lowered.hasPrefix("comments")
            || lowered.hasPrefix("[comments]") { return false }
        return trimmed.count >= 40 && trimmed.split(whereSeparator: \.isWhitespace).count >= 7
    }
}

/// The picture a story is set with: the feed's own image, else the linked
/// page's share image. Results are remembered for the session.
@MainActor
final class TodayImageStore: ObservableObject {
    static let shared = TodayImageStore()
    @Published private(set) var images: [String: URL] = [:]
    private var looked: Set<String> = []

    func image(for item: TodayEditionItem) -> URL? { images[item.id] }

    func resolve(_ item: TodayEditionItem) async {
        guard !looked.contains(item.id) else { return }
        looked.insert(item.id)
        let articles = item.sourceArticles.compactMap(\.liveArticle)
        if let feedImage = articles.compactMap(\.imageURL).first(where: Self.isPhoto) {
            images[item.id] = feedImage
            return
        }
        for article in articles.prefix(3) {
            guard let page = article.externalURL ?? article.url,
                  page.host?.contains("ycombinator.com") != true else { continue }
            if let image = await Self.shareImage(of: page) {
                images[item.id] = image
                return
            }
        }
    }

    nonisolated private static func isPhoto(_ url: URL) -> Bool {
        let lowered = url.absoluteString.lowercased()
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && !["feedburner", "pixel", "badge", "favicon", "logo", "avatar", ".svg"].contains { lowered.contains($0) }
    }

    nonisolated private static func shareImage(of page: URL) async -> URL? {
        var request = URLRequest(url: page, timeoutInterval: 6)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { return nil }
        // The share image lives in <head>; never scan a whole long page.
        let html = String(decoding: data.prefix(300_000), as: UTF8.self)
        for key in ["og:image:secure_url", "og:image", "twitter:image"] {
            if let value = metaContent(html, key: key), let url = URL(string: value, relativeTo: page)?.absoluteURL, isPhoto(url) {
                return url
            }
        }
        return nil
    }

    nonisolated private static func metaContent(_ html: String, key: String) -> String? {
        guard let tagPattern = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in tagPattern.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let name = attribute(tag, "property") ?? attribute(tag, "name")
            if name?.lowercased() == key, let content = attribute(tag, "content"), !content.isEmpty {
                return content.replacingOccurrences(of: "&amp;", with: "&")
            }
        }
        return nil
    }

    nonisolated private static func attribute(_ tag: String, _ name: String) -> String? {
        guard let pattern = try? NSRegularExpression(pattern: "\\s\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", options: [.caseInsensitive]),
              let match = pattern.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
}

// MARK: - One story on the page

private struct TodayStoryView: View {
    var item: TodayEditionItem
    var rank: TodayStoryRank
    var isWritingLede: Bool
    var isUpdating: Bool
    var onToggleConsumed: () -> Void
    @State private var referencesExpanded = false
    @ObservedObject private var imageStore = TodayImageStore.shared

    private var lead: Bool { rank == .lead }
    private var brief: Bool { rank == .brief }

    private var lede: String? {
        let text = item.snapshot.lede?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// The feed's own excerpt, when it reads as reporting.
    private var excerpt: String? {
        TodayExcerpt.isReadable(item.snapshot.snapshotSummary) ? item.snapshot.snapshotSummary : nil
    }

    private var awaitingLede: Bool {
        !brief && lede == nil && isWritingLede
    }

    private var openable: TodayEditionSourceArticle? {
        item.sourceArticles.first(where: { $0.isRepresentative && $0.liveArticle != nil })
            ?? item.sourceArticles.first(where: { $0.liveArticle != nil })
    }

    private var ledeSource: TodayEditionSourceArticle? {
        guard lede != nil, let sourceID = item.snapshot.ledeSourceArticleID else { return nil }
        return item.sourceArticles.first(where: { $0.articleID == sourceID })
    }

    private var primary: TodayEditionSourceArticle? {
        item.sourceArticles.first(where: \.isRepresentative) ?? item.sourceArticles.first
    }

    private var publication: String {
        primary.map { PublicationName.of(feedTitle: $0.feedTitle, url: $0.url) } ?? ""
    }

    private var accent: Color { TodayAccent.color(for: publication.isEmpty ? item.id : publication) }

    private var coverage: Int { item.sourceArticles.filter { $0.membershipType != .duplicate }.count }

    private var image: URL? { brief ? nil : imageStore.image(for: item) }

    var body: some View {
        Group {
            switch rank {
            case .lead: hero
            case .story: card
            case .brief: briefCard
            }
        }
        .opacity(item.snapshot.isConsumed ? 0.55 : 1)
        .task(id: item.id) { if !brief { await imageStore.resolve(item) } }
    }

    // MARK: Slots

    /// The lead: a full-bleed picture with the headline over it, or with no
    /// picture a tinted panel where the report's own words take its place.
    @ViewBuilder
    private var hero: some View {
        if let image {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: image) { phase in
                    if let picture = phase.image {
                        picture.resizable().scaledToFill()
                    } else {
                        accent.opacity(0.25)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 440)
                .clipped()
                LinearGradient(colors: [.clear, SkimStyle.background.opacity(0.65), SkimStyle.background.opacity(0.96)],
                               startPoint: .init(x: 0.5, y: 0.25), endPoint: .bottom)
                VStack(alignment: .leading, spacing: 10) {
                    kicker
                    headlineLink(size: 28)
                    if let text = lede ?? excerpt {
                        Text(text)
                            .font(.system(size: 15))
                            .foregroundStyle(SkimStyle.text.opacity(0.9))
                            .lineLimit(4)
                    }
                    actions
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            .frame(height: 440)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                kicker
                headlineLink(size: 30)
                if awaitingLede {
                    TodayLedeSkeleton(lead: true)
                } else if let lede {
                    pullQuote(lede, size: 20, cite: ledeSource)
                } else if let excerpt {
                    bodyText(excerpt, size: 16)
                }
                actions
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [accent.opacity(0.32), SkimStyle.surface.opacity(0.6)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
    }

    /// A story card: picture on top when the report has one, else the lede as
    /// a large quote under an accent rule.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image {
                AsyncImage(url: image) { phase in
                    if let picture = phase.image { picture.resizable().scaledToFill() } else { accent.opacity(0.2) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .clipped()
            } else {
                Rectangle().fill(accent).frame(height: 3)
            }
            VStack(alignment: .leading, spacing: 9) {
                kicker
                if image == nil, let lede {
                    pullQuote(lede, size: 19, cite: nil)
                }
                headlineLink(size: 20)
                if awaitingLede {
                    TodayLedeSkeleton(lead: false)
                } else if image != nil, let text = lede ?? excerpt {
                    bodyText(text, size: 14)
                } else if lede == nil, let excerpt {
                    bodyText(excerpt, size: 14)
                }
                if let source = ledeSource {
                    sourceLink(source)
                }
                if let delta = item.materialDelta {
                    Text("What's new: \(delta)")
                        .font(.system(size: 14))
                        .foregroundStyle(SkimStyle.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
            .padding(16)
        }
        .background(
            image == nil
                ? AnyShapeStyle(LinearGradient(colors: [accent.opacity(0.16), SkimStyle.surface], startPoint: .topLeading, endPoint: .center))
                : AnyShapeStyle(SkimStyle.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(SkimStyle.separator, lineWidth: 1))
    }

    /// A brief: half-width, headline only, under an accent rule.
    private var briefCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(accent).frame(height: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(publication.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .kerning(1.0)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                headlineLink(size: 16)
                Spacer(minLength: 0)
                HStack {
                    Text("\(item.sourceArticles.count) \(item.sourceArticles.count == 1 ? "report" : "reports")")
                        .font(.system(size: 12))
                        .foregroundStyle(SkimStyle.secondary)
                    Spacer()
                    readToggle
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(SkimStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SkimStyle.separator, lineWidth: 1))
    }

    // MARK: Pieces

    private var kicker: some View {
        (Text(publication.uppercased()).foregroundColor(lead && image != nil ? Color(red: 0.61, green: 0.79, blue: 1.0) : accent)
            + Text(coverage > 1 ? " · \(coverage) REPORTS" : "").foregroundColor(SkimStyle.secondary))
            .font(.system(size: 11, weight: .bold))
            .kerning(1.2)
            .lineLimit(1)
    }

    private func bodyText(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(SkimStyle.text.opacity(0.84))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The lede is a verified excerpt from a report, so it is set as that
    /// report's own words.
    private func pullQuote(_ text: String, size: CGFloat, cite: TodayEditionSourceArticle?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\u{201C}")
                .font(.system(size: 44, weight: .bold, design: .serif))
                .foregroundStyle(accent)
                .frame(height: 22, alignment: .top)
            Text(text)
                .font(.system(size: size, design: .serif).italic())
                .foregroundStyle(SkimStyle.text.opacity(0.95))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let cite {
                Text(PublicationName.of(feedTitle: cite.feedTitle, url: cite.url))
                    .font(.system(size: 11.5))
                    .foregroundStyle(SkimStyle.secondary)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if !item.sourceArticles.isEmpty {
                    Button { withAnimation { referencesExpanded.toggle() } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .rotationEffect(.degrees(referencesExpanded ? 90 : 0))
                            Text("\(item.sourceArticles.count) \(item.sourceArticles.count == 1 ? "report" : "reports")")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SkimStyle.secondary)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(referencesExpanded ? "Expanded" : "Collapsed")
                }
                Spacer()
                readToggle
            }
            if referencesExpanded {
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
            }
        }
    }

    private var readToggle: some View {
        Button(action: onToggleConsumed) {
            Image(systemName: item.snapshot.isConsumed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(item.snapshot.isConsumed ? Color.green : SkimStyle.secondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
        .accessibilityLabel(item.snapshot.isConsumed ? "Mark unread" : "Mark read")
    }

    private func headlineText(size: CGFloat) -> some View {
        Text(item.snapshot.snapshotTitle)
            .font(.system(size: size, weight: .bold, design: .serif))
            .foregroundStyle(SkimStyle.text)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    @ViewBuilder
    private func headlineLink(size: CGFloat) -> some View {
        if let source = openable {
            NavigationLink {
                ArticleDetailView(articleID: source.articleID)
            } label: {
                headlineText(size: size)
            }
            .buttonStyle(.plain)
        } else {
            headlineText(size: size)
        }
    }

    @ViewBuilder
    private func sourceLink(_ source: TodayEditionSourceArticle) -> some View {
        let publication = PublicationName.of(feedTitle: source.feedTitle, url: source.url)
        let published = source.publishedAt.map { "Published \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Published: unknown"
        // One byline: the publication as a kicker, then the report's own
        // title and when it ran.
        let label = VStack(alignment: .leading, spacing: 3) {
            Text("Report preview · \(publication)".uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(SkimStyle.secondary)
            (Text(source.articleTitle).italic().foregroundColor(SkimStyle.secondary)
                + Text(" · \(published)").foregroundColor(SkimStyle.secondary.opacity(0.75)))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
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
