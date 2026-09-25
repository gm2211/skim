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
                    Text(request.subtitle)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)

                    HStack(spacing: 12) {
                        Picker("Going back", selection: $range) {
                            ForEach(CatchUpRange.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("catch-up-range")
                        .onChange(of: range) { _, selected in session.start(request: request, range: selected) }

                        Spacer()

                        AppModelPicker(isDisabled: session.isLoading)
                    }

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

                        CatchUpFrontPage(page: session.page, articles: session.articles, isLoading: session.isLoading)

                        AIDisclaimerLabel()
                            .padding(.top, 8)

                    } else if let fallbackText = session.fallbackText {
                        // Structured parse failed — render plain AI text as before
                        CatchUpFallbackText(fallbackText)

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

// MARK: - The page

private struct CatchUpFrontPage: View {
    var page: NativeAI.CatchUpPage
    var articles: [Article]
    var isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(page.stories.enumerated()), id: \.element.id) { index, story in
                if index > 0 {
                    Divider()
                        .overlay(SkimStyle.separator.opacity(0.6))
                        .padding(.vertical, 18)
                }
                CatchUpStoryView(story: story, lead: index == 0, articles: articles, isWriting: isLoading)
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
}

private struct CatchUpStoryView: View {
    var story: NativeAI.CatchUpStory
    var lead: Bool
    var articles: [Article]
    var isWriting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: lead ? 10 : 7) {
            Text(story.headline)
                .font(.system(size: lead ? 26 : 18, weight: lead ? .bold : .semibold))
                .foregroundStyle(SkimStyle.text)
                .fixedSize(horizontal: false, vertical: true)

            if story.lede.isEmpty {
                if isWriting { CatchUpLedeSkeleton(lead: lead) }
            } else {
                Text(story.lede)
                    .font(.system(size: lead ? 16 : 15, weight: .regular))
                    .foregroundStyle(SkimStyle.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            CatchUpByline(articles: behind)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var behind: [Article] {
        story.articleIndexes.compactMap { handle -> Article? in
            let zeroBased = handle - 1
            return articles.indices.contains(zeroBased) ? articles[zeroBased] : nil
        }
    }
}

private struct CatchUpBriefView: View {
    var brief: NativeAI.CatchUpBrief
    var articles: [Article]

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("•")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(SkimStyle.accent)

            VStack(alignment: .leading, spacing: 5) {
                Text(brief.text)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(SkimStyle.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                CatchUpByline(articles: behind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var behind: [Article] {
        brief.articleIndexes.prefix(2).compactMap { handle -> Article? in
            let zeroBased = handle - 1
            return articles.indices.contains(zeroBased) ? articles[zeroBased] : nil
        }
    }
}

/// The articles a story was built from, printed as a byline under it.
private struct CatchUpByline: View {
    var articles: [Article]

    var body: some View {
        if articles.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(articles) { article in
                    NavigationLink(value: article.id) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(PublicationName.of(article: article))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SkimStyle.accent)
                                .fixedSize()

                            Text(article.title)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(SkimStyle.secondary.opacity(0.85))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(article.title), \(PublicationName.of(article: article)). Tap to open article.")
                }
            }
            .padding(.top, 3)
        }
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

// MARK: - Fallback plain text

private struct CatchUpFallbackText: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(formattedText)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(SkimStyle.text)
            .lineSpacing(5)
            .textSelection(.enabled)
    }

    private var formattedText: AttributedString {
        if let parsed = try? AttributedString(markdown: text) {
            return parsed
        }
        return AttributedString(text)
    }
}
