import SkimCore
import SwiftUI

/// Asks before unfollowing a feed, because unfollowing deletes its articles.
/// Set `feed` to ask; it goes back to nil when the reader answers.
struct UnfollowConfirmation: ViewModifier {
    @ObservedObject var model: AppModel
    @Binding var feed: Feed?
    var onUnfollowed: (Feed) -> Void = { _ in }
    @State private var starred = 0

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                feed.map { "Unfollow \($0.title)?" } ?? "",
                isPresented: Binding(get: { feed != nil }, set: { if !$0 { feed = nil } }),
                titleVisibility: .visible,
                presenting: feed
            ) { target in
                Button("Unfollow", role: .destructive) {
                    Task {
                        if await model.unfollowFeed(id: target.id) {
                            onUnfollowed(target)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(starred > 0
                     ? "Its articles go too, including \(starred) starred."
                     : "Its articles go too. You can follow it again from Discover.")
            }
            .task(id: feed?.id) {
                guard let id = feed?.id else { return }
                starred = await model.starredCount(feedID: id)
            }
    }
}

extension View {
    func unfollowConfirmation(model: AppModel, feed: Binding<Feed?>, onUnfollowed: @escaping (Feed) -> Void = { _ in }) -> some View {
        modifier(UnfollowConfirmation(model: model, feed: feed, onUnfollowed: onUnfollowed))
    }
}
