// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SkimCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "SkimCore", targets: ["SkimCore"])
    ],
    targets: [
        .target(
            name: "SkimCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "SkimCoreTests",
            dependencies: ["SkimCore"]
        )
    ]
)
