import Foundation
import Testing
@testable import MayStockKit

@Suite("Swing detection")
struct SwingDetectionTests {
    private func candles(_ closes: [Double]) -> [Candle] {
        CandleFixture.flat(closes)
    }

    @Test func detectsAlternatingExtremes() {
        // 100 → 120 → 100 → 130: two completed swings, up then down.
        var closes: [Double] = []
        closes += stride(from: 100.0, through: 120.0, by: 2).map { $0 }
        closes += stride(from: 118.0, through: 100.0, by: -2).map { $0 }
        closes += stride(from: 102.0, through: 130.0, by: 2).map { $0 }

        let swings = ForesightAnalysis.swings(candles: candles(closes), minimumSwingPct: 5)
        #expect(swings.count >= 2)
        #expect(swings[0].isUp)
        #expect(!swings[1].isUp, "swings must alternate direction")
    }

    @Test func noiseBelowTheThresholdIsIgnored() {
        // ±1% wobble cannot produce 10% swings.
        let closes = (0..<200).map { 100 + Double($0 % 3) }
        let swings = ForesightAnalysis.swings(candles: candles(closes), minimumSwingPct: 10)
        #expect(swings.isEmpty)
    }

    @Test func aLargerThresholdFindsFewerSwings() {
        var price = 100.0
        var closes: [Double] = []
        for index in 0..<600 {
            let step: Double = Double((index / 20) % 2 == 0 ? 1 : -1) * 0.01
            price *= (1.0 + step)
            closes.append(price)
        }
        let fine = ForesightAnalysis.swings(candles: candles(closes), minimumSwingPct: 3)
        let coarse = ForesightAnalysis.swings(candles: candles(closes), minimumSwingPct: 15)
        #expect(fine.count >= coarse.count)
    }

    @Test func amplitudeMatchesTheEndpoints() {
        var closes: [Double] = []
        closes += stride(from: 100.0, through: 150.0, by: 5).map { $0 }
        closes += stride(from: 145.0, through: 100.0, by: -5).map { $0 }
        let swings = ForesightAnalysis.swings(candles: candles(closes), minimumSwingPct: 10)
        if let first = swings.first {
            let expected = (first.endPrice / first.startPrice - 1) * 100
            #expect(abs(first.amplitudePct - expected) < 1e-9)
        }
    }

    @Test func degenerateInputIsSafe() {
        #expect(ForesightAnalysis.swings(candles: [], minimumSwingPct: 5).isEmpty)
        #expect(ForesightAnalysis.swings(candles: candles([100]), minimumSwingPct: 5).isEmpty)
        #expect(ForesightAnalysis.swings(candles: candles([100, 101]), minimumSwingPct: 0).isEmpty)
    }
}

@Suite("Perfect foresight ceiling")
struct PerfectForesightTests {
    @Test func perfectTradingBeatsBuyAndHold() {
        // A round trip up and back: buy-and-hold ends flat, perfect foresight
        // captures both legs.
        var closes: [Double] = []
        closes += stride(from: 100.0, through: 200.0, by: 5).map { $0 }
        closes += stride(from: 195.0, through: 100.0, by: -5).map { $0 }
        let result = ForesightAnalysis.perfectForesight(
            candles: CandleFixture.flat(closes), minimumSwingPct: 10, roundTripCostPct: 0)
        #expect(abs(result.buyHoldReturnPct) < 1e-9)
        #expect(result.perfectReturnPct > 100, "catching both legs must beat sitting still")
    }

    @Test func longOnlyGivesUpTheDownSwings() {
        var closes: [Double] = []
        closes += stride(from: 100.0, through: 200.0, by: 5).map { $0 }
        closes += stride(from: 195.0, through: 100.0, by: -5).map { $0 }
        let result = ForesightAnalysis.perfectForesight(
            candles: CandleFixture.flat(closes), minimumSwingPct: 10, roundTripCostPct: 0)
        #expect(result.perfectLongOnlyReturnPct < result.perfectReturnPct)
        #expect(result.perfectLongOnlyReturnPct > 0)
    }

    @Test func costsBiteHarderTheMoreSwingsYouTake() {
        var price = 100.0
        var closes: [Double] = []
        for index in 0..<800 {
            let step: Double = Double((index / 15) % 2 == 0 ? 1 : -1) * 0.012
            price *= (1.0 + step)
            closes.append(price)
        }
        let candles = CandleFixture.flat(closes)
        let free = ForesightAnalysis.perfectForesight(
            candles: candles, minimumSwingPct: 5, roundTripCostPct: 0)
        let costly = ForesightAnalysis.perfectForesight(
            candles: candles, minimumSwingPct: 5, roundTripCostPct: 0.3)
        #expect(costly.perfectReturnPct < free.perfectReturnPct)
        #expect(costly.swings.count == free.swings.count, "cost must not change the swings")
    }

    @Test func theCeilingIsAstronomicalAndThatIsThePoint() {
        // Even a handful of perfectly-timed swings compounds absurdly. The
        // ceiling is never the binding constraint — identification is.
        var price = 100.0
        var closes: [Double] = []
        for index in 0..<1_000 {
            let step: Double = Double((index / 25) % 2 == 0 ? 1 : -1) * 0.015
            price *= (1.0 + step)
            closes.append(price)
        }
        let result = ForesightAnalysis.perfectForesight(
            candles: CandleFixture.flat(closes), minimumSwingPct: 10, roundTripCostPct: 0.3)
        #expect(result.perfectReturnPct > result.buyHoldReturnPct)
        #expect(result.perfectDailyPct > 0)
    }
}

@Suite("Level reliability")
struct LevelReliabilityTests {
    @Test func aPerfectRangeShowsAHighHoldRate() {
        // Price bounces cleanly between 100 and 120 — levels should hold.
        var closes: [Double] = []
        for _ in 0..<10 {
            closes += stride(from: 100.0, through: 120.0, by: 2).map { $0 }
            closes += stride(from: 118.0, through: 100.0, by: -2).map { $0 }
        }
        let level = ForesightAnalysis.levelReliability(
            candles: CandleFixture.flat(closes), minimumSwingPct: 10,
            tolerancePct: 1, targetPct: 5, roundTripCostPct: 0)
        if level.tests > 3 { #expect(level.holdRate > 0.5) }
    }

    @Test func aCleanTrendShowsLevelsBreaking() {
        // A relentless uptrend: every prior high is taken out.
        var price = 100.0
        var closes: [Double] = []
        for _ in 0..<400 {
            price *= 1.01
            closes.append(price)
        }
        let level = ForesightAnalysis.levelReliability(
            candles: CandleFixture.flat(closes), minimumSwingPct: 5,
            tolerancePct: 0.5, targetPct: 2, roundTripCostPct: 0)
        if level.tests > 3 { #expect(level.holdRate < 0.5, "a trend breaks its own levels") }
    }

    @Test func theZStatisticScalesWithSampleSize() {
        // The same 60% means very different things at n=10 and n=1000.
        let small = LevelReliability(
            tests: 10, held: 6, broken: 4,
            averageBouncePct: 2, averageBreakPct: 2, expectancyPct: 0)
        let large = LevelReliability(
            tests: 1_000, held: 600, broken: 400,
            averageBouncePct: 2, averageBreakPct: 2, expectancyPct: 0)
        #expect(abs(small.holdRate - large.holdRate) < 1e-9)
        #expect(large.zStatistic > small.zStatistic * 5)
        #expect(!small.isSignificant)
        #expect(large.isSignificant)
    }

    @Test func aCoinFlipScoresZero() {
        let fair = LevelReliability(
            tests: 100, held: 50, broken: 50,
            averageBouncePct: 2, averageBreakPct: 2, expectancyPct: 0)
        #expect(abs(fair.zStatistic) < 1e-9)
        #expect(!fair.isSignificant)
    }

    @Test func annualEdgeCountsHowOftenTheChanceAppears() {
        // The same per-bet edge is worth far more if it shows up weekly.
        let rare = LevelReliability(
            tests: 10, held: 6, broken: 4,
            averageBouncePct: 2, averageBreakPct: 2, expectancyPct: 1)
        let frequent = LevelReliability(
            tests: 100, held: 60, broken: 40,
            averageBouncePct: 2, averageBreakPct: 2, expectancyPct: 1)
        #expect(frequent.annualEdgePct(overDays: 365) > rare.annualEdgePct(overDays: 365))
    }

    @Test func noTouchesIsReportedNotFaked() {
        let closes = (0..<50).map { 100 + Double($0) * 0.001 }
        let level = ForesightAnalysis.levelReliability(
            candles: CandleFixture.flat(closes), minimumSwingPct: 50)
        #expect(level.tests == 0)
        #expect(level.zStatistic == 0)
        #expect(level.annualEdgePct(overDays: 365) == 0)
    }

    @Test func expectancySubtractsTheRoundTrip() {
        // A 60% hit rate on a symmetric ±2% bet is +0.4% gross; costs take 0.3%.
        var closes: [Double] = []
        for _ in 0..<10 {
            closes += stride(from: 100.0, through: 120.0, by: 2).map { $0 }
            closes += stride(from: 118.0, through: 100.0, by: -2).map { $0 }
        }
        let free = ForesightAnalysis.levelReliability(
            candles: CandleFixture.flat(closes), minimumSwingPct: 10,
            tolerancePct: 1, targetPct: 5, roundTripCostPct: 0)
        let costly = ForesightAnalysis.levelReliability(
            candles: CandleFixture.flat(closes), minimumSwingPct: 10,
            tolerancePct: 1, targetPct: 5, roundTripCostPct: 0.3)
        #expect(abs((free.expectancyPct - costly.expectancyPct) - 0.3) < 1e-9)
    }
}
