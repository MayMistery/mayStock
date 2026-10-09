import Foundation
import Testing
@testable import MayStockKit

/// A perpetual's position tiers, from OKX's table to the kernel's ceiling:
/// read in contracts and handed over in base units, held to by a backtest and
/// a live plan alike, and said in the report when they cut a position short
/// or were missing.
@Suite("Position tiers")
struct PositionTierTests {

    /// OKX states each tier's limit in contracts and the kernel counts base
    /// units: a DOGE contract is 1 000 DOGE, so the demo's first tier of 1 500
    /// contracts (2026-10-09) is 1 500 000 DOGE. The table comes back
    /// smallest first whatever order the rows arrived in.
    @Test func okxTiersArriveInBaseUnitsSmallestFirst() async throws {
        let (client, host) = ScriptedHTTP.client([
            .init(status: 200, body: #"""
                {"code":"0","msg":"","data":[{"instId":"DOGE-USDT-SWAP","instFamily":"DOGE-USDT","uly":"DOGE-USDT",
                 "tickSz":"0.0000001","lotSz":"0.01","minSz":"0.01","ctVal":"1000","ctMult":"1"}]}
                """#),
            .init(status: 200, body: #"""
                {"code":"0","msg":"","data":[
                 {"tier":"2","minSz":"1500.01","maxSz":"3000","mmr":"0.01","imr":"0.025","maxLever":"40"},
                 {"tier":"1","minSz":"0","maxSz":"1500","mmr":"0.0065","imr":"0.02","maxLever":"50"}]}
                """#),
        ])
        let tiers = try await client.positionTiers(instId: "DOGE-USDT-SWAP")
        #expect(tiers == [
            KernelPositionTier(maxBase: 1_500_000, maintenanceMarginRate: 0.0065, maxLeverage: 50),
            KernelPositionTier(maxBase: 3_000_000, maintenanceMarginRate: 0.01, maxLeverage: 40),
        ])
        #expect(ScriptedHTTP.paths(for: host) == ["/api/v5/public/instruments", "/api/v5/public/position-tiers"])
    }

    /// A contract whose value cannot be read leaves the table unconvertible:
    /// an error, never a guess at what a contract holds.
    @Test func aContractWithNoValueIsAnError() async {
        let (client, _) = ScriptedHTTP.client([
            .init(status: 200, body: #"""
                {"code":"0","msg":"","data":[{"instId":"X-USDT-SWAP","instFamily":"X-USDT",
                 "tickSz":"0.1","lotSz":"1","minSz":"1"}]}
                """#),
        ])
        await #expect(throws: OKXError.self) { _ = try await client.positionTiers(instId: "X-USDT-SWAP") }
    }

    /// The tiers reach the kernel both ways. A backtest on them holds every
    /// position to the limit its leverage allows and reports the limit and the
    /// orders it cut; one without them says it went without. A live plan
    /// stops at the same limit and says the venue stopped it.
    @Test func aBacktestAndALivePlanStopAtTheSameLimit() throws {
        let strategy = try KernelStrategy(manifestJSON: KernelGoldenTests.manifest(
            instType: "SWAP",
            signals: #"{"longEntry": "close > 0", "longExit": "close < 0"}"#,
            risk: #"{"leverage":10}"#,
            costs: #"{"feeBps":5,"slippageBps":0}"#))
        let bars = KernelGoldenTests.candles(300)
        // Full size at 10× is about ten coins at these prices; the venue allows two.
        let tiers = [
            KernelPositionTier(maxBase: 2, maintenanceMarginRate: 0.004, maxLeverage: 100),
            KernelPositionTier(maxBase: 50, maintenanceMarginRate: 0.01, maxLeverage: 5),
        ]
        let tiered = try strategy.backtest(
            candles: bars, config: KernelBacktestConfig(initialCapital: 30_000, positionTiers: tiers))
        #expect(tiered.positionLimit == 2)
        #expect(tiered.positionLimited > 0)
        #expect(!tiered.positionTiersUnmodelled)
        #expect(!tiered.trades.isEmpty && tiered.trades.allSatisfy { $0.quantity <= 2 * (1 + 1e-12) })

        let bare = try strategy.backtest(candles: bars, config: KernelBacktestConfig(initialCapital: 30_000))
        #expect(bare.positionTiersUnmodelled)
        #expect(bare.positionLimit == nil && bare.positionLimited == 0)

        let plan = try strategy.decide(
            candles: bars, current: nil,
            account: KernelAccountState(equity: 30_000, dayStartEquity: 30_000, positionTiers: tiers))
        #expect(plan.shouldTrade)
        #expect(abs(plan.targetBaseQuantity - 2) < 1e-9, "\(plan.targetBaseQuantity)")
        #expect(plan.reason.contains("交易所档位"), "\(plan.reason)")
    }

    private func result(market: StrategyMarket, unmodelled: Bool, limit: Double?, limited: Int) -> BacktestResult {
        let equity = (0..<50).map {
            EquityPoint(ts: Date(timeIntervalSince1970: Double($0) * 3_600), equity: 1_000, price: 100)
        }
        return BacktestResult(
            strategyId: "s", market: market, start: equity[0].ts, end: equity[49].ts,
            barCount: 50, initialCapital: 1_000, finalEquity: 1_000, trades: [], equityCurve: equity,
            liquidations: 0, warmupBars: 0, fundingUnmodelled: false,
            positionTiersUnmodelled: unmodelled, positionLimit: limit, positionLimited: limited,
            metrics: BacktestMetrics(trades: [], equityCurve: equity, initialCapital: 1_000,
                                     market: market, freeParameterCount: 1))
    }

    /// The report says when a perpetual ran without its tiers, and how often
    /// the venue's limit cut a position the capital would have carried — and
    /// says neither when neither happened.
    @Test func theReportSaysWhatTheTiersDid() {
        let notes = { (result: BacktestResult) in
            RobustnessAssessment.evaluate(results: [.d30: result], market: result.market, freeParameterCount: 1).notes
        }
        let missing = notes(result(market: .hourlySwap, unmodelled: true, limit: nil, limited: 0))
        #expect(missing.contains { $0.contains("没有按交易所的仓位档位回测") })
        let cut = notes(result(market: .hourlySwap, unmodelled: false, limit: 2.5, limited: 3))
        #expect(cut.contains { $0.contains("3 次开仓或加仓被交易所档位截短") && $0.contains("2.5 BTC") }, "\(cut)")
        let quiet = notes(result(market: .hourlySwap, unmodelled: false, limit: 2.5, limited: 0))
        #expect(!quiet.contains { $0.contains("档位") }, "\(quiet)")
    }
}
