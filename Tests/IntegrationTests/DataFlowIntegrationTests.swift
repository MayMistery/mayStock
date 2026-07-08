import Foundation
@testable import MayStock

/// Integration tests for data flow through the system.
/// Tests MarketDataProvider, system monitors, and configuration persistence.
@MainActor
enum DataFlowIntegrationTests {
    static func runAll() async throws {
        try await testMarketDataProviderReceivesAndStoresTicks()
        try await testSystemMonitorsProduceValidData()
        try await testConfigurationPersistsAcrossServiceInstances()
    }

    static func testMarketDataProviderReceivesAndStoresTicks() async throws {
        let provider = MarketDataProvider()
        provider.start(instId: "BTC-USDT", candleChannel: "candle1s")

        for _ in 0..<100 {
            if provider.currentPrice > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        assert(provider.currentPrice > 0, "Should have a non-zero price")
        assert(!provider.ticks.isEmpty, "Should have accumulated ticks")
        provider.stop()
    }

    static func testSystemMonitorsProduceValidData() async throws {
        let cpu = CPUMonitor()
        let memory = MemoryMonitor()
        let network = NetworkMonitor()

        cpu.sample()
        memory.sample()
        network.sample()

        try await Task.sleep(for: .milliseconds(500))

        cpu.sample()
        network.sample()

        assert(cpu.currentUsage >= 0, "CPU usage should be non-negative")
        assert(memory.usedBytes > 0, "Used memory should be positive")
        assert(memory.totalBytes > 0, "Total memory should be positive")
        assert(network.bytesInPerSecond >= 0, "Network bytes in should be non-negative")
    }

    static func testConfigurationPersistsAcrossServiceInstances() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MayStock-Integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let service1 = ConfigurationService(directory: tempDir)
        service1.monitorItems[0].label = "BITCOIN"
        try service1.save()

        let service2 = ConfigurationService(directory: tempDir)
        assert(service2.monitorItems[0].label == "BITCOIN",
               "Expected reloaded label to be BITCOIN, got \(service2.monitorItems[0].label)")

        try FileManager.default.removeItem(at: tempDir)
    }
}
