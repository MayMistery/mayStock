import Foundation
import Testing
@testable import MayStockKit

// MARK: - Fakes

/// A feed that records what it was asked and emits whatever a test says.
actor FakeFeed: MarketFeed {
    nonisolated let venue: Venue
    private(set) var subscribed: [String: BarInterval] = [:]
    private var handler: (@Sendable (MarketFeedEvent) -> Void)?

    init(venue: Venue) { self.venue = venue }

    func setHandler(_ handler: @escaping @Sendable (MarketFeedEvent) -> Void) { self.handler = handler }
    func subscribe(instId: String, bar: BarInterval) { subscribed[instId] = bar }
    func unsubscribe(instId: String, bar: BarInterval) { subscribed[instId] = nil }
    func switchBar(instId: String, from old: BarInterval, to new: BarInterval) { subscribed[instId] = new }
    func emit(_ event: MarketFeedEvent) { handler?(event) }
}

struct FakeSource: MarketDataSource {
    let venue: Venue
    func ticker(instId: String) async throws -> Ticker { throw MarketDataError.transport("offline") }
    func candles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle] { [] }
    func historyCandles(instId: String, bar: BarInterval, target: Int,
                        progress: (@Sendable (Int) -> Void)?) async throws -> [Candle] { [] }
    func instrumentMeta(instId: String) async throws -> InstrumentMeta? { nil }
    func book(instId: String, depth: Int) async throws -> OrderBook? { nil }
    func search(_ query: String) async throws -> [InstrumentMatch] { [] }
}

/// Wait for a condition the hub reaches through a task hop.
@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

// MARK: - Hub

@Suite("Market hub")
@MainActor
struct MarketHubTests {
    private func makeHub() -> (MarketHub, FakeFeed, FakeFeed) {
        let okx = FakeFeed(venue: .okx)
        let schwab = FakeFeed(venue: .schwab)
        let hub = MarketHub(
            feeds: [okx, schwab],
            sources: [FakeSource(venue: .okx), FakeSource(venue: .schwab)])
        return (hub, okx, schwab)
    }

    @Test func eachItemSubscribesOnItsOwnVenue() async {
        let (hub, okx, schwab) = makeHub()
        hub.setWatchlist([WatchItem(instId: "BTC-USDT"), WatchItem(venue: .schwab, instId: "TSLA")])
        #expect(await eventually { await okx.subscribed["BTC-USDT"] == .m1 })
        #expect(await eventually { await schwab.subscribed["TSLA"] == .m1 })
        #expect(await okx.subscribed["TSLA"] == nil, "a stock never reaches the crypto feed")
        #expect(hub.session(for: "TSLA")?.venue == .schwab)
        #expect(hub.session(for: "BTC-USDT")?.venue == .okx)
        #expect(hub.activeVenues == [.okx, .schwab])
    }

    @Test func feedHealthIsPerVenue() async {
        let (hub, _, schwab) = makeHub()
        hub.setWatchlist([WatchItem(instId: "BTC-USDT"), WatchItem(venue: .schwab, instId: "TSLA")])
        #expect(await eventually { await schwab.subscribed["TSLA"] != nil })
        await schwab.emit(.state(.connected))
        #expect(await eventually { hub.feedState(for: .schwab) == .connected })
        #expect(hub.feedState(for: .okx) == .idle, "one venue's health says nothing about another's")
        #expect(hub.session(for: "TSLA")?.connection == .connected)
        #expect(hub.session(for: "BTC-USDT")?.connection == .idle)
    }

    @Test func aTickerFromTheWrongVenueIsIgnored() async {
        let (hub, okx, schwab) = makeHub()
        hub.setWatchlist([WatchItem(venue: .schwab, instId: "TSLA")])
        #expect(await eventually { await schwab.subscribed["TSLA"] != nil })
        let stray = Ticker(instId: "TSLA", last: 1, bid: nil, ask: nil, reference: 1, high: 1, low: 1,
                           volume: 0, basis: .rolling24h, ts: Date())
        await okx.emit(.ticker(stray))
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(hub.session(for: "TSLA")?.ticker == nil)
        let real = Ticker(instId: "TSLA", last: 350, bid: nil, ask: nil, reference: 340, high: 351, low: 339,
                          volume: 1_000, basis: .previousClose, phase: .regular, ts: Date())
        await schwab.emit(.ticker(real))
        #expect(await eventually { hub.session(for: "TSLA")?.ticker?.last == 350 })
        #expect(hub.session(for: "TSLA")?.marketPhase == .regular)
    }

    @Test func aBarTheVenueCannotServeIsRefused() async {
        let (hub, _, schwab) = makeHub()
        hub.setWatchlist([WatchItem(venue: .schwab, instId: "QQQ", defaultBar: .h4)])
        #expect(await eventually { await schwab.subscribed["QQQ"] != nil })
        // The default fell back to the venue's finest bar rather than a
        // subscription nothing would ever answer.
        #expect(hub.session(for: "QQQ")?.bar == .m1)
        hub.switchBar(instId: "QQQ", to: .h4)
        #expect(hub.session(for: "QQQ")?.bar == .m1)
        hub.switchBar(instId: "QQQ", to: .d1)
        #expect(hub.session(for: "QQQ")?.bar == .d1)
    }

    @Test func removingAnItemUnsubscribesItsVenue() async {
        let (hub, _, schwab) = makeHub()
        hub.setWatchlist([WatchItem(venue: .schwab, instId: "TSLA")])
        #expect(await eventually { await schwab.subscribed["TSLA"] != nil })
        hub.setWatchlist([])
        #expect(await eventually { await schwab.subscribed["TSLA"] == nil })
        #expect(hub.session(for: "TSLA") == nil)
        #expect(hub.activeVenues.isEmpty)
    }
}

// MARK: - Yahoo wire

@Suite("Yahoo wire")
struct YahooWireTests {
    /// Cut down from a real TSLA one-minute chart, 2026-09-04: pre-market
    /// 08:00–13:30Z, regular 13:30–20:00Z, post 20:00–00:00Z.
    static let chart = """
    {"chart":{"result":[{"meta":{"currency":"USD","symbol":"TSLA","exchangeName":"NMS",
    "fullExchangeName":"NasdaqGS","instrumentType":"EQUITY","regularMarketTime":1788552000,
    "gmtoffset":-14400,"timezone":"EDT","exchangeTimezoneName":"America/New_York",
    "regularMarketPrice":354.08,"regularMarketDayHigh":364.69,"regularMarketDayLow":351.32,
    "regularMarketVolume":65018209,"longName":"Tesla, Inc.","chartPreviousClose":376.365,
    "previousClose":376.365,"priceHint":2,
    "currentTradingPeriod":{"pre":{"timezone":"EDT","start":1788508800,"end":1788528600,"gmtoffset":-14400},
    "regular":{"timezone":"EDT","start":1788528600,"end":1788552000,"gmtoffset":-14400},
    "post":{"timezone":"EDT","start":1788552000,"end":1788566400,"gmtoffset":-14400}},
    "dataGranularity":"1m","range":"1d","validRanges":["1d","5d"]},
    "timestamp":[1788528600,1788528660,1788528720,1788552000],
    "indicators":{"quote":[{"open":[360.0,359.5,null,354.1],"high":[361.0,360.2,null,354.4],
    "low":[359.0,358.8,null,353.9],"close":[359.6,359.0,null,352.89],"volume":[120000,98000,null,5000]}]}}],
    "error":null}}
    """

    private func decoded(_ body: String = Self.chart) throws -> YahooChart {
        switch try YahooWire.decodeChart(Data(body.utf8)) {
        case .success(let chart): return chart
        case .failure(let error): throw error
        }
    }

    @Test func aPriceWithoutMarketTimeCannotBecomeANewQuote() throws {
        let body = #"{"chart":{"result":[{"meta":{"symbol":"TSLA","regularMarketPrice":354.08},"timestamp":[],"indicators":{"quote":[]}}],"error":null}}"#
        let chart = try decoded(body)
        let now = Date(timeIntervalSince1970: 1_788_848_000)
        #expect(YahooWire.ticker(from: chart, now: now) == nil)
        #expect(YahooWire.ticker(from: chart, now: now.addingTimeInterval(3_600)) == nil,
                "polling again must not manufacture a newer trade time")
    }

    @Test func aClosedMarketQuoteKeepsItsReportedTradeTime() throws {
        let body = #"{"chart":{"result":[{"meta":{"symbol":"TSLA","regularMarketPrice":354.08,"regularMarketTime":1788552000},"timestamp":[],"indicators":{"quote":[]}}],"error":null}}"#
        let chart = try decoded(body)
        let now = Date(timeIntervalSince1970: 1_788_848_000)
        let quote = try #require(YahooWire.ticker(from: chart, now: now))
        let later = try #require(YahooWire.ticker(from: chart, now: now.addingTimeInterval(3_600)))
        #expect(quote.last == 354.08)
        #expect(quote.ts == Date(timeIntervalSince1970: 1_788_552_000))
        #expect(later.ts == quote.ts)
        #expect(now.timeIntervalSince(quote.ts) > 300)
    }

    @Test func anExtendedSessionPrintSuppliesItsOwnTimeWithoutMetadataTime() throws {
        let body = Self.chart.replacingOccurrences(of: #""regularMarketTime":1788552000,"#, with: "")
        let chart = try decoded(body)
        let quote = try #require(YahooWire.ticker(from: chart, now: Date(timeIntervalSince1970: 1_788_560_000)))
        #expect(quote.last == 352.89)
        #expect(quote.ts == chart.bars.last?.ts)
        #expect(quote.phase == .afterHours)
    }

    @Test func theQuoteReadsTheChartTheWayAStockAppDoes() throws {
        let chart = try decoded()
        // 15:00Z: the regular session is running.
        let ticker = try #require(YahooWire.ticker(from: chart, now: Date(timeIntervalSince1970: 1_788_534_000)))
        #expect(ticker.instId == "TSLA")
        #expect(ticker.last == 352.89, "the latest print, extended hours included")
        #expect(ticker.reference == 376.365, "the previous regular close")
        #expect(ticker.basis == .previousClose)
        #expect(ticker.phase == .regular)
        #expect(ticker.high == 364.69 && ticker.low == 351.32, "Yahoo's own day figures win over the bars")
        #expect(ticker.volume == 65_018_209)
        #expect(ticker.open == 360.0, "the first regular-session bar's open")
        #expect(abs(ticker.changePct - (352.89 - 376.365) / 376.365 * 100) < 1e-9)
    }

    @Test func thePhaseFollowsTheClockAgainstTheChartsOwnPeriods() throws {
        let chart = try decoded()
        func phase(_ ts: TimeInterval) -> MarketPhase { YahooWire.phase(of: chart, now: Date(timeIntervalSince1970: ts)) }
        #expect(phase(1_788_510_000) == .preMarket)
        #expect(phase(1_788_530_000) == .regular)
        #expect(phase(1_788_560_000) == .afterHours)
        #expect(phase(1_788_570_000) == .closed, "past the post session")
        #expect(phase(1_788_500_000) == .closed, "before the pre session")
    }

    @Test func aBarThatNeverPrintedIsNotACandle() throws {
        let chart = try decoded()
        let now = Date(timeIntervalSince1970: 1_788_552_030)
        let candles = YahooWire.candles(from: chart, bar: .m1, now: now)
        #expect(candles.count == 3, "the null row is dropped")
        #expect(candles.map(\.close) == [359.6, 359.0, 352.89])
        #expect(candles[0].confirmed && candles[1].confirmed)
        #expect(!candles[2].confirmed, "the bar opened thirty seconds ago is still forming")
    }

    @Test func everyBarIntervalHasAnAnswer() {
        for bar in BarInterval.allCases {
            #expect((YahooWire.interval(for: bar) != nil) == Venue.schwab.supportedBars.contains(bar), "\(bar)")
        }
    }

    @Test func anUnknownSymbolIsNamedNotGuessed() throws {
        let body = #"{"chart":{"result":null,"error":{"code":"Not Found","description":"No data found, symbol may be delisted"}}}"#
        guard case .failure(let error) = try YahooWire.decodeChart(Data(body.utf8)) else {
            Issue.record("a refusal decoded as a chart"); return
        }
        #expect(error == .unknownInstrument("No data found, symbol may be delisted"))
    }

    @Test func searchKeepsUSListingsOnly() throws {
        let body = """
        {"quotes":[{"symbol":"TSLA","shortname":"Tesla, Inc.","quoteType":"EQUITY","exchange":"NMS","exchDisp":"NASDAQ"},
        {"symbol":"YTSL.NE","shortname":"TESLA YIELD","quoteType":"ETF","exchange":"NEO","exchDisp":"NEO"},
        {"symbol":"TSLA=F","shortname":"future","quoteType":"FUTURE","exchange":"NMS","exchDisp":"NASDAQ"},
        {"symbol":"QQQ","longname":"Invesco QQQ Trust","quoteType":"ETF","exchange":"NGM","exchDisp":"NASDAQ"}]}
        """
        let matches = try YahooWire.matches(from: Data(body.utf8))
        #expect(matches.map(\.instId) == ["TSLA", "QQQ"])
        #expect(matches.allSatisfy { $0.instType == .stock })
        #expect(matches[1].name == "Invesco QQQ Trust")
    }

    @Test func listingMetaTicksInCents() throws {
        let meta = YahooWire.meta(from: try decoded())
        #expect(meta.instId == "TSLA")
        #expect(abs(meta.tickSize - 0.01) < 1e-12)
        #expect(meta.lotSize == 1 && meta.minSize == 1)
        #expect(meta.contractValue == nil, "a share is its own unit")
    }
}

// MARK: - Windows

@Suite("Spark windows")
struct SparkWindowTests {
    /// Samples across two New York days: Thursday 2026-09-03 afternoon and
    /// Friday 2026-09-04 morning, one a minute.
    private func buffer() -> SparklineBuffer {
        var spark = SparklineBuffer.standard(for: .schwab)
        let thursday = Date(timeIntervalSince1970: 1_788_460_000)   // 2026-09-03 19:06:40Z
        let friday = Date(timeIntervalSince1970: 1_788_530_000)     // 2026-09-04 13:53:20Z
        for minute in 0..<30 {
            spark.sample(price: 100 + Double(minute), at: thursday.addingTimeInterval(Double(minute) * 60))
        }
        for minute in 0..<30 {
            spark.sample(price: 200 + Double(minute), at: friday.addingTimeInterval(Double(minute) * 60))
        }
        return spark
    }

    @Test func theSessionWindowIsTheLatestNewYorkDay() {
        let now = Date(timeIntervalSince1970: 1_788_540_000)
        let points = SparkWindow.session.points(from: buffer(), venue: .schwab, now: now)
        #expect(points.count == 30)
        #expect(points.allSatisfy { $0.price >= 200 }, "Thursday's samples are another session")
    }

    @Test func aWeekOfDaysHoldsBothSessions() {
        let now = Date(timeIntervalSince1970: 1_788_540_000)
        #expect(SparkWindow.days(7).points(from: buffer(), venue: .schwab, now: now).count == 60)
        // Trailing minutes are read literally: an hour back from 14:26Z on
        // Friday holds Friday's thirty samples and nothing of Thursday's.
        let midMorning = Date(timeIntervalSince1970: 1_788_532_000)
        #expect(SparkWindow.trailing(minutes: 60).points(from: buffer(), venue: .schwab, now: midMorning).count == 30)
        #expect(SparkWindow.trailing(minutes: 60).points(from: buffer(), venue: .schwab, now: now).isEmpty,
                "two hours after the last print, an hour's window is empty — which is why a stock draws sessions")
    }

    @Test func aSessionVenueKeepsAWeek() {
        #expect(SparklineBuffer.standard(for: .schwab).retention >= 7 * 24 * 3_600)
        #expect(SparklineBuffer.standard(for: .okx).retention < 2 * 24 * 3_600)
    }

    @Test func theMenuBarWindowReadsMinutesByVenue() {
        #expect(WatchItem(instId: "BTC-USDT", sparklineMinutes: 1_440).sparkWindow == .trailing(minutes: 1_440))
        #expect(WatchItem(venue: .schwab, instId: "TSLA", sparklineMinutes: 60).sparkWindow == .trailing(minutes: 60))
        #expect(WatchItem(venue: .schwab, instId: "TSLA", sparklineMinutes: 1_440).sparkWindow == .session)
        #expect(WatchItem(venue: .schwab, instId: "TSLA", sparklineMinutes: 7 * 1_440).sparkWindow == .days(7))
    }
}

// MARK: - Venue declarations

@Suite("Venue market-data declarations")
struct VenueMarketDataTests {
    /// The Swift flag that frames a day must agree with the kernel's calendar
    /// for the same venue — the kernel is the authority on when a market is
    /// open, and a venue framed as continuous here but as sessions there
    /// would draw one thing and backtest another.
    @Test func continuityMatchesTheKernelCalendar() throws {
        for venue in Venue.allCases {
            let market = StrategyMarket(instId: "X", instType: venue.instrumentTypes[0], bar: .h1, venue: venue)
            let strategy = try StrategyManifest(
                id: "v", name: "v", market: market, signals: StrategySignals(longEntry: "close > 1")).compile()
            let info = try strategy.kernel.describe()
            #expect(venue.tradesContinuously == (info.calendar == "continuous"),
                    "\(venue): Swift says \(venue.tradesContinuously), kernel calendar is \(info.calendar)")
        }
    }

    @Test func everyVenueDeclaresItsDataShape() {
        for venue in Venue.allCases {
            #expect(!venue.supportedBars.isEmpty)
            #expect(!venue.marketDataSourceName.isEmpty)
            #expect(venue.changeBasis == (venue.tradesContinuously ? .rolling24h : .previousClose))
            for bar in venue.supportedBars {
                #expect(BarInterval.allCases.contains(bar))
            }
        }
        #expect(MarketDataSources().source(for: .okx).venue == .okx)
        #expect(MarketDataSources().source(for: .schwab).venue == .schwab)
    }

    @Test func alertSummariesNameThePeriodTheVenueUses() {
        let rule = AlertRule.Condition.changePct24hAbove(5)
        #expect(rule.summary(basis: .rolling24h) == "24h ≥ +5%")
        #expect(rule.summary(basis: .previousClose) == "今日 ≥ +5%")
        let event = AlertEvent(rule: AlertRule(instId: "TSLA", condition: rule), price: 350, basis: .previousClose)
        #expect(event.title == "TSLA  今日 ≥ +5%")
    }

    @Test func aStockWatchItemReadsAsItsTicker() {
        let tesla = WatchItem(venue: .schwab, instId: "TSLA")
        #expect(tesla.displayLabel == "TSLA")
        #expect(tesla.glyph == nil, "a share has no coin glyph")
        #expect(WatchItem(instId: "BTC-USDT-SWAP").displayLabel == "BTC⚡︎")
    }
}
