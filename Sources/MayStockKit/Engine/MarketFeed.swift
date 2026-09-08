import Foundation

// MARK: - The market-data port

/// Connection health of one venue's feed, as the UI shows it.
public enum FeedState: String, Sendable, Equatable {
    case idle, connecting, connected, degraded
}

/// What a venue's live feed delivers to the hub.
public enum MarketFeedEvent: Sendable {
    case state(FeedState)
    case ticker(Ticker)
    case candles(instId: String, bar: BarInterval, candles: [Candle])
    case book(OrderBook)
}

/// Live market data for one venue: subscriptions in, events out.
///
/// The hub owns one of these per venue and never learns how it works — OKX
/// pushes over two WebSockets, Yahoo is polled — so a third venue is a new
/// conformance and one line in `MarketHub.standard()`, not a new branch in
/// every page.
public protocol MarketFeed: AnyObject, Sendable {
    var venue: Venue { get }
    func setHandler(_ handler: @escaping @Sendable (MarketFeedEvent) -> Void) async
    func subscribe(instId: String, bar: BarInterval) async
    func unsubscribe(instId: String, bar: BarInterval) async
    func switchBar(instId: String, from old: BarInterval, to new: BarInterval) async
}

/// One-off reads for one venue: history, metadata, the order book where the
/// venue has one, and symbol lookup for the watchlist editor.
public protocol MarketDataSource: Sendable {
    var venue: Venue { get }
    func ticker(instId: String) async throws -> Ticker
    /// Up to `target` most recent candles, oldest first.
    func candles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle]
    /// Deep history for backtesting, oldest first, reporting rows gathered so
    /// far through `progress`.
    func historyCandles(
        instId: String, bar: BarInterval, target: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> [Candle]
    /// Nil when the venue does not list the instrument.
    func instrumentMeta(instId: String) async throws -> InstrumentMeta?
    /// Nil on a venue whose public data carries no book to draw.
    func book(instId: String, depth: Int) async throws -> OrderBook?
    /// Instruments matching a query, for adding one to the watchlist.
    func search(_ query: String) async throws -> [InstrumentMatch]
}

/// One hit of a symbol search.
public struct InstrumentMatch: Sendable, Equatable, Identifiable {
    public let instId: String
    public let name: String
    /// Where it lists, as the source names it ("NASDAQ", "OKX").
    public let exchange: String
    public let instType: InstrumentType

    public var id: String { instId }

    public init(instId: String, name: String, exchange: String, instType: InstrumentType) {
        self.instId = instId
        self.name = name
        self.exchange = exchange
        self.instType = instType
    }
}

/// A failure any source can report, so callers need not know whose wire
/// they are reading.
public enum MarketDataError: Error, CustomStringConvertible, Sendable, Equatable {
    case transport(String)
    /// The source answered with a refusal of its own.
    case api(String)
    case decoding(String)
    /// The venue does not list the instrument.
    case unknownInstrument(String)

    public var description: String {
        switch self {
        case .transport(let message): return "transport: \(message)"
        case .api(let message): return message
        case .decoding(let message): return "decoding: \(message)"
        case .unknownInstrument(let instId): return "没有这个标的：\(instId)"
        }
    }
}

/// The one-off data source for every venue, resolved by venue.
///
/// A switch rather than a dictionary so that adding a venue is a compile
/// error here until it has a source — a venue with quotes in the menu bar
/// but no history in the backtester would be the confusing half.
public struct MarketDataSources: Sendable {
    public var okx: OKXRESTClient
    public var yahoo: YahooFinanceClient

    public init(okx: OKXRESTClient = OKXRESTClient(), yahoo: YahooFinanceClient = YahooFinanceClient()) {
        self.okx = okx
        self.yahoo = yahoo
    }

    public func source(for venue: Venue) -> any MarketDataSource {
        switch venue {
        case .okx: return okx
        case .schwab: return yahoo
        }
    }
}
