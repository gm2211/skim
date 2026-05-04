import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ArticleListView()
        }
        .tint(SkimStyle.accent)
        .background(SkimStyle.background)
        .task {
            await model.load()
        }
    }
}
