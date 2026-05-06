import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAIDisclaimer = !AIBootDisclaimerView.isAccepted

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
        .fullScreenCover(isPresented: $showAIDisclaimer) {
            AIBootDisclaimerView {
                AIBootDisclaimerView.markAccepted()
                showAIDisclaimer = false
            }
        }
    }
}
