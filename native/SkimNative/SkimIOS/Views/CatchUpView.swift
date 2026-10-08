import SkimCore
import SwiftUI

// MARK: - Request model

struct CatchUpRequest: Identifiable {
    let id = UUID()
    var subtitle: String
    var statusLabel: String
    /// Resolves the articles the page is built from.
    var loadArticles: () async throws -> [Article]
    /// What the sheet's own model calls run under. The sheet drives the two
    /// passes itself so the page can fill in as it is written.
    var settings: AppSettings
}

// MARK: - Main sheet

struct CatchUpSheet: View {
    var request: CatchUpRequest
    @Environment(\.dismiss) private var dismiss

    @StateObject private var session = CatchUpSession()
    @State private var range: CatchUpRange = .anything
    @State private var startedRequestID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CatchUpControls(
                        subtitle: request.subtitle,
                        range: $range,
                        isLoading: session.isLoading
                    )
                    .onChange(of: range) { _, selected in session.start(request: request, range: selected) }

                    if session.wasStopped {
                        Text("Stopped. Change the range or run again.")
                            .font(.subheadline)
                            .foregroundStyle(SkimStyle.secondary)
                            .accessibilityIdentifier("catch-up-stopped")
                    }

                    if let errorMessage = session.errorMessage {
                        AIErrorBox(message: errorMessage, remedy: session.errorRemedy, onResolved: { session.start(request: request, range: range) })

                    } else if !session.page.isEmpty {
                        if session.isLoading {
                            CatchUpWritingRule(status: session.statusMessage)
                        }

                        CatchUpFrontPage(page: session.page, articles: session.articles, isLoading: session.isLoading, written: session.written)
                            .animation(.easeOut(duration: 0.3), value: session.written)

                        AIDisclaimerLabel()
                            .padding(.top, 8)

                    } else if session.isLoading {
                        CatchUpPlaceholder(status: session.statusMessage.isEmpty ? request.statusLabel : session.statusMessage)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background(SkimStyle.chrome.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle("Quick Catch-up")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { articleID in
                ArticleDetailView(articleID: articleID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { session.cancel(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if session.isLoading {
                        Button("Stop", role: .cancel) { session.cancel() }
                            .accessibilityIdentifier("catch-up-stop")
                    } else {
                        Button {
                            session.start(request: request, range: range)
                        } label: {
                            Label("Run Again", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .help("Run Again")
                        .accessibilityIdentifier("catch-up-run-again")
                    }
                }
            }
        }
        .task(id: request.id) {
            guard startedRequestID != request.id else { return }
            startedRequestID = request.id
            session.start(request: request, range: range)
        }
        .onDisappear { session.cancel() }
    }

}

// MARK: - Controls

/// Article count, then the range and model chips on one row. When the two
/// chips don't fit side by side (a long remote model name, large Dynamic
/// Type) they stack instead of wrapping or truncating.
private struct CatchUpControls: View {
    var subtitle: String
    @Binding var range: CatchUpRange
    var isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(subtitle.uppercased())
                .font(.system(size: 11, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(SkimStyle.secondary.opacity(0.8))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    rangeMenu
                    AppModelPicker(isDisabled: isLoading)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    rangeMenu
                    AppModelPicker(isDisabled: isLoading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rangeMenu: some View {
        Menu {
            Picker("Going back", selection: $range) {
                ForEach(CatchUpRange.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            PickerChipLabel(title: range.label, systemImage: "clock")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Going back: \(range.label)")
        .accessibilityIdentifier("catch-up-range")
    }
}

// MARK: - The page
//
// Laid out like a newspaper front page: the lead story across the top with
// its picture, then each other story as a headline and lede beside a
// thumbnail, and under every story a compact row of publication icons, one
// per article behind it. Stories appear one at a time as their ledes land.

private struct CatchUpFrontPage: View {
    var page: NativeAI.CatchUpPage
    var articles: [Article]
    var isLoading: Bool
    /// Stories whose lede is in; while loading, only those and the one being
    /// written are printed.
    var written: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleStories.enumerated()), id: \.element.id) { index, story in
                if index > 0 {
                    Divider()
                        .overlay(SkimStyle.separator.opacity(0.6))
                        .padding(.vertical, 18)
                }
                CatchUpStoryView(
                    story: story,
                    lead: index == 0,
                    articles: articles,
                    isWriting: isLoading && index >= written
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if pending > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(SkimStyle.secondary)
                    Text(pending == 1 ? "1 more story on the way" : "\(pending) more stories on the way")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SkimStyle.secondary.opacity(0.8))
                }
                .padding(.top, 22)
            }

            if !page.briefs.isEmpty {
                if !page.stories.isEmpty {
                    Divider()
                        .overlay(SkimStyle.separator)
                        .padding(.top, 22)
                        .padding(.bottom, 16)
                }

                Text("ALSO")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(SkimStyle.secondary.opacity(0.8))
                    .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(page.briefs) { brief in
                        CatchUpBriefView(brief: brief, articles: articles)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleStories: [NativeAI.CatchUpStory] {
        isLoading ? Array(page.stories.prefix(written + 1)) : page.stories
    }

    private var pending: Int {
        isLoading ? max(0, page.stories.count - written - 1) : 0
    }
}

private func catchUpArticles(_ handles: [Int], in articles: [Article]) -> [Article] {
    handles.compactMap { handle -> Article? in
        let zeroBased = handle - 1
        return articles.indices.contains(zeroBased) ? articles[zeroBased] : nil
    }
}

private struct CatchUpStoryView: View {
    var story: NativeAI.CatchUpStory
    var lead: Bool
    var articles: [Article]
    var isWriting: Bool

    var body: some View {
        if lead {
            VStack(alignment: .leading, spacing: 10) {
                if let imageURL {
                    headlineLink {
                        CatchUpImage(url: imageURL)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .padding(.bottom, 4)
                }
                text
                CatchUpRelated(articles: behind)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    text
                    if let imageURL {
                        headlineLink {
                            CatchUpImage(url: imageURL)
                                .frame(width: 96, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                }
                CatchUpRelated(articles: behind)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: lead ? 9 : 6) {
            if outlets.count > 1 {
                // A story many outlets carried reads as such at a glance.
                Text(outlets.joined(separator: " · ").uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(SkimStyle.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            headlineLink {
                Text(story.headline)
                    .font(.system(size: lead ? 27 : 19, weight: .bold, design: .serif))
                    .foregroundStyle(SkimStyle.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if story.lede.isEmpty {
                if isWriting { CatchUpLedeSkeleton(lead: lead) }
            } else {
                Text(story.lede)
                    .font(.system(size: lead ? 16 : 15, weight: .regular))
                    .foregroundStyle(SkimStyle.secondary)
                    .lineSpacing(3)
                    .lineLimit(lead ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The headline and picture open the story's leading article.
    @ViewBuilder
    private func headlineLink<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if let first = behind.first {
            NavigationLink(value: first.id) { content() }
                .buttonStyle(.plain)
        } else {
            content()
        }
    }

    private var imageURL: URL? { behind.lazy.compactMap(\.imageURL).first }

    private var outlets: [String] {
        var seen = Set<String>()
        return behind.map { PublicationName.of(article: $0) }.filter { seen.insert($0).inserted }
    }

    private var behind: [Article] { catchUpArticles(story.articleIndexes, in: articles) }
}

/// A story's picture, or nothing when it cannot load.
private struct CatchUpImage: View {
    var url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty:
                SkimStyle.surface
            default:
                SkimStyle.surface.opacity(0.5)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CatchUpBriefView: View {
    var brief: NativeAI.CatchUpBrief
    var articles: [Article]

    var body: some View {
        let behind = catchUpArticles(Array(brief.articleIndexes.prefix(2)), in: articles)
        if let first = behind.first {
            NavigationLink(value: first.id) {
                HStack(alignment: .top, spacing: 10) {
                    CatchUpPublicationIcon(article: first, size: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(brief.text)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SkimStyle.text.opacity(0.92))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(PublicationName.of(article: first))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(SkimStyle.secondary.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Text(brief.text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SkimStyle.text.opacity(0.92))
        }
    }
}

/// The articles behind a story as a compact row of publication icons, each
/// opening its article, with the count (or the one publication) after them.
private struct CatchUpRelated: View {
    var articles: [Article]

    var body: some View {
        if !articles.isEmpty {
            HStack(spacing: 6) {
                ForEach(articles) { article in
                    NavigationLink(value: article.id) {
                        CatchUpPublicationIcon(article: article, size: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(article.title), \(PublicationName.of(article: article)). Opens the article.")
                    .contextMenu {
                        Text(article.title)
                        Text(PublicationName.of(article: article))
                    }
                }
                Text(articles.count == 1 ? PublicationName.of(article: articles[0]) : "\(articles.count) sources")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SkimStyle.secondary.opacity(0.8))
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
            .padding(.top, 2)
        }
    }
}

/// A publication's badge: its initials on a colour stable for its feed, the
/// way the article list draws feeds.
private struct CatchUpPublicationIcon: View {
    var article: Article
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(color)
            Text(initials)
                .font(.system(size: size * 0.4, weight: .black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = PublicationName.of(article: article)
            .replacingOccurrences(of: "www.", with: "")
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
        if words.count > 1, let a = words[0].first, let b = words[1].first {
            return String([a, b]).uppercased()
        }
        return String((words.first ?? "S").prefix(2)).uppercased()
    }

    private var color: Color {
        let palette: [Color] = [
            Color(red: 0.12, green: 0.32, blue: 0.98),
            Color(red: 0.68, green: 0.10, blue: 0.17),
            Color(red: 0.45, green: 0.72, blue: 0.77),
            Color(red: 0.93, green: 0.23, blue: 0.13),
            Color(red: 0.91, green: 0.76, blue: 0.19),
            Color(red: 0.52, green: 0.17, blue: 0.30)
        ]
        var hash: UInt64 = 5381
        for byte in PublicationName.of(article: article).utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

// MARK: - Waiting

/// Shimmering rules where a lede is about to land.
private struct CatchUpLedeSkeleton: View {
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
        lead ? [1.0, 0.92, 0.68] : [1.0, 0.84, 0.56]
    }
}

/// What fills the sheet before the first pass comes back.
private struct CatchUpPlaceholder: View {
    var status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(SkimStyle.accent)
                Text(status)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SkimStyle.secondary)
            }

            ForEach(0..<3, id: \.self) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Capsule()
                        .fill(SkimStyle.separator)
                        .frame(height: row == 0 ? 17 : 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: row == 0 ? 0.78 : 0.62, y: 1, anchor: .leading)
                    CatchUpLedeSkeleton(lead: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A live rule under the status line while the rest of the page is written.
private struct CatchUpWritingRule: View {
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
        .padding(.bottom, 4)
    }
}
