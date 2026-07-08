// ConfigurationService Tests
// Full tests use Swift Testing framework (requires Xcode).
// This file verifies compilation and basic correctness using assertions.

import Foundation
@testable import MayStock

@MainActor
enum ConfigurationServiceTests {
    static func runAll() throws {
        try testLoadsDefaultConfigWhenNoFileExists()
        try testSavesAndReloadsConfig()
        try testHandlesCorruptedConfigGracefully()
    }

    static func testLoadsDefaultConfigWhenNoFileExists() throws {
        let tempDir = makeTempDir()
        let service = ConfigurationService(directory: tempDir)
        let items = service.monitorItems
        assert(items.count == 4, "Expected 4 default items, got \(items.count)")
        assert(items[0].type == .crypto, "Expected first item to be crypto")
        assert(items[0].label == "BTC", "Expected first item label to be BTC")
        cleanup(tempDir)
    }

    static func testSavesAndReloadsConfig() throws {
        let tempDir = makeTempDir()
        let service = ConfigurationService(directory: tempDir)
        service.monitorItems[0].label = "Bitcoin"
        try service.save()

        let service2 = ConfigurationService(directory: tempDir)
        assert(service2.monitorItems[0].label == "Bitcoin", "Expected reloaded label to be Bitcoin")
        cleanup(tempDir)
    }

    static func testHandlesCorruptedConfigGracefully() throws {
        let tempDir = makeTempDir()
        let configFile = tempDir.appendingPathComponent("config.json")
        try "{{invalid json".write(to: configFile, atomically: true, encoding: .utf8)

        let service = ConfigurationService(directory: tempDir)
        assert(service.monitorItems.count == 4, "Expected 4 default items after corruption")
        cleanup(tempDir)
    }

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MayStockTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
