// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Skim",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "Skim", targets: ["Skim"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "9.0.0"),
    ],
    targets: [
        .target(
            name: "Skim",
            dependencies: ["FeedKit"],
            path: "Sources"
        ),
    ]
)
