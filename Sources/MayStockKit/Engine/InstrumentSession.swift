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
    /// The previous interval's series, kept on screen (dimmed) while the new
    /// one backfills so switching never flashes an empty chart.
    public private(set) var staleCandles: [Candle] = []
    public private(set) var staleBar: BarInterval?
    /// A REST backfill for `bar` is in flight.
    public private(set) var isBackfilling = true
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

    // MARK: Interval switching

    /// Enough bars to be worth drawing — below this the view keeps showing the
    /// previous interval rather than a two-candle stub.
    public static let minimumDrawableCandles = 3

    /// The series a chart should render right now, and the interval it belongs
    /// to. Falls back to the previous interval while a switch is in flight.
    public var displayCandles: (candles: [Candle], bar: BarInterval) {
        if candles.count >= Self.minimumDrawableCandles || staleCandles.isEmpty {
            return (candles, bar)
        }
        return (staleCandles, staleBar ?? bar)
    }

    /// Begin switching interval: the incoming series starts empty, but the
    /// outgoing one is retained for display until the backfill lands.
    public func beginBarSwitch(to new: BarInterval) {
        guard new != bar else { return }
        if candles.count >= Self.minimumDrawableCandles {
            staleCandles = candles
            staleBar = bar
        }
        bar = new
        candles = []
        isBackfilling = true
    }

    /// Backfill landed. Ignored if the user switched again in the meantime.
    public func finishBackfill(_ incoming: [Candle], for target: BarInterval) {
        guard bar == target else { return }
        candles.mergeCandles(incoming)
        isBackfilling = false
        staleCandles = []
        staleBar = nil
        lastUpdate = Date()
    }

    /// Backfill failed — stop the spinner and let live WS candles fill in.
    public func failBackfill(for target: BarInterval) {
        guard bar == target else { return }
        isBackfilling = false
    }
}
