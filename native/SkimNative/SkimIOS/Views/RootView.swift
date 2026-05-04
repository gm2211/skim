import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ArticleListView()
        }
        .tint(SkimStyle.accent)
        .background(SkimStyle.background)
        .dynamicTypeSize(.medium)
        .task {
            await model.load()
        }
    }
}
