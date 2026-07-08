// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MayStock",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MayStock",
            path: "Sources/MayStock",
            exclude: ["SupportingFiles"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MayStockTests",
            dependencies: ["MayStock"],
            path: "Tests/MayStockTests"
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["MayStock"],
            path: "Tests/IntegrationTests"
        ),
    ]
)
