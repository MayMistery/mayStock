import Foundation
import Testing
@testable import MayStockKit

/// Regression tests pinning the kernel's arithmetic to known-good values.
///
/// These began life as a differential suite against the Swift engine and were
/// green on every case before that engine was deleted (see `docs/KERNEL.md`).
/// With the second implementation gone there is nothing left to compare
/// against, so the values it agreed on are frozen here instead. Any future edit
/// to the kernel that moves a trade, a fill price or a metric has to change one
/// of these numbers deliberately — which is exactly the review moment that
/// silent numerical drift needs.
///
/// Regenerate with: `MAYSTOCK_PRINT_GOLDENS=1 swift test --filter KernelGolden`
@Suite("Kernel golden")
struct KernelGoldenTests {

    // MARK: Fixtures

    /// Deterministic pseudo-random candles. A fixed LCG rather than
    /// `SystemRandomNumberGenerator` so a failure is reproducible.
    static func candles(_ count: Int, seed: UInt64 = 42, bar: TimeInterval = 3_600) -> [Candle] {
        var state = seed
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        var price = 30_000.0
        var out: [Candle] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            // A trending random walk with occasional regime shifts, so both
            // engines meet entries, exits, stops and gaps.
            let drift = index % 300 < 150 ? 0.0008 : -0.0006
            price *= 1 + drift + (next() - 0.5) * 0.02
            let high = price * (1 + next() * 0.01)
            let low = price * (1 - next() * 0.01)
            let open = low + (high - low) * next()
            out.append(Candle(
                ts: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * bar),
                open: open, high: max(high, max(open, price)),
                low: min(low, min(open, price)),
                close: price, volume: 10 + next() * 100, confirmed: true))
        }
        return out
    }

    static func manifest(
        id: String = "diff",
        instType: String = "SPOT",
        bar: String = "1H",
        params: String = #"[{"name":"fast","default":12,"min":5,"max":50},{"name":"slow","default":26,"min":10,"max":200}]"#,
        signals: String,
        sizing: String = #"{"mode":"equityPct","value":100}"#,
        risk: String = #"{"leverage":1,"cooldownBars":0,"minHoldBars":0}"#,
        costs: String = #"{"feeBps":10,"slippageBps":5}"#
    ) -> String {
        """
        {
          "schema": 1, "id": "\(id)", "name": "differential",
          "market": { "instId": "BTC-USDT", "instType": "\(instType)", "bar": "\(bar)" },
          "params": \(params),
          "signals": \(signals),
          "sizing": \(sizing),
          "risk": \(risk),
          "costs": \(costs)
        }
        """
    }


    /// Compact fingerprint of a whole run. Comparing every trade field would
    /// pin the fixtures rather than the behaviour; these six numbers move if
    /// any fill price, size, cost or exit decision changes.
    struct Golden: Equatable, CustomStringConvertible {
        let trades: Int
        let finalEquity: Double
        let totalReturnPct: Double
        let maxDrawdownPct: Double
        let winRate: Double
        let feesPaid: Double

        init(_ r: KernelBacktestResult) {
            trades = r.trades.count
            finalEquity = (r.finalEquity * 1e6).rounded() / 1e6
            totalReturnPct = (r.metrics.totalReturnPct * 1e6).rounded() / 1e6
            maxDrawdownPct = (r.metrics.maxDrawdownPct * 1e6).rounded() / 1e6
            winRate = (r.metrics.winRate * 1e6).rounded() / 1e6
            feesPaid = (r.metrics.feesPaid * 1e6).rounded() / 1e6
        }

        init(trades: Int, finalEquity: Double, totalReturnPct: Double,
             maxDrawdownPct: Double, winRate: Double, feesPaid: Double) {
            self.trades = trades
            self.finalEquity = finalEquity
            self.totalReturnPct = totalReturnPct
            self.maxDrawdownPct = maxDrawdownPct
            self.winRate = winRate
            self.feesPaid = feesPaid
        }

        var description: String {
            "Golden(trades: \(trades), finalEquity: \(finalEquity), "
            + "totalReturnPct: \(totalReturnPct), maxDrawdownPct: \(maxDrawdownPct), "
            + "winRate: \(winRate), feesPaid: \(feesPaid))"
        }
    }

    private func check(
        _ name: String, _ manifestJSON: String, bars: [Candle],
        capital: Double = 30_000, expect expected: Golden
    ) throws {
        let strategy = try KernelStrategy(manifestJSON: manifestJSON)
        let result = try strategy.backtest(
            candles: bars, config: KernelBacktestConfig(initialCapital: capital))
        let actual = Golden(result)
        if ProcessInfo.processInfo.environment["MAYSTOCK_PRINT_GOLDENS"] != nil {
            print("GOLDEN \(name) \(actual)")
        }
        #expect(actual == expected, "\(name): got \(actual)")
    }

    /// Frozen at the point the Swift engine was deleted, when the two agreed.
    static let GOLDENS: [String: Golden] = [
        "movingAverageCrossover": Golden(
            trades: 20, finalEquity: 29551.924786, totalReturnPct: -1.493584,
            maxDrawdownPct: 14.485792, winRate: 40.0, feesPaid: 1173.391483),
        "stopsAndTargets": Golden(
            trades: 128, finalEquity: 31741.262941, totalReturnPct: 5.80421,
            maxDrawdownPct: 15.768024, winRate: 38.28125, feesPaid: 8109.603144),
        "trailingStop": Golden(
            trades: 77, finalEquity: 26552.616469, totalReturnPct: -11.491278,
            maxDrawdownPct: 25.463248, winRate: 32.467532, feesPaid: 4737.051611),
        "atrRiskSizing": Golden(
            trades: 19, finalEquity: 33016.944843, totalReturnPct: 10.056483,
            maxDrawdownPct: 5.851893, winRate: 42.105263, feesPaid: 424.889859),
        "dailyLossBreaker": Golden(
            trades: 75, finalEquity: 39936.710149, totalReturnPct: 33.122367,
            maxDrawdownPct: 14.97631, winRate: 40.0, feesPaid: 5521.282679),
        "cooldownAndMinHold": Golden(
            trades: 43, finalEquity: 35091.205522, totalReturnPct: 16.970685,
            maxDrawdownPct: 12.86219, winRate: 46.511628, feesPaid: 2837.714358),
        "shortsAndLeverage": Golden(
            trades: 31, finalEquity: 47266.02858, totalReturnPct: 57.553429,
            maxDrawdownPct: 47.016275, winRate: 48.387097, feesPaid: 2124.784382),
        "continuousExposure": Golden(
            trades: 19, finalEquity: 30060.098403, totalReturnPct: 0.200328,
            maxDrawdownPct: 5.124814, winRate: 26.315789, feesPaid: 419.367307),
    ]

    @Test func movingAverageCrossover() throws {
        try check("movingAverageCrossover",
            Self.manifest(signals: """
            {"longEntry": "ema(close, fast) crosses_above ema(close, slow)",
             "longExit": "ema(close, fast) crosses_below ema(close, slow)"}
            """),
            bars: Self.candles(1_200),
            expect: Self.GOLDENS["movingAverageCrossover"]!)
    }
    @Test func stopsAndTargets() throws {
        try check("stopsAndTargets",
            Self.manifest(
                signals: #"{"longEntry": "close > sma(close, 20)", "longExit": "close < sma(close, 20)"}"#,
                risk: #"{"stopLossPct":2,"takeProfitPct":3,"leverage":1}"#),
            bars: Self.candles(1_500, seed: 7),
            expect: Self.GOLDENS["stopsAndTargets"]!)
    }
    @Test func trailingStop() throws {
        try check("trailingStop",
            Self.manifest(
                signals: #"{"longEntry": "close > sma(close, 30)", "longExit": "close < sma(close, 30)"}"#,
                risk: #"{"trailingStopPct":4,"leverage":1}"#),
            bars: Self.candles(1_500, seed: 11),
            expect: Self.GOLDENS["trailingStop"]!)
    }
    @Test func atrRiskSizing() throws {
        try check("atrRiskSizing",
            Self.manifest(
                signals: """
                {"longEntry": "close > ref(highest(high, fast), 1)",
                 "longExit": "close < ref(lowest(low, slow), 1)"}
                """,
                sizing: #"{"mode":"riskPerTrade","value":1}"#,
                risk: #"{"atrStop":{"period":14,"mult":2.5},"leverage":1}"#),
            bars: Self.candles(1_800, seed: 3),
            expect: Self.GOLDENS["atrRiskSizing"]!)
    }
    @Test func dailyLossBreaker() throws {
        try check("dailyLossBreaker",
            Self.manifest(
                bar: "15m",
                signals: #"{"longEntry": "close > sma(close, 10)", "longExit": "close < sma(close, 10)"}"#,
                risk: #"{"maxDailyLossPct":2,"leverage":1}"#),
            bars: Self.candles(2_000, seed: 5, bar: 900),
            expect: Self.GOLDENS["dailyLossBreaker"]!)
    }
    @Test func cooldownAndMinHold() throws {
        try check("cooldownAndMinHold",
            Self.manifest(
                signals: #"{"longEntry": "close > sma(close, 15)", "longExit": "close < sma(close, 15)"}"#,
                risk: #"{"cooldownBars":5,"minHoldBars":8,"leverage":1}"#),
            bars: Self.candles(1_200, seed: 13),
            expect: Self.GOLDENS["cooldownAndMinHold"]!)
    }
    @Test func shortsAndLeverage() throws {
        try check("shortsAndLeverage",
            Self.manifest(
                instType: "SWAP",
                signals: """
                {"longEntry": "ema(close, fast) crosses_above ema(close, slow)",
                 "longExit": "ema(close, fast) crosses_below ema(close, slow)",
                 "shortEntry": "ema(close, fast) crosses_below ema(close, slow)",
                 "shortExit": "ema(close, fast) crosses_above ema(close, slow)"}
                """,
                risk: #"{"leverage":3,"stopLossPct":5}"#,
                costs: #"{"feeBps":5,"slippageBps":5}"#),
            bars: Self.candles(1_500, seed: 17),
            expect: Self.GOLDENS["shortsAndLeverage"]!)
    }
    @Test func continuousExposure() throws {
        try check("continuousExposure",
            Self.manifest(
                signals: #"{"exposure": "clamp(sign(close - ref(close, 90)), -1, 1)"}"#,
                sizing: #"{"mode":"volatilityTarget","value":20}"#,
                risk: #"{"volLookbackBars":60,"maxExposure":1,"rebalanceThreshold":0.1,"leverage":1}"#),
            bars: Self.candles(1_500, seed: 23),
            expect: Self.GOLDENS["continuousExposure"]!)
    }

    // MARK: Semantics that must not drift

    @Test func warmupIsNaNNeverZero() throws {
        let bars = Self.candles(50)
        let sma = try TradingKernel.evaluate("sma(close, 20)", candles: bars)
        #expect(sma[0].isNaN && sma[18].isNaN, "an unfilled window is unknown")
        #expect(!sma[19].isNaN)
    }

    @Test func aDefiniteFalseBeatsAnUnknown() throws {
        // `false and unknown` is false; `true and unknown` stays unknown. This
        // is what stops a strategy trading on a half-warm indicator.
        let bars = Self.candles(50)
        let collapsed = try TradingKernel.evaluate(
            "close > 1e12 and sma(close, 200) > 0", candles: bars)
        #expect(collapsed.allSatisfy { $0 == 0 })
        let unknown = try TradingKernel.evaluate(
            "close > 0 and sma(close, 200) > 0", candles: bars)
        #expect(unknown.allSatisfy { $0.isNaN })
    }

    @Test func theLiveDecisionMatchesTheBacktestBarForBar() throws {
        // The property the whole refactor exists for: walking forward and
        // asking for a live decision must reproduce what the vectorised
        // backtest acted on. One function, two callers.
        let json = Self.manifest(signals: """
        {"longEntry": "ema(close, fast) crosses_above ema(close, slow)",
         "longExit": "ema(close, fast) crosses_below ema(close, slow)"}
        """)
        let kernel = try KernelStrategy(manifestJSON: json)
        let bars = Self.candles(500)
        let entry = try TradingKernel.evaluate(
            "ema(close, fast) crosses_above ema(close, slow)",
            params: ["fast": 12, "slow": 26], candles: bars)
        let exit = try TradingKernel.evaluate(
            "ema(close, fast) crosses_below ema(close, slow)",
            params: ["fast": 12, "slow": 26], candles: bars)

        var held: TradeDirection?
        var checked = 0
        for index in (kernel.warmupBars + 2)..<bars.count {
            let decision = try kernel.decide(
                candles: Array(bars[0...index]), current: held, barsHeld: 99)
            #expect(!decision.warmingUp)
            let expected: TradeDirection?
            if held == nil {
                expected = (!entry[index].isNaN && entry[index] != 0) ? .long : nil
            } else {
                expected = (!exit[index].isNaN && exit[index] != 0) ? nil : .long
            }
            #expect(decision.direction == expected, "bar \(index)")
            held = decision.direction
            checked += 1
        }
        #expect(checked > 300)
    }

    @Test func warmupIsRefusedRatherThanGuessed() throws {
        let kernel = try KernelStrategy(
            manifestJSON: Self.manifest(signals: #"{"longEntry": "close > sma(close, 200)"}"#))
        let decision = try kernel.decide(candles: Self.candles(50), current: nil)
        #expect(decision.warmingUp)
        #expect(decision.direction == nil)
    }

    @Test func brokenManifestsAreRejectedAtImport() throws {
        for signals in [
            #"{"longEntry": "close > (((" }"#,
            #"{"longEntry": "nosuchvariable > 1"}"#,
            #"{"longEntry": "system(close) > 1"}"#,
            #"{"longEntry": "sma(close, close) > 1"}"#,
            #"{"longEntry": "sma(close, 0) > 1"}"#,
            #"{"longEntry": "sma(close, 9999999) > 1"}"#,
        ] {
            let json = Self.manifest(signals: signals)
            var rejected = false
            do { _ = try KernelStrategy(manifestJSON: json) } catch { rejected = true }
            #expect(rejected, "\(signals) must be refused before it can trade")
        }
    }

    @Test func volatilityTargetingScalesAndCaps() throws {
        // A quiet market must not lever the book to the moon; an unknown
        // volatility must size to zero rather than guess.
        let json = Self.manifest(
            signals: #"{"exposure": "1"}"#,
            sizing: #"{"mode":"volatilityTarget","value":20}"#,
            risk: #"{"volLookbackBars":60,"maxExposure":1,"rebalanceThreshold":0.05,"leverage":1}"#)
        let kernel = try KernelStrategy(manifestJSON: json)
        #expect(kernel.isContinuous)
        #expect(kernel.warmupBars >= 61, "the vol lookback has to be primed too")

        let decision = try kernel.decide(candles: Self.candles(400), current: nil)
        let exposure = try #require(decision.targetExposure)
        #expect(exposure > 0 && exposure <= 1, "capped by maxExposure")
    }

    @Test func manyCompilesDoNotLeakOrCrash() throws {
        let json = Self.manifest(signals: #"{"longEntry": "close > sma(close, 20)"}"#)
        let bars = Self.candles(120)
        for _ in 0..<500 {
            let kernel = try KernelStrategy(manifestJSON: json)
            _ = try kernel.decide(candles: bars, current: nil)
        }
    }

    @Test func theKernelReportsAVersion() {
        #expect(!TradingKernel.version.isEmpty)
        #expect(TradingKernel.version != "unknown", "the static library must be linked")
    }
}

/// The property the sizing consolidation exists to guarantee: on the same bar,
/// with the same capital, the live plan and the backtester open the *same*
/// position.
///
/// Before this, the runner sized in Swift and the backtester in Rust. They had
/// already drifted — the Swift copy honoured only a percentage stop, so an
/// ATR-stopped `riskPerTrade` manifest risked 1% of capital per trade in
/// simulation and committed the entire budget live.
@Suite("Live sizing matches the backtest")
struct LiveSizingParityTests {

    private func parity(_ manifestJSON: String, capital: Double = 30_000) throws {
        let kernel = try KernelStrategy(manifestJSON: manifestJSON)
        let bars = KernelGoldenTests.candles(900)
        let result = try kernel.backtest(
            candles: bars, config: KernelBacktestConfig(initialCapital: capital))
        let entry = try #require(result.trades.first, "the fixture must actually trade")

        // Replay up to the bar the backtester decided on — the one *before* the
        // fill, since a signal on bar i fills at the open of bar i+1.
        let entryIndex = try #require(bars.firstIndex { $0.ts >= entry.entryTime })
        let decisionBar = max(entryIndex - 1, 0)
        let plan = try kernel.decide(
            candles: Array(bars[0...decisionBar]),
            current: nil,
            account: KernelAccountState(equity: capital, heldBase: 0, dayStartEquity: capital))

        #expect(plan.shouldTrade, "the backtest opened here, so the plan must too")
        #expect(plan.direction == entry.direction)

        // The backtester fills at the next open plus slippage; the plan sizes
        // off the decision bar's close. Compare notional, which is what sizing
        // actually decides, with room for that one-bar price difference.
        let planned = abs(plan.targetBaseQuantity) * bars[decisionBar].close
        let filled = entry.quantity * entry.entryPrice
        let drift = abs(planned - filled) / filled
        #expect(drift < 0.05, "planned \(planned) vs filled \(filled)")
    }

    @Test func equityPercentAgrees() throws {
        try parity(KernelGoldenTests.manifest(
            signals: #"{"longEntry": "close > sma(close, 20)", "longExit": "close < sma(close, 20)"}"#,
            sizing: #"{"mode":"equityPct","value":60}"#))
    }

    @Test func fixedQuoteAgrees() throws {
        try parity(KernelGoldenTests.manifest(
            signals: #"{"longEntry": "close > sma(close, 20)", "longExit": "close < sma(close, 20)"}"#,
            sizing: #"{"mode":"fixedQuote","value":12000}"#))
    }

    /// The exact case that had diverged.
    @Test func riskPerTradeWithAnAtrStopAgrees() throws {
        try parity(KernelGoldenTests.manifest(
            signals: #"{"longEntry": "close > sma(close, 20)", "longExit": "close < sma(close, 20)"}"#,
            sizing: #"{"mode":"riskPerTrade","value":1}"#,
            risk: #"{"atrStop":{"period":14,"mult":2.5},"leverage":1}"#))
    }

    @Test func riskPerTradeWithAPercentStopAgrees() throws {
        try parity(KernelGoldenTests.manifest(
            signals: #"{"longEntry": "close > sma(close, 20)", "longExit": "close < sma(close, 20)"}"#,
            sizing: #"{"mode":"riskPerTrade","value":1}"#,
            risk: #"{"stopLossPct":3,"leverage":1}"#))
    }

    /// An ATR-stopped riskPerTrade manifest must never commit the whole budget:
    /// that was the live behaviour, and it is a hundredfold over-bet.
    @Test func anAtrStoppedStrategyRisksOnePercentNotEverything() throws {
        let kernel = try KernelStrategy(manifestJSON: KernelGoldenTests.manifest(
            signals: #"{"longEntry": "close > sma(close, 20)"}"#,
            sizing: #"{"mode":"riskPerTrade","value":1}"#,
            risk: #"{"atrStop":{"period":14,"mult":2.5},"leverage":1}"#))
        let bars = KernelGoldenTests.candles(600)
        let plan = try kernel.decide(
            candles: bars, current: nil,
            account: KernelAccountState(equity: 30_000, dayStartEquity: 30_000))
        if plan.shouldTrade {
            let notional = abs(plan.targetBaseQuantity) * bars[bars.count - 1].close
            #expect(notional < 30_000, "sizing by risk must be under the full budget")
        }
    }

    @Test func theDailyLossBreakerIsTheKernelsCall() throws {
        let kernel = try KernelStrategy(manifestJSON: KernelGoldenTests.manifest(
            signals: #"{"longEntry": "close > sma(close, 20)"}"#,
            risk: #"{"maxDailyLossPct":2,"leverage":1}"#))
        let bars = KernelGoldenTests.candles(600)
        // Down 5% on the day, against a 2% limit.
        let plan = try kernel.decide(
            candles: bars, current: .long,
            account: KernelAccountState(
                equity: 28_500, heldBase: 0.4, dayStartEquity: 30_000))
        #expect(plan.haltDailyLoss)
        #expect(plan.target == 0)
        #expect(plan.shouldTrade, "a halt with a position open must close it")
        #expect(abs(plan.baseDelta + 0.4) < 1e-12, "close exactly what is held")
    }

    @Test func theRebalanceThresholdIsTheKernelsCall() throws {
        let json = KernelGoldenTests.manifest(
            signals: #"{"exposure": "1"}"#,
            sizing: #"{"mode":"equityPct","value":100}"#,
            risk: #"{"maxExposure":1,"rebalanceThreshold":0.25,"leverage":1}"#)
        let kernel = try KernelStrategy(manifestJSON: json)
        let bars = KernelGoldenTests.candles(600)
        let price = bars[bars.count - 1].close
        let full = 30_000 / price

        // Already at target — no trade.
        let held = try kernel.decide(
            candles: bars, current: .long,
            account: KernelAccountState(equity: 30_000, heldBase: full, dayStartEquity: 30_000))
        #expect(!held.shouldTrade, "\(held.reason)")

        // Flat against a full target — drift of 1.0 clears the 0.25 threshold.
        let flat = try kernel.decide(
            candles: bars, current: nil,
            account: KernelAccountState(equity: 30_000, heldBase: 0, dayStartEquity: 30_000))
        #expect(flat.shouldTrade)
        #expect(abs(flat.targetBaseQuantity - full) / full < 1e-9)
    }
}

/// Risk controls the live path used to skip entirely.
@Suite("Live risk controls")
struct LiveRiskControlTests {

    private func plan(
        _ manifestJSON: String, current: TradeDirection? = nil,
        account: KernelAccountState = KernelAccountState(equity: 30_000, dayStartEquity: 30_000)
    ) throws -> KernelDecision {
        let kernel = try KernelStrategy(manifestJSON: manifestJSON)
        return try kernel.decide(
            candles: KernelGoldenTests.candles(600), current: current, account: account)
    }

    /// Stops rode along with the order rather than being polled for. A
    /// 20-second poll sleeps straight through the intrabar spike a stop exists
    /// for, and protects nothing at all while the app is closed.
    @Test func anEntryCarriesItsStopAndTarget() throws {
        let decision = try plan(KernelGoldenTests.manifest(
            signals: #"{"longEntry": "close > 0"}"#,
            risk: #"{"stopLossPct":4,"takeProfitPct":8,"leverage":1}"#))
        #expect(decision.shouldTrade)
        let stop = try #require(decision.stopPrice, "a 4% stop must reach the exchange")
        let target = try #require(decision.takeProfitPrice)
        let entry = stop / 0.96
        #expect(stop < entry, "a long's stop sits below it")
        #expect(target > entry, "and its target above")
        #expect(abs(target / entry - 1.08) < 1e-6)
    }

    @Test func anAtrStopAlsoReachesTheExchange() throws {
        let decision = try plan(KernelGoldenTests.manifest(
            signals: #"{"longEntry": "close > 0"}"#,
            sizing: #"{"mode":"riskPerTrade","value":1}"#,
            risk: #"{"atrStop":{"period":14,"mult":2.5},"leverage":1}"#))
        #expect(decision.shouldTrade)
        #expect(decision.stopPrice != nil, "sizing by ATR without exiting by it is half a rule")
    }

    @Test func aStoplessStrategyAttachesNothing() throws {
        let decision = try plan(KernelGoldenTests.manifest(
            signals: #"{"longEntry": "close > 0"}"#))
        #expect(decision.stopPrice == nil)
        #expect(decision.takeProfitPrice == nil)
    }

    /// Cooldown: the backtester waits N bars after an exit before re-entering.
    /// Live used to re-enter on the very next bar.
    @Test func cooldownBlocksAnImmediateReentry() throws {
        let json = KernelGoldenTests.manifest(
            signals: #"{"longEntry": "close > 0"}"#,
            risk: #"{"cooldownBars":5,"leverage":1}"#)
        let blocked = try plan(json, account: KernelAccountState(
            equity: 30_000, dayStartEquity: 30_000, barsSinceExit: 2))
        #expect(!blocked.shouldTrade)
        #expect(blocked.reason.contains("冷却"))

        let allowed = try plan(json, account: KernelAccountState(
            equity: 30_000, dayStartEquity: 30_000, barsSinceExit: 6))
        #expect(allowed.shouldTrade)
    }

    @Test func cooldownNeverBlocksTheFirstEntry() throws {
        let decision = try plan(KernelGoldenTests.manifest(
            signals: #"{"longEntry": "close > 0"}"#,
            risk: #"{"cooldownBars":5,"leverage":1}"#))
        #expect(decision.shouldTrade, "nothing has been exited yet")
    }

    /// The breaker latches for the rest of the day and no longer than that —
    /// the backtester resumes at the UTC boundary, so live must too, or the
    /// backtest counts trades live can never take.
    @Test func theBreakerLatchesForTheDayAndNoLonger() throws {
        let json = KernelGoldenTests.manifest(
            signals: #"{"longEntry": "close > 0"}"#,
            risk: #"{"maxDailyLossPct":2,"leverage":1}"#)
        // Already halted today, but equity has recovered.
        let stillHalted = try plan(json, account: KernelAccountState(
            equity: 30_000, dayStartEquity: 30_000, haltedToday: true))
        #expect(stillHalted.haltDailyLoss)
        #expect(stillHalted.target == 0)

        // A fresh day resets the flag; the runner clears it at the boundary.
        let newDay = try plan(json, account: KernelAccountState(
            equity: 30_000, dayStartEquity: 30_000, haltedToday: false))
        #expect(!newDay.haltDailyLoss)
    }
}
