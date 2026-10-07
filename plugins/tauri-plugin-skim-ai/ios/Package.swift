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
    // Pins MLX, the LLM library and the tokenizer for every Skim target.
    .package(path: "../../../shared/SkimMLXEngine"),
]
if !macBridgeOnly { dependencies.append(.package(name: "Tauri", path: "../.tauri/tauri-api")) }

var targets: [Target] = [
    .executableTarget(
        name: "SkimAIMacBridge",
        dependencies: [
            .product(name: "SkimInferencePolicy", package: "SkimInferencePolicy"),
            .product(name: "SkimMLXEngine", package: "SkimMLXEngine"),
        ],
        path: "MacBridge"),
]
if !macBridgeOnly {
    targets.append(.target(name: "tauri-plugin-skim-ai", dependencies: [.byName(name: "Tauri"), .product(name: "SkimInferencePolicy", package: "SkimInferencePolicy"), .product(name: "SkimMLXEngine", package: "SkimMLXEngine")], path: "Sources"))
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
