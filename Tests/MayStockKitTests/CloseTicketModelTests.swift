import Foundation
import Testing
@testable import MayStockKit

/// A venue that holds positions, serves a book through the kernel's own
/// offline book engine, and records what it was asked to send.
final class TicketVenue: ExchangeVenue, @unchecked Sendable {
    let venue: Venue
    var positions: [ExchangePosition]
    var shares: [ExchangePosition] = []
    var coins: [String: Double] = [:]
    /// Frames the book is fed when the ticket opens: the specification, then
    /// the book itself.
    var spec = BookDocument.Spec(
        instType: "SWAP", tickSz: "0.01", lotSz: "0.01", minSz: "0.01", ctVal: "0.1", ctMult: "1",
        ctType: "linear", ctValCcy: "ETH", settleCcy: "USDT", groupId: "4")
    var asks: [(String, String)] = [("2653.30", "40"), ("2653.35", "12"), ("2653.50", "30"), ("2654.00", "100")]
    var bids: [(String, String)] = [("2653.20", "50"), ("2653.10", "20"), ("2653.00", "80"), ("2652.50", "200")]
    var account: AccountTradingConfig? = AccountTradingConfig(positionMode: .longShort, accountLevel: 2)
    var fees: FeeRates? = FeeRates(maker: 0.00016, taker: 0.00045)
    var working: [ExchangeOpenOrder] = []
    var executed: [TradeAction] = []
    var cancelled: [String] = []
    var refusal: Error?
    var status: VenueOrderStatus = .unknown
    private(set) var books: [any CloseBookFeed] = []

    init(positions: [ExchangePosition], venue: Venue = .okx) {
        self.positions = positions
        self.venue = venue
    }

    func isReady() async -> Bool { true }
    func candles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle] { [] }
    func historyCandles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle] { [] }
    func lastPrice(instId: String, mode: TradingMode) async throws -> Double { 2653.25 }
    func instrumentMeta(instId: String, mode: TradingMode) async throws -> InstrumentMeta? { nil }
    func accountTradingConfig(mode: TradingMode) async throws -> AccountTradingConfig {
        guard let account else { throw ExchangeVenueError.unsupported("OKX", "账户配置") }
        return account
    }
    func place(_ order: OrderRequest, mode: TradingMode, liveUnlocked: Bool) async throws -> OrderResult {
        Issue.record("the ticket sends plans through execute, never place")
        return OrderResult(ordId: "", raw: "")
    }
    func orderStatus(instId: String, instType: InstrumentType, clOrdId: String, mode: TradingMode) async throws -> VenueOrderStatus { status }
    func fills(instId: String?, instType: InstrumentType, mode: TradingMode) async throws -> [ExchangeFill] { [] }
    func positions(mode: TradingMode, instType: InstrumentType) async throws -> [ExchangePosition] {
        instType == .stock ? shares : positions
    }
    func allPositions(mode: TradingMode) async throws -> [ExchangePosition] { positions }
    func accountSnapshot(mode: TradingMode) async throws -> AccountSnapshot {
        AccountSnapshot(balances: [], totalEquity: 6_500, equityCurrency: "USD")
    }
    func sellableBalance(ccy: String, mode: TradingMode) async throws -> Double { coins[ccy] ?? 0 }
    func protectiveOrders(instId: String, instType: InstrumentType, mode: TradingMode) async throws -> [VenueProtectiveOrder] { [] }
    func amendProtectiveOrder(instId: String, instType: InstrumentType, algoId: String, stopPrice: Double, mode: TradingMode, liveUnlocked: Bool) async throws {}
    func placeProtectiveOrder(instId: String, instType: InstrumentType, posSide: PositionSide?, size: Double, stopPrice: Double, mode: TradingMode, liveUnlocked: Bool) async throws {}

    func closeBook(instId: String, instType: InstrumentType, mode: TradingMode) async throws -> any CloseBookFeed {
        let book = try KernelBook(instId: instId, instType: instType, mode: mode, network: false)
        try book.ingest(String(decoding: try JSONEncoder().encode(["spec": spec]), as: UTF8.self))
        try book.ingest(Self.snapshot(instId: instId, asks: asks, bids: bids))
        books.append(book)
        return book
    }

    static func snapshot(instId: String, asks: [(String, String)], bids: [(String, String)], seq: Int = 100) -> String {
        let rows = { (levels: [(String, String)]) in levels.map { #"["\#($0.0)","\#($0.1)","0","3"]"# }.joined(separator: ",") }
        return #"{"arg":{"channel":"books","instId":"\#(instId)"},"action":"snapshot","data":[{"asks":[\#(rows(asks))],"bids":[\#(rows(bids))],"ts":"1790000000000","checksum":0,"prevSeqId":-1,"seqId":\#(seq)}]}"#
    }

    func execute(_ action: TradeAction, mode: TradingMode, liveUnlocked: Bool) async throws -> String {
        if let refusal { throw refusal }
        executed.append(action)
        return "ord-\(executed.count)"
    }
    func feeRates(instId: String, instType: InstrumentType, groupId: String?, mode: TradingMode) async throws -> FeeRates? { fees }
    func workingOrders(instId: String, instType: InstrumentType, mode: TradingMode) async throws -> OpenOrderListing {
        OpenOrderListing(orders: working)
    }
    func cancelWorkingOrder(_ order: ExchangeOpenOrder, instType: InstrumentType, mode: TradingMode, liveUnlocked: Bool) async throws {
        cancelled.append(order.id)
        working.removeAll { $0.id == order.id }
    }
}

@Suite("Close ticket model")
@MainActor
struct CloseTicketModelTests {

    static func long(_ contracts: Double, _ instId: String = "ETH-USDT-SWAP") -> ExchangePosition {
        ExchangePosition(
            instId: instId, posSide: .long, quantity: contracts, averagePrice: 2687.53,
            markPrice: 2653, unrealisedPnL: -600, leverage: 20, liquidationPrice: 2564.69,
            instType: "SWAP", settlementCurrency: "USDT", marginMode: .isolated)
    }

    static func short(_ contracts: Double) -> ExchangePosition {
        ExchangePosition(
            instId: "ETH-USDT-SWAP", posSide: .short, quantity: -contracts, averagePrice: 2600,
            markPrice: 2653, unrealisedPnL: -50, leverage: 10, liquidationPrice: 2900,
            instType: "SWAP", settlementCurrency: "USDT", marginMode: .cross)
    }

    static let request = CloseTicketRequest(
        venue: .okx, mode: .demo, instId: "ETH-USDT-SWAP", instType: .swap, filedAs: "SWAP",
        holding: .position(isLong: true))

    static func opened(_ venue: any ExchangeVenue, _ request: CloseTicketRequest = request) async -> CloseTicketModel {
        let model = CloseTicketModel(request: request, venue: venue)
        await model.open()
        model.pullBook()
        return model
    }

    static func plan(_ model: CloseTicketModel) throws -> ClosePlan {
        switch model.preview {
        case .success(let plan): return plan
        case .failure(let refusal): throw refusal
        case .none: throw CloseRefusal(message: "no plan")
        }
    }

    @Test("the form starts from the exchange's holding: all of it, at the counterparty's first level")
    func prefillsFromTheExchange() async throws {
        let venue = TicketVenue(positions: [Self.long(187.75)])
        let model = await Self.opened(venue)
        defer { model.close() }
        #expect(model.holding?.quantity == 187.75)
        #expect(model.sizeIsAll && model.sizeText == "187.75")
        #expect(model.method == .limit && model.priceSource == .counterparty && model.level == 1)
        let plan = try Self.plan(model)
        #expect(plan.price?.value == 2653.2, "a sale's counterparty is the bid")
        #expect(plan.estimate.taker?.size == 50, "the first bid holds 50 contracts")
        #expect(plan.estimate.maker?.size == 137.75, "the rest rests at the limit")
        #expect(plan.estimate.fee?.ccy == "USDT")
        model.useFraction(0.75)
        #expect(model.sizeText == "140.81", "75% floored to the lot")
        #expect(!model.sizeIsAll)
    }

    @Test("a level on the ladder prices from that level, counted from the order's side")
    func pickingALevel() async throws {
        let venue = TicketVenue(positions: [Self.long(10)])
        let model = await Self.opened(venue)
        defer { model.close() }
        model.pick(isBid: true, index: 2)
        #expect(model.priceSource == .counterparty && model.level == 3)
        #expect(try Self.plan(model).price?.value == 2653.0)
        model.pick(isBid: false, index: 0)
        #expect(model.priceSource == .queue && model.level == 1)
        #expect(try Self.plan(model).price?.value == 2653.3)

        let shortVenue = TicketVenue(positions: [Self.short(10)])
        let shortModel = await Self.opened(shortVenue, CloseTicketRequest(
            venue: .okx, mode: .demo, instId: "ETH-USDT-SWAP", instType: .swap, filedAs: "SWAP",
            holding: .position(isLong: false)))
        defer { shortModel.close() }
        shortModel.pick(isBid: false, index: 1)
        #expect(shortModel.priceSource == .counterparty, "a buy-back's counterparty is the offer")
        #expect(try Self.plan(shortModel).price?.value == 2653.35)
    }

    @Test("a typed size larger than what is held by review time is refused, not sent")
    func oversizeIsRefused() async {
        let venue = TicketVenue(positions: [Self.long(50)])
        let model = await Self.opened(venue)
        defer { model.close() }
        model.editSize("50")
        venue.positions = [Self.long(30)]
        await model.review()
        #expect(model.stage == .editing)
        #expect(model.problem?.contains("超过持仓") == true, "\(model.problem ?? "")")
        #expect(venue.executed.isEmpty)
    }

    @Test("全部 means all of it as held at review, whichever way the holding moved")
    func allFollowsTheHolding() async throws {
        let venue = TicketVenue(positions: [Self.long(50)])
        let model = await Self.opened(venue)
        defer { model.close() }
        venue.positions = [Self.long(30)]
        await model.review()
        guard case .reviewing(let plan) = model.stage else { Issue.record("no review: \(model.problem ?? "")"); return }
        #expect(plan.size == 30)
    }

    @Test("confirm sends exactly the reviewed plan under its client id, and nothing before it")
    func confirmSendsTheReviewedPlan() async throws {
        let venue = TicketVenue(positions: [Self.long(10)])
        let model = await Self.opened(venue)
        defer { model.close() }
        await model.review()
        guard case .reviewing(let plan) = model.stage else { Issue.record("no review"); return }
        #expect(venue.executed.isEmpty, "a review sends nothing")
        guard case .place(let order) = plan.action else { Issue.record("not an order"); return }
        let clientId = try #require(order.clientId)
        #expect(OrderTag.belongs(clientId, to: CloseTicketModel.manualTag), "tagged as manual, never as a strategy")
        #expect(plan.wire.map { $0.body.contains(clientId) } == true)
        await model.confirm(liveUnlocked: false)
        #expect(venue.executed == [plan.action])
        guard case .sent(_, let id, _) = model.stage else { Issue.record("not sent"); return }
        #expect(id == "ord-1")
    }

    @Test("an unanswered order is looked up by its client id, never retried")
    func anUnconfirmedOrderIsResolved() async throws {
        let venue = TicketVenue(positions: [Self.long(10)])
        venue.refusal = TradeError.unconfirmed("发出后没有回音：timeout")
        venue.status = .unknown
        let model = await Self.opened(venue)
        defer { model.close() }
        await model.review()
        await model.confirm(liveUnlocked: false)
        guard case .failed(_, let failure) = model.stage else { Issue.record("not failed"); return }
        #expect(failure.outcomeUnknown)
        #expect(failure.title == "结果未确认")
        #expect(failure.advice?.contains("它没有到达") == true, "\(failure.advice ?? "")")
    }

    @Test("an exchange refusal is final, in its own words")
    func aRefusalIsFinal() async {
        let venue = TicketVenue(positions: [Self.long(10)])
        venue.refusal = TradeError.rejected(venue: "OKX", reason: "51169 Order failed because you don't have any positions in this direction")
        let model = await Self.opened(venue)
        defer { model.close() }
        await model.review()
        await model.confirm(liveUnlocked: false)
        guard case .failed(_, let failure) = model.stage else { Issue.record("not failed"); return }
        #expect(!failure.outcomeUnknown)
        #expect(failure.title == "被拒绝")
        #expect(failure.detail.contains("51169") && failure.detail.contains("刷新持仓"), "the code, and what to do about it")
    }

    @Test("a review too old to send against is not sent")
    func anExpiredReviewIsNotSent() async {
        let venue = TicketVenue(positions: [Self.long(10)])
        let model = await Self.opened(venue)
        defer { model.close() }
        model.reviewLifetime = 0
        await model.review()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.reviewExpired)
        await model.confirm(liveUnlocked: false)
        #expect(venue.executed.isEmpty)
    }

    @Test("shares: a quote book on a stock venue, limit only, no margin mode, no OKX request")
    func sharesOnAStockVenue() async throws {
        let shares = ExchangePosition(
            instId: "MU", posSide: .net, quantity: 30, averagePrice: 100, markPrice: 120,
            unrealisedPnL: 600, leverage: nil, liquidationPrice: nil, instType: "EQUITY")
        let venue = QuoteVenue(shares: [shares])
        let model = await Self.opened(venue, CloseTicketRequest(
            venue: .schwab, mode: .live, instId: "MU", instType: .stock, filedAs: "EQUITY",
            holding: .position(isLong: true)))
        defer { model.close() }
        #expect(model.holding?.family == .stock)
        #expect(model.holding?.marginMode == nil)
        #expect(model.capabilities.limitKinds == [.limit])
        #expect(model.capabilities.bookDepth == 1)
        let plan = try Self.plan(model)
        #expect(plan.wire == nil)
        #expect(plan.estimate.taker?.size == 30, "a quote is assumed to fill, and the review says so")
        #expect(plan.review.lines.contains { $0.contains("报价不含挂单量") })
        #expect(plan.review.warnings.first?.contains("嘉信实盘") == true)
    }

    @Test("a position the exchange no longer holds says so instead of offering a close")
    func aVanishedPositionSaysSo() async {
        let venue = TicketVenue(positions: [])
        let model = await Self.opened(venue)
        defer { model.close() }
        #expect(model.holding == nil)
        #expect(model.holdingNote?.contains("已经没有") == true)
        #expect(model.preview == nil)
    }

    @Test("resting closes on the instrument are warned about, and can be cancelled")
    func workingOrdersAreWeighedAndCancellable() async {
        let venue = TicketVenue(positions: [Self.long(10)])
        venue.working = [ExchangeOpenOrder(
            id: "9", book: .order, instId: "ETH-USDT-SWAP", ordType: "limit", side: .sell, posSide: .long,
            price: 2700, triggerPrice: nil, stopTriggerPrice: nil, takeProfitTriggerPrice: nil, size: 5,
            closeFraction: nil, filledSize: 0, state: "live", reduceOnly: false, clOrdId: nil, createdAt: nil)]
        let model = await Self.opened(venue)
        defer { model.close() }
        await model.review()
        guard case .reviewing(let plan) = model.stage else { Issue.record("no review"); return }
        #expect(plan.review.warnings.contains { $0.contains("同方向") })
        model.backToEditing()
        await model.cancel(venue.working[0], liveUnlocked: false)
        #expect(venue.cancelled == ["9"])
        #expect(model.working?.orders.isEmpty == true)
    }

    @Test("a coin sells what the trading account has available, floored to the lot")
    func aCoinSellsItsAvailableBalance() async throws {
        let venue = TicketVenue(positions: [])
        venue.coins = ["ETH": 0.0408135]
        venue.spec = BookDocument.Spec(instType: "SPOT", tickSz: "0.01", lotSz: "0.000001", minSz: "0.0001",
                                       baseCcy: "ETH", quoteCcy: "USDT", groupId: "12")
        let request = try #require(CloseTicketRequest.coin("ETH", venue: .okx, mode: .live))
        let model = await Self.opened(venue, request)
        defer { model.close() }
        let plan = try Self.plan(model)
        #expect(plan.size == 0.040813)
        #expect(abs(plan.remainder - 0.0000005) < 1e-12)
        #expect(plan.wire?.body.contains(#""tdMode":"cash""#) == true)
        #expect(model.capabilities.availability(of: .chase).available == false)
    }
}

/// A stock venue: shares held, a quote for a book.
final class QuoteVenue: ExchangeVenue, @unchecked Sendable {
    let venue = Venue.schwab
    var shares: [ExchangePosition]

    init(shares: [ExchangePosition]) { self.shares = shares }

    func isReady() async -> Bool { true }
    func candles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle] { [] }
    func historyCandles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle] { [] }
    func lastPrice(instId: String, mode: TradingMode) async throws -> Double { 120.05 }
    func instrumentMeta(instId: String, mode: TradingMode) async throws -> InstrumentMeta? { nil }
    func place(_ order: OrderRequest, mode: TradingMode, liveUnlocked: Bool) async throws -> OrderResult {
        OrderResult(ordId: "1", raw: "")
    }
    func orderStatus(instId: String, instType: InstrumentType, clOrdId: String, mode: TradingMode) async throws -> VenueOrderStatus { .unknown }
    func fills(instId: String?, instType: InstrumentType, mode: TradingMode) async throws -> [ExchangeFill] { [] }
    func positions(mode: TradingMode, instType: InstrumentType) async throws -> [ExchangePosition] {
        instType == .stock ? shares : []
    }
    func allPositions(mode: TradingMode) async throws -> [ExchangePosition] { [] }
    func accountSnapshot(mode: TradingMode) async throws -> AccountSnapshot {
        AccountSnapshot(balances: [], totalEquity: nil, equityCurrency: "USD")
    }
    func protectiveOrders(instId: String, instType: InstrumentType, mode: TradingMode) async throws -> [VenueProtectiveOrder] { [] }
    func amendProtectiveOrder(instId: String, instType: InstrumentType, algoId: String, stopPrice: Double, mode: TradingMode, liveUnlocked: Bool) async throws {}
    func placeProtectiveOrder(instId: String, instType: InstrumentType, posSide: PositionSide?, size: Double, stopPrice: Double, mode: TradingMode, liveUnlocked: Bool) async throws {}
    func workingOrders(instId: String, instType: InstrumentType, mode: TradingMode) async throws -> OpenOrderListing {
        OpenOrderListing()
    }
    func cancelWorkingOrder(_ order: ExchangeOpenOrder, instType: InstrumentType, mode: TradingMode, liveUnlocked: Bool) async throws {}

    func closeBook(instId: String, instType: InstrumentType, mode: TradingMode) async throws -> any CloseBookFeed {
        let ticker = Ticker(
            instId: instId, last: 120.05, bid: 120.00, ask: 120.10, reference: 119, open: nil,
            high: 121, low: 118, volume: 1_000, basis: .previousClose, phase: nil, ts: Date())
        return StaticBook(BookDocument.quote(
            instId: instId, spec: .shares(SchwabMarketDataSource.equityMeta(instId)), ticker: ticker, error: nil))
    }
}

/// A book that never moves.
final class StaticBook: CloseBookFeed, @unchecked Sendable {
    private let json: Data
    init(_ document: BookDocument) { json = (try? JSONEncoder().encode(document)) ?? Data() }
    func snapshot(since: UInt64) -> (seq: UInt64, json: Data)? { since < 1 ? (1, json) : nil }
    func stop() {}
}
