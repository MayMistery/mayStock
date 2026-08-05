import Foundation
import Testing
@testable import MayStockKit

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func at(_ minutes: Double) -> Date {
    epoch.addingTimeInterval(minutes * 60)
}

// MARK: - Sampling

@Suite("Equity sampling")
@MainActor
struct EquitySamplingTests {
    @Test func samplesLandInOrder() {
        let curve = AccountEquityCurve(mode: .demo)
        #expect(curve.record(equity: 100, at: at(0)))
        #expect(curve.record(equity: 110, at: at(1)))
        #expect(curve.record(equity: 120, at: at(2)))
        #expect(curve.points.map(\.equity) == [100, 110, 120])
    }

    @Test func samplesTooCloseTogetherAreDropped() {
        // The runner ticks every 20s; the curve keeps one point a minute.
        let curve = AccountEquityCurve(mode: .demo)
        #expect(curve.record(equity: 100, at: at(0)))
        #expect(!curve.record(equity: 101, at: epoch.addingTimeInterval(20)))
        #expect(!curve.record(equity: 102, at: epoch.addingTimeInterval(59)))
        #expect(curve.record(equity: 103, at: epoch.addingTimeInterval(60)))
        #expect(curve.points.count == 2)
    }

    @Test func aBackwardClockCannotCorruptTheOrdering() {
        // NTP corrections and sleep/wake can move the clock backwards. The
        // window lookup assumes ascending timestamps, so this must be refused.
        let curve = AccountEquityCurve(mode: .demo)
        #expect(curve.record(equity: 100, at: at(10)))
        #expect(!curve.record(equity: 999, at: at(5)))
        #expect(curve.points.count == 1)
        #expect(curve.points[0].equity == 100)
    }

    @Test func nonsenseEquityIsRefused() {
        let curve = AccountEquityCurve(mode: .demo)
        #expect(!curve.record(equity: .nan, at: at(0)))
        #expect(!curve.record(equity: .infinity, at: at(1)))
        #expect(!curve.record(equity: 0, at: at(2)))
        #expect(!curve.record(equity: -5, at: at(3)))
        #expect(curve.points.isEmpty)
    }

    @Test func demoAndLiveAreSeparateSeries() {
        let demo = AccountEquityCurve(mode: .demo)
        let live = AccountEquityCurve(mode: .live)
        demo.record(equity: 100, at: at(0))
        #expect(live.points.isEmpty)
        #expect(demo.mode == .demo)
        #expect(live.mode == .live)
    }
}

// MARK: - Windowed returns

@Suite("Trailing returns")
@MainActor
struct TrailingReturnTests {
    /// A curve with one sample a minute for `minutes`, growing steadily.
    private func curve(minutes: Int, from start: Double = 1_000, step: Double = 1) -> AccountEquityCurve {
        let curve = AccountEquityCurve(mode: .demo)
        for index in 0...minutes {
            curve.record(equity: start + Double(index) * step, at: at(Double(index)))
        }
        return curve
    }

    @Test func theReferenceIsTheLastSampleAtOrBeforeTheCutoff() {
        let curve = curve(minutes: 180)          // three hours, +1 per minute
        let now = at(180)
        let change = curve.change(over: .hour1, now: now, latest: 1_180)
        let hour = try! #require(change)
        // One hour back from minute 180 is minute 120 → equity 1_120.
        #expect(hour.startEquity == 1_120)
        #expect(hour.endEquity == 1_180)
        #expect(abs(hour.changeQuote - 60) < 1e-9)
    }

    @Test func aFullWindowReportsCompleteCoverage() {
        let curve = curve(minutes: 180)
        let change = try! #require(curve.change(over: .hour1, now: at(180), latest: 1_180))
        #expect(change.coverage == 1)
        #expect(change.isComplete)
        #expect(change.coverageNote.isEmpty)
    }

    @Test func aShortHistoryIsReportedAsShortNotAsAFullWindow() {
        // Twenty minutes of history cannot answer "how did the last 7 days go".
        // Falling back to the oldest sample is fine; pretending it is a 7-day
        // number is not.
        let curve = curve(minutes: 20)
        let change = try! #require(curve.change(over: .day7, now: at(20), latest: 1_020))
        #expect(!change.isComplete)
        #expect(change.coverage < 0.01)
        #expect(change.coveredSeconds == 20 * 60)
        #expect(!change.coverageNote.isEmpty)
        // The underlying arithmetic is still correct — it is only mislabelled,
        // which is exactly what the coverage field exists to disclose.
        #expect(abs((change.changePct ?? 0) - 2.0) < 1e-9)
    }

    @Test func coverageScalesWithTheWindow() {
        // The same 2-hour history is a complete 1h window and a partial 1d one.
        let curve = curve(minutes: 120)
        let hour = try! #require(curve.change(over: .hour1, now: at(120), latest: 1_120))
        let day = try! #require(curve.change(over: .day1, now: at(120), latest: 1_120))
        #expect(hour.isComplete)
        #expect(!day.isComplete)
        #expect(day.coverage > hour.coverage - 1)  // day coverage ≈ 2/24
        #expect(abs(day.coverage - 120.0 / 1_440.0) < 1e-9)
    }

    @Test func theLiveEquityIsUsedAsTheEndpoint() {
        // The curve records once a minute; the panel marks continuously. The
        // number on screen should be the fresher one.
        let curve = curve(minutes: 120)
        let stored = try! #require(curve.change(over: .hour1, now: at(120)))
        let live = try! #require(curve.change(over: .hour1, now: at(120), latest: 2_000))
        #expect(stored.endEquity == 1_120)
        #expect(live.endEquity == 2_000)
    }

    @Test func anEmptyCurveAnswersNothingRatherThanZero() {
        let curve = AccountEquityCurve(mode: .demo)
        #expect(curve.change(over: .hour1) == nil)
        #expect(curve.change(over: .day1, latest: 1_000) == nil)
        #expect(curve.changes(latest: 1_000).isEmpty)
    }

    @Test func aSingleSampleHasNoSpanToMeasure() {
        let curve = AccountEquityCurve(mode: .demo)
        curve.record(equity: 1_000, at: at(0))
        let change = try! #require(curve.change(over: .hour1, now: at(0), latest: 1_000))
        #expect(change.coveredSeconds == 0)
        #expect(change.coverage == 0)
        #expect(!change.isComplete)
    }

    @Test func lossesCarryTheirSign() {
        let curve = curve(minutes: 120, from: 2_000, step: -1)
        let change = try! #require(curve.change(over: .hour1, now: at(120), latest: 1_880))
        #expect(change.changeQuote < 0)
        #expect((change.changePct ?? 0) < 0)
    }

    @Test func everyWindowIsOffered() {
        #expect(EquityWindow.allCases.map(\.label) == ["1h", "1d", "7d"])
        #expect(EquityWindow.day7.seconds == 7 * 86_400)
    }
}

// MARK: - Compaction

@Suite("Curve compaction")
@MainActor
struct CurveCompactionTests {
    @Test func recentHistoryKeepsFullResolution() {
        let curve = AccountEquityCurve(mode: .demo)
        for index in 0..<600 {                    // ten hours, one per minute
            curve.record(equity: 1_000 + Double(index), at: at(Double(index)))
        }
        #expect(curve.points.count == 600, "inside the fine horizon nothing is thinned")
    }

    @Test func olderHistoryIsThinnedButNotLost() {
        let curve = AccountEquityCurve(mode: .demo)
        // 40 hours at one sample a minute = 2400 raw samples.
        for index in 0..<2_400 {
            curve.record(equity: 1_000 + Double(index), at: at(Double(index)))
        }
        #expect(curve.points.count < 2_400, "the coarse region must be thinned")
        // 25h fine (1500) + 15h coarse at one per 15 min (60) ≈ 1560.
        #expect(curve.points.count > 1_500)
        #expect(curve.points.count < 1_700)
        #expect(curve.recordedSpan > 39 * 3_600, "thinning must not shorten the history")
    }

    @Test func thinningPreservesOrderAndEndpoints() {
        let curve = AccountEquityCurve(mode: .demo)
        for index in 0..<2_400 {
            curve.record(equity: 1_000 + Double(index), at: at(Double(index)))
        }
        let timestamps = curve.points.map(\.ts)
        #expect(timestamps == timestamps.sorted())
        let newest: Double = 1_000 + Double(2_399)
        #expect(curve.points.last?.equity == newest)
        #expect(curve.points.first?.ts == at(0))
    }

    @Test func expiredPointsAreDropped() {
        let curve = AccountEquityCurve(mode: .demo)
        curve.record(equity: 1_000, at: at(0))
        // Jump 40 days forward: the first sample is past the retention horizon.
        curve.record(equity: 2_000, at: at(40 * 24 * 60))
        #expect(curve.points.count == 1)
        #expect(curve.points[0].equity == 2_000)
    }

    @Test func aLongWindowStaysAnswerableAfterThinning() {
        // The 7-day window must survive compaction — it reads from the coarse
        // region, which is precisely the part that gets thinned.
        let curve = AccountEquityCurve(mode: .demo)
        let minutes = 9 * 24 * 60
        for index in stride(from: 0, to: minutes, by: 5) {
            curve.record(equity: 1_000 + Double(index) / 100, at: at(Double(index)))
        }
        let change = try! #require(curve.change(over: .day7, now: at(Double(minutes))))
        #expect(change.isComplete, "seven days of history must answer a seven-day window")
        #expect(change.changeQuote > 0)
    }
}

// MARK: - Normalisation and persistence

@Suite("Equity curve persistence")
@MainActor
struct EquityPersistenceTests {
    @Test func normalisationSortsDedupesAndDropsGarbage() {
        let messy = [
            AccountEquityPoint(ts: at(2), equity: 102),
            AccountEquityPoint(ts: at(0), equity: 100),
            AccountEquityPoint(ts: at(2), equity: 999),   // duplicate timestamp
            AccountEquityPoint(ts: at(1), equity: .nan),  // garbage
            AccountEquityPoint(ts: at(3), equity: -1),    // garbage
        ]
        let clean = AccountEquityCurve.normalise(messy)
        #expect(clean.map(\.equity) == [100, 102])
        #expect(clean.map(\.ts) == [at(0), at(2)])
    }

    @Test func replaceNormalisesWhateverItIsGiven() {
        let curve = AccountEquityCurve(mode: .demo)
        curve.replace(points: [
            AccountEquityPoint(ts: at(5), equity: 105),
            AccountEquityPoint(ts: at(1), equity: 101),
        ])
        #expect(curve.points.map(\.equity) == [101, 105])
    }

    @Test func aCurveRoundTripsThroughDisk() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maystock-equity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountEquityStore(directory: directory, mode: .demo)
        let original = (0..<50).map {
            AccountEquityPoint(ts: at(Double($0)), equity: 1_000 + Double($0))
        }
        try store.save(original)

        let loaded = store.load()
        #expect(loaded.count == original.count)
        #expect(loaded.first == original.first)
        #expect(loaded.last == original.last)
    }

    @Test func aMissingFileLoadsEmptyRatherThanThrowing() {
        let store = AccountEquityStore(
            directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), mode: .live)
        #expect(store.load().isEmpty)
    }

    @Test func modesGetSeparateFiles() {
        let directory = URL(fileURLWithPath: "/tmp")
        let demo = AccountEquityStore(directory: directory, mode: .demo)
        let live = AccountEquityStore(directory: directory, mode: .live)
        #expect(demo.fileURL != live.fileURL)
        #expect(demo.fileURL.lastPathComponent == "equity-demo.json")
    }

    @Test func spanIsDescribedInHumanUnits() {
        #expect(AccountEquityCurve.describe(45) == "45 秒")
        #expect(AccountEquityCurve.describe(20 * 60) == "20 分钟")
        #expect(AccountEquityCurve.describe(3 * 3_600) == "3 小时")
        #expect(AccountEquityCurve.describe(5 * 86_400) == "5 天")
    }
}

// MARK: - Account snapshot parsing

@Suite("Account equity parsing")
struct AccountEquityParsingTests {
    /// The exact shape `okx account balance-all --json` returns.
    private let balanceAll = """
    {
      "trading": {
        "available": true,
        "totalEq": "79542.31467104556",
        "adjEq": "",
        "details": [
          {"availEq": "", "ccy": "USDT", "eq": "79622.66165066771", "frozenBal": "0", "upl": ""},
          {"availEq": "", "ccy": "ETH", "eq": "0.0000379848", "frozenBal": "0", "upl": ""}
        ]
      },
      "funding": {"available": true, "details": []},
      "valuation": {"available": true, "valuationCcy": "USD", "totalBal": "79561.7789709", "details": []},
      "meta": {"source": "aggregate"}
    }
    """

    @Test func totalEquityIsFoundInTheAggregate() {
        let equity = TradeBridge.parseTotalEquity(json: balanceAll)
        #expect(equity != nil)
        #expect(abs((equity ?? 0) - 79_542.31467104556) < 1e-6)
    }

    @Test func unifiedEquityWinsOverTheValuationBlock() {
        // Both are present and they disagree; picking whichever the tree walk
        // happened to hit last would make the number flicker between ticks.
        let equity = try! #require(TradeBridge.parseTotalEquity(json: balanceAll))
        #expect(equity != 79_561.7789709)
    }

    @Test func theValuationBlockIsTheFallback() {
        let json = """
        {"valuation": {"valuationCcy": "USD", "totalBal": "1234.5"}}
        """
        #expect(TradeBridge.parseTotalEquity(json: json) == 1_234.5)
    }

    @Test func anEmptyTotalIsNotZero() {
        // OKX returns "" for fields it has no value for; that is unknown, not
        // an account worth nothing.
        let json = """
        {"trading": {"totalEq": "", "details": [{"ccy": "USDT", "eq": "500"}]}}
        """
        #expect(TradeBridge.parseTotalEquity(json: json) == nil)
    }

    @Test func balancesStillParseAlongsideTheTotal() {
        let balances = TradeBridge.parseBalances(json: balanceAll)
        #expect(balances.count == 2)
        let usdt = try! #require(balances.first { $0.ccy == "USDT" })
        #expect(abs(usdt.total - 79_622.66165066771) < 1e-6)
    }

    @Test func garbageYieldsNothing() {
        #expect(TradeBridge.parseTotalEquity(json: "not json at all") == nil)
        #expect(TradeBridge.parseTotalEquity(json: "") == nil)
    }
}
