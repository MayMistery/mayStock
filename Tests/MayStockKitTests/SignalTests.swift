import Foundation
import Testing
@testable import MayStockKit

// MARK: - Alignment

@Suite("Alternative data alignment")
struct SeriesAlignerTests {
    private func candles(_ count: Int, spacing: TimeInterval = 3_600) -> [Candle] {
        (0..<count).map { index in
            Candle(ts: Date(timeIntervalSince1970: Double(index) * spacing),
                   open: 100, high: 100, low: 100, close: 100, volume: 1, confirmed: true)
        }
    }

    @Test func carriesTheLastKnownValueForward() {
        let bars = candles(5)
        let observations = [
            SeriesObservation(ts: bars[1].ts, value: 10),
            SeriesObservation(ts: bars[3].ts, value: 20),
        ]
        let aligned = SeriesAligner.align(observations, to: bars)
        #expect(aligned[0].isNaN, "nothing published yet is unknown, not zero")
        #expect(aligned[1] == 10)
        #expect(aligned[2] == 10, "value holds until the next observation")
        #expect(aligned[3] == 20)
        #expect(aligned[4] == 20)
    }

    @Test func neverUsesAnObservationFromTheFuture() {
        let bars = candles(4)
        // Published one second after bar 2 opens — bar 2 must not see it.
        let observations = [
            SeriesObservation(ts: bars[2].ts.addingTimeInterval(1), value: 99),
        ]
        let aligned = SeriesAligner.align(observations, to: bars)
        #expect(aligned[0].isNaN)
        #expect(aligned[1].isNaN)
        #expect(aligned[2].isNaN, "a value stamped after the bar opened is look-ahead")
        #expect(aligned[3] == 99)
    }

    @Test func unorderedObservationsStillAlign() {
        let bars = candles(4)
        let observations = [
            SeriesObservation(ts: bars[3].ts, value: 30),
            SeriesObservation(ts: bars[1].ts, value: 10),
        ]
        let aligned = SeriesAligner.align(observations, to: bars)
        #expect(aligned[1] == 10)
        #expect(aligned[3] == 30)
    }

    @Test func emptyInputsAreSafe() {
        let empty = SeriesAligner.align([], to: candles(3))
        #expect(empty.allSatisfy { $0.isNaN })
        #expect(SeriesAligner.align([SeriesObservation(ts: Date(), value: 1)], to: []).isEmpty)
    }

    @Test func coverageCountsRealValues() {
        let bars = candles(4)
        let observations = [SeriesObservation(ts: bars[2].ts, value: 5)]
        let aligned = SeriesAligner.align(observations, to: bars)
        let coverage = SeriesAligner.coverage(
            name: "x", spec: AlternativeSeriesSpec(source: .fundingRate),
            observations: observations, aligned: aligned)
        #expect(abs(coverage.coverageRatio - 0.5) < 1e-9)
        #expect(!coverage.isUsable, "half a window is not enough to backtest on")
    }
}

@Suite("Alternative series specs")
struct AlternativeSeriesSpecTests {
    @Test func fundingResolvesToThePerpetual() {
        let spec = AlternativeSeriesSpec(source: .fundingRate)
            .resolved(against: StrategyMarket(instId: "BTC-USDT", instType: .spot, bar: .h1))
        #expect(spec.instId == "BTC-USDT-SWAP")
        #expect(spec.ccy == "BTC")
    }

    @Test func perpetualMarketsDoNotGetDoubleSuffixed() {
        let spec = AlternativeSeriesSpec(source: .fundingRate)
            .resolved(against: StrategyMarket(instId: "ETH-USDT-SWAP", instType: .swap, bar: .h4))
        #expect(spec.instId == "ETH-USDT-SWAP")
    }

    @Test func explicitValuesSurviveResolution() {
        let spec = AlternativeSeriesSpec(source: .instrumentClose, instId: "SOL-USDT")
            .resolved(against: StrategyMarket(instId: "BTC-USDT"))
        #expect(spec.instId == "SOL-USDT")
    }

    @Test func historyLimitsReflectTheRealEndpoints() {
        // Measured, not assumed — `maystock-lab signals` re-checks these.
        #expect(AlternativeSeriesSource.longShortRatio.historyLimitDays(bar: .h1) == 30)
        #expect(AlternativeSeriesSource.longShortRatio.historyLimitDays(bar: .d1) == 179)
        #expect(AlternativeSeriesSource.fundingRate.historyLimitDays(bar: .h1) == 90)
        #expect(AlternativeSeriesSource.instrumentClose.historyLimitDays(bar: .h1) == nil)
    }

    @Test func rubikPeriodsMapToSupportedValues() {
        #expect(AlternativeSeriesSource.rubikPeriod(for: .m5) == "5m")
        #expect(AlternativeSeriesSource.rubikPeriod(for: .h1) == "1H")
        #expect(AlternativeSeriesSource.rubikPeriod(for: .d1) == "1D")
    }
}

// MARK: - Declared series in expressions

@Suite("Declared data in expressions")
struct DeclaredSeriesTests {
    @Test func declaredNamesResolveAsVariables() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.data = ["funding": AlternativeSeriesSpec(source: .fundingRate)]
        manifest.signals = StrategySignals(
            longEntry: "funding < 0 and close > sma(close, 5)",
            longExit: "funding > 0.0002")
        let strategy = try manifest.compile()
        #expect(strategy.usesAlternativeData)
        #expect(strategy.dataSpecs["funding"]?.instId == "BTC-USDT-SWAP")
    }

    @Test func undeclaredSeriesStillFailToCompile() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.data = ["funding": AlternativeSeriesSpec(source: .fundingRate)]
        manifest.signals = StrategySignals(longEntry: "openInterest > 0")
        #expect(throws: StrategyManifestError.self) { _ = try manifest.compile() }
    }

    @Test func aSeriesMayNotShadowABuiltIn() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.data = ["close": AlternativeSeriesSpec(source: .fundingRate)]
        #expect(throws: StrategyManifestError.self) { _ = try manifest.compile() }
    }

    @Test func aSeriesMayNotShadowAParameter() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.data = ["fast": AlternativeSeriesSpec(source: .fundingRate)]
        #expect(throws: StrategyManifestError.self) { _ = try manifest.compile() }
    }

    @Test func declaredSeriesFeedTheEvaluator() throws {
        let series = try TradingKernel.evaluate(
            "funding < 0",
            candles: CandleFixture.flat([100, 100, 100, 100]),
            externalSeries: ["funding": [-1, -1, 1, 1]])
        #expect(series == [1, 1, 0, 0])
    }

    @Test func mismatchedSeriesLengthsArePaddedNotMisaligned() throws {
        let series = try TradingKernel.evaluate(
            "short",
            candles: CandleFixture.flat([1, 2, 3, 4]),
            externalSeries: ["short": [5, 6]])
        #expect(series.count == 4)
        #expect(series[0] == 5 && series[1] == 6)
        #expect(series[2].isNaN && series[3].isNaN, "missing tail is unknown, never recycled")
    }

    @Test func indicatorsWorkOverDeclaredSeries() throws {
        let series = try TradingKernel.evaluate(
            "sma(x, 3)",
            candles: CandleFixture.flat(Array(repeating: 100.0, count: 6)),
            externalSeries: ["x": [1, 2, 3, 4, 5, 6]])
        #expect(series[2] == 2)
        #expect(series[5] == 5)
    }
}

// MARK: - Information coefficient

@Suite("Signal information coefficient")
struct SignalAnalysisTests {
    /// Candles whose forward return is an exact function of `signal`.
    private func candles(_ closes: [Double]) -> [Candle] {
        CandleFixture.flat(closes)
    }

    @Test func aPerfectPredictorScoresRankCorrelationOne() {
        // Signal equals the next bar's return, so the ranks must agree exactly.
        // Needs more than the 10-observation floor before the IC is computed.
        var closes: [Double] = [100]
        for index in 0..<40 {
            let step = 1 + (Double((index * 7) % 11) - 5) / 100   // −5%…+5%, deterministic
            closes.append(closes[index] * step)
        }
        let bars = candles(closes)
        var signal: [Double] = []
        for index in 0..<closes.count - 1 { signal.append(closes[index + 1] / closes[index] - 1) }
        signal.append(0)

        let ic = SignalAnalysis.informationCoefficient(
            signal: signal, candles: bars, horizonBars: 1)
        #expect(ic.observations > 10)
        #expect(ic.spearman > 0.99, "a signal that IS the next return must rank-correlate perfectly")
    }

    @Test func noiseScoresNearZeroAndIsNotSignificant() {
        var generator = SystemRandomNumberGenerator()
        let closes = (0..<400).map { _ in Double.random(in: 90...110, using: &generator) }
        let bars = candles(closes)
        let signal = (0..<400).map { _ in Double.random(in: 0...1, using: &generator) }
        let ic = SignalAnalysis.informationCoefficient(signal: signal, candles: bars, horizonBars: 1)
        #expect(abs(ic.spearman) < 0.3)
    }

    @Test func overlapCorrectionShrinksTheStatistic() {
        // Correlated but not perfectly — a perfect rank match makes the
        // t-statistic undefined (1 − r² = 0) rather than merely large.
        var closes: [Double] = []
        for index in 0..<200 {
            closes.append(100 + Double(index) * 0.1 + sin(Double(index)) * 2)
        }
        let bars = candles(closes)
        let signal = (0..<200).map(Double.init)
        let ic = SignalAnalysis.informationCoefficient(signal: signal, candles: bars, horizonBars: 7)
        #expect(ic.effectiveObservations < ic.observations / 5,
                "7-bar overlapping windows leave roughly n/7 independent points")
        #expect(abs(ic.adjustedTStatistic) < abs(ic.tStatistic),
                "the naive t must be deflated by √h")
        #expect(abs(ic.adjustedTStatistic - ic.tStatistic / 7.0.squareRoot()) < 1e-9)
    }

    @Test func horizonOneNeedsNoCorrection() {
        let closes = (0..<100).map { 100 + Double($0) }
        let ic = SignalAnalysis.informationCoefficient(
            signal: (0..<100).map(Double.init), candles: candles(closes), horizonBars: 1)
        #expect(ic.adjustedTStatistic == ic.tStatistic)
        #expect(ic.effectiveObservations == ic.observations)
    }

    @Test func nanSignalValuesAreExcludedNotTreatedAsZero() {
        let closes = (0..<50).map { 100 + Double($0) }
        var signal = (0..<50).map(Double.init)
        for index in 0..<20 { signal[index] = .nan }
        let ic = SignalAnalysis.informationCoefficient(
            signal: signal, candles: candles(closes), horizonBars: 1)
        #expect(ic.observations <= 30, "warm-up NaNs must not become data points")
    }

    @Test func multipleTestingThresholdRisesWithTrials() {
        let one = SignalIC.multipleTestingThreshold(trials: 1)
        let many = SignalIC.multipleTestingThreshold(trials: 18)
        #expect(one == 2)
        #expect(many > 2.5, "18 combinations demand a much higher bar than one")
    }

    @Test func ranksHandleTies() {
        let ranked = SignalAnalysis.ranks(of: [5, 5, 1])
        #expect(ranked[2] == 1, "smallest value ranks first")
        #expect(ranked[0] == ranked[1], "ties share the mean rank")
    }

    @Test func quintilesSplitTheSignalNotTheReturns() {
        let signal = (0..<50).map(Double.init)
        let forward = (0..<50).map { Double($0) * 2 }
        let buckets = SignalAnalysis.quintiles(signal: signal, forward: forward, buckets: 5)
        #expect(buckets.count == 5)
        #expect(buckets[0] < buckets[4], "monotone input gives monotone buckets")
    }

    @Test func verdictRefusesToCallNoiseSignificant() {
        let ic = SignalIC(horizonBars: 7, observations: 170, pearson: 0.2,
                          spearman: 0.25, tStatistic: 3.3, quintileReturns: [1, 2, 3, 4, 5])
        // 3.3 / √7 = 1.25 — not significant once overlap is accounted for.
        #expect(!ic.isSignificant)
        #expect(SignalAnalysis.verdict(ic).contains("不显著"))
    }
}

// MARK: - Script engine

@Suite("Script strategy engine")
struct ScriptEngineTests {
    private func makeScript(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("engine.sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func candles(_ count: Int) -> [Candle] {
        CandleFixture.flat(Array(repeating: 100.0, count: count))
    }

    @Test func refusesToRunWithoutAnExplicitUnlock() async throws {
        let script = try makeScript(#"cat > /dev/null; echo '{"target":["long"]}'"#)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let engine = ScriptStrategyEngine(spec: ScriptEngineSpec(command: script.path))
        await #expect(throws: ScriptEngineError.self) {
            _ = try await engine.targets(
                candles: self.candles(1), params: [:], instId: "BTC-USDT",
                bar: .h1, enabled: false)
        }
    }

    @Test func parsesTargetsWhenUnlocked() async throws {
        let script = try makeScript(#"cat > /dev/null; echo '{"target":["long","flat",null]}'"#)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let engine = ScriptStrategyEngine(spec: ScriptEngineSpec(command: script.path))
        let targets = try await engine.targets(
            candles: candles(3), params: [:], instId: "BTC-USDT", bar: .h1, enabled: true)
        #expect(targets == [.long, nil, nil])
    }

    @Test func rejectsAWrongLengthAnswer() async throws {
        let script = try makeScript(#"cat > /dev/null; echo '{"target":["long"]}'"#)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let engine = ScriptStrategyEngine(spec: ScriptEngineSpec(command: script.path))
        await #expect(throws: ScriptEngineError.self) {
            _ = try await engine.targets(
                candles: self.candles(5), params: [:], instId: "BTC-USDT",
                bar: .h1, enabled: true)
        }
    }

    @Test func rejectsUnknownTargetValues() {
        let data = Data(#"{"target":["moon"]}"#.utf8)
        #expect(throws: ScriptEngineError.self) {
            _ = try ScriptStrategyEngine.decodeTargets(data, expected: 1)
        }
    }

    @Test func rejectsGarbageOutput() {
        #expect(throws: ScriptEngineError.self) {
            _ = try ScriptStrategyEngine.decodeTargets(Data("not json".utf8), expected: 1)
        }
        #expect(throws: ScriptEngineError.self) {
            _ = try ScriptStrategyEngine.decodeTargets(Data(#"{"oops":[]}"#.utf8), expected: 1)
        }
    }

    @Test func surfacesANonZeroExit() async throws {
        let script = try makeScript("cat > /dev/null; echo 'boom' >&2; exit 3")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let engine = ScriptStrategyEngine(spec: ScriptEngineSpec(command: script.path))
        await #expect(throws: ScriptEngineError.self) {
            _ = try await engine.targets(
                candles: self.candles(1), params: [:], instId: "BTC-USDT",
                bar: .h1, enabled: true)
        }
    }

    @Test func killsAHangingScript() async throws {
        let script = try makeScript("cat > /dev/null; sleep 30")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let engine = ScriptStrategyEngine(
            spec: ScriptEngineSpec(command: script.path, timeoutSeconds: 1))
        let started = Date()
        await #expect(throws: ScriptEngineError.self) {
            _ = try await engine.targets(
                candles: self.candles(1), params: [:], instId: "BTC-USDT",
                bar: .h1, enabled: true)
        }
        #expect(Date().timeIntervalSince(started) < 10, "the timeout must actually fire")
    }

    @Test func missingExecutableIsReportedClearly() async {
        let engine = ScriptStrategyEngine(
            spec: ScriptEngineSpec(command: "/nonexistent/\(UUID().uuidString)"))
        await #expect(throws: ScriptEngineError.self) {
            _ = try await engine.targets(
                candles: self.candles(1), params: [:], instId: "BTC-USDT",
                bar: .h1, enabled: true)
        }
    }

    @Test func requestCarriesCandlesParamsAndSeries() throws {
        let data = try ScriptStrategyEngine.encodeRequest(
            candles: candles(2), params: ["fast": 10],
            series: ["funding": [.nan, 0.5]], instId: "BTC-USDT", bar: .h4)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["instId"] as? String == "BTC-USDT")
        #expect(root["bar"] as? String == "4H")
        #expect((root["candles"] as? [Any])?.count == 2)
        let series = try #require(root["series"] as? [String: [Any]])
        #expect(series["funding"]?.first is NSNull, "NaN must travel as null, not 0")
    }

    @Test func scriptManifestsNeedNoEntryExpression() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.engine = .script(ScriptEngineSpec(command: "/bin/echo"))
        manifest.signals = StrategySignals()
        let strategy = try manifest.compile()
        #expect(strategy.isScriptEngine)
        #expect(strategy.scriptSpec?.command == "/bin/echo")
    }

    @Test func scriptTargetsDriveTheBacktestAndRiskStillApplies() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.engine = .script(ScriptEngineSpec(command: "/bin/echo"))
        manifest.signals = StrategySignals()
        manifest.risk = StrategyRisk(stopLossPct: 5)
        manifest.costs = StrategyCosts(feeBps: 0, slippageBps: 0)
        let strategy = try manifest.compile()

        let bars = CandleFixture.make([
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 101, low: 99, close: 100),
            (open: 100, high: 100, low: 90, close: 92),   // breaches the 5% stop
            (open: 92, high: 93, low: 91, close: 92),
        ])
        let config = BacktestConfig(
            initialCapital: 1_000,
            scriptTargets: [.long, .long, .long, .long, .long])
        let result = try BacktestEngine(strategy: strategy, config: config).run(candles: bars)
        #expect(result.trades.first?.exitReason == .stopLoss,
                "a script picks direction; the manifest's stop still governs")
    }
}

// MARK: - Industry feeds

@Suite("Industry signal sources")
struct IndustrySignalTests {
    @Test func industryFeedsAreNotHistoryLimited() {
        // This is the whole reason they were added: the OKX statistics cap out
        // at 30–179 days, which cannot validate anything.
        for source in AlternativeSeriesSource.allCases where source.isIndustryFeed {
            #expect(source.historyLimitDays(bar: .d1) == nil, "\(source) must carry deep history")
            #expect(source.historyLimitDays(bar: .h1) == nil)
        }
    }

    @Test func exchangeSourcesRemainLimited() {
        #expect(AlternativeSeriesSource.longShortRatio.historyLimitDays(bar: .d1) == 179)
        #expect(!AlternativeSeriesSource.longShortRatio.isIndustryFeed)
        #expect(AlternativeSeriesSource.longShortRatio.provider == "OKX")
    }

    @Test func everySourceReportsItsProvider() {
        #expect(AlternativeSeriesSource.fearGreed.provider == "alternative.me")
        #expect(AlternativeSeriesSource.hashRate.provider == "blockchain.info")
        #expect(AlternativeSeriesSource.vix.provider == "fred.stlouisfed.org")
        for source in AlternativeSeriesSource.allCases {
            #expect(!source.provider.isEmpty)
            #expect(!source.displayName.isEmpty)
        }
    }

    @Test func globalSourcesNeedNoInstrument() {
        #expect(AlternativeSeriesSource.fearGreed.isGlobal)
        #expect(AlternativeSeriesSource.vix.isGlobal)
        #expect(!AlternativeSeriesSource.coinbasePremium.isGlobal, "premium is BTC-specific")
        #expect(!AlternativeSeriesSource.fundingRate.isGlobal)
    }

    @Test func industrySourcesCompileInsideAManifest() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.data = [
            "fng": AlternativeSeriesSpec(source: .fearGreed),
            "dxy": AlternativeSeriesSpec(source: .dollarIndex),
        ]
        manifest.signals = StrategySignals(
            longEntry: "fng < 30 and roc(dxy, 30) < 0",
            longExit: "fng > 70")
        let strategy = try manifest.compile()
        #expect(strategy.usesAlternativeData)
        #expect(strategy.dataSpecs.count == 2)
    }

    @Test func rawSourceNamesRoundTripThroughJSON() throws {
        for source in AlternativeSeriesSource.allCases {
            let spec = AlternativeSeriesSpec(source: source)
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(AlternativeSeriesSpec.self, from: data)
            #expect(decoded.source == source)
        }
    }
}
