import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } content: {
            ArticleListView()
        } detail: {
            if let article = appState.selectedArticle {
                ArticleDetailView(article: article)
            } else {
                Text("Select an article to read")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $appState.showAddFeed) {
            AddFeedView()
        }
        .modelContainer(for: [Feed.self, Article.self])
    }
}
