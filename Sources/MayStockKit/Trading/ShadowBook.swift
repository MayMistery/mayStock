import Foundation

/// A simulated account for a venue that has no demo environment.
///
/// Schwab has no paper-trading account, so "demo" on Schwab is this: orders
/// fill locally against the live quote, at the touch plus the configured
/// slippage, with the venue's real fee components, and only while the
/// kernel calendar says the market is open. Everything is written to disk
/// after every change, so a restart keeps its positions, and the ledger
/// reads it exactly as it would read an exchange — fills, positions, a
/// snapshot — which is what makes the demo path the live path with one
/// function swapped.
///
/// It is deliberately not generous: a market order placed at 20:00 waits
/// for the next open; a limit fills only when the touch crosses it; a buy
/// that would take exposure past Reg T's two-to-one is refused as the
/// broker would refuse it.
public actor ShadowBook {
    public struct Quote: Sendable, Equatable {
        public var last: Double
        public var bid: Double?
        public var ask: Double?
        public var ts: Date

        public init(last: Double, bid: Double? = nil, ask: Double? = nil, ts: Date = Date()) {
            self.last = last
            self.bid = bid
            self.ask = ask
            self.ts = ts
        }

        public init(_ ticker: Ticker) {
            self.init(last: ticker.last, bid: ticker.bid, ask: ticker.ask, ts: ticker.ts)
        }
    }

    /// What every fill costs: the venue's fee components and the assumed
    /// adverse move, read from the same schedule the backtester uses.
    public struct Economics: Sendable, Equatable {
        public var fees: FeeModel
        public var slippageBps: Double
        /// Reg T: exposure may not exceed this multiple of equity.
        public var maxLeverage: Double

        public init(fees: FeeModel, slippageBps: Double, maxLeverage: Double = 2) {
            self.fees = fees
            self.slippageBps = slippageBps
            self.maxLeverage = maxLeverage
        }

        public init(schedule: SchwabFeeSchedule) {
            self.init(
                fees: schedule.feeModel(for: .stock) ?? FeeModel([]),
                slippageBps: schedule.slippageBps,
                maxLeverage: KernelInstrumentPolicy.policy(for: .stock).maxLeverage)
        }
    }

    public enum Status: String, Codable, Sendable {
        case pending, filled, canceled
    }

    public struct Order: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let clOrdId: String?
        public let instId: String
        public let side: OrderSide
        public let kind: OrderKind
        public let size: Double
        public let limitPrice: Double?
        /// A stop's trigger. Set only on protective orders.
        public var stopPrice: Double?
        public let reduceOnly: Bool
        public var status: Status
        public var filledSize: Double
        public var averagePrice: Double?
        public let placedAt: Date
        public var resolvedAt: Date?
        /// Why the order is where it is — "休市，待开盘" or the refusal.
        public var note: String?
        /// A stop or take-profit protecting a position rather than an entry.
        public let protective: Bool
        /// Orders cancelled when this one fills: the other leg of a bracket.
        public var ocoGroup: String?

        public var isOpen: Bool { status == .pending }
    }

    public struct Position: Codable, Sendable, Equatable {
        public var instId: String
        /// Signed shares.
        public var quantity: Double
        public var averagePrice: Double
    }

    public struct Fill: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let orderId: String
        public let clOrdId: String?
        public let instId: String
        public let side: OrderSide
        public let price: Double
        public let size: Double
        /// Positive cost.
        public let fee: Double
        public let ts: Date
    }

    struct State: Codable, Sendable, Equatable {
        var cash: Double
        var startingCash: Double
        var orders: [Order] = []
        var positions: [String: Position] = [:]
        var fills: [Fill] = []
        var sequence: Int = 0
        var createdAt: Date
        var resetAt: Date?
    }

    public let venue: Venue
    public let fileURL: URL?
    private var state: State
    private let calendar: KernelCalendar
    /// The most recent quote per instrument, so a settle can price without
    /// being handed every quote again.
    private var quotes: [String: Quote] = [:]

    /// Retained fills; positions are cumulative, so older rows are history.
    public static let maxFills = 5_000

    public init(venue: Venue, fileURL: URL?, startingCash: Double) {
        self.venue = venue
        self.fileURL = fileURL
        self.calendar = KernelCalendar(market: StrategyMarket(
            instId: "", instType: venue.instrumentTypes[0], bar: .m1, venue: venue))
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let loaded = try? Self.decoder.decode(State.self, from: data) {
            state = loaded
        } else {
            state = State(cash: startingCash, startingCash: startingCash, createdAt: Date())
        }
    }

    // MARK: Reads

    public var cash: Double { state.cash }
    public var startingCash: Double { state.startingCash }
    public var createdAt: Date { state.createdAt }
    public var openOrders: [Order] { state.orders.filter(\.isOpen) }
    public var allOrders: [Order] { state.orders }

    public func quote(for instId: String) -> Quote? { quotes[instId] }

    public func positions() -> [ExchangePosition] {
        state.positions.values.filter { $0.quantity != 0 }.sorted { $0.instId < $1.instId }.map { position in
            let mark = quotes[position.instId]?.last
            return ExchangePosition(
                instId: position.instId, posSide: .net, quantity: position.quantity,
                averagePrice: position.averagePrice, markPrice: mark,
                unrealisedPnL: mark.map { ($0 - position.averagePrice) * position.quantity } ?? 0,
                leverage: nil, liquidationPrice: nil,
                notionalUsd: mark.map { $0 * position.quantity }, instType: "EQUITY")
        }
    }

    /// Dollars, then one line per holding in shares — the shape the runner
    /// values an account by.
    public func snapshot(marks: [String: Double] = [:]) -> AccountSnapshot {
        var balances = [AccountBalance(
            ccy: venue.quoteCurrency, available: state.cash, total: state.cash, valuationUsd: state.cash)]
        var equity = state.cash
        var priced = true
        for position in state.positions.values.sorted(by: { $0.instId < $1.instId }) where position.quantity != 0 {
            let mark = marks[position.instId] ?? quotes[position.instId]?.last
            balances.append(AccountBalance(
                ccy: position.instId, available: position.quantity, total: position.quantity,
                valuationUsd: mark.map { $0 * position.quantity }))
            if let mark { equity += mark * position.quantity } else { priced = false }
        }
        return AccountSnapshot(
            balances: balances, totalEquity: priced ? equity : nil,
            // The book's cash is the venue's quote currency by construction,
            // and every holding is valued in it.
            equityCurrency: venue.quoteCurrency)
    }

    public func fills(instId: String?) -> [ExchangeFill] {
        state.fills.filter { instId == nil || $0.instId == instId }.map { fill in
            ExchangeFill(
                id: fill.id, instId: fill.instId, side: fill.side, posSide: nil,
                price: fill.price, size: fill.size, fee: -fill.fee, feeCcy: venue.quoteCurrency,
                ordId: fill.orderId, clOrdId: fill.clOrdId, ts: fill.ts)
        }
    }

    /// The runner's reading of every non-protective order carrying the tag.
    public func status(clOrdId: String) -> VenueOrderStatus {
        let orders = state.orders.filter { $0.clOrdId == clOrdId && !$0.protective }
        guard !orders.isEmpty else { return .unknown }
        if orders.contains(where: \.isOpen) { return .live }
        let filled = orders.reduce(0.0) { $0 + $1.filledSize }
        if filled > 0 {
            let notional = orders.reduce(0.0) { $0 + $1.filledSize * ($1.averagePrice ?? 0) }
            return .filled(filledSize: filled, averagePrice: notional / filled)
        }
        if let refused = orders.first(where: { $0.note?.hasPrefix("拒绝") ?? false }) {
            return .rejected(refused.note ?? "拒绝")
        }
        return .canceled
    }

    public func protectiveOrders(instId: String) -> [VenueProtectiveOrder] {
        state.orders.filter { $0.instId == instId && $0.protective && $0.isOpen }.map { order in
            VenueProtectiveOrder(
                algoId: order.id, instId: order.instId,
                stopTriggerPrice: order.stopPrice, takeProfitTriggerPrice: order.stopPrice == nil ? order.limitPrice : nil,
                size: order.size, posSide: nil)
        }
    }

    // MARK: Placement

    /// Place an order. A market order fills at once when the session is
    /// open, otherwise it waits for the next open; a limit fills when the
    /// touch is inside it. A refusal — no quote, Reg T — is thrown as the
    /// exchange's own verdict so the runner treats it as final.
    @discardableResult
    public func place(_ request: OrderRequest, quote: Quote?, economics: Economics, now: Date = Date()) throws -> Order {
        if let quote { quotes[request.instId] = quote }
        guard request.size > 0 else {
            throw TradeError.rejected(venue: venue.displayName + "影子账户", reason: "数量必须大于 0")
        }
        var order = Order(
            id: nextId("shadow"), clOrdId: request.clOrdId, instId: request.instId, side: request.side,
            kind: request.kind, size: request.size, limitPrice: request.limitPrice, stopPrice: nil,
            reduceOnly: request.reduceOnly, status: .pending, filledSize: 0, averagePrice: nil,
            placedAt: now, resolvedAt: nil, note: nil, protective: false, ocoGroup: nil)
        if let reason = regTRefusal(for: order, economics: economics) {
            order.status = .canceled
            order.resolvedAt = now
            order.note = "拒绝：" + reason
            state.orders.append(order)
            persist()
            throw TradeError.rejected(venue: venue.displayName + "影子账户", reason: reason)
        }
        state.orders.append(order)
        attachProtection(to: order, request: request, now: now)
        settle(now: now, economics: economics)
        if request.kind == .ioc, let index = state.orders.firstIndex(where: { $0.id == order.id }), state.orders[index].isOpen {
            state.orders[index].status = .canceled
            state.orders[index].resolvedAt = now
            state.orders[index].note = "IOC 未能立即成交，已撤销"
        }
        persist()
        return state.orders.first { $0.id == order.id } ?? order
    }

    /// A standalone stop guarding a position.
    @discardableResult
    public func placeProtective(instId: String, side: OrderSide, size: Double, stopPrice: Double, now: Date = Date()) -> Order {
        let order = Order(
            id: nextId("stop"), clOrdId: nil, instId: instId, side: side, kind: .market, size: size,
            limitPrice: nil, stopPrice: stopPrice, reduceOnly: true, status: .pending, filledSize: 0,
            averagePrice: nil, placedAt: now, resolvedAt: nil, note: nil, protective: true, ocoGroup: nil)
        state.orders.append(order)
        persist()
        return order
    }

    public func amendProtective(id: String, stopPrice: Double) throws {
        guard let index = state.orders.firstIndex(where: { $0.id == id && $0.protective && $0.isOpen }) else {
            throw TradeError.rejected(venue: venue.displayName + "影子账户", reason: "止损单 \(id) 不存在或已结束")
        }
        state.orders[index].stopPrice = stopPrice
        persist()
    }

    public func cancel(id: String, now: Date = Date()) {
        guard let index = state.orders.firstIndex(where: { $0.id == id && $0.isOpen }) else { return }
        state.orders[index].status = .canceled
        state.orders[index].resolvedAt = now
        state.orders[index].note = "已撤销"
        persist()
    }

    /// Start over with fresh cash. Positions and open orders are dropped —
    /// this is the user's "reset the paper account", and it says so on
    /// the record.
    public func reset(cash: Double, now: Date = Date()) {
        state = State(cash: cash, startingCash: cash, createdAt: state.createdAt, resetAt: now)
        persist()
        Log.warn("shadow: \(venue.displayName)影子账户已重置，现金 \(PriceFormatter.plain(cash))")
    }

    // MARK: Settlement

    /// Bring the book up to date with the latest quotes. Called by the
    /// venue on every read, so a pending order is judged whenever the
    /// runner looks — never later than its next tick.
    public func settle(quotes fresh: [String: Quote] = [:], now: Date = Date(), economics: Economics) {
        for (instId, quote) in fresh { quotes[instId] = quote }
        settle(now: now, economics: economics)
        persist()
    }

    private func settle(now: Date, economics: Economics) {
        guard calendar.isOpen(at: now) else { return }
        for index in state.orders.indices where state.orders[index].isOpen {
            let order = state.orders[index]
            guard let quote = quotes[order.instId] else { continue }
            guard let price = fillPrice(for: order, quote: quote, economics: economics) else { continue }
            fill(at: index, price: price, now: now, economics: economics)
        }
    }

    /// The price an open order executes at now, or nil while it waits.
    private func fillPrice(for order: Order, quote: Quote, economics: Economics) -> Double? {
        let slip = economics.slippageBps / 10_000
        let buyTouch = quote.ask ?? quote.last
        let sellTouch = quote.bid ?? quote.last
        if let stop = order.stopPrice {
            // A stop becomes a market order once the last trade crosses it,
            // and fills through the trigger, not at it.
            switch order.side {
            case .sell: return quote.last <= stop ? Swift.min(quote.last, stop) * (1 - slip) : nil
            case .buy: return quote.last >= stop ? Swift.max(quote.last, stop) * (1 + slip) : nil
            }
        }
        switch order.kind {
        case .market:
            return order.side == .buy ? buyTouch * (1 + slip) : sellTouch * (1 - slip)
        case .limit, .ioc:
            guard let limit = order.limitPrice else { return nil }
            switch order.side {
            case .buy: return buyTouch <= limit ? Swift.min(buyTouch, limit) : nil
            case .sell: return sellTouch >= limit ? Swift.max(sellTouch, limit) : nil
            }
        }
    }

    private func fill(at index: Int, price: Double, now: Date, economics: Economics) {
        var order = state.orders[index]
        var size = order.size
        if order.reduceOnly {
            // Never overshoot into the opposite side: a stop for ten shares
            // on a position that shrank to six closes six.
            let held = state.positions[order.instId]?.quantity ?? 0
            let closable = order.side == .sell ? Swift.max(held, 0) : Swift.max(-held, 0)
            size = Swift.min(size, closable)
            guard size > 0 else {
                order.status = .canceled
                order.resolvedAt = now
                order.note = "没有可平的仓位，已撤销"
                state.orders[index] = order
                return
            }
        }
        let notional = price * size
        let fee = economics.fees.charge(side: order.side, units: size, notional: notional)
        state.sequence += 1
        state.fills.append(Fill(
            id: "shadow-fill-\(state.sequence)", orderId: order.id, clOrdId: order.clOrdId,
            instId: order.instId, side: order.side, price: price, size: size, fee: fee, ts: now))
        if state.fills.count > Self.maxFills { state.fills.removeFirst(state.fills.count - Self.maxFills) }
        state.cash += order.side == .buy ? -(notional + fee) : (notional - fee)
        apply(instId: order.instId, side: order.side, size: size, price: price)
        order.status = .filled
        order.filledSize = size
        order.averagePrice = price
        order.resolvedAt = now
        order.note = size < order.size ? "按可平数量 \(PriceFormatter.plain(size)) 成交" : nil
        state.orders[index] = order
        if let group = order.ocoGroup {
            for other in state.orders.indices where state.orders[other].ocoGroup == group && state.orders[other].id != order.id && state.orders[other].isOpen {
                state.orders[other].status = .canceled
                state.orders[other].resolvedAt = now
                state.orders[other].note = "另一腿已成交，OCO 撤销"
            }
        }
    }

    /// Average-cost accounting, flipping through flat when a fill crosses it.
    private func apply(instId: String, side: OrderSide, size: Double, price: Double) {
        var position = state.positions[instId] ?? Position(instId: instId, quantity: 0, averagePrice: 0)
        let signed = side == .buy ? size : -size
        let before = position.quantity
        let after = before + signed
        if before == 0 || (before > 0) == (signed > 0) {
            let cost = abs(before) * position.averagePrice + size * price
            position.averagePrice = abs(after) > 0 ? cost / abs(after) : 0
        } else if (before > 0) != (after > 0) && after != 0 {
            position.averagePrice = price
        } else if after == 0 {
            position.averagePrice = 0
        }
        position.quantity = after
        if after == 0 {
            state.positions[instId] = nil
        } else {
            state.positions[instId] = position
        }
    }

    private func attachProtection(to order: Order, request: OrderRequest, now: Date) {
        let closing: OrderSide = request.side == .buy ? .sell : .buy
        var legs: [Order] = []
        if let stop = request.stopTriggerPrice {
            legs.append(Order(
                id: nextId("stop"), clOrdId: nil, instId: order.instId, side: closing, kind: .market,
                size: order.size, limitPrice: nil, stopPrice: stop, reduceOnly: true, status: .pending,
                filledSize: 0, averagePrice: nil, placedAt: now, resolvedAt: nil, note: nil, protective: true, ocoGroup: nil))
        }
        if let takeProfit = request.takeProfitTriggerPrice {
            legs.append(Order(
                id: nextId("tp"), clOrdId: nil, instId: order.instId, side: closing, kind: .limit,
                size: order.size, limitPrice: takeProfit, stopPrice: nil, reduceOnly: true, status: .pending,
                filledSize: 0, averagePrice: nil, placedAt: now, resolvedAt: nil, note: nil, protective: true, ocoGroup: nil))
        }
        guard !legs.isEmpty else { return }
        let group = legs.count > 1 ? "oco-\(order.id)" : nil
        for var leg in legs {
            leg.ocoGroup = group
            state.orders.append(leg)
        }
    }

    /// Reg T: the book after this order may not carry exposure beyond the
    /// leverage cap times equity. Reducing orders are always allowed.
    private func regTRefusal(for order: Order, economics: Economics) -> String? {
        guard let quote = quotes[order.instId] else {
            return "没有 \(order.instId) 的行情，无法撮合"
        }
        let held = state.positions[order.instId]?.quantity ?? 0
        let signed = order.side == .buy ? order.size : -order.size
        let after = held + signed
        guard abs(after) > abs(held) else { return nil }
        let snapshot = snapshot()
        guard let equity = snapshot.totalEquity else { return "持仓没有行情，无法计算购买力" }
        var exposure = 0.0
        for position in state.positions.values where position.instId != order.instId {
            guard let mark = quotes[position.instId]?.last else { return "持仓没有行情，无法计算购买力" }
            exposure += abs(position.quantity) * mark
        }
        exposure += abs(after) * (order.limitPrice ?? quote.last)
        let cap = equity * economics.maxLeverage
        guard exposure <= cap + 1e-6 else {
            return String(
                format: "超出 Reg T 购买力：成交后敞口 %.0f，权益 %.0f 的 %.0f 倍上限是 %.0f",
                exposure, equity, economics.maxLeverage, cap)
        }
        return nil
    }

    // MARK: Plumbing

    private func nextId(_ prefix: String) -> String {
        state.sequence += 1
        return "\(prefix)-\(state.sequence)"
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            Log.warn("shadow: 影子账户写盘失败：\(error)")
        }
    }
}
