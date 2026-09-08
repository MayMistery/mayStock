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

    @Test func shortingIsRefusedWhereTheTypeCannotShort() throws {
        var manifest = StrategyLibrary.emaTrend   // spot
        manifest.signals.shortEntry = "close < sma(close, 20)"
        #expect(throws: StrategyManifestError.shortingNotAllowed(.spot)) {
            _ = try manifest.compile()
        }
    }

    @Test func leverageIsRefusedWhereTheTypeCannotBorrow() throws {
        var manifest = StrategyLibrary.emaTrend   // spot
        manifest.risk.leverage = 3
        #expect(throws: StrategyManifestError.leverageNotAllowed(.spot, 3)) {
            _ = try manifest.compile()
        }
    }

    @Test func absurdLeverageIsRefused() throws {
        var manifest = StrategyLibrary.donchianBreakout   // swap
        manifest.risk.leverage = 500
        #expect(throws: StrategyManifestError.leverageOutOfRange(
            500, max: InstrumentType.swap.maxLeverage)) {
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
        let schedules = FeeSchedules()
        #expect(StrategyLibrary.emaTrend.effectiveCosts(under: schedules)?.feeBps == 10)          // spot taker
        #expect(StrategyLibrary.donchianBreakout.effectiveCosts(under: schedules)?.feeBps == 5)   // swap taker
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

    /// An emptied library must stay empty: the app reloads the library on every
    /// import, delete and launch, and re-seeding there would undo "remove every
    /// strategy" the next time the app started.
    @Test func anEmptiedLibraryIsNotReseeded() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(store.seedPresetsOnFirstRun().count == StrategyLibrary.presets.count)

        for manifest in store.load() { try store.delete(id: manifest.id) }
        #expect(store.load().isEmpty)
        #expect(store.seedPresetsOnFirstRun().isEmpty, "an emptied library must stay empty")
        #expect(store.load().isEmpty)

        // The explicit restore is still how the examples come back.
        #expect(store.installPresetsIfEmpty().count == StrategyLibrary.presets.count)
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
        #expect(loaded.broken.first?.reason.contains("杠杆") == true)
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

/// Guards written against the *vocabulary* rather than against today's two
/// cases: adding a third instrument type has to fail here on the day it is
/// added, not on the day its multiplier is quietly wrong in the book.
@Suite("Instrument type vocabulary")
struct InstrumentTypeVocabularyTests {

    /// One sample id per (venue, type) the venue trades. A new venue or a new
    /// type with no sample fails the require below, which is the point — the
    /// table is the checklist.
    private static let sampleIds: [Venue: [InstrumentType: String]] = [
        .okx: [.spot: "BTC-USDT", .swap: "BTC-USDT-SWAP", .option: "BTC-USD-260926-80000-C"],
        .schwab: [.stock: "AAPL"],
    ]

    @Test func everyVenueRecognisesEachOfItsTypesFromAnId() throws {
        for venue in Venue.allCases {
            let samples = try #require(Self.sampleIds[venue], "\(venue) 缺少样本表")
            for type in venue.instrumentTypes {
                let id = try #require(samples[type], "\(venue) 的 \(type) 缺少样本 instId")
                #expect(venue.instrumentType(of: id) == type)
                let (base, quote) = venue.currencies(of: id)
                #expect(!base.isEmpty, "\(venue) \(type)")
                // An option names its settlement index (BTC-USD) rather than
                // the book's currency; every other family is quoted in the
                // currency the account settles in.
                #expect(type == .option || quote == venue.quoteCurrency,
                        "\(venue) \(type) 的计价币读成了 \(quote)")
            }
        }
    }

    /// A type nobody trades is a declaration with no venue behind it — a
    /// manifest could name it and no account could ever fill it.
    @Test func everyTypeTradesSomewhere() {
        for type in InstrumentType.allCases {
            #expect(Venue.allCases.contains { $0.trades(type) }, "\(type) 没有任何交易所交易它")
        }
    }

    /// A multiplier may only be implied where it cannot be anything else.
    /// Anything that trades in contracts has to ask the exchange, and "we could
    /// not ask" must stay distinguishable from "the answer is 1".
    @Test func onlyContractTradedTypesWithholdTheirContractSize() {
        for type in InstrumentType.allCases {
            if type.tradesInContracts {
                #expect(type.impliedContractSize == nil, "\(type) 不该自带面值")
            } else {
                #expect(type.impliedContractSize == 1, "\(type) 的面值应恒为 1")
            }
        }
    }

    @Test func aPositionAdmitsWhenItsMultiplierIsNotAFact() throws {
        for venue in Venue.allCases {
            for type in venue.instrumentTypes {
                let id = try #require(Self.sampleIds[venue]?[type])
                let untaught = StrategyPositionState(strategyId: "s", instId: id, venue: venue)
                #expect(untaught.contractSizeIsKnown == (type.impliedContractSize != nil))

                var taught = untaught
                taught.contractSize = 0.01
                #expect(taught.contractSizeIsKnown)
                #expect(taught.multiplier == 0.01)
            }
        }
    }
}

// MARK: - Option manifests

@Suite("期权策略清单")
struct OptionManifestTests {
    private func decode(_ json: String) throws -> StrategyManifest {
        try JSONDecoder().decode(StrategyManifest.self, from: Data(json.utf8))
    }

    private let json = """
    {
      "schema": 1, "id": "opt", "name": "Option trend",
      "market": { "instId": "BTC-USDT", "instType": "OPTION", "bar": "4H" },
      "signals": {
        "longEntry": "close > sma(close, 20)", "longExit": "close < sma(close, 20)",
        "shortEntry": "close < sma(close, 20)", "shortExit": "close > sma(close, 20)"
      },
      "sizing": { "mode": "equityPct", "value": 10 },
      "risk": { "stopLossPct": 50, "takeProfitPct": 150, "volLookbackBars": 30 },
      "options": { "minDaysToExpiry": 14, "moneynessPct": 2 }
    }
    """

    @Test("期权清单能解码、编译，并推导标的指数")
    func decodesAndCompiles() throws {
        let manifest = try decode(json)
        let compiled = try manifest.compile()
        #expect(compiled.isOptionStrategy)
        #expect(compiled.canGoShort, "a put is a legitimate bearish view")
        #expect(compiled.optionsSpec.minDaysToExpiry == 14)
        #expect(compiled.optionsSpec.moneynessPct == 2)
        #expect(compiled.optionsSpec.resolvedUnderlying(for: manifest.market) == "BTC-USD")
        #expect(compiled.warmupBars >= 31, "the pricing model needs its volatility window primed")
        // Round-trips with the block intact.
        let again = try JSONDecoder().decode(StrategyManifest.self, from: manifest.encoded())
        #expect(again == manifest)
    }

    @Test("options 块省略时全部取默认")
    func theBlockDefaults() throws {
        let stripped = json.replacingOccurrences(
            of: #""options": { "minDaysToExpiry": 14, "moneynessPct": 2 }"#, with: #""options": null"#)
        let compiled = try decode(stripped).compile()
        #expect(compiled.optionsSpec == StrategyOptionsSpec())
        #expect(compiled.optionsSpec.minDaysToExpiry == 7)
    }

    @Test("现货清单带 options 块会被拒绝")
    func anOptionsBlockOnSpotIsRefused() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.options = StrategyOptionsSpec(moneynessPct: 5)
        #expect(throws: StrategyManifestError.self) { _ = try manifest.compile() }
    }

    @Test("期权策略拒绝引擎做不到的东西，且说出来的是策略的话不是表达式的话")
    func unsupportedRiskRulesAreRefusedWithTheirOwnWording() throws {
        var manifest = try decode(json)
        manifest.risk.trailingStopPct = 5
        do {
            _ = try manifest.compile()
            Issue.record("a trailing stop must be refused on an option strategy")
        } catch let error as StrategyManifestError {
            guard case .rejectedByKernel(let reason) = error else {
                Issue.record("expected the kernel's own verdict, got \(error)"); return
            }
            #expect(reason.contains("trailingStopPct"))
            #expect(!error.description.hasPrefix("signals"))
        }
    }

    @Test("单笔风险模式在期权上不需要止损：权利金就是风险")
    func riskPerTradeNeedsNoStopOnOptions() throws {
        var manifest = try decode(json)
        manifest.sizing = StrategySizing(mode: .riskPerTrade, value: 2)
        manifest.risk = StrategyRisk(volLookbackBars: 30)
        _ = try manifest.compile()
    }

    @Test("从 instId 认出期权、永续和现货")
    func instrumentFamiliesAreReadOffTheId() {
        #expect(Venue.okx.instrumentType(of: "BTC-USD-260926-80000-C") == .option)
        #expect(Venue.okx.instrumentType(of: "ETH-USD-261225-3000-P") == .option)
        #expect(Venue.okx.instrumentType(of: "BTC-USDT-SWAP") == .swap)
        #expect(Venue.okx.instrumentType(of: "BTC-USDT") == .spot)
        // A dated future is not an option, and neither is a typo.
        #expect(Venue.okx.instrumentType(of: "BTC-USD-260926") == .spot)
        #expect(Venue.okx.instrumentType(of: "BTC-USD-260926-80000-X") == .spot)
        #expect(Venue.okx.optionKind(of: "BTC-USD-260926-80000-C") == .call)
        #expect(Venue.okx.optionKind(of: "BTC-USD-260926-80000-P") == .put)
        #expect(Venue.okx.optionUnderlying(of: "BTC-USD-260926-80000-C") == "BTC-USD")
        #expect(Venue.okx.optionUnderlying(of: "BTC-USDT") == nil)
        // An option id means nothing on a venue that lists no options: it is
        // a ticker like any other, not a contract spelled the OKX way.
        #expect(Venue.schwab.instrumentType(of: "BTC-USD-260926-80000-C") == .stock)
        #expect(Venue.schwab.optionKind(of: "BTC-USD-260926-80000-C") == nil)
    }

    /// Every family declares its own behaviour; nothing may fall through to
    /// "whatever spot does" by accident.
    @Test("每个品种家族都声明了自己的行为")
    func everyFamilyDeclaresItself() {
        for family in InstrumentType.allCases {
            #expect(!family.displayName.isEmpty)
            // OKX has a CLI module for exactly the families it lists.
            #expect((family.cliModule != nil) == Venue.okx.trades(family), "\(family)")
            #expect(family.tradesInContracts == (family.impliedContractSize == nil),
                    "\(family): a contract multiplier is known without asking only in base units")
            #expect(!family.usesPositionSide || family.isDerivative)
            #expect(!family.settlesFunding || family.isDerivative)
        }
        #expect(InstrumentType.option.isDerivative)
        #expect(!InstrumentType.option.usesPositionSide)
        #expect(!InstrumentType.option.settlesFunding)
        #expect(InstrumentType.option.allowsShorting && !InstrumentType.option.allowsLeverage)
    }

    @Test("内置示例里的期权清单能编译")
    func theShippedOptionExampleCompiles() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Strategies/examples/12-btc-options-trend.json")
        let manifest = try StrategyManifest.load(from: url)
        let compiled = try manifest.compile()
        #expect(compiled.isOptionStrategy)
        #expect(compiled.optionsSpec.resolvedUnderlying(for: manifest.market) == "BTC-USD")
    }
}
