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

    // MARK: - MLX

    @objc public func mlxIsAvailable(_ invoke: Invoke) throws {
        // MLX runs wherever Metal is available — all modern iOS/macOS.
        // Concrete readiness depends on model download, checked separately.
        invoke.resolve(true)
    }

    @objc public func mlxIsModelDownloaded(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(RepoIdArgs.self)
        Task {
            let downloaded = await MLXRunner.shared.isModelDownloaded(repoId: args.repoId)
            invoke.resolve(downloaded)
        }
    }

    @objc public func mlxDownloadModel(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(RepoIdArgs.self)
        let webview = self.webviewWindow
        Task {
            await MLXRunner.shared.setProgressSink { progress in
                let payload: [String: Any] = ["repoId": args.repoId, "progress": progress]
                try? webview?.emitJS(event: "skim-ai://mlx-download-progress", payload: payload)
            }
            await MLXRunner.shared.setModel(repoId: args.repoId)
            do {
                _ = try await MLXRunner.shared.ensureLoaded()
                invoke.resolve()
            } catch {
                invoke.reject("MLX download failed: \(error.localizedDescription)")
            }
        }
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
    }

    // MARK: - Foundation Models

    @objc public func fmIsAvailable(_ invoke: Invoke) throws {
        Task {
            let available = await FoundationModelRunner.shared.isAvailable
            invoke.resolve(available)
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
        if let value = KeychainStore.get(args.key) {
            invoke.resolve(value)
        } else {
            invoke.resolve(NSNull())
        }
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
