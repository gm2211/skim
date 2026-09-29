// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkimChatEval",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "skim-chat-eval", targets: ["skim-chat-eval"]),
        .library(name: "SkimChatEvalCore", targets: ["SkimChatEvalCore"])
    ],
    dependencies: [
        .package(path: "../../native/SkimCore"),
        .package(path: "../../shared/SkimInferencePolicy")
    ],
    targets: [
        .target(
            name: "SkimChatEvalCore",
            dependencies: [
                .product(name: "SkimCore", package: "SkimCore"),
                .product(name: "SkimInferencePolicy", package: "SkimInferencePolicy")
            ]
        ),
        .executableTarget(
            name: "skim-chat-eval",
            dependencies: ["SkimChatEvalCore"]
        ),
        .testTarget(
            name: "SkimChatEvalCoreTests",
            dependencies: ["SkimChatEvalCore"]
        )
    ]
)
