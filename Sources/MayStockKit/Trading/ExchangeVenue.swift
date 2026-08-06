import Foundation

/// Everything the trading loop needs from an exchange.
///
/// The kernel decides *what* to trade and the venue decides *how* to reach a
/// particular exchange. Keeping that seam explicit is what lets a second
/// exchange be added by writing one conformance rather than by editing the
/// runner: `StrategyRunner` names this protocol and never OKX.
///
/// The protocol is deliberately narrow. Anything an exchange can answer that
/// the trading loop does not need — order books, funding history, fee tiers —
/// stays on the concrete adapter, so a new venue is not obliged to implement
/// surface it will never be asked for.
public protocol ExchangeVenue: Sendable {
    /// Shown in diagnostics and written into the ledger, so a book assembled
    /// from two venues can still say where each fill came from.
    var venueName: String { get }

    /// True once the venue is reachable *and* authenticated. Without both,
    /// nothing below works, not even in a simulated environment.
    func isReady() async -> Bool

    // MARK: Market data

    func candles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle]
    func historyCandles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle]
    func lastPrice(instId: String) async throws -> Double
    /// Nil when the exchange does not publish metadata for the instrument.
    func instrumentMeta(instId: String) async throws -> InstrumentMeta?

    /// The alternative series a manifest declares — funding rates, open
    /// interest, long/short ratios — aligned to `candles`.
    ///
    /// Optional, because these statistics are exchange-specific rather than
    /// universal: a venue that publishes none inherits the default below and
    /// returns nothing. That is not silent degradation. An unavailable series
    /// aligns to NaN, NaN is *unknown* throughout the kernel, and a strategy
    /// whose signal depends on an unknown never fires — so a venue without the
    /// data declines to trade rather than trading blind.
    func alternativeSeries(
        specs: [String: AlternativeSeriesSpec], market: StrategyMarket,
        candles: [Candle], days: Int
    ) async -> (series: [String: [Double]], coverage: [SeriesCoverage])

    // MARK: Trading

    func place(
        _ order: OrderRequest, mode: TradingMode, liveUnlocked: Bool
    ) async throws -> OrderResult

    /// Resolve an order whose submission outcome is unknown.
    ///
    /// This exists because a timeout is *not* a rejection. A request that timed
    /// out may well have reached the exchange and filled; treating it as a
    /// failure loses a real position. Callers ask here on the next tick instead
    /// of guessing.
    func orderStatus(
        instId: String, instType: InstrumentType, clOrdId: String, mode: TradingMode
    ) async throws -> VenueOrderStatus

    func fills(
        instId: String?, instType: InstrumentType, mode: TradingMode
    ) async throws -> [ExchangeFill]

    func positions(mode: TradingMode, instType: InstrumentType) async throws -> [ExchangePosition]

    func accountSnapshot(mode: TradingMode) async throws -> AccountSnapshot
}

extension ExchangeVenue {
    public func alternativeSeries(
        specs: [String: AlternativeSeriesSpec], market: StrategyMarket,
        candles: [Candle], days: Int
    ) async -> (series: [String: [Double]], coverage: [SeriesCoverage]) {
        ([:], [])
    }
}

/// What the exchange says became of an order we are unsure about.
public enum VenueOrderStatus: Sendable, Equatable {
    /// The exchange has never heard of it — the request genuinely did not land,
    /// so it is safe to retry.
    case unknown
    /// Accepted and still working.
    case live
    /// Partially or fully filled; `filledSize` is in exchange units.
    case filled(filledSize: Double, averagePrice: Double)
    case canceled
    case rejected(String)

    /// True when the order can no longer change, so the caller may stop asking.
    public var isTerminal: Bool {
        switch self {
        case .filled, .canceled, .rejected: return true
        case .unknown, .live: return false
        }
    }

    /// True when the exchange holds a position because of this order.
    public var didExecute: Bool {
        if case .filled(let size, _) = self { return size > 0 }
        return false
    }
}
