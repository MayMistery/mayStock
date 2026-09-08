import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Client

/// Yahoo Finance's public chart endpoint, read the way a browser reads it.
///
/// The interim source for US equities while the Schwab Trader API application
/// is pending: no key, no account, prints for US listings that lag the tape
/// by seconds, one-minute bars with both extended sessions, and a symbol
/// search. It is not a contract — Yahoo has changed and gated these endpoints
/// before (the v7 quote endpoint now wants a cookie and a crumb, which is why
/// quotes here are read off the chart's own `meta` block) — so nothing
/// outside this file names Yahoo: the app reaches it through
/// `MarketDataSource` and `MarketFeed`, and the day Schwab's market data is
/// wired in, this file stops being used without a page noticing.
public struct YahooFinanceClient: MarketDataSource, Sendable {
    /// The venue whose instruments this quotes. Yahoo is a data source, not a
    /// venue: a stock still trades at Schwab, this is only where its price
    /// comes from for now.
    public let venue = Venue.schwab
    public let baseURL: URL
    public let searchURL: URL
    private let session: URLSession

    /// What Yahoo serves per interval, measured 2026-09: one-minute bars for
    /// the last seven days, five- and fifteen-minute bars for sixty, hourly
    /// for two years, daily and weekly as far back as the listing goes.
    static let intradayLookback: [BarInterval: TimeInterval] = [
        .m1: 7 * 86_400,
        .m5: 59 * 86_400,
        .m15: 59 * 86_400,
        .h1: 729 * 86_400,
    ]

    public init(
        baseURL: URL = URL(string: "https://query1.finance.yahoo.com")!,
        searchURL: URL = URL(string: "https://query2.finance.yahoo.com")!,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.searchURL = searchURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Requests

    private func data(base: URL, path: String, query: [String: String]) async throws -> Data {
        var components = URLComponents(
            url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw MarketDataError.transport("bad url") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Yahoo answers a bare client with a 429 page; it answers a browser.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) MayStock", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            #if canImport(FoundationNetworking)
            (data, response) = try await session.compatData(for: request)
            #else
            (data, response) = try await session.data(for: request)
            #endif
        } catch {
            throw MarketDataError.transport(String(describing: error))
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // A refusal for an unknown symbol still carries the JSON error
            // block, which is the message worth surfacing.
            if let chart = try? YahooWire.decodeChart(data), case .failure(let error) = chart {
                throw error
            }
            throw MarketDataError.transport("HTTP \(http.statusCode)")
        }
        return data
    }

    /// One chart request: the instrument's `meta` block plus its bars.
    public func chart(
        symbol: String, interval: String, period: YahooPeriod, includePrePost: Bool
    ) async throws -> YahooChart {
        var query = ["interval": interval, "includePrePost": includePrePost ? "true" : "false"]
        switch period {
        case .range(let range):
            query["range"] = range
        case .between(let from, let to):
            query["period1"] = String(Int(from.timeIntervalSince1970))
            query["period2"] = String(Int(to.timeIntervalSince1970))
        }
        let data = try await data(base: baseURL, path: "v8/finance/chart/\(symbol)", query: query)
        switch try YahooWire.decodeChart(data) {
        case .success(let chart): return chart
        case .failure(let error): throw error
        }
    }

    // MARK: MarketDataSource

    public func ticker(instId: String) async throws -> Ticker {
        let chart = try await chart(symbol: instId, interval: "1m", period: .range("1d"), includePrePost: true)
        guard let ticker = YahooWire.ticker(from: chart) else {
            throw MarketDataError.decoding("\(instId) 的图表里没有可用的价格")
        }
        return ticker
    }

    public func candles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle] {
        try await historyCandles(instId: instId, bar: bar, target: target, progress: nil)
    }

    public func historyCandles(
        instId: String, bar: BarInterval, target: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> [Candle] {
        guard target > 0 else { return [] }
        guard let interval = YahooWire.interval(for: bar) else {
            throw MarketDataError.api("\(venue.displayName)的行情源没有 \(bar.rawValue) K 线")
        }
        let now = Date()
        let lookback: TimeInterval
        if let intraday = Self.intradayLookback[bar] {
            lookback = intraday
        } else {
            // Daily and weekly go as far back as asked: bars are sessions, and
            // a calendar day holds 252/365 of one. Ten percent of slack covers
            // holidays and the odd missing row.
            let days = Double(target) * bar.seconds / 86_400 * 365.25 / 252 * 1.1 + 7
            lookback = days * 86_400
        }
        let chart = try await chart(
            symbol: instId, interval: interval,
            period: .between(now.addingTimeInterval(-lookback), now), includePrePost: false)
        let candles = YahooWire.candles(from: chart, bar: bar, now: now)
        progress?(candles.count)
        return candles.count > target ? Array(candles.suffix(target)) : candles
    }

    public func instrumentMeta(instId: String) async throws -> InstrumentMeta? {
        do {
            let chart = try await chart(symbol: instId, interval: "1d", period: .range("5d"), includePrePost: false)
            return YahooWire.meta(from: chart)
        } catch MarketDataError.unknownInstrument {
            return nil
        }
    }

    /// Yahoo's public data carries no book to draw.
    public func book(instId: String, depth: Int) async throws -> OrderBook? { nil }

    public func search(_ query: String) async throws -> [InstrumentMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let data = try await data(
            base: searchURL, path: "v1/finance/search",
            query: ["q": trimmed, "quotesCount": "8", "newsCount": "0", "listsCount": "0"])
        return try YahooWire.matches(from: data)
    }
}

/// How far back a chart request reaches.
public enum YahooPeriod: Sendable, Equatable {
    /// One of Yahoo's named ranges: `1d`, `5d`, `1mo`, `max`…
    case range(String)
    case between(Date, Date)
}

// MARK: - Decoded chart

/// One instrument's chart response, decoded to what the app needs.
public struct YahooChart: Sendable, Equatable {
    public struct Period: Sendable, Equatable {
        public let start: Date
        public let end: Date
        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }
        public func contains(_ date: Date) -> Bool { date >= start && date < end }
    }

    public struct Bar: Sendable, Equatable {
        public let ts: Date
        public let open: Double?
        public let high: Double?
        public let low: Double?
        public let close: Double?
        public let volume: Double?
    }

    public let symbol: String
    public let currency: String?
    /// Yahoo's short exchange code ("NMS") and its display name ("NasdaqGS").
    public let exchangeCode: String?
    public let exchangeName: String?
    public let longName: String?
    public let regularMarketPrice: Double?
    public let previousClose: Double?
    public let regularMarketTime: Date?
    public let regularDayHigh: Double?
    public let regularDayLow: Double?
    public let regularVolume: Double?
    /// Fraction digits Yahoo quotes the instrument to.
    public let priceHint: Int?
    public let preMarket: Period?
    public let regular: Period?
    public let postMarket: Period?
    public let bars: [Bar]
}

// MARK: - Wire

/// Decoding of Yahoo's chart and search responses, shared by the client and
/// the tests. Yahoo's numbers arrive as JSON numbers with nulls for bars that
/// never printed, which is why every field on a bar is optional.
public enum YahooWire {
    struct Envelope: Decodable { let chart: ChartBlock }
    struct ChartBlock: Decodable {
        let result: [ResultBlock]?
        let error: APIError?
    }
    struct APIError: Decodable {
        let code: String
        let description: String
    }
    struct ResultBlock: Decodable {
        let meta: Meta
        let timestamp: [Double]?
        let indicators: Indicators
    }
    struct Meta: Decodable {
        let symbol: String
        let currency: String?
        let exchangeName: String?
        let fullExchangeName: String?
        let longName: String?
        let shortName: String?
        let regularMarketPrice: Double?
        let previousClose: Double?
        let chartPreviousClose: Double?
        let regularMarketTime: Double?
        let regularMarketDayHigh: Double?
        let regularMarketDayLow: Double?
        let regularMarketVolume: Double?
        let priceHint: Int?
        let currentTradingPeriod: TradingPeriods?
    }
    struct TradingPeriods: Decodable {
        let pre: PeriodBlock?
        let regular: PeriodBlock?
        let post: PeriodBlock?
    }
    struct PeriodBlock: Decodable {
        let start: Double
        let end: Double
    }
    struct Indicators: Decodable { let quote: [QuoteArrays] }
    struct QuoteArrays: Decodable {
        let open: [Double?]?
        let high: [Double?]?
        let low: [Double?]?
        let close: [Double?]?
        let volume: [Double?]?
    }

    /// The chart, or the refusal Yahoo sent instead of one.
    public static func decodeChart(_ data: Data) throws -> Result<YahooChart, MarketDataError> {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw MarketDataError.decoding(String(describing: error))
        }
        guard let result = envelope.chart.result?.first else {
            let error = envelope.chart.error
            if error?.code == "Not Found" {
                return .failure(.unknownInstrument(error?.description ?? "unknown symbol"))
            }
            return .failure(.api(error.map { "\($0.code): \($0.description)" } ?? "empty chart"))
        }
        let meta = result.meta
        let timestamps = result.timestamp ?? []
        let quote = result.indicators.quote.first
        func column(_ values: [Double?]?, _ index: Int) -> Double? {
            guard let values, index < values.count else { return nil }
            return values[index]
        }
        let bars = timestamps.enumerated().map { index, ts in
            YahooChart.Bar(
                ts: Date(timeIntervalSince1970: ts),
                open: column(quote?.open, index), high: column(quote?.high, index),
                low: column(quote?.low, index), close: column(quote?.close, index),
                volume: column(quote?.volume, index))
        }
        func period(_ block: PeriodBlock?) -> YahooChart.Period? {
            block.map {
                YahooChart.Period(start: Date(timeIntervalSince1970: $0.start),
                                  end: Date(timeIntervalSince1970: $0.end))
            }
        }
        return .success(YahooChart(
            symbol: meta.symbol,
            currency: meta.currency,
            exchangeCode: meta.exchangeName,
            exchangeName: meta.fullExchangeName,
            longName: meta.longName ?? meta.shortName,
            regularMarketPrice: meta.regularMarketPrice,
            previousClose: meta.chartPreviousClose ?? meta.previousClose,
            regularMarketTime: meta.regularMarketTime.map { Date(timeIntervalSince1970: $0) },
            regularDayHigh: meta.regularMarketDayHigh,
            regularDayLow: meta.regularMarketDayLow,
            regularVolume: meta.regularMarketVolume,
            priceHint: meta.priceHint,
            preMarket: period(meta.currentTradingPeriod?.pre),
            regular: period(meta.currentTradingPeriod?.regular),
            postMarket: period(meta.currentTradingPeriod?.post),
            bars: bars))
    }

    /// Yahoo's name for a bar interval, or nil for one it does not serve.
    /// There is no four-hour bar on a six-and-a-half-hour session.
    public static func interval(for bar: BarInterval) -> String? {
        switch bar {
        case .m1: return "1m"
        case .m5: return "5m"
        case .m15: return "15m"
        case .h1: return "1h"
        case .h4: return nil
        case .d1: return "1d"
        case .w1: return "1wk"
        }
    }

    /// Where the session is at `now`, judged against the chart's own trading
    /// periods for the day it describes. A weekend's chart still names
    /// Friday's periods, and `now` is past all three, which is `closed`.
    public static func phase(of chart: YahooChart, now: Date) -> MarketPhase {
        if chart.regular?.contains(now) == true { return .regular }
        if chart.preMarket?.contains(now) == true { return .preMarket }
        if chart.postMarket?.contains(now) == true { return .afterHours }
        return .closed
    }

    /// The bars that printed, as candles. A bar Yahoo lists without a close
    /// never traded and is not a candle.
    public static func candles(from chart: YahooChart, bar: BarInterval, now: Date) -> [Candle] {
        chart.bars.compactMap { row -> Candle? in
            guard let close = row.close, close.isFinite else { return nil }
            let open = row.open ?? close
            return Candle(
                ts: row.ts,
                open: open,
                high: row.high ?? Swift.max(open, close),
                low: row.low ?? Swift.min(open, close),
                close: close,
                volume: row.volume ?? 0,
                confirmed: row.ts.addingTimeInterval(bar.seconds) <= now)
        }
        .sorted { $0.ts < $1.ts }
    }

    /// The quote a one-minute, extended-hours chart implies.
    ///
    /// `last` is the latest print, extended sessions included, so a stock that
    /// moved after the bell shows the after-hours price with the phase saying
    /// so. The change is against the previous regular close — what a stock's
    /// daily change means everywhere it is quoted. High, low and volume are
    /// the regular session's, from Yahoo's own day figures when it gives them
    /// and from the regular-session bars when it does not.
    public static func ticker(from chart: YahooChart, now: Date = Date()) -> Ticker? {
        let prints = chart.bars.filter { ($0.close ?? .nan).isFinite }
        let latest = prints.last
        guard let last = latest?.close ?? chart.regularMarketPrice, last > 0 else { return nil }
        let reference = chart.previousClose ?? prints.first?.open ?? last
        let phase = phase(of: chart, now: now)

        let regularBars = chart.regular.map { period in
            prints.filter { period.contains($0.ts) }
        } ?? prints
        let open = regularBars.first?.open
        let high = chart.regularDayHigh ?? regularBars.compactMap(\.high).max() ?? last
        let low = chart.regularDayLow ?? regularBars.compactMap(\.low).min() ?? last
        let volume = chart.regularVolume ?? regularBars.compactMap(\.volume).reduce(0, +)

        // A quote needs the print's own time, or the official last-trade time
        // when the chart has no prints. Retrieval time cannot make it fresh.
        guard let ts = latest?.ts ?? chart.regularMarketTime,
              ts.timeIntervalSince1970.isFinite, ts.timeIntervalSince1970 > 0 else { return nil }
        return Ticker(
            instId: chart.symbol, last: last, bid: nil, ask: nil,
            reference: reference, open: open, high: high, low: low, volume: volume,
            basis: .previousClose, phase: phase, ts: ts)
    }

    /// Static facts about the listing. US equities tick in cents and trade in
    /// whole shares here; Schwab allows fractional orders, which the order
    /// path will say when it exists.
    public static func meta(from chart: YahooChart) -> InstrumentMeta {
        let decimals = chart.priceHint ?? 2
        let tick = pow(10, -Double(Swift.max(Swift.min(decimals, 6), 0)))
        return InstrumentMeta(instId: chart.symbol, tickSize: tick, lotSize: 1, minSize: 1)
    }

    struct SearchEnvelope: Decodable { let quotes: [SearchQuote] }
    struct SearchQuote: Decodable {
        let symbol: String?
        let shortname: String?
        let longname: String?
        let quoteType: String?
        let exchDisp: String?
        let exchange: String?
    }

    /// Listed US stocks and ETFs from a search response; futures, indices,
    /// currencies and foreign listings are dropped because the venue this
    /// source stands in for does not trade them.
    public static func matches(from data: Data) throws -> [InstrumentMatch] {
        let envelope: SearchEnvelope
        do {
            envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        } catch {
            throw MarketDataError.decoding(String(describing: error))
        }
        return envelope.quotes.compactMap { quote in
            guard let symbol = quote.symbol, !symbol.isEmpty,
                  let type = quote.quoteType, type == "EQUITY" || type == "ETF",
                  let exchange = quote.exchange, usExchanges.contains(exchange) else { return nil }
            return InstrumentMatch(
                instId: symbol, name: quote.longname ?? quote.shortname ?? symbol,
                exchange: quote.exchDisp ?? exchange, instType: .stock)
        }
    }

    /// Yahoo's codes for the US listings Schwab trades.
    static let usExchanges: Set<String> = ["NMS", "NGM", "NCM", "NYQ", "PCX", "ASE", "BTS", "NAS"]
}

// MARK: - Feed

/// Live prices for US equities by polling the chart endpoint.
///
/// Yahoo pushes nothing, so each instrument is re-read on a cadence set by
/// its session: every few seconds while any session is open, once a minute
/// when the market is closed. The one-minute chart doubles as the live
/// one-minute candle; other intervals are re-read every half minute while
/// trading.
public actor YahooMarketFeed: MarketFeed {
    public nonisolated let venue = Venue.schwab
    private let client: YahooFinanceClient
    private var handler: (@Sendable (MarketFeedEvent) -> Void)?
    private var polls: [String: Poll] = [:]
    private var state: FeedState = .idle
    private var consecutiveFailures = 0

    /// Seconds between reads while a session is open, and while it is not.
    public static let tradingInterval: TimeInterval = 3
    public static let closedInterval: TimeInterval = 60
    /// How often a non-minute candle series is refreshed while trading.
    static let candleRefresh: TimeInterval = 30
    /// Failures in a row before the feed reports itself degraded.
    static let degradeAfter = 3

    private struct Poll {
        var bar: BarInterval
        var task: Task<Void, Never>
        var lastCandleRefresh = Date.distantPast
    }

    public init(client: YahooFinanceClient = YahooFinanceClient()) {
        self.client = client
    }

    public func setHandler(_ handler: @escaping @Sendable (MarketFeedEvent) -> Void) {
        self.handler = handler
    }

    public func subscribe(instId: String, bar: BarInterval) {
        guard polls[instId] == nil else { return }
        if state == .idle { setState(.connecting) }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.poll(instId: instId)
        }
        polls[instId] = Poll(bar: bar, task: task)
    }

    public func unsubscribe(instId: String, bar: BarInterval) {
        polls.removeValue(forKey: instId)?.task.cancel()
        if polls.isEmpty { setState(.idle) }
    }

    public func switchBar(instId: String, from old: BarInterval, to new: BarInterval) {
        polls[instId]?.bar = new
        polls[instId]?.lastCandleRefresh = .distantPast
    }

    // MARK: Polling

    private func poll(instId: String) async {
        while !Task.isCancelled, polls[instId] != nil {
            let interval = await readOnce(instId: instId)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// One read of the instrument; returns how long to wait before the next.
    private func readOnce(instId: String) async -> TimeInterval {
        let now = Date()
        do {
            let chart = try await client.chart(
                symbol: instId, interval: "1m", period: .range("1d"), includePrePost: true)
            guard let ticker = YahooWire.ticker(from: chart, now: now) else {
                throw MarketDataError.decoding("\(instId) 没有价格")
            }
            noteSuccess()
            handler?(.ticker(ticker))

            let trading = ticker.phase != .closed
            if let poll = polls[instId] {
                if poll.bar == .m1 {
                    let recent = YahooWire.candles(from: chart, bar: .m1, now: now).suffix(3)
                    if !recent.isEmpty { handler?(.candles(instId: instId, bar: .m1, candles: Array(recent))) }
                } else if trading || poll.lastCandleRefresh == .distantPast,
                          now.timeIntervalSince(poll.lastCandleRefresh) >= Self.candleRefresh {
                    let recent = try await client.candles(instId: instId, bar: poll.bar, target: 3)
                    polls[instId]?.lastCandleRefresh = now
                    if !recent.isEmpty { handler?(.candles(instId: instId, bar: poll.bar, candles: recent)) }
                }
            }
            return trading ? Self.tradingInterval : Self.closedInterval
        } catch {
            noteFailure(instId: instId, error: error)
            return 10
        }
    }

    private func noteSuccess() {
        consecutiveFailures = 0
        setState(.connected)
    }

    private func noteFailure(instId: String, error: Error) {
        consecutiveFailures += 1
        if consecutiveFailures == Self.degradeAfter {
            Log.warn("yahoo: \(instId) 连续 \(consecutiveFailures) 次读取失败，行情降级：\(error)")
            setState(.degraded)
        }
    }

    private func setState(_ new: FeedState) {
        guard new != state else { return }
        state = new
        handler?(.state(new))
    }
}
