import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isDropTargeted: Bool = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } content: {
            ArticleListView()
        } detail: {
            if let article = appState.selectedArticle {
                ArticleDetailView(article: article)
            } else {
                ContentUnavailableView(
                    "Select an article to read",
                    systemImage: "doc.text",
                    description: Text("Pick an article from the list.")
                )
                .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $appState.showAddFeed) {
            AddFeedView()
        }
        .sheet(isPresented: $appState.showSettings) {
            SettingsView().environmentObject(appState)
        }
        .modelContainer(for: [Feed.self, Article.self])
        .onChange(of: appState.selectedArticle) { _, newValue in
            adaptColumns(forSelection: newValue)
        }
        .onAppear {
            adaptColumns(forSelection: appState.selectedArticle)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedURLs(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay(alignment: .top) {
            if isDropTargeted {
                Text("Drop OPML file to import feeds")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    /// On iPad portrait (compact width), collapse sidebar to .detailOnly when an article is selected
    /// so the reader gets full screen real estate. Landscape (regular width) stays balanced.
    private func adaptColumns(forSelection article: Article?) {
        #if canImport(UIKit)
        if horizontalSizeClass == .compact {
            // iPhone or iPad portrait/slide-over: collapse to detail once reading.
            columnVisibility = article == nil ? .automatic : .detailOnly
        } else {
            // Regular width (iPad landscape, macOS): always show 3-pane.
            columnVisibility = .all
        }
        #else
        columnVisibility = .all
        #endif
    }

    /// Accept .opml / .xml files dragged in. Actual parsing is tracked in a follow-up issue.
    @discardableResult
    private func handleDroppedURLs(_ urls: [URL]) -> Bool {
        let accepted = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "opml" || ext == "xml"
        }
        guard !accepted.isEmpty else { return false }
        for url in accepted {
            print("[OPML drop] received: \(url.absoluteString)")
        }
        return true
    }
}
