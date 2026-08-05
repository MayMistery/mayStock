// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MayStock",
    platforms: [.macOS(.v15)],
    targets: [
        // C ABI of the Rust trading kernel (see kernel/). Build it first with
        // `Scripts/build-kernel.sh`; SwiftPM cannot run cargo itself.
        .target(
            name: "CMayStockKernel",
            path: "Sources/CMayStockKernel",
            linkerSettings: [
                // unsafeFlags is acceptable here because MayStock is a leaf
                // application, never consumed as a package dependency.
                .unsafeFlags(["-L", ".build/kernel", "-lmaystock_kernel"]),
            ]
        ),
        // Platform-independent market engine: models, OKX REST/WS clients,
        // candle merging, alert engine, trade bridge. Compiles on macOS & Linux.
        .target(
            name: "MayStockKit",
            dependencies: ["CMayStockKernel"],
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
        // Strategy research bench: backtest, optimise, walk-forward, portfolio.
        .executableTarget(
            name: "maystock-lab",
            dependencies: ["MayStockKit"],
            path: "Sources/maystock-lab",
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
