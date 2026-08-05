import Foundation
import Testing
@testable import MayStockKit

@Suite("Backtest engine")
struct BacktestEngineTests {

    /// A spot strategy with costs switched off, so arithmetic is exact.
    private func strategy(
        longEntry: String,
        longExit: String? = nil,
        shortEntry: String? = nil,
        shortExit: String? = nil,
        risk: StrategyRisk = StrategyRisk(),
        sizing: StrategySizing = StrategySizing(mode: .equityPct, value: 100),
        instType: InstrumentType = .spot,
        feeBps: Double = 0,
        slippageBps: Double = 0
    ) throws -> CompiledStrategy {
        try StrategyManifest(
            id: "test", name: "Test",
            market: StrategyMarket(
                instId: instType == .swap ? "BTC-USDT-SWAP" : "BTC-USDT",
                instType: instType, bar: .h1),
            signals: StrategySignals(longEntry: longEntry, longExit: longExit,
                                     shortEntry: shortEntry, shortExit: shortExit),
            sizing: sizing,
            risk: risk,
            costs: StrategyCosts(feeBps: feeBps, slippageBps: slippageBps)
        ).compile()
    }

    // MARK: Look-ahead

    @Test func fillsAtTheNextBarOpenNotTheSignalBarClose() throws {
        // A V-bottom: the entry signal fires on the bar that closes at 90, but
        // that price is gone by the time an order could exist. A look-ahead bug
        // would report an entry at 90; the honest answer is the next open, 105.
        let candles = CandleFixture.make([
            (open: 100, high: 101, low: 99, close: 100),
            (open: 100, high: 101, low: 99, close: 100),
            (open: 100, high: 101, low: 99, close: 100),
            (open: 100, high: 101, low: 89, close: 90),    // signal bar
            (open: 105, high: 112, low: 104, close: 110),  // entry fills here
            (open: 111, high: 115, low: 110, close: 112),  // exit fills here
        ])
        let engine = BacktestEngine(
            strategy: try strategy(longEntry: "close < 95", longExit: "close > 105"),
            config: BacktestConfig(initialCapital: 10_000))
        let result = try engine.run(candles: candles)

        #expect(result.trades.count == 1)
        let trade = try #require(result.trades.first)
        #expect(trade.entryPrice == 105, "entry must fill at the next bar's open")
        #expect(trade.exitPrice == 111, "exit must fill at the next bar's open")
        #expect(trade.direction == .long)
        #expect(trade.exitReason == .signal)
    }

    @Test func pnlAndEquityAgreeWithHandArithmetic() throws {
        let candles = CandleFixture.make([
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),  // entry fills here
            (open: 110, high: 110, low: 110, close: 110),
            (open: 120, high: 120, low: 120, close: 120),  // exit fills here
        ])
        let engine = BacktestEngine(
            strategy: try strategy(longEntry: "close > 99", longExit: "close > 105"),
            config: BacktestConfig(initialCapital: 1_000))
        let result = try engine.run(candles: candles)

        let trade = try #require(result.trades.first)
        #expect(trade.entryPrice == 100)
        #expect(trade.exitPrice == 120)
        #expect(abs(trade.quantity - 10) < 1e-9)          // 1,000 / 100
        #expect(abs(trade.netPnL - 200) < 1e-9)           // 10 units × 20
        #expect(abs(result.finalEquity - 1_200) < 1e-9)
        #expect(abs(result.metrics.totalReturnPct - 20) < 1e-9)
    }

    @Test func feesAreChargedOnBothLegs() throws {
        let candles = CandleFixture.make([
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),
        ])
        // Flat prices, 10 bps per side ⇒ the only P&L is the round-trip cost.
        let engine = BacktestEngine(
            strategy: try strategy(longEntry: "close > 99", longExit: "bar_index > 2", feeBps: 10),
            config: BacktestConfig(initialCapital: 1_000))
        let result = try engine.run(candles: candles)

        let trade = try #require(result.trades.first)
        #expect(abs(trade.fees - 2) < 1e-6, "1,000 notional × 10bps, twice")
        #expect(trade.netPnL < 0)
    }

    @Test func slippageMovesFillsAgainstTheTrader() throws {
        let candles = CandleFixture.make(Array(repeating:
            (open: 100.0, high: 100.0, low: 100.0, close: 100.0), count: 5))
        let engine = BacktestEngine(
            strategy: try strategy(longEntry: "close > 99", longExit: "bar_index > 2",
                                   slippageBps: 50),
            config: BacktestConfig(initialCapital: 1_000))
        let result = try engine.run(candles: candles)

        let trade = try #require(result.trades.first)
        #expect(trade.entryPrice > 100, "buying pays up")
        #expect(trade.exitPrice < 100, "selling receives less")
    }

    // MARK: Protective exits

    @Test func stopWinsWhenOneBarTouchesBothStopAndTarget() throws {
        let candles = CandleFixture.make([
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 106, low: 94, close: 100),   // entry here; both levels touched
            (open: 100, high: 101, low: 99, close: 100),
        ])
        let engine = BacktestEngine(
            strategy: try strategy(longEntry: "close > 99",
                                   risk: StrategyRisk(stopLossPct: 5, takeProfitPct: 5)),
            config: BacktestConfig(initialCapital: 1_000))
        let result = try engine.run(candles: candles)

        let trade = try #require(result.trades.first)
        #expect(trade.exitReason == .stopLoss, "ambiguous bars must assume the loss")
        #expect(trade.exitPrice == 95)
    }

    @Test func aGapThroughTheStopFillsAtTheOpen() throws {
        let candles = CandleFixture.make([
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 101, low: 99, close: 100),   // entry at 100, stop at 95
            (open: 90, high: 92, low: 88, close: 90),      // gaps straight through
        ])
        let engine = BacktestEngine(
            strategy: try strategy(longEntry: "close > 99", risk: StrategyRisk(stopLossPct: 5)),
            config: BacktestConfig(initialCapital: 1_000))
        let result = try engine.run(candles: candles)

        let trade = try #require(result.trades.first)
        #expect(trade.exitReason == .stopLoss)
        #expect(trade.exitPrice == 90, "you cannot get filled at a price the market skipped")
    }

    @Test func takeProfitFiresWhenOnlyTheTargetIsTouched() throws {
        let candles = CandleFixture.make([
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 107, low: 99, close: 106),
            (open: 106, high: 107, low: 105, close: 106),
        ])
        let engine = BacktestEngine(
            strategy: try strategy(longEntry: "close > 99",
                                   risk: StrategyRisk(stopLossPct: 5, takeProfitPct: 5)),
            config: BacktestConfig(initialCapital: 1_000))
        let result = try engine.run(candles: candles)

        let trade = try #require(result.trades.first)
        #expect(trade.exitReason == .takeProfit)
        #expect(trade.exitPrice == 105)
    }

    // MARK: Shorting & leverage

    @Test func shortsProfitWhenPriceFalls() throws {
        let candles = CandleFixture.make([
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),   // short opens here
            (open: 90, high: 90, low: 90, close: 90),
            (open: 80, high: 80, low: 80, close: 80),        // covers here
        ])
        let engine = BacktestEngine(
            strategy: try strategy(longEntry: "0", shortEntry: "close > 99",
                                   shortExit: "close < 95", instType: .swap),
            config: BacktestConfig(initialCapital: 1_000))
        let result = try engine.run(candles: candles)

        let trade = try #require(result.trades.first)
        #expect(trade.direction == .short)
        #expect(trade.netPnL > 0)
        #expect(abs(trade.netPnL - 200) < 1e-6)   // 10 units short, 100 → 80
    }

    @Test func leveragedLossesLiquidate() throws {
        let candles = CandleFixture.make([
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),
            (open: 100, high: 100, low: 100, close: 100),  // 10× long opens here
            (open: 100, high: 100, low: 85, close: 88),    // −12% wipes the margin
        ])
        let engine = BacktestEngine(
            strategy: try strategy(longEntry: "close > 99",
                                   risk: StrategyRisk(leverage: 10), instType: .swap),
            config: BacktestConfig(initialCapital: 1_000, maintenanceMarginRate: 0.005))
        let result = try engine.run(candles: candles)

        #expect(result.liquidations == 1)
        #expect(result.trades.first?.exitReason == .liquidation)
    }

    // MARK: Funding

    @Test func swapFundingIsChargedToOpenPositions() throws {
        let candles = CandleFixture.make(Array(repeating:
            (open: 100.0, high: 100.0, low: 100.0, close: 100.0), count: 6))
        // One settlement inside bar 3, at 1% — deliberately large so it shows.
        let funding = [FundingRate(ts: candles[3].ts.addingTimeInterval(60), rate: 0.01)]
        let engine = BacktestEngine(
            strategy: try strategy(longEntry: "close > 99", longExit: "bar_index > 3",
                                   instType: .swap),
            config: BacktestConfig(initialCapital: 1_000, fundingRates: funding))
        let result = try engine.run(candles: candles)

        let trade = try #require(result.trades.first)
        #expect(abs(trade.funding - 10) < 1e-6, "long pays 1% of 1,000 notional")
        #expect(trade.netPnL < 0, "flat prices plus funding is a loss")
        #expect(!result.fundingUnmodelled)
    }

    @Test func missingFundingHistoryIsFlaggedNotIgnored() throws {
        let candles = CandleFixture.flat(Array(repeating: 100.0, count: 5))
        let engine = BacktestEngine(
            strategy: try strategy(longEntry: "close > 99", instType: .swap),
            config: BacktestConfig(initialCapital: 1_000))
        let result = try engine.run(candles: candles)
        #expect(result.fundingUnmodelled)
    }

    // MARK: Guards

    @Test func warmupBarsAreExcludedFromTheEquityCurve() throws {
        let candles = CandleFixture.flat(Array(stride(from: 100.0, to: 160.0, by: 1)))
        let compiled = try strategy(longEntry: "close > sma(close, 20)")
        let result = try BacktestEngine(strategy: compiled).run(candles: candles)
        #expect(result.barCount == candles.count - compiled.warmupBars)
        #expect(result.equityCurve.count == result.barCount)
    }

    @Test func conflictingEntrySignalsKeepTheStrategyFlat() throws {
        let candles = CandleFixture.flat(Array(repeating: 100.0, count: 6))
        let engine = BacktestEngine(
            strategy: try strategy(longEntry: "close > 99", shortEntry: "close > 99",
                                   instType: .swap),
            config: BacktestConfig(initialCapital: 1_000))
        let result = try engine.run(candles: candles)
        #expect(result.trades.isEmpty, "an ambiguous strategy must not pick a side on its own")
    }

    @Test func dailyLossLimitHaltsTrading() throws {
        // 24 hourly bars a day; a 40% drop on day one must trip a 10% limit.
        var rows: [(open: Double, high: Double, low: Double, close: Double)] = []
        for _ in 0..<3 { rows.append((100, 100, 100, 100)) }
        rows.append((100, 100, 60, 60))
        for _ in 0..<3 { rows.append((60, 60, 60, 60)) }
        let engine = BacktestEngine(
            strategy: try strategy(longEntry: "close > 50",
                                   risk: StrategyRisk(maxDailyLossPct: 10)),
            config: BacktestConfig(initialCapital: 1_000))
        let result = try engine.run(candles: CandleFixture.make(rows))
        #expect(result.trades.contains { $0.exitReason == .dailyLossHalt })
    }

    @Test func emptyInputProducesAnEmptyResultRatherThanACrash() throws {
        let engine = BacktestEngine(strategy: try strategy(longEntry: "close > 1"))
        let result = try engine.run(candles: [])
        #expect(result.trades.isEmpty)
        #expect(result.metrics.totalReturnPct == 0)
    }
}

// MARK: - Metrics

@Suite("Backtest metrics")
struct BacktestMetricsTests {
    private func curve(_ equities: [Double], startPrice: Double = 100) -> [EquityPoint] {
        equities.enumerated().map { index, equity in
            EquityPoint(ts: Date(timeIntervalSince1970: Double(index) * 3_600),
                        equity: equity, price: startPrice + Double(index))
        }
    }

    @Test func drawdownMeasuresPeakToTrough() {
        let metrics = BacktestMetrics(
            trades: [], equityCurve: curve([100, 120, 90, 110]),
            initialCapital: 100, bar: .h1, freeParameterCount: 1)
        #expect(abs(metrics.maxDrawdownPct - 25) < 1e-9)   // 120 → 90
        #expect(abs(metrics.maxDrawdownAbsolute - 30) < 1e-9)
    }

    @Test func benchmarkComesFromThePriceSeries() {
        let metrics = BacktestMetrics(
            trades: [], equityCurve: curve([100, 100, 100], startPrice: 100),
            initialCapital: 100, bar: .h1, freeParameterCount: 1)
        #expect(abs(metrics.buyHoldReturnPct - 2) < 1e-9)   // 100 → 102
        #expect(metrics.excessReturnPct < 0, "flat equity underperforms a rising market")
        #expect(!metrics.beatsBuyHold)
    }

    @Test func profitFactorHandlesALosslessRun() {
        let win = BacktestTrade(
            id: 1, direction: .long, entryTime: .distantPast, exitTime: .distantPast,
            entryPrice: 1, exitPrice: 2, quantity: 1, notional: 1,
            grossPnL: 1, fees: 0, funding: 0, netPnL: 1, returnPct: 1,
            bars: 1, exitReason: .signal)
        let metrics = BacktestMetrics(
            trades: [win], equityCurve: curve([100, 101]),
            initialCapital: 100, bar: .h1, freeParameterCount: 1)
        #expect(metrics.profitFactor.isInfinite)
        #expect(PriceFormatter.ratio(metrics.profitFactor) == "∞")
        #expect(metrics.winRate == 100)
    }

    @Test func annualisationIsMarkedUnreliableOnShortWindows() {
        let short = BacktestMetrics(
            trades: [], equityCurve: curve([100, 102]),
            initialCapital: 100, bar: .h1, freeParameterCount: 1)
        #expect(!short.annualisationReliable)
    }
}

// MARK: - Robustness

@Suite("Robustness grading")
struct RobustnessTests {
    private func result(returnPct: Double, trades: Int, bars: Int = 200) -> BacktestResult {
        let equity = (0..<bars).map { index -> EquityPoint in
            let progress = Double(index) / Double(max(bars - 1, 1))
            return EquityPoint(
                ts: Date(timeIntervalSince1970: Double(index) * 3_600),
                equity: 1_000 * (1 + returnPct / 100 * progress),
                price: 100)
        }
        let sample = (0..<trades).map { index in
            BacktestTrade(
                id: index + 1, direction: .long, entryTime: .distantPast, exitTime: .distantPast,
                entryPrice: 100, exitPrice: 101, quantity: 1, notional: 100,
                grossPnL: 1, fees: 0, funding: 0, netPnL: 1, returnPct: 1,
                bars: 2, exitReason: .signal)
        }
        return BacktestResult(
            strategyId: "s", instId: "BTC-USDT", bar: .h1,
            start: equity.first?.ts ?? Date(), end: equity.last?.ts ?? Date(),
            barCount: bars, initialCapital: 1_000,
            finalEquity: equity.last?.equity ?? 1_000,
            trades: sample, equityCurve: equity, liquidations: 0, warmupBars: 0,
            fundingUnmodelled: false,
            metrics: BacktestMetrics(trades: sample, equityCurve: equity,
                                     initialCapital: 1_000, bar: .h1, freeParameterCount: 2))
    }

    @Test func tooFewTradesGradesAsInsufficient() {
        let assessment = RobustnessAssessment.evaluate(
            results: [.d30: result(returnPct: 40, trades: 3)], bar: .h1, freeParameterCount: 2)
        #expect(assessment.grade == .insufficientData)
        #expect(assessment.requiredTrades == 60, "2 parameters × 30 trades")
    }

    @Test func noTradesIsAlsoInsufficient() {
        let assessment = RobustnessAssessment.evaluate(
            results: [.d1: result(returnPct: 0, trades: 0)], bar: .h1, freeParameterCount: 1)
        #expect(assessment.grade == .insufficientData)
        #expect(assessment.observedTrades == 0)
    }

    @Test func gradingUsesTheLongestAvailableWindow() {
        let assessment = RobustnessAssessment.evaluate(
            results: [.d1: result(returnPct: 5, trades: 1),
                      .d365: result(returnPct: 20, trades: 100)],
            bar: .h1, freeParameterCount: 1)
        #expect(assessment.observedTrades == 100)
    }

    @Test func emptyResultsAreUnavailableNotOptimistic() {
        let assessment = RobustnessAssessment.evaluate(
            results: [:], bar: .h1, freeParameterCount: 1)
        #expect(assessment.grade == .insufficientData)
    }
}
