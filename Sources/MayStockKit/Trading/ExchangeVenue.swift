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

    /// The price the ledger marks `instId` at, in the quote currency it books
    /// in. For spot and perpetuals that is the last trade. For an option it is
    /// the exchange's mark — quoted in the settlement coin per unit of
    /// underlying — converted at the index, so a held premium is worth what
    /// the account would actually get for it. Defaults to `lastPrice`, which
    /// is right for every family a venue without options trades.
    func valuationPrice(instId: String) async throws -> Double

    // MARK: Options

    /// Every live contract on an underlying index. Defaults to refusing: a
    /// venue that lists no options must say so rather than answer with an
    /// empty chain the runner would read as "nothing qualifies today".
    func optionChain(underlying: String) async throws -> [OptionContract]
    /// Bid, ask, mark and index for one contract, read together so the four
    /// numbers describe the same instant.
    func optionQuote(instId: String) async throws -> OptionQuote
    /// The index price of an underlying, e.g. `BTC-USD`.
    func indexPrice(underlying: String) async throws -> Double

    // MARK: Account

    /// How the account is set up for derivatives: whether a perpetual order
    /// must name its leg, and which margin mode an option order needs. Read
    /// rather than assumed — an account switched to net mode rejects every
    /// order that names a leg, with an error that says nothing about why.
    func accountTradingConfig(mode: TradingMode) async throws -> AccountTradingConfig

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

    /// Funding settled on perpetual positions.
    ///
    /// Optional: a venue with no perpetuals, or no way to report the charge,
    /// inherits an empty default. Booking nothing is honest there; booking a
    /// guess would not be.
    func fundingPayments(
        instId: String?, mode: TradingMode
    ) async throws -> [FundingPayment]

    // MARK: Protective orders

    /// The stop and take-profit orders the exchange is currently holding.
    ///
    /// Read rather than remembered: an app that has just restarted, or that was
    /// closed while a stop moved, has no business guessing what the exchange is
    /// enforcing on its behalf.
    func protectiveOrders(
        instId: String, instType: InstrumentType, mode: TradingMode
    ) async throws -> [VenueProtectiveOrder]

    /// Move an existing protective order's trigger price.
    ///
    /// Amending beats cancel-and-replace: a cancelled stop leaves the position
    /// unprotected for as long as the replacement takes to land, which is
    /// precisely the window a fast move exploits.
    func amendProtectiveOrder(
        instId: String, instType: InstrumentType, algoId: String,
        stopPrice: Double, mode: TradingMode, liveUnlocked: Bool
    ) async throws

    /// Attach a standalone reduce-only stop to a position that has none.
    func placeProtectiveOrder(
        instId: String, instType: InstrumentType, posSide: PositionSide?,
        size: Double, stopPrice: Double, mode: TradingMode, liveUnlocked: Bool
    ) async throws
}

/// A stop or take-profit the exchange is holding for us.
public struct VenueProtectiveOrder: Sendable, Equatable, Identifiable {
    public let algoId: String
    public let instId: String
    public let stopTriggerPrice: Double?
    public let takeProfitTriggerPrice: Double?
    public let size: Double
    public let posSide: PositionSide?

    public var id: String { algoId }

    public init(
        algoId: String, instId: String, stopTriggerPrice: Double?,
        takeProfitTriggerPrice: Double?, size: Double, posSide: PositionSide?
    ) {
        self.algoId = algoId
        self.instId = instId
        self.stopTriggerPrice = stopTriggerPrice
        self.takeProfitTriggerPrice = takeProfitTriggerPrice
        self.size = size
        self.posSide = posSide
    }
}

extension ExchangeVenue {
    public func alternativeSeries(
        specs: [String: AlternativeSeriesSpec], market: StrategyMarket,
        candles: [Candle], days: Int
    ) async -> (series: [String: [Double]], coverage: [SeriesCoverage]) {
        ([:], [])
    }

    public func fundingPayments(
        instId: String?, mode: TradingMode
    ) async throws -> [FundingPayment] { [] }

    public func valuationPrice(instId: String) async throws -> Double {
        try await lastPrice(instId: instId)
    }

    public func optionChain(underlying: String) async throws -> [OptionContract] {
        throw ExchangeVenueError.unsupported(venueName, "期权链")
    }

    public func optionQuote(instId: String) async throws -> OptionQuote {
        throw ExchangeVenueError.unsupported(venueName, "期权报价")
    }

    public func indexPrice(underlying: String) async throws -> Double {
        throw ExchangeVenueError.unsupported(venueName, "指数价")
    }

    public func accountTradingConfig(mode: TradingMode) async throws -> AccountTradingConfig {
        throw ExchangeVenueError.unsupported(venueName, "账户配置")
    }
}

/// A capability the venue does not have. Thrown, never defaulted around: the
/// runner reports it against the strategy that needed it.
public enum ExchangeVenueError: Error, CustomStringConvertible, Sendable, Equatable {
    case unsupported(String, String)

    public var description: String {
        switch self {
        case .unsupported(let venue, let capability):
            return "\(venue) 不提供\(capability)"
        }
    }
}

/// How the account handles derivative orders.
public struct AccountTradingConfig: Sendable, Equatable {
    public enum PositionMode: String, Sendable, Equatable {
        /// Every perpetual order names the leg it acts on.
        case longShort = "long_short_mode"
        /// One net position per instrument; orders name no leg.
        case net = "net_mode"
    }

    public let positionMode: PositionMode?
    /// OKX's `acctLv`: 1 simple, 2 single-currency margin, 3 multi-currency
    /// margin, 4 portfolio margin.
    public let accountLevel: Int?

    public init(positionMode: PositionMode?, accountLevel: Int?) {
        self.positionMode = positionMode
        self.accountLevel = accountLevel
    }

    /// The `tdMode` an option order has to carry. Options are margined by the
    /// account, not the order: a simple account buys them for cash, a
    /// single-currency margin account isolates them, and the multi-currency
    /// and portfolio modes cross-margin everything.
    public var optionTradeMode: String {
        switch accountLevel {
        case .some(1): return "cash"
        case .some(2): return "isolated"
        default: return "cross"
        }
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
