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

/// Quick Catch-up, laid out like a broadsheet front page: a dateline under a
/// double rule, the lead story with its picture, two featured stories, then
/// the rest of the page and a dense "Also" block. On a wide screen the lead
/// runs beside its picture and the tiers sit in two columns; on a phone the
/// page is one column. Stories print as their ledes land.
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
                    CatchUpControls(range: $range, isLoading: session.isLoading)
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
                        CatchUpDateline(
                            trailing: session.isLoading ? session.statusMessage : request.subtitle,
                            isLive: session.isLoading
                        )

                        CatchUpFrontPage(page: session.page, articles: session.articles, isLoading: session.isLoading, written: session.written)
                            .animation(.easeOut(duration: 0.3), value: session.written)

                        AIDisclaimerLabel()
                            .padding(.top, 8)

                    } else if session.isLoading {
                        CatchUpGhostPage(status: session.statusMessage.isEmpty ? request.statusLabel : session.statusMessage)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
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
                        Button("Run Again") { session.start(request: request, range: range) }
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

/// The range and model chips on one row. When the two don't fit side by side
/// (a long remote model name, large Dynamic Type) they stack instead of
/// wrapping or truncating.
private struct CatchUpControls: View {
    @Binding var range: CatchUpRange
    var isLoading: Bool

    var body: some View {
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

// MARK: - Masthead

/// The dateline over the page: today's date on the left, what the run read
/// (or what it is doing) on the right, under a double rule. The rule pulses
/// while the page is still being written.
private struct CatchUpDateline: View {
    var trailing: String
    var isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day().year()).uppercased())
                    .foregroundStyle(SkimStyle.secondary)
                Spacer(minLength: 8)
                Text(trailing.uppercased())
                    .foregroundStyle(SkimStyle.secondary.opacity(0.75))
                    .multilineTextAlignment(.trailing)
            }
            .font(.system(size: 10.5, weight: .bold))
            .kerning(1.0)
            .lineLimit(2)
            .minimumScaleFactor(0.85)

            CatchUpRule(strong: true, live: isLive)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A newspaper rule: a thin hairline, or the double rule under a masthead.
private struct CatchUpRule: View {
    var strong = false
    var live = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 2) {
            Rectangle()
                .fill(live ? SkimStyle.accent : SkimStyle.text.opacity(strong ? 0.28 : 0.11))
                .frame(height: strong ? 2 : 1)
                .opacity(live ? (pulse ? 0.9 : 0.3) : 1)
                .animation(live ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
                .onAppear { pulse = live }
                .onChange(of: live) { _, now in pulse = now }
            if strong {
                Rectangle()
                    .fill(SkimStyle.text.opacity(0.11))
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - The page

private struct CatchUpFrontPage: View {
    var page: NativeAI.CatchUpPage
    var articles: [Article]
    var isLoading: Bool
    /// Stories whose lede is in; while loading, only those and the one being
    /// written are printed.
    var written: Int
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var wide: Bool { sizeClass == .regular }

    var body: some View {
        let stories = visibleStories
        VStack(alignment: .leading, spacing: 0) {
            if let lead = stories.first {
                CatchUpStoryView(story: lead, tier: .lead, wide: wide, articles: articles, isWriting: isLoading && written == 0)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.bottom, 20)
                CatchUpRule(strong: true)
            }

            let features = Array(stories.dropFirst().prefix(2))
            if !features.isEmpty {
                columns(features, startingAt: 1, spacing: 20) { story, index in
                    CatchUpStoryView(story: story, tier: .feature, wide: wide, articles: articles, isWriting: isLoading && index >= written)
                }
                .padding(.vertical, 20)
                CatchUpRule()
            }

            let rest = Array(stories.dropFirst(3))
            if !rest.isEmpty {
                columns(rest, startingAt: 3, spacing: 16) { story, index in
                    CatchUpStoryView(story: story, tier: .story, wide: wide, articles: articles, isWriting: isLoading && index >= written)
                }
                .padding(.top, 4)
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
                CatchUpAlsoBlock(briefs: page.briefs, articles: articles, wide: wide)
                    .padding(.top, page.stories.isEmpty ? 0 : 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Two columns with a hairline between them on a wide screen, one column
    /// with a hairline between rows on a phone.
    @ViewBuilder
    private func columns<Content: View>(
        _ items: [NativeAI.CatchUpStory],
        startingAt first: Int,
        spacing: CGFloat,
        @ViewBuilder content: @escaping (NativeAI.CatchUpStory, Int) -> Content
    ) -> some View {
        if wide {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
                    if start > 0 { CatchUpRule().padding(.vertical, spacing) }
                    HStack(alignment: .top, spacing: 0) {
                        content(items[start], first + start)
                            .padding(.trailing, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if start + 1 < items.count {
                            Rectangle().fill(SkimStyle.text.opacity(0.11)).frame(width: 1)
                            content(items[start + 1], first + start + 1)
                                .padding(.leading, 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, story in
                    if offset > 0 { CatchUpRule().padding(.vertical, spacing) }
                    content(story, first + offset)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
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

/// Where a story sits on the page, which sets its type size and picture.
private enum CatchUpTier {
    case lead, feature, story

    var headlineSize: CGFloat {
        switch self {
        case .lead: return 28
        case .feature: return 20
        case .story: return 17
        }
    }

    var ledeSize: CGFloat {
        switch self {
        case .lead: return 16
        case .feature: return 14.5
        case .story: return 14
        }
    }

    var ledeLines: Int? {
        switch self {
        case .lead: return nil
        case .feature: return 4
        case .story: return 3
        }
    }
}

private struct CatchUpStoryView: View {
    var story: NativeAI.CatchUpStory
    var tier: CatchUpTier
    var wide: Bool
    var articles: [Article]
    var isWriting: Bool

    var body: some View {
        switch tier {
        case .lead:
            if wide, let imageURL {
                // A broadsheet lead: text on the left, picture on the right.
                HStack(alignment: .top, spacing: 24) {
                    text.frame(maxWidth: .infinity, alignment: .leading)
                    picture(imageURL, aspect: 4 / 3, radius: 8)
                        .frame(maxWidth: 320)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let imageURL {
                        picture(imageURL, aspect: 16 / 9, radius: 8)
                    }
                    text
                }
            }
        case .feature:
            VStack(alignment: .leading, spacing: 10) {
                if let imageURL {
                    picture(imageURL, aspect: 21 / 9, radius: 6)
                }
                text
            }
        case .story:
            HStack(alignment: .top, spacing: 14) {
                text.frame(maxWidth: .infinity, alignment: .leading)
                if let imageURL {
                    headlineLink {
                        CatchUpImage(url: imageURL)
                            .frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
    }

    private func picture(_ url: URL, aspect: CGFloat, radius: CGFloat) -> some View {
        headlineLink {
            CatchUpImage(url: url)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: tier == .lead ? 9 : 6) {
            if outlets.count > 1 {
                // A story many outlets carried reads as such at a glance.
                Text(outlets.joined(separator: " · ").uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(SkimStyle.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            headlineLink {
                Text(story.headline)
                    .font(.system(size: tier.headlineSize, weight: .bold, design: .serif))
                    .foregroundStyle(SkimStyle.text)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(tier == .lead ? 1 : 0)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if story.lede.isEmpty {
                if isWriting { CatchUpLedeSkeleton(lines: tier.ledeLines ?? 4) }
            } else {
                Text(story.lede)
                    .font(.system(size: tier.ledeSize, weight: .regular))
                    .foregroundStyle(SkimStyle.text.opacity(0.84))
                    .lineSpacing(3)
                    .lineLimit(tier.ledeLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            CatchUpRelated(articles: behind, size: tier == .lead ? 26 : 22)
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
        .overlay(RoundedRectangle(cornerRadius: 0).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// The briefs below the fold: a boxed block with a hairline under each.
private struct CatchUpAlsoBlock: View {
    var briefs: [NativeAI.CatchUpBrief]
    var articles: [Article]
    var wide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ALSO")
                .font(.system(size: 11, weight: .bold))
                .kerning(1.3)
                .foregroundStyle(SkimStyle.secondary)
                .padding(.bottom, 8)
            CatchUpRule()

            if wide {
                let rows = Array(stride(from: 0, to: briefs.count, by: 2))
                ForEach(rows, id: \.self) { start in
                    HStack(alignment: .top, spacing: 0) {
                        brief(briefs[start]).padding(.trailing, 14)
                        if start + 1 < briefs.count {
                            brief(briefs[start + 1]).padding(.leading, 14)
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    CatchUpRule()
                }
            } else {
                ForEach(briefs) { item in
                    brief(item)
                    CatchUpRule()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func brief(_ item: NativeAI.CatchUpBrief) -> some View {
        CatchUpBriefView(brief: item, articles: articles)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    CatchUpPublicationIcon(article: first, size: 20)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(brief.text)
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(SkimStyle.text.opacity(0.94))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(PublicationName.of(article: first))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(SkimStyle.secondary.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Text(brief.text)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(SkimStyle.text.opacity(0.94))
        }
    }
}

/// The articles behind a story as a compact row of publication icons, each
/// opening its article, with the count (or the one publication) after them.
private struct CatchUpRelated: View {
    var articles: [Article]
    var size: CGFloat = 22

    var body: some View {
        if !articles.isEmpty {
            HStack(spacing: 6) {
                ForEach(articles) { article in
                    NavigationLink(value: article.id) {
                        CatchUpPublicationIcon(article: article, size: size)
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
            .padding(.top, 4)
        }
    }
}

/// A publication's badge: its favicon when the feed has one, otherwise its
/// initials on a colour stable for its feed, the way the article list draws
/// feeds.
private struct CatchUpPublicationIcon: View {
    var article: Article
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
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
    var lines: Int = 3
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(widths.prefix(lines).enumerated()), id: \.offset) { _, width in
                Capsule()
                    .fill(SkimStyle.separator)
                    .frame(height: 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: width, y: 1, anchor: .leading)
            }
        }
        .padding(.top, 4)
        .opacity(pulse ? 0.95 : 0.4)
        .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityElement()
        .accessibilityLabel("Writing this story")
    }

    private var widths: [CGFloat] { [1.0, 0.92, 0.68, 0.84] }
}

/// What fills the sheet before the first pass comes back: the dateline over
/// the shape of a front page, drawn in shimmering rules.
private struct CatchUpGhostPage: View {
    var status: String
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CatchUpDateline(trailing: status, isLive: true)

            VStack(alignment: .leading, spacing: 20) {
                ghost(height: 180, radius: 8)
                VStack(alignment: .leading, spacing: 10) {
                    ghost(width: 0.9, height: 20)
                    ghost(width: 0.64, height: 20)
                }
                CatchUpLedeSkeleton(lines: 4)
                CatchUpRule(strong: true).padding(.top, 6)
                ForEach(0..<2, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        ghost(height: 110, radius: 6)
                        ghost(width: 0.78, height: 15)
                        CatchUpLedeSkeleton(lines: 2)
                    }
                    .padding(.top, 4)
                }
            }
            .opacity(pulse ? 0.9 : 0.45)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status)
    }

    private func ghost(width: CGFloat = 1, height: CGFloat, radius: CGFloat = 999) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(SkimStyle.separator)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(x: width, y: 1, anchor: .leading)
    }
}
