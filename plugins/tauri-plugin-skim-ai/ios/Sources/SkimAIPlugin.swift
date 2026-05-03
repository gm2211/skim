import SwiftRs
import Tauri
import UIKit
import WebKit

// MARK: - Command argument structs

class RepoIdArgs: Decodable {
    let repoId: String
}

class CompleteArgs: Decodable {
    let system: String
    let user: String
    let maxTokens: Int?
    let jsonMode: Bool?
}

class KeychainSetArgs: Decodable {
    let key: String
    let value: String
}

class KeychainKeyArgs: Decodable {
    let key: String
}

// MARK: - Plugin

class SkimAIPlugin: Plugin {

    // The hosting WKWebView, captured from load(webview:). We dispatch a
    // CustomEvent on `window` for download progress because the iOS Tauri
    // plugin Plugin.trigger only routes to JS Channels (not the global
    // event bus the Tauri JS `listen` uses).
    private var hostWebView: WKWebView?

    override func load(webview: WKWebView) {
        self.hostWebView = webview
    }

    private func emitMlxProgress(repoId: String, progress: Double) {
        guard let webview = hostWebView else { return }
        let payload = "{ repoId: '\(repoId)', percent: \(progress) }"
        let js = "window.dispatchEvent(new CustomEvent('skim-ai://mlx-download-progress', { detail: \(payload) }))"
        DispatchQueue.main.async {
            webview.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - MLX

    @objc public func mlxIsAvailable(_ invoke: Invoke) throws {
        // MLX needs Metal GPU. iOS Simulator's Metal stack lacks the MPS
        // operations MLX requires — running the model crashes the process.
        // Gate it off so the UI surfaces the limitation instead.
        #if targetEnvironment(simulator)
        invoke.resolve(false)
        #else
        invoke.resolve(true)
        #endif
    }

    @objc public func mlxIsModelDownloaded(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(RepoIdArgs.self)
        Task {
            let downloaded = await MLXRunner.shared.isModelDownloaded(repoId: args.repoId)
            invoke.resolve(downloaded)
        }
    }

    @objc public func mlxDownloadModel(_ invoke: Invoke) throws {
        #if targetEnvironment(simulator)
        invoke.reject("MLX is not available in the iOS Simulator (Metal backend unsupported). Run on a real iPhone with iOS 17+.")
        return
        #else
        let args = try invoke.parseArgs(RepoIdArgs.self)
        Task { [weak self] in
            await MLXRunner.shared.setProgressSink { [weak self] progress in
                self?.emitMlxProgress(repoId: args.repoId, progress: progress)
            }
            await MLXRunner.shared.setModel(repoId: args.repoId)
            do {
                _ = try await MLXRunner.shared.ensureLoaded()
                invoke.resolve()
            } catch {
                invoke.reject("MLX download failed: \(error.localizedDescription)")
            }
        }
        #endif
    }

    @objc public func mlxDeleteModel(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(RepoIdArgs.self)
        Task {
            do {
                try await MLXRunner.shared.deleteModel(repoId: args.repoId)
                invoke.resolve()
            } catch {
                invoke.reject("Delete failed: \(error.localizedDescription)")
            }
        }
    }

    @objc public func mlxComplete(_ invoke: Invoke) throws {
        #if targetEnvironment(simulator)
        invoke.reject("MLX is not available in the iOS Simulator. Run on a real iPhone with iOS 17+.")
        return
        #else
        let args = try invoke.parseArgs(CompleteArgs.self)
        Task {
            do {
                let text = try await MLXRunner.shared.complete(
                    systemPrompt: args.system,
                    userPrompt: args.user,
                    jsonMode: args.jsonMode ?? false,
                    maxTokens: args.maxTokens ?? 512
                )
                invoke.resolve(text)
            } catch {
                invoke.reject("MLX complete failed: \(error.localizedDescription)")
            }
        }
        #endif
    }

    // MARK: - Foundation Models

    @objc public func fmIsAvailable(_ invoke: Invoke) throws {
        Task {
            let available = await FoundationModelRunner.shared.isAvailable
            invoke.resolve(available)
        }
    }

    @objc public func fmAvailability(_ invoke: Invoke) throws {
        Task {
            let availability = await FoundationModelRunner.shared.availability
            invoke.resolve(availability.dictionary)
        }
    }

    @objc public func fmComplete(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(CompleteArgs.self)
        Task {
            do {
                let text = try await FoundationModelRunner.shared.complete(
                    systemPrompt: args.system,
                    userPrompt: args.user,
                    jsonMode: args.jsonMode ?? false,
                    maxTokens: args.maxTokens ?? 512
                )
                invoke.resolve(text)
            } catch {
                invoke.reject("FoundationModels complete failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - iOS Keychain bridge (for OAuth tokens that should not live in SQLite)

    @objc public func iosKeychainStore(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(KeychainSetArgs.self)
        KeychainStore.set(args.value, for: args.key)
        invoke.resolve()
    }

    @objc public func iosKeychainLoad(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(KeychainKeyArgs.self)
        let value: String? = KeychainStore.get(args.key)
        invoke.resolve(value)
    }

    @objc public func iosKeychainClear(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(KeychainKeyArgs.self)
        KeychainStore.set(nil, for: args.key)
        invoke.resolve()
    }
}

@_cdecl("init_plugin_skim_ai")
func initPlugin() -> Plugin {
    return SkimAIPlugin()
}
