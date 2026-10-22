import SkimCore
import SwiftUI

/// The Briefing on iPhone: the edition the AI wrote from the reader's feeds.
///
/// A magazine column: the lead piece with its picture, drop cap and
/// takeaways, then the other pieces, then the briefs. Citations are small
/// numbers in the text that open the report; each piece lists its reporting
/// beneath it. Like Today it runs inside the article list's chrome, which
/// owns the title bar and drives `showSettings`.
struct DispatchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("dispatchDays") private var days = 3
    @Binding var showSettings: Bool
    var onBrowseArticles: () -> Void
    var onAsk: (AIChatRequest) -> Void = { _ in }
    @State private var openArticleID: String?
    @State private var showAISettings = false
    private static let pageTop = "dispatch-page-top"
    private static let citeScheme = "skim-cite"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        if let status = model.dispatchStatus { TodayWritingRule(status: status) }
                        notices
                        if let edition = model.dispatch, !edition.themes.isEmpty {
                            ForEach(Array(edition.themes.enumerated()), id: \.offset) { index, theme in
                                piece(theme, index: index, edition: edition)
                                Rectangle().fill(SkimStyle.separator).frame(height: 1)
                            }
                            briefs(edition)
                            Text("Written by AI from your feeds\(edition.model.isEmpty ? "" : " (\(edition.model))"). It can get things wrong: the numbers link to the reporting.")
                                .font(.system(size: 12))
                                .foregroundStyle(SkimStyle.secondary)
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                        } else if model.dispatchStatus != nil || (model.dispatch == nil && model.dispatchError == nil) {
                            TodayPageSkeleton()
                        } else if model.dispatch?.isComplete == true {
                            empty
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .id(Self.pageTop)
                }
                .onChange(of: model.todayPage) { _, _ in proxy.scrollTo(Self.pageTop, anchor: .top) }
                .refreshable { await model.refreshAll() }
                .gesture(DragGesture(minimumDistance: 48, coordinateSpace: .local).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    turn(to: model.todayPage + (value.translation.width < 0 ? 1 : -1))
                })
            }
            pageBar
        }
        .background(SkimStyle.background.ignoresSafeArea())
        .foregroundStyle(SkimStyle.text)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Self.citeScheme, let id = url.host() else { return .systemAction }
            openArticleID = id
            return .handled
        })
        .navigationDestination(item: $openArticleID) { id in ArticleDetailView(articleID: id) }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .task(id: "\(days)-\(model.todayPage)") {
            await load()
            // Renew the window at local midnight if the paper stays open.
            while !Task.isCancelled {
                let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
                do { try await Task.sleep(for: .seconds(max(1, end.timeIntervalSinceNow + 1))) } catch { return }
                await load()
            }
        }
        .onDisappear { model.cancelDispatchWork() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
    }

    private func load(_ mode: AppModel.DispatchMode = .open) async {
        await model.loadDispatch(days: days, mode: mode)
    }

    private func turn(to page: Int) {
        guard page >= 1, page <= AppModel.todayPageCount, page != model.todayPage else { return }
        withAnimation(.smooth(duration: 0.2)) { model.todayPage = page }
    }

    private var window: (start: Date, end: Date) {
        Dispatch.window(now: Date(), page: model.todayPage, days: Dispatch.days(days))
    }

    static func dateline(start: Date, end: Date) -> String {
        let last = end.addingTimeInterval(-1)
        if Calendar.current.isDate(start, inSameDayAs: last) {
            return start.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        let from = start.formatted(.dateTime.month(.wide).day())
        let sameMonth = Calendar.current.isDate(start, equalTo: last, toGranularity: .month)
        return "\(from) – \(sameMonth ? last.formatted(.dateTime.day()) : last.formatted(.dateTime.month(.wide).day()))"
    }

    private var spanLabel: String {
        let days = Dispatch.days(days)
        if model.todayPage > 1 { return days == 1 ? "DAILY EDITION" : "\(days)-DAY EDITION" }
        return days == 1 ? "TODAY" : "LAST \(days) DAYS"
    }

    /// The dateline under the nameplate in the title bar.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(SkimStyle.text.opacity(0.28)).frame(height: 1).padding(.top, 10)
            HStack(alignment: .firstTextBaseline) {
                Text(Self.dateline(start: window.start, end: window.end).uppercased())
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(spanLabel).foregroundStyle(SkimStyle.secondary.opacity(0.8))
            }
            .font(.system(size: 10.5, weight: .bold))
            .kerning(1.0)
            .foregroundStyle(SkimStyle.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            if let edition = model.dispatch, edition.articleCount > 0 {
                Text("Written by AI from \(edition.articleCount) articles · \(edition.themes.count) \(edition.themes.count == 1 ? "theme" : "themes")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SkimStyle.secondary.opacity(0.85))
            }
            Rectangle().fill(SkimStyle.text.opacity(0.28)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let error = model.dispatchError, model.dispatchStatus == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn’t write this edition").font(.headline)
                Text(error).font(.subheadline).foregroundStyle(SkimStyle.secondary)
                HStack(spacing: 20) {
                    Button("Try again") { Task { await load(.retry) } }.frame(minHeight: 44)
                    AISettingsButton(titled: true, font: .body, color: SkimStyle.accent, onDismiss: { Task { await load() } })
                }
            }
        }
        if let edition = model.dispatch, model.dispatchStatus == nil {
            let failed = edition.themes.filter { !$0.isWritten && $0.error != nil }.count
            if failed > 0 {
                notice("\(failed) \(failed == 1 ? "piece wasn’t" : "pieces weren’t") written.", action: "Retry") { Task { await load(.retry) } }
            }
            if model.todayPage == 1, model.dispatchNewArticles > 0, !edition.themes.isEmpty {
                notice("\(model.dispatchNewArticles) new \(model.dispatchNewArticles == 1 ? "article" : "articles") since this edition was written.", action: "Write a new edition") {
                    Task { await load(.rewrite) }
                }
            }
        }
    }

    private func notice(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(text)
                Spacer(minLength: 4)
                Button(action, action: perform).fontWeight(.semibold)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                Button(action, action: perform).fontWeight(.semibold)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(SkimStyle.secondary)
        .tint(SkimStyle.accent)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).stroke(SkimStyle.separator))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: SkimIcon.today).font(.largeTitle).foregroundStyle(SkimStyle.accent)
            Text(model.todayPage == 1 ? "Nothing to write about yet" : "Nothing was published in these days").font(.title3.bold())
            Text("Pull down to check your feeds again.").foregroundStyle(SkimStyle.secondary)
            Button("Browse articles") { onBrowseArticles() }.frame(minHeight: 44)
        }
        .padding(.vertical, 28)
    }

    /// A paragraph with its `[n]` citations as small links to the reports.
    private func cited(_ paragraph: String, ids: [String], color: Color) -> AttributedString {
        var result = AttributedString()
        for part in Dispatch.parts(paragraph) {
            switch part {
            case .text(let text):
                result += AttributedString(text)
            case .cites(let numbers):
                for number in numbers where number >= 1 && number <= ids.count {
                    var cite = AttributedString(" \(number)")
                    cite.baselineOffset = 6
                    cite.font = .system(size: 10, weight: .bold)
                    cite.foregroundColor = color
                    cite.link = URL(string: "\(Self.citeScheme)://\(ids[number - 1])")
                    result += cite
                }
            }
        }
        return result
    }

    @ViewBuilder
    private func piece(_ theme: DispatchEdition.Theme, index: Int, edition: DispatchEdition) -> some View {
        let lead = index == 0
        let color = TodayAccent.color(for: theme.kicker)
        let reports = theme.articleIDs.compactMap { edition.article($0) }
        VStack(alignment: .leading, spacing: 10) {
            (Text(theme.kicker.uppercased()).foregroundColor(color)
             + Text(" · \(reports.count) \(reports.count == 1 ? "REPORT" : "REPORTS")").foregroundColor(SkimStyle.secondary))
                .font(.system(size: 11, weight: .bold))
                .kerning(1.2)
            Text(theme.headline)
                .font(.system(size: lead ? 30 : 22, weight: .bold, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            if !theme.dek.isEmpty {
                Text(theme.dek)
                    .font(.system(size: lead ? 18 : 15, design: .serif).italic())
                    .foregroundStyle(SkimStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if lead, let image = reports.lazy.compactMap(\.imageURL).first {
                AsyncImage(url: image) { phase in
                    if let picture = phase.image {
                        picture.resizable().scaledToFill()
                            .frame(maxWidth: .infinity).frame(height: 190).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            if theme.isWritten {
                ForEach(Array(theme.body.enumerated()), id: \.offset) { _, paragraph in
                    Text(cited(paragraph, ids: theme.articleIDs, color: color))
                        .font(.system(size: lead ? 17 : 16))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !theme.takeaways.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("WHAT IT MEANS").font(.system(size: 11, weight: .bold)).kerning(1.2).foregroundStyle(SkimStyle.secondary)
                        ForEach(Array(theme.takeaways.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(color)
                                Text(cited(line, ids: theme.articleIDs, color: color)).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 14.5))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
                }
            } else if let error = theme.error {
                Text(error).font(.system(size: 13)).foregroundStyle(Color.orange)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach([1.0, 0.94, 0.7], id: \.self) { width in
                        GeometryReader { proxy in
                            Capsule().fill(SkimStyle.surface).frame(width: proxy.size.width * width, height: 11)
                        }
                        .frame(height: 11)
                    }
                }
                .accessibilityLabel("Writing this piece")
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(reports.enumerated()), id: \.offset) { number, report in
                    Button { openArticleID = report.id } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(number + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(color).monospacedDigit()
                            Text(report.publication).font(.system(size: 12, weight: .semibold)).foregroundStyle(SkimStyle.secondary).lineLimit(1)
                            Text(report.title).font(.system(size: 12.5)).foregroundStyle(SkimStyle.secondary.opacity(0.85)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Report \(number + 1), \(report.publication): \(report.title)")
                }
            }
            .padding(.top, 4)
            if theme.isWritten {
                Button {
                    onAsk(chat(theme, edition: edition))
                } label: {
                    Label("Ask about this", systemImage: SkimIcon.chat).font(.system(size: 14, weight: .medium))
                }
                .tint(SkimStyle.accent)
                .frame(minHeight: 44)
            }
        }
        .padding(.top, lead ? 6 : 0)
    }

    @ViewBuilder
    private func briefs(_ edition: DispatchEdition) -> some View {
        if !edition.briefs.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("ALSO IN YOUR FEEDS").font(.system(size: 11, weight: .bold)).kerning(1.4).foregroundStyle(SkimStyle.secondary)
                    .padding(.bottom, 6)
                ForEach(Array(edition.briefs.enumerated()), id: \.offset) { _, brief in
                    let source = brief.articleIDs.first.flatMap { edition.article($0) }
                    Button { if let source { openArticleID = source.id } } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(brief.text).font(.system(size: 15)).foregroundStyle(SkimStyle.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            if let source { Text(source.publication).font(.system(size: 12, weight: .semibold)).foregroundStyle(SkimStyle.accent) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) { Rectangle().fill(SkimStyle.separator.opacity(0.6)).frame(height: 1) }
                }
            }
        }
    }

    private func chat(_ theme: DispatchEdition.Theme, edition: DispatchEdition) -> AIChatRequest {
        let model = self.model
        let ids = theme.articleIDs
        return AIChatRequest(sessionKey: "\(edition.id)-\(theme.headline)", title: "Ask about this",
                             placeholder: "\(theme.headline)\n\nAsk why it matters, where the reports disagree, or what happens next.") { conversation in
            let context = await model.articlesForTodayChat(await model.dispatchReports(ids))
            guard !context.isEmpty else {
                return AIChatAnswer(text: "These reports are no longer on this device. Refresh your feeds and try again.", articles: [])
            }
            let (text, citations) = try await NativeAI.chat(conversation: conversation, articles: context, settings: model.settings)
            return AIChatAnswer(text: text, articles: context, webCitations: citations,
                                articleHandles: NativeAI.libraryChatHandles(articles: context, conversation: conversation))
        }
    }

    /// A chat about the whole edition, reading every piece's reports.
    static func pageChat(_ edition: DispatchEdition, model: AppModel) -> AIChatRequest {
        let ids = Array(edition.themes.flatMap(\.articleIDs).prefix(30))
        return AIChatRequest(sessionKey: "\(edition.id)-page", title: "Ask about \(Dispatch.name)",
                             placeholder: "Ask about this edition’s \(edition.themes.count) themes: what matters most, what connects them.") { conversation in
            let context = await model.articlesForTodayChat(await model.dispatchReports(ids))
            guard !context.isEmpty else {
                return AIChatAnswer(text: "These reports are no longer on this device. Refresh your feeds and try again.", articles: [])
            }
            let (text, citations) = try await NativeAI.chat(conversation: conversation, articles: context, settings: model.settings)
            return AIChatAnswer(text: text, articles: context, webCitations: citations,
                                articleHandles: NativeAI.libraryChatHandles(articles: context, conversation: conversation))
        }
    }

    private var pageBar: some View {
        HStack(spacing: 12) {
            Button { turn(to: model.todayPage - 1) } label: {
                Label(model.todayPage == 2 ? "Latest" : "Newer", systemImage: "chevron.left")
            }
            .disabled(model.todayPage <= 1)
            .opacity(model.todayPage <= 1 ? 0.35 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 1) {
                Text(model.todayPage == 1 ? "Front page" : "Page \(model.todayPage)").font(.system(size: 12, weight: .semibold))
                Text(Self.dateline(start: window.start, end: window.end)).font(.system(size: 11)).foregroundStyle(SkimStyle.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Button { turn(to: model.todayPage + 1) } label: {
                HStack(spacing: 4) { Text("Older"); Image(systemName: "chevron.right") }
            }
            .disabled(model.todayPage >= AppModel.todayPageCount)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(SkimStyle.text)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(SkimStyle.chrome)
        .overlay(alignment: .top) { Rectangle().fill(SkimStyle.separator.opacity(0.4)).frame(height: 1) }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Covers", selection: $days) {
                        Text("1 day").tag(1)
                        Text("3 days").tag(3)
                        Text("7 days").tag(7)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Each edition covers")
                } footer: {
                    Text("The AI reads every article in these days and writes the paper from them. Each page turned goes back one more edition.")
                }
                Section("Writing") {
                    AppModelPicker(isDisabled: model.dispatchStatus != nil)
                    Button("Write a new edition") {
                        showSettings = false
                        Task { await load(.rewrite) }
                    }
                    .disabled(model.dispatchStatus != nil)
                    Button {
                        showAISettings = true
                    } label: {
                        Label("AI Settings…", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle(Dispatch.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } }
            }
        }
        .presentationDetents([.medium])
        .sheet(isPresented: $showAISettings) { SettingsSheet(isPresented: $showAISettings, aiOnly: true) }
    }
}
