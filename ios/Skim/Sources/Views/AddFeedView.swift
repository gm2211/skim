import SwiftUI

struct AddFeedView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var feedUrl = ""
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Feed URL", text: $feedUrl)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Feed URL")
                } footer: {
                    Text("Enter the RSS or Atom feed URL")
                }

                if let error = error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button("Add") {
                            addFeed()
                        }
                        .disabled(feedUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func addFeed() {
        let url = feedUrl.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }

        isLoading = true
        error = nil

        Task {
            do {
                try await appState.addFeed(url: url, modelContext: modelContext)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}
