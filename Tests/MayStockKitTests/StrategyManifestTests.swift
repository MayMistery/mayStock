import Foundation
import Testing
@testable import MayStockKit

@Suite("Strategy manifest")
struct StrategyManifestTests {

    private func decode(_ json: String) throws -> StrategyManifest {
        try JSONDecoder().decode(StrategyManifest.self, from: Data(json.utf8))
    }

    // MARK: Decoding

    @Test func decodesTheDocumentedShape() throws {
        let manifest = try decode("""
        {
          "schema": 1, "id": "ema-trend-btc", "name": "EMA 双均线趋势", "version": "1.0.0",
          "market": { "instId": "BTC-USDT", "instType": "SPOT", "bar": "1H" },
          "params": [
            { "name": "fast", "default": 12, "min": 2, "max": 100, "label": "快线周期" },
            { "name": "slow", "default": 26 }
          ],
          "signals": {
            "longEntry": "ema(close, fast) crosses_above ema(close, slow)",
            "longExit": "ema(close, fast) crosses_below ema(close, slow)"
          },
          "sizing": { "mode": "equityPct", "value": 100 },
          "risk": { "stopLossPct": 4, "leverage": 1, "cooldownBars": 1, "minHoldBars": 0 }
        }
        """)
        let compiled = try manifest.compile()
        #expect(compiled.name == "EMA 双均线趋势")
        #expect(compiled.market.bar == .h1)
        #expect(compiled.parameterValues["fast"] == 12)
        #expect(compiled.canGoLong && !compiled.canGoShort)
        // Declaration order is preserved so the UI does not shuffle sliders.
        #expect(manifest.params.items.map(\.name) == ["fast", "slow"])
    }

    @Test func acceptsTheMapShapeForParams() throws {
        let manifest = try decode("""
        {
          "name": "Map params",
          "market": { "instId": "BTC-USDT", "instType": "SPOT", "bar": "1H" },
          "params": { "fast": { "default": 5 }, "slow": 20 },
          "signals": { "longEntry": "ema(close, fast) crosses_above ema(close, slow)" }
        }
        """)
        #expect(manifest.params["fast"] == 5)
        #expect(manifest.params["slow"] == 20)
        _ = try manifest.compile()
    }

    @Test func derivesAnIdWhenOmitted() throws {
        let manifest = try decode("""
        { "name": "My Strategy",
          "market": { "instId": "BTC-USDT", "instType": "SPOT", "bar": "1D" },
          "signals": { "longEntry": "close > 1" } }
        """)
        #expect(manifest.id == "my-strategy")
    }

    @Test func encodingRoundTrips() throws {
        let original = StrategyLibrary.emaTrend
        let decoded = try JSONDecoder().decode(StrategyManifest.self, from: original.encoded())
        #expect(decoded == original)
    }

    @Test func missingRequiredFieldsGiveAReadableError() {
        #expect(throws: (any Error).self) {
            _ = try self.decode(#"{ "name": "no market", "signals": { "longEntry": "close > 1" } }"#)
        }
    }

    // MARK: Validation

    @Test func shortingRequiresASwapMarket() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.signals.shortEntry = "close < sma(close, 20)"
        #expect(throws: StrategyManifestError.shortingRequiresSwap) {
            _ = try manifest.compile()
        }
    }

    @Test func leverageRequiresASwapMarket() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.risk.leverage = 3
        #expect(throws: StrategyManifestError.leverageRequiresSwap(3)) {
            _ = try manifest.compile()
        }
    }

    @Test func absurdLeverageIsRefused() throws {
        var manifest = StrategyLibrary.donchianBreakout
        manifest.risk.leverage = 500
        #expect(throws: StrategyManifestError.leverageOutOfRange(500)) {
            _ = try manifest.compile()
        }
    }

    @Test func undeclaredIdentifiersAreCaughtAtImport() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.signals.longEntry = "ema(close, undeclared) > 0"
        #expect(throws: StrategyManifestError.self) {
            _ = try manifest.compile()
        }
    }

    @Test func badExpressionsAreCaughtAtImport() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.signals.longExit = "ema(close, ) >"
        #expect(throws: StrategyManifestError.self) {
            _ = try manifest.compile()
        }
    }

    @Test func aStrategyNeedsAtLeastOneEntry() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.signals = StrategySignals(longEntry: nil, longExit: "close < 1")
        #expect(throws: StrategyManifestError.noEntrySignal) {
            _ = try manifest.compile()
        }
    }

    @Test func riskPerTradeSizingDemandsAStop() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.sizing = StrategySizing(mode: .riskPerTrade, value: 1)
        manifest.risk = StrategyRisk()      // no stop of any kind
        #expect(throws: StrategyManifestError.riskPerTradeNeedsStop) {
            _ = try manifest.compile()
        }
    }

    @Test func equityPercentCannotExceedOneHundred() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.sizing = StrategySizing(mode: .equityPct, value: 400)
        #expect(throws: StrategyManifestError.self) {
            _ = try manifest.compile()
        }
    }

    @Test func parameterDefaultsMustSitInsideTheirRange() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.params = StrategyParameterSet([
            StrategyParameter(name: "fast", value: 500, minimum: 2, maximum: 100),
        ])
        #expect(throws: StrategyManifestError.self) {
            _ = try manifest.compile()
        }
    }

    @Test func futureSchemaVersionsAreRejectedNotGuessedAt() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.schema = 99
        #expect(throws: StrategyManifestError.unsupportedSchema(99)) {
            _ = try manifest.compile()
        }
    }

    // MARK: Costs & defaults

    @Test func costDefaultsFollowTheInstrumentType() {
        #expect(StrategyLibrary.emaTrend.effectiveCosts.feeBps == 10)          // spot taker
        #expect(StrategyLibrary.donchianBreakout.effectiveCosts.feeBps == 5)   // swap taker
    }

    @Test func parameterClampingHonoursDeclaredBounds() {
        var set = StrategyParameterSet([
            StrategyParameter(name: "fast", value: 12, minimum: 2, maximum: 100),
        ])
        set.setValue(500, for: "fast")
        #expect(set["fast"] == 100)
        set.setValue(-5, for: "fast")
        #expect(set["fast"] == 2)
    }

    // MARK: Library

    @Test func everyBuiltInPresetCompiles() throws {
        for preset in StrategyLibrary.presets {
            #expect(throws: Never.self, "preset \(preset.id) must compile") {
                _ = try preset.compile()
            }
        }
        #expect(StrategyLibrary.compiledPresets.count == StrategyLibrary.presets.count)
    }

    @Test func presetIdsAreUnique() {
        let ids = StrategyLibrary.presets.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func theOnlyShortingPresetIsASwap() throws {
        for preset in StrategyLibrary.presets where preset.signals.shortEntry != nil {
            #expect(preset.market.instType == .swap)
        }
    }

    @Test func presetsProduceRunnableSignalsOnRealisticData() throws {
        // Uptrend with regular pullbacks: 80 bars up, 20 bars down. Deep enough
        // to flip the fast EMA under the slow one, shallow enough to stay above
        // the 200-bar trend filter — the regime the preset is written for. If
        // this stops trading, a preset has quietly died.
        var price = 100.0
        var closes: [Double] = []
        for index in 0..<800 {
            price += (index % 100) < 80 ? 0.6 : -1.0
            closes.append(price)
        }
        let candles = CandleFixture.make(closes.map {
            (open: $0, high: $0 * 1.002, low: $0 * 0.998, close: $0)
        })
        let compiled = try StrategyLibrary.emaTrend.compile()
        let result = try BacktestEngine(strategy: compiled).run(candles: candles)
        #expect(!result.trades.isEmpty)
    }

    @Test func paramsMayMixBareNumbersAndFullSpecs() throws {
        let manifest = try decode("""
        {
          "name": "Mixed params",
          "market": { "instId": "BTC-USDT", "instType": "SPOT", "bar": "1H" },
          "params": { "fast": 12, "slow": { "default": 26, "min": 5, "max": 400 } },
          "signals": { "longEntry": "ema(close, fast) crosses_above ema(close, slow)" }
        }
        """)
        #expect(manifest.params["fast"] == 12)
        #expect(manifest.params["slow"] == 26)
        _ = try manifest.compile()
    }
}

// MARK: - Store

@Suite("Strategy store")
struct StrategyStoreTests {
    private func tempStore() -> StrategyStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-strategies-\(UUID().uuidString)")
        return StrategyStore(directory: dir)
    }

    @Test func savesAndReloads() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(StrategyLibrary.emaTrend)
        #expect(store.load().count == 1)
        #expect(store.loadCompiled().ready.first?.id == "ema-trend")
    }

    @Test func importRejectsAManifestThatDoesNotCompile() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-\(UUID().uuidString).json")
        try Data("""
        { "name": "Broken",
          "market": { "instId": "BTC-USDT", "instType": "SPOT", "bar": "1H" },
          "signals": { "longEntry": "nonsense(close, 3) > 0" } }
        """.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) { _ = try store.importManifest(from: url) }
        #expect(store.load().isEmpty, "a rejected import must not land in the library")
    }

    @Test func importDeduplicatesIds() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preset-\(UUID().uuidString).json")
        try StrategyLibrary.emaTrend.encoded().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try store.importManifest(from: url, existing: [])
        let second = try store.importManifest(from: url, existing: [first])
        #expect(first.id == "ema-trend")
        #expect(second.id == "ema-trend-2")
        #expect(store.load().count == 2)
    }

    @Test func presetsSeedAnEmptyLibraryOnce() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(store.installPresetsIfEmpty().count == StrategyLibrary.presets.count)
        #expect(store.installPresetsIfEmpty().isEmpty, "seeding must not duplicate")
    }

    @Test func brokenManifestsAreReportedNotSilentlyDropped() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        var broken = StrategyLibrary.emaTrend
        broken.id = "broken"
        broken.risk.leverage = 5    // illegal on spot
        try broken.encoded().write(to: store.directory.appendingPathComponent("broken.json"))

        let loaded = store.loadCompiled()
        #expect(loaded.ready.isEmpty)
        #expect(loaded.broken.count == 1)
        #expect(loaded.broken.first?.1.contains("杠杆") == true)
    }
}

// MARK: - Config migration

@Suite("Strategy config migration")
struct StrategyConfigTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-cfg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func v2ConfigsKeepTheirWatchlistAndGainStrategyDefaults() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A 2.0 config: no `strategy` key, and the removed `defaultQuoteSize`.
        let v2 = """
        {"schemaVersion":2,
         "watchlist":[{"id":"7C0A6E2A-0000-0000-0000-000000000000","instId":"ETH-USDT",
                       "enabled":true,"style":"full","sparklineMinutes":60,"defaultBar":"1m"}],
         "alerts":[],
         "trading":{"enabled":true,"liveTradingUnlocked":false,"defaultQuoteSize":250},
         "general":{"launchAtLogin":false,"hoverDelayMs":150,"hideDelayMs":350}}
        """
        try Data(v2.utf8).write(to: dir.appendingPathComponent("config.json"))

        let loaded = ConfigIO(directory: dir).load()
        #expect(loaded.watchlist.first?.instId == "ETH-USDT", "an upgrade must not lose the watchlist")
        #expect(loaded.schemaVersion == AppConfig.currentSchemaVersion)
        #expect(loaded.strategy.mode == .demo)
        #expect(loaded.strategy.allocations.isEmpty)
    }

    @Test func strategyPrefsRoundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = AppConfig.default
        config.strategy.totalCapital = 5_000
        config.strategy.setCapital(2_000, for: "ema-trend")
        config.strategy.setRunning(true, for: "ema-trend")
        try ConfigIO(directory: dir).save(config)

        let loaded = ConfigIO(directory: dir).load()
        #expect(loaded.strategy.allocation(for: "ema-trend")?.capital == 2_000)
        #expect(loaded.strategy.allocation(for: "ema-trend")?.running == true)
    }
}
