import Foundation
import CMayStockKernel

// MARK: - What can be done

/// How a holding is closed.
public enum CloseMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case limit, chase, market, protect

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .market: return "市价"
        case .limit: return "限价"
        case .chase: return "追逐限价"
        case .protect: return "止盈止损"
        }
    }
}

public struct CloseAvailability: Codable, Sendable, Equatable {
    public let available: Bool
    /// Why not — shown on the control, never hidden.
    public let reason: String?

    public init(available: Bool, reason: String?) {
        self.available = available
        self.reason = reason
    }
}

/// Where a limit price comes from.
public enum ClosePriceSourceKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The Nth level on the other side: fills against the levels up to it.
    case counterparty
    /// The Nth level on the order's own side: joins that queue.
    case queue
    case mid, last, fixed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .counterparty: return "对手价"
        case .queue: return "同向价"
        case .mid: return "中间价"
        case .last: return "最新价"
        case .fixed: return "自定义"
        }
    }

    public var takesLevel: Bool { self == .counterparty || self == .queue }
}

/// What a venue can do to close a holding of one family — declared in the
/// kernel, once, for every venue (`trade::close::capabilities`).
public struct CloseCapabilities: Codable, Sendable, Equatable {
    public let market: CloseAvailability
    public let limit: CloseAvailability
    public let chase: CloseAvailability
    public let takeProfit: CloseAvailability
    public let stopLoss: CloseAvailability
    public let limitKinds: [TradeOrderKind]
    public let priceSources: [ClosePriceSourceKind]
    /// Levels of the book the venue shows; 1 is the touch alone.
    public let bookDepth: Int

    public func availability(of method: CloseMethod) -> CloseAvailability {
        switch method {
        case .market: return market
        case .limit: return limit
        case .chase: return chase
        case .protect:
            if takeProfit.available || stopLoss.available { return CloseAvailability(available: true, reason: nil) }
            return stopLoss
        }
    }

    /// Nothing can be done, for one reason — a family the app does not trade.
    public static func none(_ reason: String) -> CloseCapabilities {
        let no = CloseAvailability(available: false, reason: reason)
        return CloseCapabilities(
            market: no, limit: no, chase: no, takeProfit: no, stopLoss: no,
            limitKinds: [], priceSources: [], bookDepth: 0)
    }

    public static func unsupportedFamily(_ filedAs: String, venue: Venue) -> CloseCapabilities {
        .none("\(venue.displayName)的\(filedAs.isEmpty ? "这类" : filedAs)持仓不在 App 能交易的品种里（永续、期权、现货、股票），请到交易所处理")
    }
}

// MARK: - What is asked

public enum ClosePriceSource: Codable, Sendable, Equatable, Hashable {
    case counterparty(level: Int)
    case queue(level: Int)
    case mid
    case last
    case fixed(Double)

    public var kind: ClosePriceSourceKind {
        switch self {
        case .counterparty: return .counterparty
        case .queue: return .queue
        case .mid: return .mid
        case .last: return .last
        case .fixed: return .fixed
        }
    }

    public var level: Int? {
        switch self {
        case .counterparty(let level), .queue(let level): return level
        default: return nil
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, level, price }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "counterparty": self = .counterparty(level: try c.decode(Int.self, forKey: .level))
        case "queue": self = .queue(level: try c.decode(Int.self, forKey: .level))
        case "mid": self = .mid
        case "last": self = .last
        case "fixed": self = .fixed(try c.decode(Double.self, forKey: .price))
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "未知的价格来源 \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .kind)
        switch self {
        case .counterparty(let level), .queue(let level): try c.encode(level, forKey: .level)
        case .fixed(let price): try c.encode(price, forKey: .price)
        case .mid, .last: break
        }
    }
}

public enum CloseSize: Codable, Sendable, Equatable {
    /// All of it, as held when the plan is made.
    case all
    case amount(Double)

    private enum CodingKeys: String, CodingKey { case kind, amount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = try c.decode(String.self, forKey: .kind) == "all" ? .all : .amount(try c.decode(Double.self, forKey: .amount))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all: try c.encode("all", forKey: .kind)
        case .amount(let amount):
            try c.encode("amount", forKey: .kind)
            try c.encode(amount, forKey: .amount)
        }
    }
}

/// What the person asked for (`trade::close::Ticket`).
public struct CloseTicketInput: Codable, Sendable, Equatable {
    public var method: CloseMethod
    public var size: CloseSize
    public var price: ClosePriceSource
    public var limitKind: TradeOrderKind
    public var maxChasePct: Double
    public var takeProfit: Double?
    public var stopLoss: Double?

    public init(
        method: CloseMethod, size: CloseSize, price: ClosePriceSource = .counterparty(level: 1),
        limitKind: TradeOrderKind = .limit, maxChasePct: Double = CloseTicketInput.defaultMaxChasePct,
        takeProfit: Double? = nil, stopLoss: Double? = nil
    ) {
        self.method = method
        self.size = size
        self.price = price
        self.limitKind = limitKind
        self.maxChasePct = maxChasePct
        self.takeProfit = takeProfit
        self.stopLoss = stopLoss
    }

    /// May's choice, 2026-09-24 (`trade::close::DEFAULT_MAX_CHASE_PCT`).
    public static let defaultMaxChasePct = 0.2
}

/// The holding as the exchange reports it now (`trade::close::Holding`).
public struct CloseHolding: Codable, Sendable, Equatable {
    public let instId: String
    public let family: InstrumentType
    /// A coin is always long.
    public let isLong: Bool
    /// What can be closed, positive: contracts, coins, shares.
    public let quantity: Double
    /// Those units for a person: `张`, `ETH`, `股`.
    public let unit: String
    public let posSide: PositionSide?
    /// `cross`, `isolated` or `cash`.
    public let marginMode: String?
    public let averagePrice: Double?
    public let liquidationPrice: Double?

    public init(
        instId: String, family: InstrumentType, isLong: Bool, quantity: Double, unit: String,
        posSide: PositionSide?, marginMode: String?, averagePrice: Double?, liquidationPrice: Double?
    ) {
        self.instId = instId
        self.family = family
        self.isLong = isLong
        self.quantity = quantity
        self.unit = unit
        self.posSide = posSide
        self.marginMode = marginMode
        self.averagePrice = averagePrice
        self.liquidationPrice = liquidationPrice
    }

    public init(position: ExchangePosition, family: InstrumentType) {
        self.init(
            instId: position.instId, family: family, isLong: position.quantity > 0,
            quantity: abs(position.quantity), unit: family == .stock ? "股" : "张",
            posSide: family.usesPositionSide ? position.posSide : nil,
            marginMode: position.marginMode?.rawValue,
            averagePrice: position.averagePrice > 0 ? position.averagePrice : nil,
            liquidationPrice: position.liquidationPrice)
    }

    public init(coin: String, available: Double, instId: String) {
        self.init(
            instId: instId, family: .spot, isLong: true, quantity: max(available, 0), unit: coin,
            posSide: nil, marginMode: nil, averagePrice: nil, liquidationPrice: nil)
    }

    /// A long is sold, a short bought back.
    public var closingSide: OrderSide { isLong ? .sell : .buy }

    public var actionLabel: String {
        switch family {
        case .swap, .option: return isLong ? "卖出平多" : "买入平空"
        case .spot, .stock: return isLong ? "卖出" : "买入平空"
        }
    }
}

/// Everything a plan is made from (`trade::close::PlanInput`).
public struct ClosePlanInput: Encodable, Sendable {
    public struct Account: Encodable, Sendable {
        public let level: Int?
    }

    /// An open order on the instrument, as the kernel reads one.
    public struct Working: Encodable, Sendable {
        let id: String
        let book: String
        let instId: String
        let ordType: String
        let side: String
        let posSide: String?
        let price: Double?
        let triggerPrice: Double?
        let stopTriggerPrice: Double?
        let takeProfitTriggerPrice: Double?
        let size: Double?
        let closeFraction: Double?
        let filledSize: Double
        let state: String
        let reduceOnly: Bool
        let clientId: String?

        init(_ order: ExchangeOpenOrder) {
            id = order.id
            book = order.book.rawValue
            instId = order.instId
            ordType = order.ordType
            side = order.side.rawValue
            posSide = order.posSide?.rawValue
            price = order.price
            triggerPrice = order.triggerPrice
            stopTriggerPrice = order.stopTriggerPrice
            takeProfitTriggerPrice = order.takeProfitTriggerPrice
            size = order.size
            closeFraction = order.closeFraction
            filledSize = order.filledSize
            state = order.state
            reduceOnly = order.reduceOnly
            clientId = order.clOrdId
        }
    }

    let venue: String
    let mode: String
    let holding: CloseHolding
    let ticket: CloseTicketInput
    let account: Account?
    let fees: FeeRates?
    let working: [Working]?
    let workingUnread: String?
    let clientId: String?
    let nowMs: Int64

    public init(
        venue: Venue, mode: TradingMode, holding: CloseHolding, ticket: CloseTicketInput,
        account: AccountTradingConfig?, fees: FeeRates?, working: [ExchangeOpenOrder]?, workingUnread: String?,
        clientId: String?, now: Date = Date()
    ) {
        self.venue = venue.rawValue
        self.mode = mode == .demo ? "demo" : "live"
        self.holding = holding
        self.ticket = ticket
        self.account = account.map { Account(level: $0.accountLevel) }
        self.fees = fees
        self.working = working?.map(Working.init)
        self.workingUnread = workingUnread
        self.clientId = clientId
        self.nowMs = Int64(now.timeIntervalSince1970 * 1_000)
    }
}

// MARK: - The plan

public struct CloseMoney: Decodable, Sendable, Equatable {
    public let amount: Double
    public let ccy: String
    /// As it reads — written by the kernel, for every screen alike.
    public let text: String
}

public struct CloseFill: Decodable, Sendable, Equatable {
    public let size: Double
    public let average: Double
    public let worst: Double
    public let levels: Int
}

public struct CloseResting: Decodable, Sendable, Equatable {
    public let size: Double
    public let price: Double
}

public struct CloseLeg: Decodable, Sendable, Equatable {
    public let label: String
    public let trigger: Double
    public let distancePct: Double?
    public let pnl: CloseMoney?
}

/// What the close is expected to do against the book as published.
public struct CloseEstimate: Decodable, Sendable, Equatable {
    public let mid: Double?
    public let spreadBps: Double?
    /// Filled on arrival, taking liquidity.
    public let taker: CloseFill?
    /// Left resting, making it.
    public let maker: CloseResting?
    /// Cancelled on arrival (IOC remainder, FOK short of the size).
    public let cancelled: Double
    /// A market order beyond the levels shown.
    public let beyondBook: Double
    public let slippageBps: Double?
    public let fee: CloseMoney?
    public let feeBasis: String?
    /// Proceeds of a sale, cost of a buy-back.
    public let notional: CloseMoney?
    public let pnl: CloseMoney?
    /// `pnl` less the fee, where both are in one currency.
    public let netPnl: CloseMoney?
    public let legs: [CloseLeg]
}

public struct CloseResolvedPrice: Decodable, Sendable, Equatable {
    public let value: Double
    public let text: String
    public let source: String
}

/// Everything the confirmation says, built by the kernel from the one
/// action that will be sent.
public struct CloseReview: Decodable, Sendable, Equatable {
    public let headline: String
    public let lines: [String]
    public let warnings: [String]
}

public struct ClosePlan: Decodable, Sendable, Equatable {
    public let action: TradeAction
    /// The exact request, where the venue is OKX.
    public let wire: WireRequest?
    public let side: OrderSide
    public let size: Double
    /// Of the holding, 0–1.
    public let share: Double
    /// Left behind below one lot when all of it was asked for.
    public let remainder: Double
    public let price: CloseResolvedPrice?
    public let estimate: CloseEstimate
    public let review: CloseReview
    public let bookSeq: Int64?
    public let bookExchangeMs: Int64?
}

/// Why a close cannot be done, in the kernel's words.
public struct CloseRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

// MARK: - The kernel

public enum KernelClose {
    /// What `venue` can do to close a holding of `family`.
    public static func capabilities(venue: Venue, family: InstrumentType) -> CloseCapabilities {
        do {
            let text = try callReturningString { error in ms_close_capabilities(venue.rawValue, family.rawValue, error) }
            return try JSONDecoder().decode(CloseCapabilities.self, from: Data(text.utf8))
        } catch {
            // A declaration the kernel cannot answer is a build mismatch, not
            // a market condition: offer nothing, and say why.
            Log.warn("kernel: 读取平仓能力失败（\(venue.rawValue) \(family.rawValue)）：\(error)")
            return .none("内核没有给出这个品种的平仓能力：\(error)")
        }
    }

    /// Plan a close against a book document (`KernelBook`'s, or a quote's).
    public static func plan(_ input: ClosePlanInput, book: Data) -> Result<ClosePlan, CloseRefusal> {
        do {
            let json = try encodeJSON(input)
            let bookText = String(decoding: book, as: UTF8.self)
            let text: String
            do {
                text = try callReturningString { error in ms_close_plan(json, bookText, error) }
            } catch let error as KernelError {
                return .failure(CloseRefusal(message: error.description))
            }
            return .success(try JSONDecoder().decode(ClosePlan.self, from: Data(text.utf8)))
        } catch {
            return .failure(CloseRefusal(message: "内核规划失败：\(error)"))
        }
    }
}
