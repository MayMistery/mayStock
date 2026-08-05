import Foundation
import Testing
@testable import MayStockKit

@Suite("Sparkline buffer")
struct SparklineBufferTests {
    private let t0 = Date(timeIntervalSince1970: 1_783_500_000)

    private func candles(from start: Date, count: Int, step: TimeInterval, price: Double) -> [Candle] {
        (0..<count).map { index in
            Candle(ts: start.addingTimeInterval(Double(index) * step),
                   open: price, high: price, low: price, close: price + Double(index),
                   volume: 1, confirmed: true)
        }
    }

    @Test func keepsAFullDayOfHistory() {
        var buffer = SparklineBuffer()
        // 24h of one-minute bars, then a live tick right at the end.
        buffer.seed(candles: candles(from: t0.addingTimeInterval(-86_400), count: 1_440,
                                     step: 60, price: 100))
        buffer.sample(price: 200, at: t0)

        let day = buffer.window(minutes: 1_440, now: t0)
        #expect(day.count > 1_400)
        // The old 1 800-sample ring could not reach past 30 minutes.
        #expect(day.first!.ts <= t0.addingTimeInterval(-86_000))
        #expect(day.last!.price == 200)
    }

    @Test func liveSamplesNeverEvictTheDayOfHistory() {
        var buffer = SparklineBuffer()
        buffer.seed(candles: candles(from: t0.addingTimeInterval(-86_400), count: 1_440,
                                     step: 60, price: 100))
        // Two hours of one-per-second ticks — 7 200 samples, four times what
        // the whole buffer used to hold.
        for second in 0..<7_200 {
            buffer.sample(price: 150, at: t0.addingTimeInterval(Double(second)))
        }
        let now = t0.addingTimeInterval(7_199)
        #expect(buffer.window(minutes: 1_440, now: now).count > 1_000)
        #expect(buffer.window(minutes: 5, now: now).count == 301) // inclusive of the cutoff
        // Bounded memory: fine tier + coarse tier, not 24h × 1Hz.
        #expect(buffer.points.count < 12_000)
    }

    @Test func compactsAgedSamplesToOnePerMinute() {
        var buffer = SparklineBuffer(fineWindow: 300, coarseInterval: 60, retention: 3_600)
        for second in 0..<1_200 {
            buffer.sample(price: Double(second), at: t0.addingTimeInterval(Double(second)))
        }
        // Everything older than the 5-minute fine window is now minute-grade…
        #expect(buffer.coarse.count <= 18)
        // …and the recent window is still second-grade.
        #expect(buffer.fine.count >= 290)
        #expect(buffer.last?.price == 1_199)
    }

    @Test func seedsAtMultipleResolutionsWithoutTouchingLiveData() {
        var buffer = SparklineBuffer()
        buffer.sample(price: 999, at: t0)
        // Coarse seed first (wide reach), then a fine seed refining recent hours.
        buffer.seed(candles: candles(from: t0.addingTimeInterval(-86_400), count: 288,
                                     step: 300, price: 100))
        buffer.seed(candles: candles(from: t0.addingTimeInterval(-18_000), count: 300,
                                     step: 60, price: 500))

        let window = buffer.window(minutes: 1_440, now: t0)
        #expect(window.first!.ts <= t0.addingTimeInterval(-86_000)) // coarse reach survived
        #expect(window.last!.price == 999)                          // live sample untouched
        // The fine seed refined the last 5 hours beyond 5-minute spacing.
        let recent = buffer.window(minutes: 60, now: t0)
        #expect(recent.count > 12)
    }

    @Test func rejectsOutOfOrderAndOverFrequentSamples() {
        var buffer = SparklineBuffer()
        buffer.sample(price: 100, at: t0)
        buffer.sample(price: 101, at: t0.addingTimeInterval(0.2)) // too soon
        buffer.sample(price: 102, at: t0.addingTimeInterval(-5))  // in the past
        buffer.sample(price: 103, at: t0.addingTimeInterval(1))
        #expect(buffer.points.map(\.price) == [100, 103])
    }

    @Test func windowReturnsExactlyTheTrailingSpan() {
        var buffer = SparklineBuffer()
        let now = Date(timeIntervalSince1970: 10_000)
        for second in 0..<600 {
            buffer.sample(price: 100 + Double(second) * 0.01,
                          at: now.addingTimeInterval(Double(second - 600)))
        }
        #expect(buffer.window(minutes: 5, now: now).count == 300)
        #expect(buffer.movePct(minutes: 5, now: now)! > 0)
    }

    @Test func seedingIsIdempotent() {
        var buffer = SparklineBuffer()
        let bars = candles(from: Date(timeIntervalSince1970: 0), count: 10, step: 60, price: 1)
        buffer.seed(candles: bars)
        #expect(buffer.points.count == 10)
        buffer.seed(candles: bars)
        #expect(buffer.points.count == 10)
    }

    @Test func movePctUsesTheWindowNotTheWholeBuffer() {
        var buffer = SparklineBuffer()
        buffer.sample(price: 100, at: t0)
        buffer.sample(price: 110, at: t0.addingTimeInterval(600))
        let now = t0.addingTimeInterval(600)
        #expect(buffer.movePct(minutes: 30, now: now)! == 10)
        #expect(buffer.movePct(minutes: 5, now: now) == nil) // only one point in window
    }
}

@Suite("Chart maths")
struct ChartMathTests {
    private let t0 = Date(timeIntervalSince1970: 1_783_500_000)

    @Test func valueTicksLandOnRoundNumbers() {
        let ticks = ChartMath.valueTicks(lo: 118_116, hi: 118_352, target: 4)
        #expect(!ticks.isEmpty)
        #expect(ticks.allSatisfy { $0 >= 118_116 && $0 <= 118_352 })
        #expect(ticks.allSatisfy { $0.truncatingRemainder(dividingBy: 50) == 0 })
    }

    @Test func valueTicksSurviveDegenerateRanges() {
        #expect(ChartMath.valueTicks(lo: 5, hi: 5).isEmpty)
        #expect(ChartMath.valueTicks(lo: 10, hi: 1).isEmpty)
        #expect(ChartMath.valueTicks(lo: 0, hi: .infinity).isEmpty)
    }

    @Test func timeTicksAlignToWallClock() {
        let zone = TimeZone(identifier: "UTC")!
        // 09:03 → 10:03 should label 09:15, 09:30, 09:45, 10:00 — not 09:03.
        let start = Date(timeIntervalSince1970: 1_783_500_180)
        let ticks = ChartMath.timeTicks(from: start, to: start.addingTimeInterval(3_600),
                                        maxLabels: 5, timeZone: zone)
        #expect(!ticks.isEmpty)
        for tick in ticks {
            #expect(tick.timeIntervalSince1970.truncatingRemainder(dividingBy: 900) == 0)
        }
        #expect(ticks.count <= 5)
    }

    @Test func timeTicksStayWithinTheRequestedLabelBudget() {
        for span in [300.0, 900, 3_600, 14_400, 86_400] {
            let ticks = ChartMath.timeTicks(from: t0, to: t0.addingTimeInterval(span), maxLabels: 5)
            #expect(ticks.count <= 5, "span \(span) produced \(ticks.count) labels")
            #expect(!ticks.isEmpty, "span \(span) produced no labels")
        }
    }

    @Test func candleAxisTicksSitOnBoundariesNotArbitraryIndices() {
        let zone = TimeZone(identifier: "UTC")!
        // 96 one-minute bars starting at 09:03 UTC.
        let start = Date(timeIntervalSince1970: 1_783_500_180)
        let stamps = (0..<96).map { start.addingTimeInterval(Double($0) * 60) }
        let ticks = ChartMath.axisTicks(timestamps: stamps, maxLabels: 5,
                                        barSeconds: 60, timeZone: zone)
        #expect(!ticks.isEmpty)
        #expect(ticks.count <= 5)
        // Every label is a round half hour.
        for tick in ticks {
            #expect(tick.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1_800) == 0)
        }
    }

    @Test func candleAxisTicksFillTheBudgetInsteadOfOvershooting() {
        let zone = TimeZone(identifier: "UTC")!
        // ~3 months of daily bars: weekly boundaries overshoot the budget and
        // monthly ones leave only two labels, so the row gets thinned weeks.
        let start = Date(timeIntervalSince1970: 1_775_000_000)
        let stamps = (0..<90).map { start.addingTimeInterval(Double($0) * 86_400) }
        let ticks = ChartMath.axisTicks(timestamps: stamps, maxLabels: 5,
                                        barSeconds: 86_400, timeZone: zone)
        #expect(ticks.count > 2)
        #expect(ticks.count <= 5)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // Still on real calendar boundaries, not arbitrary indices: either every
        // label is the same weekday (weeks) or the same day of month (months).
        let weekdays = Set(ticks.map { calendar.component(.weekday, from: $0.date) })
        let monthDays = Set(ticks.map { calendar.component(.day, from: $0.date) })
        #expect(weekdays.count == 1 || monthDays.count == 1)
        #expect(ticks.allSatisfy { $0.isMajor })
    }

    @Test func candleAxisTicksThinADenserRungWhenTheCoarserOneIsTooSparse() {
        let zone = TimeZone(identifier: "UTC")!
        // ~7 weeks of daily bars: weekly boundaries overshoot, monthly ones
        // leave a near-empty axis, so the weekly rung gets thinned.
        let start = Date(timeIntervalSince1970: 1_775_000_000)
        let stamps = (0..<50).map { start.addingTimeInterval(Double($0) * 86_400) }
        let ticks = ChartMath.axisTicks(timestamps: stamps, maxLabels: 5,
                                        barSeconds: 86_400, timeZone: zone)
        #expect(ticks.count >= 3)
        #expect(ticks.count <= 5)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let weekdays = Set(ticks.map { calendar.component(.weekday, from: $0.date) })
        let monthDays = Set(ticks.map { calendar.component(.day, from: $0.date) })
        #expect(weekdays.count == 1 || monthDays.count == 1)
    }

    @Test func candleAxisTicksMarkDayBoundariesAsMajor() {
        let zone = TimeZone(identifier: "UTC")!
        // Hourly bars spanning three days.
        let start = Date(timeIntervalSince1970: 1_783_468_800) // 00:00 UTC
        let stamps = (0..<72).map { start.addingTimeInterval(Double($0) * 3_600) }
        let ticks = ChartMath.axisTicks(timestamps: stamps, maxLabels: 5,
                                        barSeconds: 3_600, timeZone: zone)
        #expect(ticks.contains { $0.isMajor })
    }

    @Test func movingAverageCoversFullHistoryNotJustTheTail() {
        let values = (1...25).map(Double.init)
        let ma = ChartMath.movingAverage(values, period: 20)
        #expect(ma.prefix(19).allSatisfy { $0 == nil })
        #expect(ma[19] == 10.5)  // mean of 1...20
        #expect(ma[24] == 15.5)  // mean of 6...25
    }

    @Test func downsamplePreservesEndpointsAndExtremes() {
        let points = (0..<2_000).map { index in
            SparkPoint(ts: Date(timeIntervalSince1970: 1_783_500_000 + Double(index)),
                       price: index == 1_234 ? 9_999 : Double(index % 17))
        }
        let reduced = ChartMath.downsample(points, buckets: 100)
        #expect(reduced.count < 300)
        #expect(reduced.first == points.first)
        #expect(reduced.last == points.last)
        #expect(reduced.contains { $0.price == 9_999 }) // the spike survives
        #expect(zip(reduced, reduced.dropFirst()).allSatisfy { $0.ts <= $1.ts })
    }

    @Test func downsampleLeavesSmallSeriesAlone() {
        let points = (0..<10).map {
            SparkPoint(ts: Date(timeIntervalSince1970: Double($0)), price: Double($0))
        }
        #expect(ChartMath.downsample(points, buckets: 100) == points)
    }
}

@Suite("Depth profile")
struct DepthProfileTests {
    private func book(levels: Int, tick: Double = 1) -> OrderBook {
        let mid = 1_000.0
        let bids = (0..<levels).map {
            BookLevel(price: mid - 0.5 - Double($0) * tick, size: 1)
        }
        let asks = (0..<levels).map {
            BookLevel(price: mid + 0.5 + Double($0) * tick, size: 2)
        }
        return OrderBook(instId: "T-USDT", bids: bids, asks: asks,
                         ts: Date(timeIntervalSince1970: 0))
    }

    @Test func windowClipsTheBookAndRescalesTheSizeAxis() throws {
        let book = book(levels: 100)
        let wide = try #require(book.profile(withinPct: 1.0))
        let tight = try #require(book.profile(withinPct: 0.1))

        // ±0.1% of 1000 is ±1.0, so only the levels next to the touch survive…
        #expect(tight.hi - tight.lo < wide.hi - wide.lo)
        #expect(tight.bids.count < wide.bids.count)
        // …and the axis rescales, which is what makes zooming reveal anything.
        #expect(tight.maxCumulative < wide.maxCumulative)
        #expect(tight.lo < tight.mid && tight.mid < tight.hi)
    }

    @Test func windowNarrowsToTheBookWhenItIsTooShallow() throws {
        let shallow = book(levels: 3)
        let profile = try #require(shallow.profile(withinPct: 5))
        #expect(profile.clampedToBook)
        #expect(profile.spanPct < 5)
        // Both sides still reach the edge rather than stopping in mid-air.
        #expect(profile.bids.last!.price == profile.lo)
        #expect(profile.asks.last!.price == profile.hi)
    }

    @Test func imbalanceReflectsTheVisibleWindow() throws {
        let profile = try #require(book(levels: 50).profile(withinPct: nil))
        // Asks carry twice the size per level.
        #expect(profile.askTotal > profile.bidTotal)
        #expect(profile.imbalance < 0)
        #expect(abs(profile.imbalance + 1.0 / 3.0) < 1e-9)
    }

    @Test func emptyOrCrossedBooksProduceNoProfile() {
        let empty = OrderBook(instId: "T-USDT", bids: [], asks: [], ts: Date())
        #expect(empty.profile(withinPct: 1) == nil)
        let oneSided = OrderBook(instId: "T-USDT",
                                 bids: [BookLevel(price: 10, size: 1)], asks: [],
                                 ts: Date())
        #expect(oneSided.profile(withinPct: 1) == nil)
    }

    @Test func spreadIsReportedInBasisPoints() throws {
        let book = book(levels: 5)
        #expect(book.spread == 1)
        let bps = try #require(book.spreadBps)
        #expect(abs(bps - 10) < 1e-9)
    }
}

@Suite("Interval switching")
@MainActor
struct BarSwitchTests {
    private func series(_ bar: BarInterval, count: Int) -> [Candle] {
        (0..<count).map { index in
            Candle(ts: Date(timeIntervalSince1970: Double(index) * bar.seconds),
                   open: 100, high: 101, low: 99, close: 100, volume: 1, confirmed: true)
        }
    }

    @Test func keepsTheOldSeriesOnScreenUntilTheBackfillLands() {
        let session = InstrumentSession(instId: "T-USDT", bar: .m1)
        session.finishBackfill(series(.m1, count: 100), for: .m1)
        #expect(session.isBackfilling == false)

        session.beginBarSwitch(to: .h1)
        #expect(session.isBackfilling)
        // The chart still has something to draw — no empty-state flash.
        #expect(session.displayCandles.candles.count == 100)
        #expect(session.displayCandles.bar == .m1)

        // A lone websocket push for the new interval must not become the chart.
        session.apply(candles: series(.h1, count: 1), reset: false)
        #expect(session.displayCandles.bar == .m1)

        session.finishBackfill(series(.h1, count: 300), for: .h1)
        #expect(session.isBackfilling == false)
        #expect(session.displayCandles.bar == .h1)
        #expect(session.displayCandles.candles.count == 300)
        #expect(session.staleCandles.isEmpty)
    }

    @Test func aStaleBackfillNeverOverwritesANewerInterval() {
        let session = InstrumentSession(instId: "T-USDT", bar: .m1)
        session.finishBackfill(series(.m1, count: 50), for: .m1)
        session.beginBarSwitch(to: .h1)
        session.beginBarSwitch(to: .d1)

        session.finishBackfill(series(.h1, count: 300), for: .h1) // late, wrong interval
        #expect(session.isBackfilling)
        #expect(session.bar == .d1)
        #expect(session.candles.isEmpty)

        session.finishBackfill(series(.d1, count: 200), for: .d1)
        #expect(session.displayCandles.bar == .d1)
    }

    @Test func aFailedBackfillStopsTheSpinner() {
        let session = InstrumentSession(instId: "T-USDT", bar: .m1)
        session.finishBackfill(series(.m1, count: 50), for: .m1)
        session.beginBarSwitch(to: .h4)
        session.failBackfill(for: .h4)
        #expect(session.isBackfilling == false)
    }
}
