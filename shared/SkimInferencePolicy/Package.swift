// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkimInferencePolicy",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SkimInferencePolicy", targets: ["SkimInferencePolicy"])],
    targets: [
        .target(name: "SkimInferencePolicy"),
        .testTarget(name: "SkimInferencePolicyTests", dependencies: ["SkimInferencePolicy"])
    ]
)
