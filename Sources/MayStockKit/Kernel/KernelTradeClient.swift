import Foundation
import CMayStockKernel

// MARK: - What can be sent

/// How an order rests, as the kernel names it (`trade::wire::OrderKind`).
public enum TradeOrderKind: String, Codable, Sendable, CaseIterable, Equatable {
    case market, limit
    /// Rests as a maker or is cancelled; never takes.
    case postOnly = "post_only"
    /// Fills what it can at once, cancels the rest.
    case ioc
    /// Fills entirely at once or not at all.
    case fok

    public init(_ kind: OrderKind) {
        switch kind {
        case .market: self = .market
        case .limit: self = .limit
        case .ioc: self = .ioc
        }
    }

    public var isPriced: Bool { self != .market }

    public var displayName: String {
        switch self {
        case .market: return "市价"
        case .limit: return "限价"
        case .postOnly: return "只做 Maker"
        case .ioc: return "IOC"
        case .fok: return "FOK"
        }
    }

    /// What it does to the part that does not fill at once.
    public var explanation: String {
        switch self {
        case .market: return "按对手盘逐档成交"
        case .limit: return "没成交的部分一直挂着，直到成交或撤单"
        case .postOnly: return "只挂单不吃单；会立即成交的价格会被交易所直接撤销"
        case .ioc: return "能成交的立即成交，其余立即撤销"
        case .fok: return "必须一次全部成交，否则整单撤销"
        }
    }
}

/// A regular order (`trade::wire::OrderSpec`).
public struct TradeOrderSpec: Codable, Sendable, Equatable {
    public var instId: String
    public var instType: InstrumentType
    public var side: OrderSide
    public var kind: TradeOrderKind
    /// Contracts for derivatives, coins for spot — or the quote currency
    /// when `sizeInQuote`.
    public var size: Double
    public var sizeInQuote: Bool
    public var price: Double?
    public var tradeMode: String?
    public var posSide: PositionSide?
    public var reduceOnly: Bool
    public var clientId: String?
    public var stopTrigger: Double?
    public var takeProfitTrigger: Double?

    public init(
        instId: String, instType: InstrumentType, side: OrderSide, kind: TradeOrderKind, size: Double,
        sizeInQuote: Bool = false, price: Double? = nil, tradeMode: String? = nil, posSide: PositionSide? = nil,
        reduceOnly: Bool = false, clientId: String? = nil, stopTrigger: Double? = nil, takeProfitTrigger: Double? = nil
    ) {
        self.instId = instId
        self.instType = instType
        self.side = side
        self.kind = kind
        self.size = size
        self.sizeInQuote = sizeInQuote
        self.price = price
        self.tradeMode = tradeMode
        self.posSide = posSide
        self.reduceOnly = reduceOnly
        self.clientId = clientId
        self.stopTrigger = stopTrigger
        self.takeProfitTrigger = takeProfitTrigger
    }

    /// The runner's and the order gate's request, as the kernel sends it.
    /// A quote-sized request only means something on a spot market order
    /// (`tgtCcy=quote_ccy`); everywhere else the size is in order units.
    public init(_ order: OrderRequest) {
        self.init(
            instId: order.instId, instType: order.instType, side: order.side,
            kind: TradeOrderKind(order.kind), size: order.size,
            sizeInQuote: order.instType == .spot && order.kind == .market && order.sizeUnit == .quote,
            price: order.kind.isPriced ? order.limitPrice : nil,
            tradeMode: order.tradeMode, posSide: order.posSide, reduceOnly: order.reduceOnly,
            clientId: order.clOrdId, stopTrigger: order.stopTriggerPrice,
            takeProfitTrigger: order.takeProfitTriggerPrice)
    }
}

/// An order the exchange works after it is placed (`trade::wire::AlgoSpec`).
public struct TradeAlgoSpec: Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        /// Post-only at the best price, re-priced every second, cancelled
        /// once the book has run `maxChaseRatio` (0.002 = 0.2%).
        case chase(maxChaseRatio: Double)
        /// Filled at market once the last trade crosses a trigger.
        case protection(takeProfit: Double?, stopLoss: Double?)

        private enum CodingKeys: String, CodingKey { case type, maxChaseRatio, takeProfit, stopLoss }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "chase":
                self = .chase(maxChaseRatio: try c.decode(Double.self, forKey: .maxChaseRatio))
            case "protection":
                self = .protection(
                    takeProfit: try c.decodeIfPresent(Double.self, forKey: .takeProfit),
                    stopLoss: try c.decodeIfPresent(Double.self, forKey: .stopLoss))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "未知的策略委托类型 \(other)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .chase(let ratio):
                try c.encode("chase", forKey: .type)
                try c.encode(ratio, forKey: .maxChaseRatio)
            case .protection(let takeProfit, let stopLoss):
                try c.encode("protection", forKey: .type)
                try c.encodeIfPresent(takeProfit, forKey: .takeProfit)
                try c.encodeIfPresent(stopLoss, forKey: .stopLoss)
            }
        }
    }

    public var instId: String
    public var instType: InstrumentType
    public var side: OrderSide
    public var posSide: PositionSide?
    public var size: Double
    public var tradeMode: String?
    public var reduceOnly: Bool
    /// Cancelled by the exchange with its position (`cxlOnClosePos`).
    public var cancelWithPosition: Bool
    public var clientId: String?
    public var kind: Kind

    public init(
        instId: String, instType: InstrumentType, side: OrderSide, posSide: PositionSide?, size: Double,
        tradeMode: String?, reduceOnly: Bool, cancelWithPosition: Bool, clientId: String? = nil, kind: Kind
    ) {
        self.instId = instId
        self.instType = instType
        self.side = side
        self.posSide = posSide
        self.size = size
        self.tradeMode = tradeMode
        self.reduceOnly = reduceOnly
        self.cancelWithPosition = cancelWithPosition
        self.clientId = clientId
        self.kind = kind
    }
}

/// Everything the kernel can ask OKX to do to an account
/// (`trade::wire::Action`) — closed, as it is there.
public enum TradeAction: Codable, Sendable, Equatable {
    case place(TradeOrderSpec)
    case placeAlgo(TradeAlgoSpec)
    case cancel(instId: String, orderId: String)
    case cancelAlgo(instId: String, algoId: String)
    /// Move an existing stop's trigger; it still fills at market.
    case amendStop(instId: String, algoId: String, stop: Double)
    /// The exchange's own check of an order, without placing it.
    case precheck(TradeOrderSpec)

    private enum CodingKeys: String, CodingKey { case action, order, algo, instId, orderId, algoId, stop }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .action) {
        case "place": self = .place(try c.decode(TradeOrderSpec.self, forKey: .order))
        case "placeAlgo": self = .placeAlgo(try c.decode(TradeAlgoSpec.self, forKey: .algo))
        case "cancel":
            self = .cancel(instId: try c.decode(String.self, forKey: .instId), orderId: try c.decode(String.self, forKey: .orderId))
        case "cancelAlgo":
            self = .cancelAlgo(instId: try c.decode(String.self, forKey: .instId), algoId: try c.decode(String.self, forKey: .algoId))
        case "amendStop":
            self = .amendStop(
                instId: try c.decode(String.self, forKey: .instId), algoId: try c.decode(String.self, forKey: .algoId),
                stop: try c.decode(Double.self, forKey: .stop))
        case "precheck": self = .precheck(try c.decode(TradeOrderSpec.self, forKey: .order))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "未知的交易动作 \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .place(let order):
            try c.encode("place", forKey: .action)
            try c.encode(order, forKey: .order)
        case .placeAlgo(let algo):
            try c.encode("placeAlgo", forKey: .action)
            try c.encode(algo, forKey: .algo)
        case .cancel(let instId, let orderId):
            try c.encode("cancel", forKey: .action)
            try c.encode(instId, forKey: .instId)
            try c.encode(orderId, forKey: .orderId)
        case .cancelAlgo(let instId, let algoId):
            try c.encode("cancelAlgo", forKey: .action)
            try c.encode(instId, forKey: .instId)
            try c.encode(algoId, forKey: .algoId)
        case .amendStop(let instId, let algoId, let stop):
            try c.encode("amendStop", forKey: .action)
            try c.encode(instId, forKey: .instId)
            try c.encode(algoId, forKey: .algoId)
            try c.encode(stop, forKey: .stop)
        case .precheck(let order):
            try c.encode("precheck", forKey: .action)
            try c.encode(order, forKey: .order)
        }
    }

    /// The instrument it acts on.
    public var instId: String {
        switch self {
        case .place(let order), .precheck(let order): return order.instId
        case .placeAlgo(let algo): return algo.instId
        case .cancel(let instId, _), .cancelAlgo(let instId, _), .amendStop(let instId, _, _): return instId
        }
    }
}

/// One request exactly as it is signed and sent.
public struct WireRequest: Decodable, Sendable, Equatable {
    public let endpoint: String
    public let method: String
    public let path: String
    public let body: String

    /// The body laid out for reading, keys in the order they were sent.
    public var prettyBody: String {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return body }
        return text
    }
}

/// An accepted request: the exchange's id for what it now holds.
public struct TradeReceipt: Sendable, Equatable {
    /// The order or algo id; nil for a precheck, which places nothing.
    public let id: String?
    public let clientId: String?
    public let elapsedMs: Int
    public let raw: String
}

/// The account's fee rates, as fractions of notional — positive when
/// charged, negative when rebated.
public struct FeeRates: Codable, Sendable, Equatable {
    public let maker: Double
    public let taker: Double

    public init(maker: Double, taker: Double) {
        self.maker = maker
        self.taker = taker
    }
}

// MARK: - The kernel's trading path

/// Swift face of the kernel's `trade` module: orders signed and sent over
/// REST by the kernel itself, with the key from the okx CLI's config file.
///
/// Every call blocks inside the kernel until the exchange answers or the
/// request times out, so each runs on a queue of its own, never on the
/// cooperative pool a stalled network would starve.
public struct KernelTradeClient: Sendable {
    public let configPath: String
    public let demoProfile: String?
    public let liveProfile: String?

    public init(configPath: String, demoProfile: String?, liveProfile: String?) {
        self.configPath = configPath
        self.demoProfile = demoProfile
        self.liveProfile = liveProfile
    }

    /// The profiles the app's settings map each environment to.
    public init(bridge: TradeBridge, configPath: String = OKXProfileCatalog.defaultFileURL().path) {
        self.init(configPath: configPath, demoProfile: bridge.demoProfile, liveProfile: bridge.liveProfile)
    }

    private struct Access: Encodable {
        let mode: String
        let liveUnlocked: Bool
        let configPath: String
        let profile: String?
    }

    private func access(_ mode: TradingMode, liveUnlocked: Bool) -> Access {
        Access(
            mode: mode == .demo ? "demo" : "live", liveUnlocked: liveUnlocked, configPath: configPath,
            profile: mode == .demo ? demoProfile : liveProfile)
    }

    /// Two JSON objects merged, the way the kernel reads a request: the
    /// access fields and the action's fields side by side.
    private static func merged<A: Encodable, B: Encodable>(_ a: A, _ b: B) throws -> String {
        let encoder = JSONEncoder()
        guard var first = try JSONSerialization.jsonObject(with: encoder.encode(a)) as? [String: Any],
              let second = try JSONSerialization.jsonObject(with: encoder.encode(b)) as? [String: Any] else {
            throw KernelError.encoding("请求不是 JSON 对象")
        }
        first.merge(second) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: first, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static let queue = DispatchQueue(label: "maystock.kernel.trade", qos: .userInitiated, attributes: .concurrent)

    private static func offload(_ body: @escaping @Sendable () -> String) async -> String {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    // MARK: Acting

    private struct Reply: Decodable {
        let outcome: String
        let id: String?
        let clientId: String?
        let elapsedMs: Int?
        let raw: String?
        let code: String?
        let message: String?
        let reason: String?
    }

    /// What it took beyond one request — sending again what the exchange
    /// certainly had not acted on, or waiting for room under its rate
    /// limit — is logged in the kernel's words, whatever came of it.
    private static func noteDelivery(_ text: String, _ what: String) {
        guard let reply = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let note = reply["note"] as? String else { return }
        Log.warn("trade: \(what) \(note)，结果 \(reply["outcome"] as? String ?? "?")")
    }

    /// Sign and send one action. Returns the receipt, or throws what became
    /// of it: `.rejected` (the exchange refused — final), `.notDelivered`
    /// (the exchange certainly did not act on it — safe to send again),
    /// `.unconfirmed` (no verdict — may have been acted on),
    /// `.liveTradingLocked` or `.refused` (stopped here). An outcome this
    /// side does not know is `.unconfirmed`: it says nothing about whether
    /// the order was acted on.
    public func send(_ action: TradeAction, mode: TradingMode, liveUnlocked: Bool) async throws -> TradeReceipt {
        let request: String
        do {
            request = try Self.merged(access(mode, liveUnlocked: liveUnlocked), action)
        } catch {
            throw TradeError.refused("请求无法编码：\(error)")
        }
        let text = await Self.offload {
            guard let pointer = ms_trade_send(request) else { return "" }
            defer { ms_string_free(pointer) }
            return String(cString: pointer)
        }
        Self.noteDelivery(text, "\(action.instId) 下单/撤单")
        return try Self.receipt(from: text)
    }

    /// The kernel's reply to a send, read: the receipt, or the error that
    /// says what became of the order.
    static func receipt(from text: String) throws -> TradeReceipt {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(text.utf8)) else {
            throw TradeError.unconfirmed("内核回复无法解析：\(text.prefix(200))")
        }
        switch reply.outcome {
        case "accepted":
            return TradeReceipt(id: reply.id, clientId: reply.clientId, elapsedMs: reply.elapsedMs ?? 0, raw: reply.raw ?? "")
        case "rejected":
            throw TradeError.rejected(venue: Venue.okx.displayName, reason: "\(reply.code ?? "?") \(reply.message ?? "")")
        case "notDelivered":
            throw TradeError.notDelivered(reply.reason ?? "未给出原因")
        case "unconfirmed":
            throw TradeError.unconfirmed(reply.reason ?? "未给出原因")
        case "refused" where reply.code == "liveLocked":
            throw TradeError.liveTradingLocked
        case "refused":
            throw TradeError.refused(reply.reason ?? "未给出原因")
        default:
            throw TradeError.unconfirmed("内核回复了不认识的结果 \(reply.outcome)：\(text.prefix(200))")
        }
    }

    /// The exact request an action becomes, from the same function that
    /// builds what `send` signs.
    public static func describe(_ action: TradeAction) throws -> WireRequest {
        let json = try encodeJSON(action)
        let text = try callReturningString { error in ms_trade_describe(json, error) }
        return try JSONDecoder().decode(WireRequest.self, from: Data(text.utf8))
    }

    /// Open the connection ahead of the first order, so the order itself
    /// pays one round trip. Returns that round trip in milliseconds.
    @discardableResult
    public static func warm() async -> Result<Int, KernelError> {
        let text = await offload {
            var error: UnsafeMutablePointer<CChar>?
            let ms = ms_trade_warm(&error)
            if ms < 0 { return "!" + (KernelStrategy.take(&error) ?? "预热失败") }
            return String(ms)
        }
        if text.hasPrefix("!") { return .failure(.kernel(String(text.dropFirst()))) }
        return .success(Int(text) ?? 0)
    }

    // MARK: Reading

    private struct ReadReply<T: Decodable>: Decodable {
        let outcome: String
        let data: T?
        let reason: String?
    }

    /// One signed read: the kernel's reply, as text.
    private func call(_ read: [String: String?], extra: [String: [String]], mode: TradingMode) async throws -> String {
        var fields: [String: Any] = [:]
        for (key, value) in read { if let value { fields[key] = value } }
        for (key, value) in extra { fields[key] = value }
        let accessData = try JSONEncoder().encode(access(mode, liveUnlocked: false))
        guard var object = try JSONSerialization.jsonObject(with: accessData) as? [String: Any] else {
            throw KernelError.encoding("请求不是 JSON 对象")
        }
        object.merge(fields) { _, new in new }
        let request = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        let text = await Self.offload {
            guard let pointer = ms_trade_read(request) else { return "" }
            defer { ms_string_free(pointer) }
            return String(cString: pointer)
        }
        Self.noteDelivery(text, "读取 \(read["read"].flatMap { $0 } ?? "?")")
        return text
    }

    /// A read whose answer is one of OKX's own documents, handed back whole
    /// for the one reader of its fields (`KernelAccount`).
    private func document(_ read: [String: String?], mode: TradingMode) async throws -> String {
        let text = try await call(read, extra: [:], mode: mode)
        guard let reply = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw TradeError.readFailed("内核回复无法解析：\(text.prefix(200))")
        }
        guard reply["outcome"] as? String == "ok", let data = reply["data"],
              JSONSerialization.isValidJSONObject(data) else {
            throw TradeError.readFailed(reply["reason"] as? String ?? "未给出原因")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
    }

    private func read<T: Decodable>(_ read: [String: String?], extra: [String: [String]] = [:], mode: TradingMode) async throws -> T {
        let text = try await call(read, extra: extra, mode: mode)
        let reply: ReadReply<T>
        do {
            reply = try JSONDecoder().decode(ReadReply<T>.self, from: Data(text.utf8))
        } catch {
            throw TradeError.readFailed("内核回复无法解析：\(error)")
        }
        guard reply.outcome == "ok", let data = reply.data else {
            throw TradeError.readFailed(reply.reason ?? "未给出原因")
        }
        return data
    }

    private struct Row: Decodable {
        let id: String
        let book: String
        let instId: String
        let instType: String?
        let ordType: String
        let side: String
        let posSide: String?
        let price: Double?
        let triggerPrice: Double?
        let stopTriggerPrice: Double?
        let takeProfitTriggerPrice: Double?
        let size: Double?
        let closeFraction: Double?
        let filledSize: Double?
        let state: String?
        let reduceOnly: Bool?
        let clientId: String?
        let createdMs: Double?

        var order: ExchangeOpenOrder? {
            guard let side = OrderSide(rawValue: side) else { return nil }
            return ExchangeOpenOrder(
                id: id, book: book == "algo" ? .algo : .order, instId: instId, ordType: ordType, side: side,
                posSide: posSide.flatMap(PositionSide.init(rawValue:)), price: price, triggerPrice: triggerPrice,
                stopTriggerPrice: stopTriggerPrice, takeProfitTriggerPrice: takeProfitTriggerPrice, size: size,
                closeFraction: closeFraction, filledSize: filledSize ?? 0, state: state ?? "",
                reduceOnly: reduceOnly ?? false, clOrdId: clientId,
                createdAt: createdMs.map { Date(timeIntervalSince1970: $0 / 1_000) })
        }
    }

    private struct Listing: Decodable {
        let orders: [Row]
        let unavailable: [String]
    }

    /// Working orders on both books — every family OKX lists for this app
    /// when none is named — narrowed to one instrument when `instId` is set.
    /// A listing that could not be read is named in `unavailable`.
    public func workingOrders(
        mode: TradingMode, families: [InstrumentType] = [], instId: String? = nil
    ) async throws -> OpenOrderListing {
        let listing: Listing = try await read(
            ["read": "workingOrders", "instId": instId],
            extra: ["families": families.map(\.rawValue)], mode: mode)
        return OpenOrderListing(orders: listing.orders.compactMap(\.order), unavailable: listing.unavailable)
    }

    private struct Status: Decodable {
        let status: String
        let filledSize: Double?
        let averagePrice: Double?
    }

    /// One order by the client id it was sent with. `.unknown` only when the
    /// exchange has no such order — the one answer that makes a resend safe.
    public func orderStatus(instId: String, clientId: String, mode: TradingMode) async throws -> VenueOrderStatus {
        let status: Status = try await read(["read": "orderStatus", "instId": instId, "clientId": clientId], mode: mode)
        switch status.status {
        case "live": return .live
        case "canceled": return .canceled
        case "filled": return .filled(filledSize: status.filledSize ?? 0, averagePrice: status.averagePrice ?? 0)
        default: return .unknown
        }
    }

    /// The stops and targets armed on one instrument — its `conditional`
    /// and `oco` orders — as the runner's trailing stop reads them.
    public func protectiveOrders(family: InstrumentType, instId: String, mode: TradingMode) async throws -> [VenueProtectiveOrder] {
        let listing: Listing = try await read(["read": "protection", "family": family.rawValue, "instId": instId], mode: mode)
        return Self.protective(listing.orders.compactMap(\.order), instId: instId)
    }

    /// The orders that protect a position on `instId`: its own, with a stop
    /// or a target. An algo order with neither leg protects nothing.
    static func protective(_ orders: [ExchangeOpenOrder], instId: String) -> [VenueProtectiveOrder] {
        orders.filter { $0.instId == instId }.compactMap { order in
            guard order.stopTriggerPrice != nil || order.takeProfitTriggerPrice != nil else { return nil }
            return VenueProtectiveOrder(
                algoId: order.id, instId: instId, stopTriggerPrice: order.stopTriggerPrice,
                takeProfitTriggerPrice: order.takeProfitTriggerPrice, size: order.size ?? 0, posSide: order.posSide)
        }
    }

    /// The account's open positions — one family's when named — short legs
    /// negative.
    public func positions(mode: TradingMode, family: InstrumentType? = nil) async throws -> [ExchangePosition] {
        KernelAccount.positions(try await document(["read": "positions", "family": family?.rawValue], mode: mode))
    }

    /// The trading account's balances — one currency's when named. What an
    /// order can sell is `available` here: coins in the funding account are
    /// not on the book until moved.
    public func balances(mode: TradingMode, ccy: String? = nil) async throws -> [AccountBalance] {
        KernelAccount.balances(try await document(["read": "balance", "ccy": ccy], mode: mode))
    }

    /// The whole account — trading and funding balances, and the USD
    /// valuation — as the checkup, the overview and the runner's sizing read it.
    public func accountSnapshot(mode: TradingMode) async throws -> AccountSnapshot {
        let document = try await document(["read": "accountSnapshot"], mode: mode)
        return AccountSnapshot(
            balances: KernelAccount.balances(document),
            totalEquity: KernelAccount.totalEquity(document),
            // Both figures the reader returns are dollars: `totalEq` is OKX's
            // own USD equity, and `totalBal` is the valuation asked for in USD.
            equityCurrency: "USD")
    }

    /// How the account is set up for derivatives: position mode and level.
    public func accountTradingConfig(mode: TradingMode) async throws -> AccountTradingConfig {
        let document = try await document(["read": "accountConfig"], mode: mode)
        guard let config = TradeBridge.parseAccountTradingConfig(json: document) else {
            throw TradeError.readFailed("账户配置里没有 acctLv / posMode")
        }
        return config
    }

    /// The same document, as the connection card shows it.
    public func accountConfigInfo(mode: TradingMode) async throws -> AccountConfigInfo {
        let document = try await document(["read": "accountConfig"], mode: mode)
        guard let info = TradeBridge.parseAccountConfig(json: document) else {
            throw TradeError.readFailed("账户配置里没有 acctLv / posMode")
        }
        return info
    }

    /// The last three days' fills on one family, oldest first, each with the
    /// `clOrdId` it was tagged with.
    public func fills(mode: TradingMode, family: InstrumentType, instId: String? = nil) async throws -> [ExchangeFill] {
        TradeBridge.parseFills(json: try await document(
            ["read": "fills", "family": family.rawValue, "instId": instId], mode: mode))
    }

    /// Everything the account has filled lately, whichever family and whoever
    /// placed it. One read per family — the listing takes one `instType` —
    /// and a family that could not be read is named in `unavailable`, since
    /// a missing fill book hides what *happened*.
    public func fillListing(mode: TradingMode) async throws -> ExchangeFillListing {
        let families = InstrumentType.allCases.filter { Venue.okx.trades($0) }
        let results = await withTaskGroup(of: (InstrumentType, Result<[ExchangeFill], Error>).self) { group in
            for family in families {
                group.addTask {
                    do { return (family, .success(try await fills(mode: mode, family: family))) }
                    catch { return (family, .failure(error)) }
                }
            }
            var out: [(InstrumentType, Result<[ExchangeFill], Error>)] = []
            for await result in group { out.append(result) }
            return out
        }
        var listing = ExchangeFillListing()
        var firstError: Error?
        for (family, result) in results {
            switch result {
            case .success(let fills): listing.fills += fills
            case .failure(let error):
                firstError = firstError ?? error
                listing.unavailable.append(family.displayName)
                Log.warn("trade: 读取\(family.displayName)成交失败：\(error)")
            }
        }
        if listing.unavailable.count == families.count, let firstError { throw firstError }
        listing.unavailable.sort()
        return listing
    }

    /// Funding settled on perpetual positions (bill type 8), on one
    /// instrument when named.
    public func fundingPayments(mode: TradingMode, instId: String?) async throws -> [FundingPayment] {
        TradeBridge.parseFundingPayments(json: try await document(["read": "fundingBills"], mode: mode), instId: instId)
    }

    /// Prove the path orders take works for this environment: the account
    /// read and its configuration, both signed by the kernel with the key the
    /// environment is mapped to.
    public func verifyConnection(mode: TradingMode) async throws -> VenueConnectionReport {
        async let snapshot = accountSnapshot(mode: mode)
        async let config = try? accountConfigInfo(mode: mode)
        return VenueConnectionReport(
            mode: mode, profile: mode == .demo ? demoProfile : liveProfile, checkedAt: Date(),
            totalEquity: try await snapshot.totalEquity, balanceCount: try await snapshot.balances.count,
            account: await config)
    }

    /// The positions and balance documents, unparsed, for the live layer's
    /// fallback when its account socket is down.
    public func accountDocuments(mode: TradingMode) async throws -> (positions: String, balance: String) {
        async let positions = document(["read": "positions"], mode: mode)
        async let balance = document(["read": "balance"], mode: mode)
        return try await (positions, balance)
    }

    /// The account's fee rates: on one instrument, from its own fee group, or
    /// — without one — the family's standard rates.
    public func feeRates(family: InstrumentType, instId: String?, groupId: String?, mode: TradingMode) async throws -> FeeRates {
        try await read(["read": "feeRates", "family": family.rawValue, "instId": instId, "groupId": groupId], mode: mode)
    }
}
