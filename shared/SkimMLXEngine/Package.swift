// swift-tools-version: 6.0
import PackageDescription

// The MLX inference core shared by the iOS app, the macOS AI helper and the
// Tauri iOS plugin, so the library-facing code (downloading, loading,
// generation, article prefix reuse) lives in exactly one place.
let package = Package(
    name: "SkimMLXEngine",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SkimMLXEngine", targets: ["SkimMLXEngine"])],
    dependencies: [
        .package(path: "../SkimInferencePolicy"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.3.4")),
    ],
    targets: [
        .target(
            name: "SkimMLXEngine",
            dependencies: [
                .product(name: "SkimInferencePolicy", package: "SkimInferencePolicy"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
