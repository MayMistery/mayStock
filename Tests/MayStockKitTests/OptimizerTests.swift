import Foundation
import Testing
@testable import MayStockKit

// MARK: - Fee schedule

@Suite("OKX fee schedule")
struct FeeScheduleTests {
    @Test func defaultsToTheMostExpensiveRealisticTier() {
        let schedule = OKXFeeSchedule()
        #expect(schedule.tier == .lv1, "a fresh account is Lv1; assuming better flatters every backtest")
        #expect(schedule.feeBps(for: .spot) == 10)
        #expect(schedule.feeBps(for: .swap) == 5)
        #expect(schedule.executionStyle == .taker)
    }

    @Test func roundTripCostIsBothLegsPlusSlippage() {
        let schedule = OKXFeeSchedule(tier: .lv1, slippageBps: 5)
        // (10 + 5) × 2 = 30 bps = 0.30%
        #expect(abs(schedule.roundTripCostPct(for: .spot) - 0.30) < 1e-9)
    }

    @Test func feesFallAsTiersRise() {
        let tiers = OKXFeeTier.allCases
        for (lower, higher) in zip(tiers, tiers.dropFirst()) {
            #expect(higher.spotTakerBps <= lower.spotTakerBps, "\(higher) must not cost more than \(lower)")
            #expect(higher.spotMakerBps <= lower.spotMakerBps)
        }
    }

    @Test func topTiersEarnMakerRebates() {
        #expect(OKXFeeTier.vip9.spotMakerBps < 0, "VIP9 pays you to provide liquidity")
        #expect(OKXFeeTier.lv1.spotMakerBps > 0)
    }

    @Test func accountRatesOverrideThePublishedTable() {
        var schedule = OKXFeeSchedule(tier: .lv1)
        #expect(!schedule.syncedFromAccount)
        schedule.apply(AccountFeeRates(instType: .spot, makerBps: 3, takerBps: 4))
        #expect(schedule.feeBps(for: .spot) == 4)
        #expect(schedule.feeBps(for: .spot, style: .maker) == 3)
        #expect(schedule.syncedFromAccount)
        #expect(schedule.feeBps(for: .swap) == 5, "syncing spot must not touch swap")

        schedule.clearSync()
        #expect(schedule.feeBps(for: .spot) == 10)
        #expect(!schedule.syncedFromAccount)
    }

    @Test func okxSignConventionIsInverted() {
        // OKX reports a charge as a negative fraction: -0.001 == 10 bps out.
        let json = #"{"code":"0","data":[{"level":"Lv1","taker":"-0.001","maker":"-0.0008"}]}"#
        let rates = TradeBridge.parseFeeRates(json: json, instType: .spot)
        #expect(rates?.takerBps == 10)
        #expect(rates?.makerBps == 8)
    }

    @Test func genuineRebatesStayNegative() {
        let json = #"{"code":"0","data":[{"taker":"-0.00015","maker":"0.00002"}]}"#
        let rates = TradeBridge.parseFeeRates(json: json, instType: .spot)
        #expect(abs((rates?.takerBps ?? 0) - 1.5) < 1e-9)
        #expect((rates?.makerBps ?? 0) < 0, "a positive OKX maker value is a rebate")
    }

    @Test func manifestCostsWinOverTheAccountTier() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.costs = StrategyCosts(feeBps: 0, slippageBps: 0)
        let strategy = try manifest.compile()
        let candles = CandleFixture.flat(Array(repeating: 100.0, count: 6))
        let config = BacktestConfig(
            initialCapital: 1_000,
            feeSchedule: OKXFeeSchedule(tier: .lv1))   // would charge 10 bps
        let result = try BacktestEngine(strategy: strategy, config: config).run(candles: candles)
        #expect(result.metrics.feesPaid == 0, "an explicit manifest cost must not be overridden")
    }

    @Test func tierChangesFlowIntoBacktestCosts() throws {
        var manifest = StrategyLibrary.emaTrend
        manifest.costs = nil                       // follow the account tier
        manifest.signals = StrategySignals(longEntry: "close > 1", longExit: "bar_index > 2")
        let strategy = try manifest.compile()
        let candles = CandleFixture.flat(Array(repeating: 100.0, count: 8))

        func fees(_ tier: OKXFeeTier) throws -> Double {
            let config = BacktestConfig(
                initialCapital: 1_000,
                feeSchedule: OKXFeeSchedule(tier: tier, slippageBps: 0))
            return try BacktestEngine(strategy: strategy, config: config)
                .run(candles: candles).metrics.feesPaid
        }
        let retail = try fees(.lv1)
        let whale = try fees(.vip9)
        #expect(retail > whale, "a VIP account must backtest cheaper than a retail one")
    }
}

// MARK: - Grid

@Suite("Parameter grid")
struct ParameterGridTests {
    @Test func onlyRangedParametersAreSearched() {
        let manifest = StrategyManifest(
            id: "g", name: "g",
            market: StrategyMarket(instId: "BTC-USDT"),
            params: StrategyParameterSet([
                StrategyParameter(name: "ranged", value: 10, minimum: 5, maximum: 20),
                StrategyParameter(name: "fixed", value: 3),
            ]),
            signals: StrategySignals(longEntry: "close > 1"))
        let grid = ParameterGrid(manifest: manifest, pointsPerAxis: 4)
        #expect(grid.axes.count == 1, "a knob with no declared range does not get turned")
        #expect(grid.axes.first?.name == "ranged")
    }

    @Test func cartesianProductCoversEveryCombination() {
        let grid = ParameterGrid(axes: [("a", [1, 2]), ("b", [10, 20, 30])])
        #expect(grid.size == 6)
        let combinations = grid.combinations()
        #expect(combinations.count == 6)
        #expect(combinations.allSatisfy { $0["a"] != nil && $0["b"] != nil })
        #expect(Set(combinations.map { "\($0["a"]!)-\($0["b"]!)" }).count == 6)
    }

    @Test func limitStopsRunawaySearches() {
        let grid = ParameterGrid(axes: [("a", Array(1...100).map(Double.init)),
                                        ("b", Array(1...100).map(Double.init))])
        #expect(grid.size == 10_000)
        #expect(grid.combinations(limit: 250).count <= 250)
    }

    @Test func gridIncludesBothEndsOfTheRange() {
        let manifest = StrategyManifest(
            id: "g", name: "g",
            market: StrategyMarket(instId: "BTC-USDT"),
            params: StrategyParameterSet([
                StrategyParameter(name: "n", value: 10, minimum: 5, maximum: 20),
            ]),
            signals: StrategySignals(longEntry: "close > 1"))
        let values = ParameterGrid(manifest: manifest, pointsPerAxis: 4).axes.first?.values ?? []
        #expect(values.first == 5)
        #expect(values.last == 20)
    }
}

// MARK: - Optimizer

@Suite("Strategy optimizer")
struct StrategyOptimizerTests {
    /// Rising prices with a dip, so different parameters genuinely differ.
    private func candles() -> [Candle] {
        var closes: [Double] = []
        var price = 100.0
        for index in 0..<400 {
            price += (index % 50) < 40 ? 0.5 : -1.2
            closes.append(price)
        }
        return CandleFixture.make(closes.map {
            (open: $0, high: $0 * 1.003, low: $0 * 0.997, close: $0)
        })
    }

    private func strategy() throws -> CompiledStrategy {
        try StrategyManifest(
            id: "opt", name: "opt",
            market: StrategyMarket(instId: "BTC-USDT", instType: .spot, bar: .h1),
            params: StrategyParameterSet([
                StrategyParameter(name: "fast", value: 8, minimum: 4, maximum: 16),
                StrategyParameter(name: "slow", value: 20, minimum: 18, maximum: 30),
            ]),
            signals: StrategySignals(
                longEntry: "ema(close, fast) crosses_above ema(close, slow)",
                longExit: "ema(close, fast) crosses_below ema(close, slow)"),
            costs: StrategyCosts(feeBps: 10, slippageBps: 5)
        ).compile()
    }

    @Test func rankingPutsPassingCandidatesFirst() throws {
        let objective = OptimizationObjective(kind: .totalReturn, minTrades: 2)
        let result = StrategyOptimizer(strategy: try strategy(), objective: objective)
            .run(candles: candles())
        #expect(result.evaluated > 0)
        // Every rejected candidate must sort after every passing one.
        let firstRejected = result.candidates.firstIndex { !$0.passes }
        let lastPassing = result.candidates.lastIndex { $0.passes }
        if let firstRejected, let lastPassing { #expect(lastPassing < firstRejected) }
    }

    @Test func constraintsActuallyReject() throws {
        let objective = OptimizationObjective(kind: .totalReturn, maxDrawdownPct: 0.0001, minTrades: 1)
        let result = StrategyOptimizer(strategy: try strategy(), objective: objective)
            .run(candles: candles())
        #expect(result.best == nil, "an impossible drawdown limit must reject everything")
        #expect(result.warnings.contains { $0.contains("没有任何参数组") })
    }

    @Test func minimumTradeCountIsEnforced() throws {
        let objective = OptimizationObjective(kind: .totalReturn, minTrades: 10_000)
        let result = StrategyOptimizer(strategy: try strategy(), objective: objective)
            .run(candles: candles())
        #expect(result.passing.isEmpty)
        #expect(result.candidates.allSatisfy { $0.rejection?.contains("交易") == true })
    }

    @Test func aStrategyWithNoRangesCannotBeOptimised() throws {
        let strategy = try StrategyLibrary.dualMomentum.compile()
        var manifest = strategy.manifest
        manifest.params = StrategyParameterSet([StrategyParameter(name: "lookback", value: 30)])
        manifest.signals = StrategySignals(longEntry: "roc(close, lookback) > 0",
                                           longExit: "roc(close, lookback) < 0")
        let result = StrategyOptimizer(strategy: try manifest.compile()).run(candles: candles())
        #expect(result.evaluated == 0)
        #expect(result.warnings.contains { $0.contains("无可寻优空间") })
    }

    @Test func objectivesRankDifferently() {
        let steady = BacktestMetrics(
            trades: [], equityCurve: (0..<50).map {
                EquityPoint(ts: Date(timeIntervalSince1970: Double($0) * 3_600),
                            equity: 100 + Double($0), price: 100)
            }, initialCapital: 100, bar: .h1, freeParameterCount: 1)
        #expect(OptimizationObjective.Kind.totalReturn.score(steady) > 0)
        #expect(OptimizationObjective.Kind.dailyReturn.score(steady) > 0)
        // returnOverDrawdown floors the denominator, so a zero-drawdown run
        // cannot win by dividing by nearly nothing.
        #expect(OptimizationObjective.Kind.returnOverDrawdown.score(steady).isFinite)
    }

    @Test func infiniteMetricsNeverBecomeTheScore() {
        let win = BacktestTrade(
            id: 1, direction: .long, entryTime: .distantPast, exitTime: .distantPast,
            entryPrice: 1, exitPrice: 2, quantity: 1, notional: 1,
            grossPnL: 1, fees: 0, funding: 0, netPnL: 1, returnPct: 1,
            bars: 1, exitReason: .signal)
        let metrics = BacktestMetrics(
            trades: [win],
            equityCurve: [EquityPoint(ts: Date(), equity: 100, price: 1),
                          EquityPoint(ts: Date().addingTimeInterval(3_600), equity: 101, price: 1)],
            initialCapital: 100, bar: .h1, freeParameterCount: 1)
        #expect(metrics.profitFactor.isInfinite)
        #expect(OptimizationObjective.Kind.profitFactor.score(metrics).isFinite,
                "an infinite metric must not become an unbeatable score")
    }
}

// MARK: - Multiple testing

@Suite("Multiple-testing guard")
struct StatisticsTests {
    @Test func inverseNormalMatchesKnownQuantiles() {
        #expect(abs(Statistics.inverseNormalCDF(0.5)) < 1e-9)
        #expect(abs(Statistics.inverseNormalCDF(0.975) - 1.959964) < 1e-4)
        #expect(abs(Statistics.inverseNormalCDF(0.025) + 1.959964) < 1e-4)
        #expect(abs(Statistics.inverseNormalCDF(0.99) - 2.326348) < 1e-4)
    }

    @Test func luckThresholdRisesWithTheNumberOfTries() {
        let few = TradingKernel.expectedMaxSharpeUnderNull(trials: 10, years: 1)
        let many = TradingKernel.expectedMaxSharpeUnderNull(trials: 10_000, years: 1)
        #expect(many > few, "more tries means a higher Sharpe is reachable by luck alone")
        #expect(few > 0)
    }

    @Test func luckThresholdFallsWithMoreData() {
        let short = TradingKernel.expectedMaxSharpeUnderNull(trials: 1_000, years: 0.25)
        let long = TradingKernel.expectedMaxSharpeUnderNull(trials: 1_000, years: 4)
        #expect(long < short, "a longer sample makes lucky Sharpes harder to come by")
    }

    @Test func degenerateInputsAreSafe() {
        #expect(TradingKernel.expectedMaxSharpeUnderNull(trials: 1, years: 1) == 0)
        #expect(TradingKernel.expectedMaxSharpeUnderNull(trials: 100, years: 0) == 0)
    }
}

// MARK: - Walk-forward

@Suite("Walk-forward")
struct WalkForwardTests {
    private func trendingCandles(_ count: Int) -> [Candle] {
        var closes: [Double] = []
        var price = 100.0
        for index in 0..<count {
            price += (index % 100) < 80 ? 0.6 : -1.0
            closes.append(price)
        }
        return CandleFixture.make(closes.map {
            (open: $0, high: $0 * 1.002, low: $0 * 0.998, close: $0)
        })
    }

    private func strategy() throws -> CompiledStrategy {
        try StrategyManifest(
            id: "wf", name: "wf",
            market: StrategyMarket(instId: "BTC-USDT", instType: .spot, bar: .h1),
            params: StrategyParameterSet([
                StrategyParameter(name: "fast", value: 8, minimum: 6, maximum: 12),
                StrategyParameter(name: "slow", value: 24, minimum: 20, maximum: 28),
            ]),
            signals: StrategySignals(
                longEntry: "ema(close, fast) crosses_above ema(close, slow)",
                longExit: "ema(close, fast) crosses_below ema(close, slow)"),
            costs: StrategyCosts(feeBps: 10, slippageBps: 5)
        ).compile()
    }

    @Test func producesFoldsWithNonOverlappingOutOfSample() throws {
        let analysis = WalkForwardAnalysis(strategy: try strategy(), folds: 3)
        let result = analysis.run(candles: trendingCandles(1_200))
        #expect(!result.folds.isEmpty)
        for (earlier, later) in zip(result.folds, result.folds.dropFirst()) {
            #expect(earlier.outOfSampleEnd <= later.outOfSampleStart + 1,
                    "out-of-sample stretches must march forward, never revisit")
        }
    }

    @Test func inSampleAlwaysPrecedesOutOfSample() throws {
        let analysis = WalkForwardAnalysis(strategy: try strategy(), folds: 3)
        let result = analysis.run(candles: trendingCandles(1_200))
        for fold in result.folds {
            #expect(fold.inSampleEnd <= fold.outOfSampleEnd,
                    "fitting must never see data from after the trading window")
        }
    }

    @Test func insufficientHistoryIsRefusedNotFaked() throws {
        let analysis = WalkForwardAnalysis(strategy: try strategy(), folds: 8)
        let result = analysis.run(candles: trendingCandles(200))
        #expect(result.folds.isEmpty)
        #expect(result.warnings.contains { $0.contains("历史长度不足") })
        #expect(result.verdict.contains("数据不足"))
    }

    @Test func verdictCallsOutALosingOutOfSample() {
        let losing = (0..<40).map { index in
            EquityPoint(ts: Date(timeIntervalSince1970: Double(index) * 3_600),
                        equity: 1_000 - Double(index) * 5, price: 100)
        }
        let result = WalkForwardResult(
            folds: [WalkForwardFold(
                id: 0, inSampleStart: Date(), inSampleEnd: Date(),
                outOfSampleStart: Date(), outOfSampleEnd: Date(),
                parameters: ["fast": 8],
                inSample: BacktestMetrics(trades: [], equityCurve: [], initialCapital: 1_000,
                                          bar: .h1, freeParameterCount: 1),
                outOfSample: BacktestMetrics(trades: [], equityCurve: losing, initialCapital: 1_000,
                                             bar: .h1, freeParameterCount: 1),
                outOfSampleTrades: [BacktestTrade(
                    id: 1, direction: .long, entryTime: .distantPast, exitTime: .distantPast,
                    entryPrice: 1, exitPrice: 0.9, quantity: 1, notional: 1,
                    grossPnL: -0.1, fees: 0, funding: 0, netPnL: -0.1, returnPct: -10,
                    bars: 1, exitReason: .signal)],
                outOfSampleEquity: losing)],
            stitchedEquity: losing,
            stitchedMetrics: BacktestMetrics(
                trades: [BacktestTrade(
                    id: 1, direction: .long, entryTime: .distantPast, exitTime: .distantPast,
                    entryPrice: 1, exitPrice: 0.9, quantity: 1, notional: 1,
                    grossPnL: -0.1, fees: 0, funding: 0, netPnL: -0.1, returnPct: -10,
                    bars: 1, exitReason: .signal)],
                equityCurve: losing, initialCapital: 1_000, bar: .h1, freeParameterCount: 1),
            objective: OptimizationObjective(), totalTrials: 100, warnings: [])
        #expect(result.verdict.contains("不要投入真金"))
        #expect(result.profitableFolds == 0)
    }
}

// MARK: - Portfolio

@Suite("Portfolio backtest")
struct PortfolioBacktestTests {
    private func result(equities: [Double], prices: [Double]) -> BacktestResult {
        let curve = zip(equities, prices).enumerated().map { index, pair in
            EquityPoint(ts: Date(timeIntervalSince1970: Double(index) * 3_600),
                        equity: pair.0, price: pair.1)
        }
        return BacktestResult(
            strategyId: "s", instId: "X-USDT", bar: .h1,
            start: curve.first?.ts ?? Date(), end: curve.last?.ts ?? Date(),
            barCount: curve.count, initialCapital: equities.first ?? 0,
            finalEquity: equities.last ?? 0, trades: [], equityCurve: curve,
            liquidations: 0, warmupBars: 0, fundingUnmodelled: false,
            metrics: BacktestMetrics(trades: [], equityCurve: curve,
                                     initialCapital: equities.first ?? 0,
                                     bar: .h1, freeParameterCount: 1))
    }

    private func leg(_ id: String, weight: Double, equities: [Double], prices: [Double]) -> PortfolioLeg {
        PortfolioLeg(strategyId: id, strategyName: id, instId: "X-USDT",
                     weight: weight, result: result(equities: equities, prices: prices))
    }

    @Test func equalWeightsAverageTheLegs() {
        let combined = PortfolioBacktest.combine(legs: [
            leg("a", weight: 0.5, equities: [100, 120], prices: [10, 11]),
            leg("b", weight: 0.5, equities: [100, 80], prices: [10, 9]),
        ], initialCapital: 1_000)
        // +20% and −20% at equal weight is flat.
        #expect(abs((combined.equityCurve.last?.equity ?? 0) - 1_000) < 1e-6)
    }

    @Test func weightsShiftTheOutcome() {
        let combined = PortfolioBacktest.combine(legs: [
            leg("a", weight: 0.9, equities: [100, 120], prices: [10, 11]),
            leg("b", weight: 0.1, equities: [100, 80], prices: [10, 9]),
        ], initialCapital: 1_000)
        #expect((combined.equityCurve.last?.equity ?? 0) > 1_000)
    }

    @Test func offsettingLegsDiversifyTheDrawdown() {
        // One leg dips while the other rises: the portfolio never sees either dip.
        let combined = PortfolioBacktest.combine(legs: [
            leg("a", weight: 0.5, equities: [100, 80, 100, 80, 100], prices: [10, 10, 10, 10, 10]),
            leg("b", weight: 0.5, equities: [100, 120, 100, 120, 100], prices: [10, 10, 10, 10, 10]),
        ], initialCapital: 1_000)
        #expect(combined.metrics.maxDrawdownPct < combined.undiversifiedDrawdownPct)
        #expect(combined.diversificationBenefitPct > 0)
    }

    @Test func identicalLegsDiversifyNothing() {
        let equities: [Double] = [100, 80, 100, 80, 100]
        let combined = PortfolioBacktest.combine(legs: [
            leg("a", weight: 0.5, equities: equities, prices: [10, 10, 10, 10, 10]),
            leg("b", weight: 0.5, equities: equities, prices: [10, 10, 10, 10, 10]),
        ], initialCapital: 1_000)
        #expect(abs(combined.metrics.maxDrawdownPct - combined.undiversifiedDrawdownPct) < 1e-6)
        let correlation = combined.correlations.values.first ?? 0
        #expect(abs(correlation - 1) < 1e-6, "identical legs are perfectly correlated")
    }

    @Test func correlationDetectsOppositeMovement() {
        let combined = PortfolioBacktest.combine(legs: [
            leg("a", weight: 0.5, equities: [100, 110, 100, 110], prices: [10, 10, 10, 10]),
            leg("b", weight: 0.5, equities: [100, 90, 100, 90], prices: [10, 10, 10, 10]),
        ], initialCapital: 1_000)
        #expect((combined.correlations.values.first ?? 0) < -0.9)
    }

    @Test func zeroWeightLegsAreIgnored() {
        let combined = PortfolioBacktest.combine(legs: [
            leg("a", weight: 1, equities: [100, 120], prices: [10, 11]),
            leg("b", weight: 0, equities: [100, 10], prices: [10, 1]),
        ], initialCapital: 1_000)
        #expect(abs((combined.equityCurve.last?.equity ?? 0) - 1_200) < 1e-6)
    }

    @Test func emptyInputIsSafe() {
        let combined = PortfolioBacktest.combine(legs: [], initialCapital: 1_000)
        #expect(combined.equityCurve.isEmpty)
        #expect(combined.metrics.totalReturnPct == 0)
    }
}
