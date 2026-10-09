import Foundation

/// OKX behind the `ExchangeVenue` port.
///
/// Market data comes from the public REST client. Everything that acts on
/// the account, and every account reading the trading loop depends on —
/// positions, balances, configuration, fills, funding, working orders, an
/// order's fate, fee rates — goes through the kernel, which signs it itself.
/// The `okx` CLI remains for the ledger (bills) behind the equity page.
public struct OKXVenue: ExchangeVenue {
    public let venue = Venue.okx

    /// The real market, which signals read whatever the trading mode.
    private let rest: OKXRESTClient
    /// The demo environment's own books, marks and listings.
    private let demoRest: OKXRESTClient
    private let bridge: TradeBridge
    private let trade: KernelTradeClient

    public init(rest: OKXRESTClient = OKXRESTClient(), bridge: TradeBridge) {
        self.rest = rest
        self.demoRest = OKXRESTClient(baseURL: rest.baseURL, simulated: true)
        self.bridge = bridge
        self.trade = KernelTradeClient(bridge: bridge)
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

    /// Ready once the CLI's config file holds a key: the kernel signs with it
    /// and needs nothing else.
    public func isReady() async -> Bool {
        bridge.hasCredentials()
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

    /// A perpetual's isolated tiers; the demo states its own (2026-10-09: SOL's
    /// first tier ends at 2 500 contracts on the demo, 5 000 on the real
    /// market). Only a perpetual is tiered here.
    public func positionTiers(instId: String, mode: TradingMode) async throws -> [KernelPositionTier]? {
        guard venue.instrumentType(of: instId) == .swap else { return nil }
        return try await market(mode).positionTiers(instId: instId)
    }

    /// Options are marked, not last-traded: a thin book's last print can be
    /// hours old, while the mark is refreshed continuously and is the number
    /// the exchange itself values the position at.
    public func valuationPrice(instId: String, mode: TradingMode) async throws -> Double {
        guard venue.instrumentType(of: instId) == .option else {
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
        try await trade.accountTradingConfig(mode: mode)
    }

    /// The kernel readies the leg (`trade::leg`): the mode from its margin
    /// rule, the leverage held where the family has one.
    public func prepareLeg(_ leg: LegPreparation, mode: TradingMode, liveUnlocked: Bool) async throws -> LegReadiness {
        try await trade.prepare(leg, mode: mode, liveUnlocked: liveUnlocked)
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
        let receipt = try await trade.send(.place(TradeOrderSpec(order)), mode: mode, liveUnlocked: liveUnlocked)
        guard let id = receipt.id else { throw TradeError.unconfirmed("交易所回复成功但没有 ordId") }
        return OrderResult(ordId: id, clOrdId: order.clOrdId, raw: receipt.raw)
    }

    /// Look the order up by its client id. Absent is the one answer that
    /// makes a retry safe.
    public func orderStatus(
        instId: String, instType: InstrumentType, clOrdId: String, mode: TradingMode
    ) async throws -> VenueOrderStatus {
        try await trade.orderStatus(instId: instId, clientId: clOrdId, mode: mode)
    }

    public func fills(
        instId: String?, instType: InstrumentType, mode: TradingMode
    ) async throws -> [ExchangeFill] {
        try await trade.fills(mode: mode, family: instType, instId: instId)
    }

    /// Positions come from the kernel's signed read of OKX's own document,
    /// parsed by the one reader of its fields. Only contracts are held as
    /// positions; spot is a balance.
    public func positions(
        mode: TradingMode, instType: InstrumentType
    ) async throws -> [ExchangePosition] {
        guard instType.isDerivative else { return [] }
        return try await trade.positions(mode: mode, family: instType)
    }

    public func allPositions(mode: TradingMode) async throws -> [ExchangePosition] {
        try await trade.positions(mode: mode)
    }

    public func accountSnapshot(mode: TradingMode) async throws -> AccountSnapshot {
        try await trade.accountSnapshot(mode: mode)
    }

    public func sellableBalance(ccy: String, mode: TradingMode) async throws -> Double {
        try await trade.balances(mode: mode, ccy: ccy).first { $0.ccy.uppercased() == ccy.uppercased() }?.available ?? 0
    }

    public func accountDocuments(mode: TradingMode) async throws -> (positions: String, balance: String) {
        try await trade.accountDocuments(mode: mode)
    }

    public func fundingPayments(
        instId: String?, mode: TradingMode
    ) async throws -> [FundingPayment] {
        try await trade.fundingPayments(mode: mode, instId: instId)
    }

    // MARK: Protective orders

    public func protectiveOrders(
        instId: String, instType: InstrumentType, mode: TradingMode
    ) async throws -> [VenueProtectiveOrder] {
        try await trade.protectiveOrders(family: instType, instId: instId, mode: mode)
    }

    public func amendProtectiveOrder(
        instId: String, instType: InstrumentType, algoId: String,
        stopPrice: Double, mode: TradingMode, liveUnlocked: Bool
    ) async throws {
        _ = try await trade.send(
            .amendStop(instId: instId, algoId: algoId, stop: stopPrice), mode: mode, liveUnlocked: liveUnlocked)
    }

    /// A standalone reduce-only stop, filled at market, in the mode of the
    /// position it protects.
    public func placeProtectiveOrder(
        instId: String, instType: InstrumentType, posSide: PositionSide?, tradeMode: String?,
        size: Double, stopPrice: Double, mode: TradingMode, liveUnlocked: Bool
    ) async throws {
        let algo = TradeAlgoSpec(
            instId: instId, instType: instType, side: posSide == .short ? .buy : .sell, posSide: posSide,
            size: size, tradeMode: tradeMode, reduceOnly: true, cancelWithPosition: false,
            kind: .protection(takeProfit: nil, stopLoss: stopPrice))
        _ = try await trade.send(.placeAlgo(algo), mode: mode, liveUnlocked: liveUnlocked)
    }

    // MARK: Closing by hand

    /// The kernel's own book: `books` and `bbo-tbt` merged by sequence, in
    /// the environment the order goes to.
    public func closeBook(instId: String, instType: InstrumentType, mode: TradingMode) async throws -> any CloseBookFeed {
        try KernelBook(instId: instId, instType: instType, mode: mode)
    }

    public func execute(_ action: TradeAction, mode: TradingMode, liveUnlocked: Bool) async throws -> String {
        try await trade.send(action, mode: mode, liveUnlocked: liveUnlocked).id ?? ""
    }

    public func feeRates(instId: String, instType: InstrumentType, groupId: String?, mode: TradingMode) async throws -> FeeRates? {
        try await trade.feeRates(family: instType, instId: instId, groupId: groupId, mode: mode)
    }

    /// OKX's own `account/max-size`, asked in the margin mode the order goes
    /// out in, at the leverage its leg is held at. Measured on the demo
    /// account (2026-10-09): for a perpetual it is the margin check's
    /// boundary to the lot — margin at the buy price limit for a market buy,
    /// at the mark for a sale, plus the taker fee, against what is free; for
    /// spot it is the free quote over the last price. Every OKX order states
    /// a mode, so an order without one is a mistake to say, not a default to
    /// ask with.
    public func maxOpeningSize(
        instId: String, instType: InstrumentType, side: OrderSide, tradeMode: String?, mode: TradingMode
    ) async throws -> Double? {
        guard let tradeMode else { throw TradeError.refused("问可开上限要先定出这张单的 tdMode") }
        let most = try await trade.maxOrderSize(family: instType, instId: instId, tradeMode: tradeMode, mode: mode)
        return side == .buy ? most.maxBuy : most.maxSell
    }

    public func warmTrading() async {
        if case .failure(let error) = await KernelTradeClient.warm() {
            Log.warn("trade: 预热交易连接失败：\(error)")
        }
    }

    public func workingOrders(
        instId: String, instType: InstrumentType, mode: TradingMode
    ) async throws -> OpenOrderListing {
        try await trade.workingOrders(mode: mode, families: [instType], instId: instId)
    }

    /// Every working order on the account, for the overview.
    public func openOrders(mode: TradingMode) async throws -> OpenOrderListing {
        try await trade.workingOrders(mode: mode)
    }

    public func cancelWorkingOrder(
        _ order: ExchangeOpenOrder, instType: InstrumentType,
        mode: TradingMode, liveUnlocked: Bool
    ) async throws {
        let action: TradeAction = switch order.book {
        case .order: .cancel(instId: order.instId, orderId: order.id)
        case .algo: .cancelAlgo(instId: order.instId, algoId: order.id)
        }
        _ = try await trade.send(action, mode: mode, liveUnlocked: liveUnlocked)
    }
}
