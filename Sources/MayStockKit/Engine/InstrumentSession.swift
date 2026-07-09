import Foundation
import Observation

/// Live, observable market state for one instrument. All mutation happens on
/// the main actor (fed by `MarketHub`), so SwiftUI/AppKit can read it directly.
@Observable
@MainActor
public final class InstrumentSession {
    public let instId: String

    public private(set) var ticker: Ticker?
    public private(set) var bar: BarInterval
    public private(set) var candles: [Candle] = []
    /// books5 live snapshot (best 5 levels, ~100ms cadence).
    public private(set) var liveBook: OrderBook?
    /// 50-level REST snapshot for the depth chart (refreshed while panel open).
    public private(set) var deepBook: OrderBook?
    public private(set) var spark = SparklineBuffer()
    public private(set) var meta: InstrumentMeta?
    public private(set) var connection: OKXConnectionState = .idle
    public private(set) var lastUpdate: Date?

    /// Direction of the most recent price change (+1 / -1 / 0), for tick pulses.
    public private(set) var lastTickDirection: Int = 0

    public init(instId: String, bar: BarInterval = .m1) {
        self.instId = instId
        self.bar = bar
    }

    public var priceDecimals: Int {
        if let meta { return meta.priceDecimals }
        if let last = ticker?.last { return PriceFormatter.autoDecimals(for: last) }
        return 2
    }

    public var formattedPrice: String? {
        guard let last = ticker?.last else { return nil }
        return PriceFormatter.price(last, decimals: priceDecimals)
    }

    // MARK: Mutation (MarketHub only)

    public func apply(ticker new: Ticker) {
        if let old = ticker?.last {
            lastTickDirection = new.last > old ? 1 : (new.last < old ? -1 : lastTickDirection)
        }
        ticker = new
        spark.sample(price: new.last, at: new.ts)
        lastUpdate = Date()
    }

    public func apply(candles incoming: [Candle], reset: Bool) {
        if reset {
            candles = incoming.sorted { $0.ts < $1.ts }
        } else {
            candles.mergeCandles(incoming)
        }
        lastUpdate = Date()
    }

    public func apply(book: OrderBook) {
        liveBook = book
        lastUpdate = Date()
    }

    public func apply(deepBook book: OrderBook) {
        deepBook = book
    }

    public func apply(meta new: InstrumentMeta) {
        meta = new
    }

    public func apply(connection new: OKXConnectionState) {
        connection = new
    }

    public func seedSparkline(from seedCandles: [Candle]) {
        spark.seed(candles: seedCandles)
    }

    public func switchBar(_ new: BarInterval) {
        guard new != bar else { return }
        bar = new
        candles = []
    }
}
