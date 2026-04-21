import SwiftUI

/// Settings > On-device MLX > Manage models.
/// Lists available MLX-compatible models, shows download / delete controls,
/// and a progress bar while weights are being fetched.
struct MLXModelsView: View {
    @StateObject private var manager = MLXModelManager.shared

    var body: some View {
        List {
            if manager.isDownloading, let progress = manager.downloadProgress {
                Section("Downloading") {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress) {
                            Text("Fetching weights…")
                        }
                        Text("\(Int(progress * 100))%")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let err = manager.lastError {
                Section {
                    Text(err).foregroundStyle(.red).font(.footnote)
                }
            }

            Section("Models") {
                ForEach(manager.availableModels()) { option in
                    ModelRow(option: option, manager: manager)
                }
            }

            Section {
                Button("Delete all cached models", role: .destructive) {
                    Task { await manager.deleteAll() }
                }
                .disabled(manager.downloadedRepoIds.isEmpty || manager.isDownloading)
            } footer: {
                Text("Models are stored under Application Support. Deleting frees disk space; you can re-download any time.")
            }
        }
        .navigationTitle("On-device models")
        .onAppear { manager.refreshDownloadedState() }
    }
}

private struct ModelRow: View {
    let option: MLXModelOption
    @ObservedObject var manager: MLXModelManager

    private var isDownloaded: Bool { manager.downloadedRepoIds.contains(option.repoId) }
    private var isActive: Bool { manager.activeRepoId == option.repoId }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.displayName).font(.headline)
                        if isActive {
                            Text("ACTIVE")
                                .font(.caption2).bold()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    Text(option.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "~%.1f GB · %@", option.sizeGB, option.repoId))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                if isDownloaded {
                    if !isActive {
                        Button("Use this model") {
                            Task { await manager.selectModel(repoId: option.repoId) }
                        }
                        .buttonStyle(.bordered)
                    }
                    Button(role: .destructive) {
                        Task { await manager.deleteModel(repoId: option.repoId) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(manager.isDownloading)
                } else {
                    Button {
                        Task { await manager.download(repoId: option.repoId) }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.isDownloading)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
