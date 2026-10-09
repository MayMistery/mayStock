import Foundation
import Testing
@testable import MayStockKit

@Suite("Reading the config file")
struct ConfigReadTests {
    private func directory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maystock-read-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A file that exists and cannot be read — here, a venue this build does
    /// not know, as a newer build would write — is kept beside itself and
    /// reported, never handed back as the defaults in silence: the next save
    /// would have written the defaults over it.
    @Test func anUnreadableFileIsKeptAndReported() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = #"{"schemaVersion":5,"watchlist":[{"id":"7C0A6E2A-0000-0000-0000-000000000000","venue":"hkex","instId":"00700"}]}"#
        try Data(original.utf8).write(to: dir.appendingPathComponent("config.json"))

        let (config, issue) = ConfigIO(directory: dir).read()
        let kept = try #require(issue?.keptAt)
        #expect(config == .default)
        #expect(try String(contentsOf: kept, encoding: .utf8) == original)
        #expect(ConfigIO(directory: dir).read().issue?.keptAt == kept, "read twice, kept once")
        let copies = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("unreadable") }
        #expect(copies.count == 1)
    }

    /// An empty watchlist restores the default one and keeps everything else;
    /// it used to throw away every other setting with it.
    @Test func anEmptyWatchlistKeepsTheRestOfTheConfig() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var saved = AppConfig.default
        saved.watchlist = []
        saved.alerts = [AlertRule(instId: "ETH-USDT-SWAP", condition: .priceAbove(3_000))]
        try ConfigIO(directory: dir).update { $0 = saved }

        let (config, issue) = ConfigIO(directory: dir).read()
        #expect(issue == nil)
        #expect(config.watchlist == AppConfig.default.watchlist)
        #expect(config.alerts.map(\.instId) == ["ETH-USDT-SWAP"])
    }

    @Test func noFileIsTheDefaultsWithNothingToReport() {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (config, issue) = ConfigIO(directory: dir).read()
        #expect(config == .default && issue == nil)
    }
}
