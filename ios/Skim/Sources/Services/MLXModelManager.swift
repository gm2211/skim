import Foundation
import SwiftUI

/// A single selectable on-device model.
struct MLXModelOption: Identifiable, Hashable {
    /// Hugging Face repo id (matches what MLX's `ModelConfiguration` uses).
    let repoId: String
    /// Human-friendly name shown in Settings.
    let displayName: String
    /// Approximate on-disk size after quantization.
    let sizeGB: Double
    /// Short description / trade-off note.
    let note: String

    var id: String { repoId }
}

/// Drives the Settings "Manage models" screen: list options, trigger downloads,
/// delete cached weights, report progress, and pick which model `MLXRunner` uses.
@MainActor
final class MLXModelManager: ObservableObject {
    static let shared = MLXModelManager()

    @Published var downloadProgress: Double?
    @Published var isDownloading: Bool = false
    @Published var lastError: String?
    @Published var activeRepoId: String = MLXRunner.defaultRepoId

    /// Set of repo ids currently present on disk.
    @Published var downloadedRepoIds: Set<String> = []

    private init() {
        refreshDownloadedState()
    }

    // MARK: - Catalog

    func availableModels() -> [MLXModelOption] {
        [
            MLXModelOption(
                repoId: "mlx-community/Qwen2.5-3B-Instruct-4bit",
                displayName: "Qwen 2.5 3B Instruct (default)",
                sizeGB: 1.9,
                note: "Recommended. Strong JSON output, good reasoning at 3B."
            ),
            MLXModelOption(
                repoId: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                displayName: "Llama 3.2 3B Instruct",
                sizeGB: 2.0,
                note: "Meta's 3B. Conversational; slightly weaker structured output."
            ),
            MLXModelOption(
                repoId: "mlx-community/Phi-3.5-mini-instruct-4bit",
                displayName: "Phi-3.5 Mini Instruct",
                sizeGB: 2.3,
                note: "Microsoft's 3.8B. Strong on reasoning; larger on disk."
            )
        ]
    }

    // MARK: - State

    func refreshDownloadedState() {
        let present = availableModels()
            .filter { MLXRunner.isRepoDownloaded($0.repoId) }
            .map(\.repoId)
        self.downloadedRepoIds = Set(present)
        Task {
            let repo = await MLXRunner.shared.activeRepoId()
            await MainActor.run { self.activeRepoId = repo }
        }
    }

    // MARK: - Actions

    /// Download the default model (Qwen 2.5 3B). Convenience wrapper.
    func downloadDefaultModel() async {
        await download(repoId: MLXRunner.defaultRepoId)
    }

    /// Trigger a download (or load) for the given repo. Progress is surfaced on
    /// `downloadProgress` in 0...1 range.
    func download(repoId: String) async {
        guard !isDownloading else { return }
        self.isDownloading = true
        self.downloadProgress = 0
        self.lastError = nil

        // Install a progress sink that hops to MainActor.
        await MLXRunner.shared.setProgressSink { fraction in
            Task { @MainActor in
                MLXModelManager.shared.downloadProgress = fraction
            }
        }

        // Switch to the selected repo before loading.
        await MLXRunner.shared.setModel(repoId: repoId)

        do {
            _ = try await MLXRunner.shared.ensureLoaded()
        } catch {
            self.lastError = (error as NSError).localizedDescription
        }

        await MLXRunner.shared.setProgressSink(nil)
        self.isDownloading = false
        self.downloadProgress = nil
        refreshDownloadedState()
        ModelRouter.shared.mlxModelAvailable = !self.downloadedRepoIds.isEmpty
    }

    /// Remove cached weights for a given repo. If the active runner was holding it,
    /// evict first so files aren't mmapped.
    func deleteModel(repoId: String) async {
        await MLXRunner.shared.evict()

        let dir = MLXRunner.cacheDirectory(forRepo: repoId)
        do {
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
        } catch {
            self.lastError = "Delete failed: \(error.localizedDescription)"
        }

        refreshDownloadedState()
        ModelRouter.shared.mlxModelAvailable = !self.downloadedRepoIds.isEmpty
    }

    /// Delete all cached on-device models. Convenience wrapper.
    func deleteAll() async {
        for option in availableModels() {
            await deleteModel(repoId: option.repoId)
        }
    }

    /// Set which model `MLXRunner` will use for inference.
    func selectModel(repoId: String) async {
        await MLXRunner.shared.setModel(repoId: repoId)
        self.activeRepoId = repoId
    }
}
