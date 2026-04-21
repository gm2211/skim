import SwiftUI
import SwiftData

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Query(sort: \Feed.title) private var feeds: [Feed]
    @Environment(\.modelContext) private var modelContext

    var totalUnread: Int {
        feeds.reduce(0) { $0 + $1.unreadCount }
    }

    var body: some View {
        List(selection: $appState.currentView) {
            Section {
                NavigationLink(value: AppState.SidebarSection.allArticles) {
                    Label {
                        HStack {
                            Text("All Articles")
                            Spacer()
                            if totalUnread > 0 {
                                Text("\(totalUnread)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("\(totalUnread) unread")
                            }
                        }
                    } icon: {
                        Image(systemName: "tray")
                    }
                }

                NavigationLink(value: AppState.SidebarSection.starred) {
                    Label("Starred", systemImage: "star")
                }

                NavigationLink(value: AppState.SidebarSection.inbox) {
                    Label("AI Inbox", systemImage: "brain")
                }

                NavigationLink(value: AppState.SidebarSection.themes) {
                    Label("Themes", systemImage: "square.grid.2x2")
                }
            }

            Section("Feeds") {
                ForEach(feeds) { feed in
                    NavigationLink(value: AppState.SidebarSection.feed(feed.id)) {
                        HStack {
                            Text(String(feed.title.prefix(1)))
                                .font(.caption.bold())
                                .frame(width: 28, height: 28)
                                .background(Color.accentColor.opacity(0.2))
                                .foregroundStyle(.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                            Text(feed.title)
                                .lineLimit(1)

                            Spacer()

                            if feed.unreadCount > 0 {
                                Text("\(feed.unreadCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("\(feed.unreadCount) unread")
                            }
                        }
                    }
                }
                .onDelete(perform: deleteFeed)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SKIM")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showAddFeed = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Feed")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await appState.refreshAllFeeds(modelContext: modelContext)
                    }
                } label: {
                    if appState.isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(appState.isRefreshing)
                .accessibilityLabel("Refresh All Feeds")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showSettings = true
                } label: {
                    Image(systemName: "gear")
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    private func deleteFeed(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(feeds[index])
        }
    }
}
