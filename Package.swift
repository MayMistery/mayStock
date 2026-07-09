// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MayStock",
    platforms: [.macOS(.v15)],
    targets: [
        // Platform-independent market engine: models, OKX REST/WS clients,
        // candle merging, alert engine, trade bridge. Compiles on macOS & Linux.
        .target(
            name: "MayStockKit",
            path: "Sources/MayStockKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The macOS menu bar app.
        .executableTarget(
            name: "MayStock",
            dependencies: ["MayStockKit"],
            path: "Sources/MayStock",
            exclude: ["SupportingFiles", "Resources", "Features"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // End-to-end test driver / diagnostics CLI (runs anywhere).
        .executableTarget(
            name: "maystock-e2e",
            dependencies: ["MayStockKit"],
            path: "Sources/maystock-e2e",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MayStockKitTests",
            dependencies: ["MayStockKit"],
            path: "Tests/MayStockKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
