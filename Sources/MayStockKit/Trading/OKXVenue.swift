import Foundation

/// OKX behind the `ExchangeVenue` port.
///
/// Composes the two things that already talk to OKX — the public REST client
/// for market data and the `okx` CLI bridge for anything authenticated — so the
/// runner sees one object instead of two. Adding a second exchange means
/// writing a sibling of this file and nothing else.
public struct OKXVenue: ExchangeVenue {
    public let venueName = "OKX"

    private let rest: OKXRESTClient
    private let bridge: TradeBridge

    public init(rest: OKXRESTClient = OKXRESTClient(), bridge: TradeBridge) {
        self.rest = rest
        self.bridge = bridge
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

    public func lastPrice(instId: String) async throws -> Double {
        try await rest.ticker(instId: instId).last
    }

    public func instrumentMeta(instId: String) async throws -> InstrumentMeta? {
        try await rest.instrumentMeta(instId: instId)
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
