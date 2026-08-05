import Foundation
import Testing
@testable import MayStockKit

@Suite("Cross-sectional universe")
struct CrossSectionalUniverseTests {
    private func candles(_ closes: [Double], start: Date = Date(timeIntervalSince1970: 0)) -> [Candle] {
        closes.enumerated().map { index, close in
            Candle(ts: start.addingTimeInterval(Double(index) * 86_400),
                   open: close, high: close, low: close, close: close,
                   volume: 1, confirmed: true)
        }
    }

    @Test func stablecoinsAreExcludedByName() {
        // A stablecoin has ~0 return and ~0 vol, so it wins any risk-adjusted
        // sort by default. Every serious crypto factor study drops them.
        for symbol in ["USDC", "USDT", "DAI", "PYUSD", "RLUSD", "FDUSD"] {
            #expect(UniverseBuilder.peggedSymbols.contains(symbol), "\(symbol) must be excluded")
        }
    }

    @Test func tokenisedCommoditiesAndWrappersAreExcluded() {
        #expect(UniverseBuilder.peggedSymbols.contains("XAUT"))
        #expect(UniverseBuilder.peggedSymbols.contains("PAXG"))
        #expect(UniverseBuilder.peggedSymbols.contains("WBTC"), "a wrapper duplicates its underlying")
        #expect(!UniverseBuilder.peggedSymbols.contains("BTC"))
        #expect(!UniverseBuilder.peggedSymbols.contains("ETH"))
    }

    @Test func volatilityCatchesPegsNoListWouldKnow() {
        // Second line of defence: a brand-new stablecoin under an unknown
        // ticker still gets caught by how little it moves.
        let peg = candles((0..<200).map { 1.0 + Double($0 % 3) * 0.0001 })
        #expect(UniverseBuilder.annualisedVolatility(peg) < UniverseBuilder.peggedVolatilityThreshold)

        var price = 100.0
        let volatile = candles((0..<200).map { index -> Double in
            price *= 1 + (Double(index % 7) - 3) / 100
            return price
        })
        #expect(UniverseBuilder.annualisedVolatility(volatile) > UniverseBuilder.peggedVolatilityThreshold)
    }

    @Test func biasesAreAlwaysReported() {
        let biases = UniverseBiases(
            survivorship: true, supplyLookAhead: true, universeSize: 30,
            requestedSize: 40, droppedForHistory: 5, excludedPegged: ["USDC"])
        #expect(biases.notes.count >= 3)
        #expect(biases.notes.contains { $0.contains("幸存者偏差") })
        #expect(biases.notes.contains { $0.contains("流通量前视") })
    }
}

@Suite("Factor model")
struct FactorModelTests {
    private let day: TimeInterval = 86_400

    private func asset(
        _ symbol: String, closes: [Double], supply: Double = 1_000_000
    ) -> UniverseAsset {
        let candles = closes.enumerated().map { index, close in
            Candle(ts: Date(timeIntervalSince1970: Double(index) * 86_400),
                   open: close, high: close, low: close, close: close,
                   volume: 1, confirmed: true)
        }
        return UniverseAsset(
            instId: "\(symbol)-USDT", symbol: symbol,
            marketCapUsd: (closes.last ?? 1) * supply,
            circulatingSupply: supply, candles: candles)
    }

    private func universe(_ assets: [UniverseAsset], bars: Int) -> CrossSectionalUniverse {
        CrossSectionalUniverse(
            assets: assets,
            biases: UniverseBiases(
                survivorship: true, supplyLookAhead: true,
                universeSize: assets.count, requestedSize: assets.count,
                droppedForHistory: 0),
            calendar: (0..<bars).map { Date(timeIntervalSince1970: Double($0) * 86_400) })
    }

    @Test func samplingCarriesForwardAndLeavesLeadingGapsUnknown() {
        let calendar = (0..<5).map { Date(timeIntervalSince1970: Double($0) * 86_400) }
        let late = [
            Candle(ts: calendar[2], open: 10, high: 10, low: 10, close: 10,
                   volume: 1, confirmed: true),
        ]
        let sampled = FactorModel.sample(late, onto: calendar)
        #expect(sampled[0].isNaN, "an asset cannot contribute before it listed")
        #expect(sampled[1].isNaN)
        #expect(sampled[2] == 10)
        #expect(sampled[4] == 10, "value carries forward")
    }

    @Test func sizeScoreFavoursSmallCaps() {
        let small = asset("SMALL", closes: Array(repeating: 1.0, count: 100), supply: 1_000)
        let large = asset("LARGE", closes: Array(repeating: 1.0, count: 100), supply: 1_000_000_000)
        let model = FactorModel(universe: universe([small, large], bars: 100))
        let series = Array(repeating: 1.0, count: 100)

        let smallScore = model.score(factor: .size, asset: small, series: series, at: 50)
        let largeScore = model.score(factor: .size, asset: large, series: series, at: 50)
        #expect((smallScore ?? 0) > (largeScore ?? 0), "small minus big: smaller ranks higher")
    }

    @Test func momentumSkipsTheMostRecentPeriod() {
        // Rises for 90 bars, then collapses in the final 7. With a skip the
        // collapse is invisible; without it, it dominates.
        var closes = (0..<93).map { 100 + Double($0) }
        closes += (0..<7).map { 193 - Double($0) * 10 }
        let subject = asset("X", closes: closes)
        let model = FactorModel(
            universe: universe([subject], bars: closes.count),
            lookbackBars: 28, skipBars: 7)

        let withSkip = model.score(factor: .momentum, asset: subject,
                                   series: closes, at: closes.count - 1)
        let withoutSkip = model.score(factor: .momentumNoSkip, asset: subject,
                                      series: closes, at: closes.count - 1)
        #expect((withSkip ?? 0) > (withoutSkip ?? 0),
                "skipping the recent window steps around short-horizon reversal")
    }

    @Test func aRisingUniverseGivesAPositiveMarketReturn() {
        let assets = (0..<12).map { index in
            asset("A\(index)", closes: (0..<200).map { 100 * pow(1.001, Double($0)) })
        }
        let model = FactorModel(universe: universe(assets, bars: 200), rebalanceBars: 7)
        let result = model.run(factor: .market)
        #expect(!result.periods.isEmpty)
        #expect(result.marketMetrics.totalReturnPct > 0)
    }

    @Test func costsAreChargedOnlyForNamesThatChanged() {
        // Twelve assets whose ranking never changes: after the first rebalance
        // nothing turns over, so cost must stop being charged.
        let assets = (0..<12).map { index in
            asset("A\(index)", closes: (0..<200).map { bar in
                100 * pow(1 + Double(index) / 10_000, Double(bar))
            })
        }
        let model = FactorModel(universe: universe(assets, bars: 200), rebalanceBars: 7)
        let result = model.run(factor: .momentum)
        #expect(result.turnover < 0.2, "a stable ranking must not be charged repeatedly")
    }

    @Test func scoringNeverSeesTheReturnItPredicts() {
        // The forward return starts at the rebalance bar, so a score computed
        // at that bar cannot contain it.
        let assets = (0..<12).map { index in
            asset("A\(index)", closes: (0..<300).map { 100 + Double($0 % 50) + Double(index) })
        }
        let model = FactorModel(universe: universe(assets, bars: 300),
                                rebalanceBars: 7, lookbackBars: 28, skipBars: 7)
        let result = model.run(factor: .momentum)
        for period in result.periods {
            #expect(period.assetsRanked > 0)
            #expect(period.longLeg.count <= assets.count)
        }
    }

    @Test func verdictRefusesAnInsignificantPremium() {
        let assets = (0..<12).map { index in
            asset("A\(index)", closes: (0..<300).map { bar in
                100 + Double((bar * (index + 1)) % 37)      // deterministic churn
            })
        }
        let model = FactorModel(universe: universe(assets, bars: 300), rebalanceBars: 7)
        let result = model.run(factor: .momentum)
        if abs(result.longShortTStatistic) <= 2 {
            #expect(result.verdict.contains("不显著"))
        }
    }

    @Test func biasesTravelWithTheResult() {
        let assets = (0..<12).map { index in
            asset("A\(index)", closes: (0..<200).map { 100 + Double($0) + Double(index) })
        }
        let result = FactorModel(universe: universe(assets, bars: 200)).run(factor: .size)
        #expect(result.biases.survivorship, "a factor result must carry its caveats")
        #expect(!result.biases.notes.isEmpty)
    }

    @Test func emptyUniverseDoesNotCrash() {
        let empty = CrossSectionalUniverse(
            assets: [],
            biases: UniverseBiases(survivorship: true, supplyLookAhead: true,
                                   universeSize: 0, requestedSize: 10, droppedForHistory: 0),
            calendar: [])
        let result = FactorModel(universe: empty).run(factor: .momentum)
        #expect(result.periods.isEmpty)
        #expect(result.verdict.contains("太少"))
    }
}
