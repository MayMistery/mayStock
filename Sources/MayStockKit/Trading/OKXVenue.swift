import Foundation

/// OKX behind the `ExchangeVenue` port.
///
/// Composes the two things that already talk to OKX — the public REST client
/// for market data and the `okx` CLI bridge for anything authenticated — so the
/// runner sees one object instead of two. Adding a second exchange means
/// writing a sibling of this file and nothing else.
public struct OKXVenue: ExchangeVenue {
    public let venueName = "OKX"

    /// The real market, which signals read whatever the trading mode.
    private let rest: OKXRESTClient
    /// The demo environment's own books, marks and listings.
    private let demoRest: OKXRESTClient
    private let bridge: TradeBridge

    public init(rest: OKXRESTClient = OKXRESTClient(), bridge: TradeBridge) {
        self.rest = rest
        self.demoRest = OKXRESTClient(baseURL: rest.baseURL, simulated: true)
        self.bridge = bridge
    }

    /// Where an order's prices come from: the environment it will be filled
    /// in. A demo option order priced from the real book was sent at 0.0215
    /// into a demo book whose best ask was 0.0375, and the exchange cancelled
    /// it unfilled; the demo marks the same contract at 0.052 against the
    /// real 0.0205, so a position valued from the real mark is not what the
    /// demo account shows either.
    func market(_ mode: TradingMode) -> OKXRESTClient {
        mode == .demo ? demoRest : rest
    }

    public func isReady() async -> Bool {
        await bridge.detectCLI() != nil && bridge.hasCredentials()
    }

    // MARK: Market data

    public func candles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle] {
        try await rest.candles(instId: instId, bar: bar, target: target)
    }

    public func historyCandles(
        instId: String, bar: BarInterval, target: Int
    ) async throws -> [Candle] {
        try await rest.historyCandles(instId: instId, bar: bar, target: target)
    }

    public func lastPrice(instId: String, mode: TradingMode) async throws -> Double {
        try await market(mode).ticker(instId: instId).last
    }

    public func instrumentMeta(instId: String, mode: TradingMode) async throws -> InstrumentMeta? {
        try await market(mode).instrumentMeta(instId: instId)
    }

    /// Options are marked, not last-traded: a thin book's last print can be
    /// hours old, while the mark is refreshed continuously and is the number
    /// the exchange itself values the position at.
    public func valuationPrice(instId: String, mode: TradingMode) async throws -> Double {
        guard InstrumentType.of(instId: instId) == .option else {
            return try await market(mode).ticker(instId: instId).last
        }
        let quote = try await market(mode).optionQuote(instId: instId)
        guard let mark = quote.markQuote, mark > 0 else {
            throw OKXError.decoding("\(instId) 没有标记价")
        }
        return mark
    }

    public func optionChain(underlying: String, mode: TradingMode) async throws -> [OptionContract] {
        try await market(mode).optionChain(underlying: underlying)
    }

    public func optionQuote(instId: String, mode: TradingMode) async throws -> OptionQuote {
        try await market(mode).optionQuote(instId: instId)
    }

    public func indexPrice(underlying: String, mode: TradingMode) async throws -> Double {
        try await market(mode).indexPrice(underlying: underlying)
    }

    public func accountTradingConfig(mode: TradingMode) async throws -> AccountTradingConfig {
        try await bridge.accountTradingConfig(mode: mode)
    }

    public func alternativeSeries(
        specs: [String: AlternativeSeriesSpec], market: StrategyMarket,
        candles: [Candle], days: Int
    ) async -> (series: [String: [Double]], coverage: [SeriesCoverage]) {
        await AlternativeDataProvider(rest: rest).load(
            specs: specs, market: market, candles: candles, days: days)
    }

    // MARK: Trading

    public func place(
        _ order: OrderRequest, mode: TradingMode, liveUnlocked: Bool
    ) async throws -> OrderResult {
        try await bridge.place(order, mode: mode, liveUnlocked: liveUnlocked)
    }

    /// Look the order up by its client id.
    ///
    /// `okx <module> orders` lists working and historical orders; an order the
    /// exchange has never seen is simply absent, which is the one case where a
    /// retry is safe.
    public func orderStatus(
        instId: String, instType: InstrumentType, clOrdId: String, mode: TradingMode
    ) async throws -> VenueOrderStatus {
        try await bridge.orderStatus(
            instId: instId, instType: instType, clOrdId: clOrdId, mode: mode)
    }

    public func fills(
        instId: String?, instType: InstrumentType, mode: TradingMode
    ) async throws -> [ExchangeFill] {
        try await bridge.fills(instId: instId, instType: instType, mode: mode)
    }

    public func positions(
        mode: TradingMode, instType: InstrumentType
    ) async throws -> [ExchangePosition] {
        try await bridge.positions(mode: mode, instType: instType)
    }

    public func accountSnapshot(mode: TradingMode) async throws -> AccountSnapshot {
        try await bridge.accountSnapshot(mode: mode)
    }

    public func fundingPayments(
        instId: String?, mode: TradingMode
    ) async throws -> [FundingPayment] {
        try await bridge.fundingPayments(instId: instId, mode: mode)
    }

    // MARK: Protective orders

    public func protectiveOrders(
        instId: String, instType: InstrumentType, mode: TradingMode
    ) async throws -> [VenueProtectiveOrder] {
        try await bridge.protectiveOrders(instId: instId, instType: instType, mode: mode)
    }

    public func amendProtectiveOrder(
        instId: String, instType: InstrumentType, algoId: String,
        stopPrice: Double, mode: TradingMode, liveUnlocked: Bool
    ) async throws {
        try await bridge.amendProtectiveOrder(
            instId: instId, instType: instType, algoId: algoId,
            stopPrice: stopPrice, mode: mode, liveUnlocked: liveUnlocked)
    }

    public func placeProtectiveOrder(
        instId: String, instType: InstrumentType, posSide: PositionSide?,
        size: Double, stopPrice: Double, mode: TradingMode, liveUnlocked: Bool
    ) async throws {
        try await bridge.placeProtectiveOrder(
            instId: instId, instType: instType, posSide: posSide, size: size,
            stopPrice: stopPrice, mode: mode, liveUnlocked: liveUnlocked)
    }
}
