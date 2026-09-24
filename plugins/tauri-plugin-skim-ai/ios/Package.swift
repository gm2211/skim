// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let macBridgeOnly = ProcessInfo.processInfo.environment["SKIM_AI_MAC_BRIDGE_ONLY"] == "1"

var products: [Product] = [
    .executable(name: "skim-ai-macos-bridge", targets: ["SkimAIMacBridge"]),
]
if !macBridgeOnly {
    products.append(.library(name: "tauri-plugin-skim-ai", type: .static, targets: ["tauri-plugin-skim-ai"]))
}

var dependencies: [Package.Dependency] = [
    .package(path: "../../../shared/SkimInferencePolicy"),
    .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.18.0"),
    .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", from: "2.21.0"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"),
]
if !macBridgeOnly { dependencies.append(.package(name: "Tauri", path: "../.tauri/tauri-api")) }

var targets: [Target] = [
    .executableTarget(
        name: "SkimAIMacBridge",
        dependencies: [
            .product(name: "SkimInferencePolicy", package: "SkimInferencePolicy"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            .product(name: "MLXLLM", package: "mlx-swift-examples"),
            .product(name: "Hub", package: "swift-transformers"),
        ],
        path: "MacBridge"),
]
if !macBridgeOnly {
    targets.append(.target(name: "tauri-plugin-skim-ai", dependencies: [.byName(name: "Tauri"), .product(name: "SkimInferencePolicy", package: "SkimInferencePolicy"), .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXLMCommon", package: "mlx-swift-examples"), .product(name: "MLXLLM", package: "mlx-swift-examples"), .product(name: "Hub", package: "swift-transformers")], path: "Sources"))
}

let package = Package(
    name: "tauri-plugin-skim-ai",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
