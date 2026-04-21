import SwiftUI

struct ArticleDetailView: View {
    @Bindable var article: Article
    @State private var showSummary = false
    @State private var summary: String?
    @State private var isSummarizing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(article.title)
                        .font(.title)
                        .fontWeight(.bold)

                    HStack(spacing: 8) {
                        if let feedTitle = article.feed?.title {
                            Text(feedTitle)
                                .font(.subheadline)
                                .foregroundStyle(.accent)
                        }
                        if let author = article.author {
                            Text("·")
                                .foregroundStyle(.secondary)
                            Text(author)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let date = article.publishedAt {
                            Text("·")
                                .foregroundStyle(.secondary)
                            Text(date, style: .date)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // AI Summary
                if isSummarizing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Summarizing...")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if let summary = summary {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AI SUMMARY")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .tracking(1)
                        Text(summary)
                            .font(.body)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Divider()

                // Content
                if let html = article.contentHtml {
                    HTMLTextView(html: html)
                } else if let text = article.contentText {
                    Text(text)
                        .font(.body)
                } else {
                    Text("No content available")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    article.isStarred.toggle()
                } label: {
                    Image(systemName: article.isStarred ? "star.fill" : "star")
                        .foregroundStyle(article.isStarred ? .yellow : .secondary)
                }
                .accessibilityLabel(article.isStarred ? "Unstar article" : "Star article")

                Button {
                    article.isRead.toggle()
                } label: {
                    Image(systemName: article.isRead ? "circle" : "circle.fill")
                        .foregroundStyle(article.isRead ? .secondary : .accent)
                }
                .accessibilityLabel(article.isRead ? "Mark as unread" : "Mark as read")

                // Feedback buttons
                Menu {
                    Button {
                        article.feedback = article.feedback == "more" ? nil : "more"
                    } label: {
                        Label(article.feedback == "more" ? "Remove Like" : "More Like This",
                              systemImage: "hand.thumbsup")
                    }
                    Button {
                        article.feedback = article.feedback == "less" ? nil : "less"
                    } label: {
                        Label(article.feedback == "less" ? "Remove Dislike" : "Less Like This",
                              systemImage: "hand.thumbsdown")
                    }
                } label: {
                    Image(systemName: feedbackIcon)
                        .foregroundStyle(feedbackColor)
                }
                .accessibilityLabel("Feedback")

                if let url = article.url.flatMap({ URL(string: $0) }) {
                    ShareLink(item: url)
                        .accessibilityLabel("Share article")
                }
            }
        }
    }

    var feedbackIcon: String {
        switch article.feedback {
        case "more": return "hand.thumbsup.fill"
        case "less": return "hand.thumbsdown.fill"
        default: return "hand.thumbsup"
        }
    }

    var feedbackColor: Color {
        switch article.feedback {
        case "more": return .green
        case "less": return .red
        default: return .secondary
        }
    }
}

// Simple HTML text renderer for article content
struct HTMLTextView: View {
    let html: String

    var body: some View {
        if let attributed = try? AttributedString(
            html: html,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.body)
        } else {
            // Fallback: strip HTML tags
            Text(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .font(.body)
        }
    }
}
