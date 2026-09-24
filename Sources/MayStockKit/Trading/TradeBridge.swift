import Foundation

// MARK: - Order model

public enum OrderSide: String, Sendable, Equatable, Codable {
    case buy, sell

    public var sign: Double { self == .buy ? 1 : -1 }
    public var displayName: String { self == .buy ? "买入" : "卖出" }
}

public enum OrderKind: String, Sendable, Equatable, Codable {
    case market, limit
    /// A limit that fills what it can at once and cancels the rest. What an
    /// option order is: OKX quotes options in a coin, the book is thin, and a
    /// market order there would be a blank cheque on the ask.
    case ioc

    /// True when the order carries a price.
    public var isPriced: Bool { self != .market }
}

/// Which leg of a hedged perpetual position an order touches.
public enum PositionSide: String, Sendable, Equatable, Codable {
    case long, short, net
}

/// How a derivative position is margined — OKX's `mgnMode`, and the `tdMode`
/// any order acting on that position has to repeat. A default of `cross` on
/// an isolated position is an order for a different position entirely, so
/// the close ticket states the position's own mode, always.
public enum MarginMode: String, Sendable, Equatable, Codable {
    case cross, isolated
    /// Not margined: paid for in full. How a simple account (acctLv 1) holds
    /// an option it bought.
    case cash

    public var displayName: String {
        switch self {
        case .cross: return "全仓"
        case .isolated: return "逐仓"
        case .cash: return "现金"
        }
    }
}

/// How `size` is denominated. Quote sizing is only meaningful for spot market
/// orders (`tgtCcy=quote_ccy`); everything else is in base units / contracts.
public enum OrderSizeUnit: String, Sendable, Equatable, Codable {
    case base, quote
}

public struct OrderRequest: Sendable, Equatable {
    public var instId: String
    public var instType: InstrumentType
    public var side: OrderSide
    public var kind: OrderKind
    public var size: Double
    public var sizeUnit: OrderSizeUnit
    public var limitPrice: Double?
    public var posSide: PositionSide?
    public var reduceOnly: Bool
    /// Protective levels attached to the order. The exchange holds these, so
    /// they survive the app being closed and they trigger on an intrabar spike
    /// that a 20-second poll would sleep straight through.
    public var stopTriggerPrice: Double?
    public var takeProfitTriggerPrice: Double?
    /// Strategy attribution tag; see `OrderTag`.
    public var clOrdId: String?
    /// OKX `tdMode`, which an option order must state: the account's margin
    /// level decides it (`AccountTradingConfig.optionTradeMode`). Nil lets
    /// the CLI default, which is right for spot and perpetuals.
    public var tradeMode: String?

    public init(
        instId: String,
        instType: InstrumentType = .spot,
        side: OrderSide,
        kind: OrderKind = .market,
        size: Double,
        sizeUnit: OrderSizeUnit = .quote,
        limitPrice: Double? = nil,
        posSide: PositionSide? = nil,
        reduceOnly: Bool = false,
        stopTriggerPrice: Double? = nil,
        takeProfitTriggerPrice: Double? = nil,
        clOrdId: String? = nil,
        tradeMode: String? = nil
    ) {
        self.stopTriggerPrice = stopTriggerPrice
        self.takeProfitTriggerPrice = takeProfitTriggerPrice
        self.tradeMode = tradeMode
        self.instId = instId
        self.instType = instType
        self.side = side
        self.kind = kind
        self.size = size
        self.sizeUnit = sizeUnit
        self.limitPrice = limitPrice
        self.posSide = posSide
        self.reduceOnly = reduceOnly
        self.clOrdId = clOrdId
    }
}

public struct OrderResult: Sendable, Equatable {
    public let ordId: String
    public let clOrdId: String?
    public let raw: String

    public init(ordId: String, clOrdId: String? = nil, raw: String) {
        self.ordId = ordId
        self.clOrdId = clOrdId
        self.raw = raw
    }
}

public struct CLIInfo: Sendable, Equatable {
    public let path: String
    public let version: String

    public init(path: String, version: String) {
        self.path = path
        self.version = version
    }
}

/// What `okx account config` says about the account a mode reaches.
public struct AccountConfigInfo: Sendable, Equatable {
    /// OKX `acctLv`: 1 simple, 2 single-currency margin, 3 multi-currency
    /// margin, 4 portfolio margin. Perpetual orders need at least 2.
    public let accountLevel: String
    /// `long_short_mode` or `net_mode`.
    public let positionMode: String
    /// Comma-separated: `read_only`, `trade`, `withdraw`.
    public let permissions: String
    public let label: String?
    public let uid: String?

    public init(accountLevel: String, positionMode: String, permissions: String,
                label: String?, uid: String?) {
        self.accountLevel = accountLevel
        self.positionMode = positionMode
        self.permissions = permissions
        self.label = label
        self.uid = uid
    }

    public var canTrade: Bool {
        permissions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("trade")
    }

    public var accountLevelName: String {
        switch accountLevel {
        case "1": return "简单交易模式"
        case "2": return "单币种保证金"
        case "3": return "跨币种保证金"
        case "4": return "组合保证金"
        default: return "模式 \(accountLevel)"
        }
    }

    public var positionModeName: String {
        switch positionMode {
        case "long_short_mode": return "开平仓（双向）"
        case "net_mode": return "买卖（单向）"
        default: return positionMode
        }
    }

    /// The simple-trading level rejects every perpetual order with 51010;
    /// worth saying before a strategy on a swap discovers it.
    public var supportsPerpetuals: Bool { accountLevel != "1" }
}

/// Proof that a mode's credentials reached its environment, with what was
/// found there.
public struct VenueConnectionReport: Sendable, Equatable {
    public let mode: TradingMode
    /// The profile the check ran under; nil means the CLI default.
    public let profile: String?
    public let checkedAt: Date
    public let totalEquity: Double?
    public let balanceCount: Int
    /// Nil when the balance read succeeded but the configuration read did not.
    public let account: AccountConfigInfo?

    public init(mode: TradingMode, profile: String?, checkedAt: Date,
                totalEquity: Double?, balanceCount: Int, account: AccountConfigInfo?) {
        self.mode = mode
        self.profile = profile
        self.checkedAt = checkedAt
        self.totalEquity = totalEquity
        self.balanceCount = balanceCount
        self.account = account
    }
}

/// Where a mode's connection stands, as the UI tracks it.
public enum VenueConnectionStatus: Sendable, Equatable {
    /// Never checked since launch.
    case unknown
    case checking
    case connected(VenueConnectionReport)
    /// The exchange, the CLI or the network said no; `hint` is what to do
    /// about it when the cause is one this app recognises.
    case failed(message: String, hint: String?, at: Date)

    public var report: VenueConnectionReport? {
        if case .connected(let report) = self { return report }
        return nil
    }
}

// MARK: - Account snapshots

public struct AccountBalance: Sendable, Equatable, Identifiable {
    public let ccy: String
    public let available: Double
    public let total: Double
    /// USD valuation when the CLI reports one.
    public let valuationUsd: Double?

    public var id: String { ccy }

    public init(ccy: String, available: Double, total: Double, valuationUsd: Double? = nil) {
        self.ccy = ccy
        self.available = available
        self.total = total
        self.valuationUsd = valuationUsd
    }
}

/// One reading of the whole account: what is held, and what the exchange says
/// it is worth.
public struct AccountSnapshot: Sendable, Equatable {
    public let balances: [AccountBalance]
    /// Exchange-reported total equity, in `equityCurrency`. Nil when the venue
    /// does not report one — callers then value the balances themselves rather
    /// than inventing a number.
    public let totalEquity: Double?
    /// What `totalEquity` is denominated in, stated by the venue that produced
    /// it rather than inferred from `Venue.quoteCurrency`.
    ///
    /// The two are not the same thing and assuming so is wrong on OKX: the
    /// book quotes in USDT, but `totalEq` is dollars — measured on the live
    /// account, `sum(details[].eqUsd) == totalEq` to the last reported digit
    /// while the USDT line alone reads `eq 65153.446` against
    /// `eqUsd 65127.385`. Summing that against Schwab as if both were the
    /// venue's quote currency would add dollars to something that is not
    /// quite dollars and call the result a portfolio.
    public let equityCurrency: String

    /// The currency every cross-venue total is stated in. Named once so the
    /// several places that ask "can this be added up" compare against the
    /// same spelling rather than four string literals.
    public static let usdCode = "USD"

    public init(balances: [AccountBalance], totalEquity: Double?, equityCurrency: String) {
        self.balances = balances
        self.totalEquity = totalEquity
        self.equityCurrency = equityCurrency
    }

    public func balance(of ccy: String) -> AccountBalance? {
        balances.first { $0.ccy == ccy }
    }

    /// The venue's own rate from `currency` into USD, taken from this very
    /// reading — `eqUsd / eq` on the currency's own line.
    ///
    /// This is not a peg and not a constant: OKX prices USDT at 0.99963 on the
    /// live account and 0.99962 on demo, and publishes both. Reading the rate
    /// out of the same snapshot the figure came from means the conversion is
    /// exactly as fresh as the number it converts. Nil when the venue said
    /// nothing about that currency, which is a reason to leave a figure out of
    /// a total rather than to guess at it.
    public func usdRate(for currency: String) -> Double? {
        if currency == Self.usdCode { return 1 }
        guard let line = balance(of: currency), line.total != 0,
              let valuation = line.valuationUsd else { return nil }
        let rate = valuation / line.total
        return rate > 0 ? rate : nil
    }
}

/// The exchange's own running totals for one instrument, from its bill ledger.
///
/// OKX serves a bounded window of bills, so a book older than the window would
/// show a difference that is the window's fault, not the book's. A comparison
/// that cannot tell those apart is worse than none, because it teaches people
/// to ignore it.
///
/// `tradeIds` is how that is decided, rather than comparing timestamps: a bill
/// is *generated by* a fill, so its stamp lands on or a few milliseconds after
/// the fill's, and "is the earliest bill older than the earliest fill" answered
/// no on a coverage that was in fact complete. Set membership asks the question
/// that was actually meant — is every trade we booked present here — and needs
/// no tolerance to do it.
public struct ExchangeBookTotals: Sendable, Equatable {
    public let instId: String
    public var realisedPnL: Double = 0
    public var fees: Double = 0
    public var funding: Double = 0
    public var earliestBillAt: Date
    /// Exchange trade ids seen in this window; the ledger's fill ids are the
    /// same identifiers.
    public var tradeIds: Set<String> = []

    public init(
        instId: String, realisedPnL: Double = 0, fees: Double = 0,
        funding: Double = 0, earliestBillAt: Date, tradeIds: Set<String> = []
    ) {
        self.instId = instId
        self.realisedPnL = realisedPnL
        self.fees = fees
        self.funding = funding
        self.earliestBillAt = earliestBillAt
        self.tradeIds = tradeIds
    }
}

/// One funding settlement on a perpetual position.
public struct FundingPayment: Sendable, Equatable, Identifiable {
    /// The exchange's bill id, which is what makes booking it idempotent.
    public let id: String
    public let instId: String
    /// Signed in the settlement currency: negative when we paid.
    public let amount: Double
    public let ccy: String
    public let ts: Date

    public init(id: String, instId: String, amount: Double, ccy: String, ts: Date) {
        self.id = id
        self.instId = instId
        self.amount = amount
        self.ccy = ccy
        self.ts = ts
    }
}

public struct ExchangePosition: Sendable, Equatable, Identifiable {
    public let instId: String
    public let posSide: PositionSide
    /// Signed position size in base units / contracts.
    public let quantity: Double
    public let averagePrice: Double
    public let markPrice: Double?
    /// Unrealised profit, in `settlementCurrency` — **not** necessarily USD.
    /// Use `unrealisedPnLUsd` for anything that adds this to another account.
    public let unrealisedPnL: Double
    public let leverage: Double?
    public let liquidationPrice: Double?
    /// The exchange's own statement of what the position controls, in USD
    /// (`notionalUsd`). Nil when the venue does not report one.
    public let notionalUsd: Double?
    /// What this position settles in, as the venue states it (`ccy`), and the
    /// venue's own rate from that into USD at the moment of the reading
    /// (`usdPx`).
    ///
    /// Both live on the position rather than on the venue because that is
    /// where the exchange puts them: OKX's USDT swaps settle in USDT while its
    /// coin-margined instruments settle in the coin, on the same account. A
    /// venue-level currency would be right today and wrong the first time an
    /// inverse or a BTC-settled option is opened, which is the same defect
    /// this field exists to close.
    ///
    /// Measured against the venue's own arithmetic on both accounts:
    /// `|pos| × ctVal × markPx × usdPx == notionalUsd` to six decimals, with
    /// `usdPx` reading 0.99962 — so this rate is published, not a peg.
    public let settlementCurrency: String?
    public let usdRate: Double?
    /// The family the exchange files the position under — `SWAP`, `FUTURES`,
    /// `OPTION`, `MARGIN` — as it spells it. Read rather than inferred from
    /// the id, so a delivery future is not mistaken for spot.
    public let instType: String
    /// Margin the exchange has locked for this position (`margin`), and the
    /// maintenance requirement it must stay above (`mmr`).
    ///
    /// Both are reported per position and neither was being read, which made
    /// "how much is tied up here" unanswerable from a position listing alone.
    public let margin: Double?
    public let maintenanceMargin: Double?
    /// The exchange's own health ratio for the position (`mgnRatio`). Higher is
    /// safer; it is the number the exchange itself would liquidate on.
    public let marginRatio: Double?
    /// How the exchange margins it; nil when the venue does not say (Schwab)
    /// or said nothing recognisable.
    public let marginMode: MarginMode?

    public var id: String { instId + posSide.rawValue }

    public init(
        instId: String, posSide: PositionSide, quantity: Double, averagePrice: Double,
        markPrice: Double?, unrealisedPnL: Double, leverage: Double?, liquidationPrice: Double?,
        notionalUsd: Double? = nil, instType: String = "",
        margin: Double? = nil, maintenanceMargin: Double? = nil, marginRatio: Double? = nil,
        settlementCurrency: String? = nil, usdRate: Double? = nil, marginMode: MarginMode? = nil
    ) {
        self.marginMode = marginMode
        self.margin = margin
        self.maintenanceMargin = maintenanceMargin
        self.marginRatio = marginRatio
        self.instId = instId
        self.posSide = posSide
        self.quantity = quantity
        self.averagePrice = averagePrice
        self.markPrice = markPrice
        self.unrealisedPnL = unrealisedPnL
        self.leverage = leverage
        self.liquidationPrice = liquidationPrice
        self.notionalUsd = notionalUsd
        self.instType = instType
        self.settlementCurrency = settlementCurrency
        self.usdRate = usdRate
    }

    /// `unrealisedPnL` in dollars, or nil when the venue gave nothing to
    /// convert it with.
    ///
    /// Nil rather than the raw figure: a caller adding this to another
    /// account's dollars must be able to tell "no profit stated" from
    /// "profit stated in something else", and returning the unconverted
    /// number would make those two identical at the call site.
    public var unrealisedPnLUsd: Double? {
        if let currency = settlementCurrency, currency == AccountSnapshot.usdCode {
            return unrealisedPnL
        }
        if settlementCurrency == nil && usdRate == nil {
            // A venue that quotes and settles in dollars and says neither —
            // Schwab. Its own currency is the portfolio currency, so there is
            // nothing to convert and nothing to be unsure about.
            return unrealisedPnL
        }
        guard let rate = usdRate, rate > 0 else { return nil }
        return unrealisedPnL * rate
    }

    public var isOption: Bool { instType == "OPTION" }

    /// The family in words.
    public var familyLabel: String {
        switch instType {
        case "SWAP": return "永续"
        case "FUTURES": return "交割"
        case "OPTION": return "期权"
        case "MARGIN": return "杠杆"
        case "SPOT": return "现货"
        default: return instType.isEmpty ? "—" : instType
        }
    }
}

/// An order the exchange is holding open, however it got there: a resting
/// limit in the order book, or an algo order — conditional, OCO, trigger,
/// trailing — waiting on its trigger. Read from the exchange rather than
/// remembered, and listed whoever placed it: what is armed on the account is
/// the account's business, not only the part MayStock placed.
public struct ExchangeOpenOrder: Sendable, Equatable, Identifiable {
    /// Which of the exchange's two books the order sits in.
    public enum Book: String, Sendable, CaseIterable {
        case order, algo

        public var displayName: String { self == .order ? "普通委托" : "策略委托" }
    }

    /// `ordId`, or `algoId` for the algo book.
    public let id: String
    public let book: Book
    public let instId: String
    /// The exchange's own type word: `limit`, `post_only`, `conditional`,
    /// `oco`, `trigger`, `move_order_stop`, `twap`…
    public let ordType: String
    public let side: OrderSide
    public let posSide: PositionSide?
    /// The price the order rests at, or fills at once triggered. Nil is market.
    public let price: Double?
    /// The level an algo order waits for: its own trigger, or the single
    /// stop / take-profit leg's trigger when it has just one.
    public let triggerPrice: Double?
    public let stopTriggerPrice: Double?
    public let takeProfitTriggerPrice: Double?
    /// Contracts or base units. Nil when the order is sized as a fraction of
    /// the position instead — see `closeFraction`.
    public let size: Double?
    /// The share of the position the order closes, when it is sized that way
    /// (1 is "close all").
    public let closeFraction: Double?
    public let filledSize: Double
    /// The exchange's state word: `live`, `partially_filled`, `effective`…
    public let state: String
    public let reduceOnly: Bool
    public let clOrdId: String?
    public let createdAt: Date?

    public init(
        id: String, book: Book, instId: String, ordType: String, side: OrderSide,
        posSide: PositionSide?, price: Double?, triggerPrice: Double?, stopTriggerPrice: Double?,
        takeProfitTriggerPrice: Double?, size: Double?, closeFraction: Double?, filledSize: Double,
        state: String, reduceOnly: Bool, clOrdId: String?, createdAt: Date?
    ) {
        self.id = id
        self.book = book
        self.instId = instId
        self.ordType = ordType
        self.side = side
        self.posSide = posSide
        self.price = price
        self.triggerPrice = triggerPrice
        self.stopTriggerPrice = stopTriggerPrice
        self.takeProfitTriggerPrice = takeProfitTriggerPrice
        self.size = size
        self.closeFraction = closeFraction
        self.filledSize = filledSize
        self.state = state
        self.reduceOnly = reduceOnly
        self.clOrdId = clOrdId
        self.createdAt = createdAt
    }

    /// The order in words: what kind, and for a conditional order which leg.
    public var kindLabel: String {
        switch ordType {
        case "limit": return "限价"
        case "market": return "市价"
        case "post_only": return "只挂单"
        case "fok": return "FOK"
        case "ioc": return "IOC"
        case "optimal_limit_ioc": return "市价 IOC"
        case "conditional":
            switch (stopTriggerPrice != nil, takeProfitTriggerPrice != nil) {
            case (true, true): return "止盈止损"
            case (true, false): return "止损"
            case (false, true): return "止盈"
            case (false, false): return "条件单"
            }
        case "oco": return "OCO 止盈止损"
        case "trigger": return "计划委托"
        case "move_order_stop": return "移动止损"
        case "chase": return "追单"
        case "iceberg": return "冰山"
        case "twap": return "TWAP"
        default: return ordType
        }
    }
}

/// What `openOrders` could and could not read.
public struct OpenOrderListing: Sendable, Equatable {
    public var orders: [ExchangeOpenOrder]
    /// Books that could not be listed, in words, so an empty list is never
    /// mistaken for "nothing armed" on a book that could not be asked.
    public var unavailable: [String]

    public init(orders: [ExchangeOpenOrder] = [], unavailable: [String] = []) {
        self.orders = orders
        self.unavailable = unavailable
    }
}

public struct ExchangeFill: Sendable, Equatable, Identifiable {
    public let id: String
    public let instId: String
    public let side: OrderSide
    public let posSide: PositionSide?
    /// In the instrument's own quoting unit: quote currency for spot and
    /// perpetuals, the settlement coin per unit of underlying for an option.
    public let price: Double
    public let size: Double
    /// Fee in `feeCcy`. OKX reports charges as negative numbers.
    public let fee: Double
    public let feeCcy: String?
    public let ordId: String?
    public let clOrdId: String?
    public let ts: Date
    /// Option fills only: the premium in USD per unit of underlying, as the
    /// exchange stamped it at execution (`fillPxUsd`).
    public let priceUsd: Double?
    /// Option fills only: the underlying index at execution (`fillIdxPx`),
    /// which converts a coin-denominated premium or fee into quote currency.
    public let indexPrice: Double?
    /// The venue's own ledger-line id, where it stamps one. The strongest
    /// identity a fill can carry — see the kernel's `fills` module — and the
    /// reason a row placed outside this app can still be recognised as one
    /// the ledger already booked.
    public let billId: String?
    /// The venue's per-instrument execution counter (`tradeId`), where it
    /// stamps one. Distinct from `id`, which falls back to a synthesised
    /// `ordId-timestamp` when the venue gives neither.
    public let tradeId: String?
    /// What the venue says the fill realised, in the instrument's settlement
    /// currency, or nil where it says nothing. An opener realises nothing; a
    /// closer on OKX carries `fillPnl`. This is the only realised figure
    /// available for a fill no strategy booked, and without it an untagged
    /// row has to show a blank where the money went.
    public let pnl: Double?

    public init(
        id: String, instId: String, side: OrderSide, posSide: PositionSide?,
        price: Double, size: Double, fee: Double, feeCcy: String?,
        ordId: String?, clOrdId: String?, ts: Date,
        priceUsd: Double? = nil, indexPrice: Double? = nil,
        billId: String? = nil, tradeId: String? = nil, pnl: Double? = nil
    ) {
        self.id = id
        self.instId = instId
        self.side = side
        self.posSide = posSide
        self.price = price
        self.size = size
        self.fee = fee
        self.feeCcy = feeCcy
        self.ordId = ordId
        self.clOrdId = clOrdId
        self.ts = ts
        self.priceUsd = priceUsd
        self.indexPrice = indexPrice
        self.billId = billId
        self.tradeId = tradeId
        self.pnl = pnl
    }

    /// This fill as the kernel's identity rule reads it. Prices, fees and
    /// currencies stay here: the rule has no use for them, and shipping them
    /// across the FFI to have them handed back would be pure cost.
    public var kernelRecord: KernelFillRecord {
        KernelFillRecord(
            id: id, instId: instId, tradeId: tradeId, billId: billId,
            ts: ts, side: side, leg: posSide)
    }
}

/// What a whole-account fill read could and could not reach.
///
/// The same shape as `OpenOrderListing` and for the same reason: a book that
/// could not be read must be named, because an empty list in its place reads
/// as "nothing traded" — which on this account was the visible bug.
///
/// `fills` is newest first by construction — the order the overview trims with
/// `prefix`. A venue's wire returns fills oldest first, so the ordering is
/// enforced here once, at the type, rather than relied on at every call site.
public struct ExchangeFillListing: Sendable, Equatable {
    public var fills: [ExchangeFill]
    public var unavailable: [String]

    public init(fills: [ExchangeFill] = [], unavailable: [String] = []) {
        self.fills = fills.sorted { $0.ts > $1.ts }
        self.unavailable = unavailable
    }
}

// MARK: - Errors

public enum TradeError: Error, CustomStringConvertible, Sendable {
    case cliNotFound
    case cliFailed(exitCode: Int32, stderr: String)
    case badOutput(String)
    case liveTradingLocked
    case notConfigured
    /// An order reached a venue for a family it does not list — a routing
    /// bug rather than a market condition, named so it reads as one.
    case unsupportedInstrument(InstrumentType)
    /// A venue saw the order and refused it — the definite verdict every
    /// adapter reports the same way, so the runner needs one rule to read
    /// "nothing is in flight" off a failure.
    case rejected(venue: String, reason: String)
    /// The exchange certainly did not act on it, and nothing is in flight:
    /// the connection never opened, or OKX kept turning it away at its rate
    /// limit, which it does before reading the request. Safe to send again.
    case notDelivered(String)
    /// The order left and no verdict came back. It may have been acted on,
    /// and has to be resolved by asking the exchange — never retried blind.
    case unconfirmed(String)
    /// Stopped before the network: a key for the wrong environment, an order
    /// the exchange could not accept as written.
    case refused(String)
    /// A read on the trading path failed; nothing was changed.
    case readFailed(String)

    public var description: String {
        switch self {
        case .rejected(let venue, let reason):
            return "\(venue)拒绝了订单：\(reason)"
        case .notDelivered(let reason):
            return "订单没有送达交易所：\(reason)"
        case .unconfirmed(let reason):
            return "订单结果未确认，可能已经成交：\(reason)"
        case .refused(let reason):
            return "订单未发出：\(reason)"
        case .readFailed(let reason):
            return "读取失败：\(reason)"
        case .cliNotFound:
            return "未找到官方 okx CLI。安装：npm install -g @okx_ai/okx-trade-cli"
        case .cliFailed(let code, let stderr):
            return "okx CLI 退出码 \(code)：\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .badOutput(let raw):
            return "okx CLI 输出无法解析：\(raw.prefix(200))"
        case .liveTradingLocked:
            return "实盘交易未解锁（设置 → 交易）。当前仅允许 demo 模拟盘。"
        case .notConfigured:
            return "okx CLI 尚未配置 API Key。运行 `okx config` 添加模拟盘密钥后重试。"
        case .unsupportedInstrument(let instType):
            return "\(instType.displayName)不在这个交易所能交易的品种里，这笔请求不该发到这里"
        }
    }

    /// Why the order certainly did not reach the book, when that is certain:
    /// the exchange refused it, or it was stopped here before it was sent.
    /// Nil for every failure whose outcome is unknown — those are resolved by
    /// asking, never read as "this did not happen".
    public var refusal: String? {
        switch self {
        case .rejected(let venue, let reason): return "\(venue)：\(reason)"
        case .refused(let reason): return reason
        case .liveTradingLocked, .unsupportedInstrument: return description
        default: return nil
        }
    }

    /// Why the exchange certainly did not act on the order, when that is so.
    /// Nothing is in flight and nothing was refused: the same order can
    /// simply be tried again.
    public var undelivered: String? {
        if case .notDelivered(let reason) = self { return reason }
        return nil
    }

    /// True when the order may have been acted on although no answer said
    /// so. Every screen that reports a failed order says this differently
    /// from a refusal: "check the exchange before trying again".
    public var outcomeUnknown: Bool {
        if case .unconfirmed = self { return true }
        return false
    }

    /// Where a failed order stands — the one classification every screen
    /// that reports a failed order reads, so no two can disagree.
    public enum Standing: Sendable, Equatable {
        /// It may have been acted on: find out before sending it again.
        case unknown
        /// The exchange certainly did not act on it: safe to send again.
        case undelivered
        /// Refused — by the exchange, or here before it was sent.
        case refused

        public var title: String {
            switch self {
            case .unknown: "结果未确认"
            case .undelivered: "没有送达"
            case .refused: "被拒绝"
            }
        }
    }

    /// Any error a send can throw. Only what says so is refused or
    /// undelivered; everything else — whatever it is — may have been acted
    /// on, the same rule the runner reads a failed placement by.
    public static func standing(of error: Error) -> Standing {
        guard let trade = error as? TradeError else { return .unknown }
        if trade.undelivered != nil { return .undelivered }
        if trade.refusal != nil { return .refused }
        return .unknown
    }

    /// What to do about an undelivered order, true of both ways it happens.
    public static let undeliveredAdvice = "这笔单没有进入交易所的订单系统，没有东西在途，可以放心重试。"

    /// What to do about it, for the failures whose cause is known.
    ///
    /// The exchange's message is accurate but terse — "APIKey does not match
    /// current environment" does not say that demo and live keys are issued
    /// separately, which is the thing the reader has to know to fix it.
    public var hint: String? {
        switch self {
        case .cliFailed(_, let text), .rejected(_, let text), .notDelivered(let text),
             .unconfirmed(let text), .refused(let text), .readFailed(let text):
            return Self.hint(for: text)
        default:
            return nil
        }
    }

    /// Advice keyed on the exchange's own code or message, wherever it came
    /// through: the CLI's output, or the kernel's reply.
    public static func hint(for text: String) -> String? {
        let lower = text.lowercased()
        let code = okxCode(in: text)
        if code == "50101" || lower.contains("does not match current environment") {
            return "这个 profile 的 API Key 属于另一个环境。OKX 的模拟盘密钥在「模拟交易」页单独创建，"
                + "实盘密钥在主站 API 管理页创建，两者不能互用——为这个环境配置一个对应的 profile。"
        }
        if code == "50111" || lower.contains("invalid ok-access-key") {
            return "API Key 无效或已被删除，请在 OKX 重新创建后运行 `okx config` 更新。"
        }
        if code == "50113" || lower.contains("invalid sign") {
            return "签名校验失败：Secret Key 或 Passphrase 不正确。"
        }
        if code == "50105" || (lower.contains("passphrase") && lower.contains("incorrect")) {
            return "Passphrase 不正确。"
        }
        if code == "50100" || lower.contains("api frozen") {
            return "这个 API Key 已被 OKX 冻结。"
        }
        if lower.contains("profile") && lower.contains("not found") {
            return "CLI 里没有这个 profile，检查 ~/.okx/config.toml。"
        }
        if code == "51169" || lower.contains("don't have any positions in this direction") {
            return "交易所上这个方向已经没有仓位了：可能已被别的单平掉。刷新持仓后再看。"
        }
        if code == "51205" {
            return "交易所不接受这张单的「只减仓」：这个持仓模式下平仓单不带它。"
        }
        if lower.contains("profile") && lower.contains("不能用于") {
            return "模拟盘和实盘的 API Key 不能互用：在设置里为这个环境选对应的 profile。"
        }
        if lower.contains("未返回") || lower.contains("timed out") || lower.contains("timeout")
            || lower.contains("enotfound") || lower.contains("econnrefused") || lower.contains("连不上") {
            return "网络或代理问题：没能连上 OKX。"
        }
        return nil
    }

    /// First non-zero OKX status code in a CLI error payload, if any.
    ///
    /// Two spellings, because the CLI uses both: a JSON `sCode`/`code` field
    /// when it passes the exchange's response through, and a plain
    /// `Code: 51001` line when it formats the error itself. Only OKX's own
    /// five-digit codes count; the `Code: 400` of an HTTP failure says the
    /// gateway refused the call, not that the exchange judged the order.
    static func okxCode(in text: String) -> String? {
        let patterns = [
            #"\"(?:sCode|code)\"\s*:\s*\"?(\d+)\"?"#,
            #"(?m)^\s*Code:\s*(\d{5})\s*$"#,
            // The kernel's rejection: the exchange's code, then its words.
            #"^\s*(\d{5})\b"#,
        ]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: range) {
                guard let found = Range(match.range(at: 1), in: text) else { continue }
                let code = String(text[found])
                if code != "0" { return code }
            }
        }
        return nil
    }
}

// MARK: - Bridge

/// Wraps OKX's official CLI (Agent Trade Kit, `okx`) for the one reading
/// with no kernel path — the ledger (bills, and its archive) behind the
/// equity page — and holds the parsers of OKX's account documents, which the
/// kernel's reads hand back whole. Credentials live in the CLI's own
/// `~/.okx/config.toml`, and every call carries an explicit `TradingMode`.
///
/// Nothing here acts on the account. Orders and every reading the trading
/// loop depends on go through the kernel (`KernelTradeClient`), which signs
/// them itself with the same config file's key.
public struct TradeBridge: Sendable {
    public var explicitCLIPath: String?
    /// CLI profile for each environment. Nil means the CLI's default profile.
    ///
    /// Kept per mode because the two environments need different keys; see
    /// `TradingPrefs.demoProfile`.
    public var demoProfile: String?
    public var liveProfile: String?
    /// Hard ceiling on one CLI invocation. Settable so a test can exercise the
    /// watchdog without waiting it out.
    public var commandTimeout: TimeInterval

    public init(
        explicitCLIPath: String? = nil,
        demoProfile: String? = nil,
        liveProfile: String? = nil,
        commandTimeout: TimeInterval = TradeBridge.defaultCommandTimeout
    ) {
        self.explicitCLIPath = explicitCLIPath
        self.demoProfile = demoProfile
        self.liveProfile = liveProfile
        self.commandTimeout = commandTimeout
    }

    /// The bridge the app's settings describe. Every process that trades on
    /// the user's behalf — the app, the hourly review — builds its bridge
    /// here, so none of them can drift onto a different profile mapping.
    public init(prefs: TradingPrefs, commandTimeout: TimeInterval = TradeBridge.defaultCommandTimeout) {
        self.init(
            explicitCLIPath: prefs.cliPath,
            demoProfile: prefs.demoProfile,
            liveProfile: prefs.liveProfile,
            commandTimeout: commandTimeout)
    }

    /// The profile a mode's calls run under.
    public func profile(for mode: TradingMode) -> String? {
        switch mode {
        case .demo: return demoProfile
        case .live: return liveProfile
        }
    }

    private static let searchPaths = [
        "/opt/homebrew/bin/okx",
        "/usr/local/bin/okx",
        "/usr/bin/okx",
    ]

    /// Locate the `okx` binary and read its version. Returns nil when absent.
    public func detectCLI() async -> CLIInfo? {
        guard let path = resolveCLIPath() else { return nil }
        let output = (try? await run(executable: path, arguments: ["--version"])) ?? ""
        return CLIInfo(path: path, version: Self.parseVersion(output))
    }

    /// The version out of `okx --version`, whatever else the CLI prints.
    ///
    /// The output has grown around the number over time — an update banner
    /// above it, then a "Pilot: installed" status line below it — so neither
    /// the first nor the last line is reliable. The version is the first line
    /// that starts like one.
    static func parseVersion(_ output: String) -> String {
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let versionLike = lines.first { line in
            let scalars = line.unicodeScalars
            guard let first = scalars.first, CharacterSet.decimalDigits.contains(first) else { return false }
            return line.contains(".")
        }
        return versionLike ?? lines.last ?? "unknown"
    }

    public func resolveCLIPath() -> String? {
        let fm = FileManager.default
        if let explicitCLIPath, fm.isExecutableFile(atPath: explicitCLIPath) {
            return explicitCLIPath
        }
        for candidate in Self.searchPaths where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // PATH lookup (covers nvm-style installs when launched from a shell).
        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                let candidate = String(dir) + "/okx"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// True when a profile with credentials exists — without one every
    /// authenticated command fails, including demo trading.
    public func hasCredentials() -> Bool {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".okx/config.toml")
        return FileManager.default.fileExists(atPath: config.path)
    }

    // MARK: Account documents
    //
    // OKX's own documents, read by the kernel (`KernelTradeClient`) and
    // parsed here — one reader of each document's fields.

    /// The account's derivatives setup, from `account/config`.
    static func parseAccountTradingConfig(json: String) -> AccountTradingConfig? {
        var result: AccountTradingConfig?
        walkObjects(in: json) { dict in
            guard result == nil,
                  dict["posMode"] != nil || dict["acctLv"] != nil else { return }
            result = AccountTradingConfig(
                positionMode: (dict["posMode"] as? String)
                    .flatMap(AccountTradingConfig.PositionMode.init(rawValue:)),
                accountLevel: number(dict, "acctLv").map { Int($0) },
                autoLoan: flag(dict, "autoLoan"))
        }
        return result
    }

    /// Funding settled on perpetual positions: OKX files it under bill type
    /// 8. The backtester models funding from real rate history, and live has
    /// to book it too — for a short held across several days it is not a
    /// rounding error but the position's whole edge, paid out eight-hourly.
    static func parseFundingPayments(json: String, instId: String?) -> [FundingPayment] {
        var found: [FundingPayment] = []
        walkObjects(in: json) { dict in
            // Type 8 is the funding fee. Filtering on it rather than on the
            // sub-type keeps both the expense and the income side.
            guard (dict["type"] as? String) == "8" || number(dict, "type") == 8 else { return }
            guard let billId = dict["billId"] as? String, !billId.isEmpty,
                  let inst = dict["instId"] as? String,
                  instId == nil || inst == instId,
                  let amount = fundingAmount(dict),
                  let ms = number(dict, "ts") else { return }
            found.append(FundingPayment(
                id: billId, instId: inst, amount: amount,
                ccy: (dict["ccy"] as? String) ?? "USDT",
                ts: Date(timeIntervalSince1970: ms / 1000)))
        }
        return found.sorted { $0.ts < $1.ts }
    }

    /// The settlement on a funding bill, wherever the exchange put it.
    ///
    /// Isolated margin books funding to the position: `balChg` is "0" and the
    /// settlement is `pnl`. Cross margin books it to the cash balance, so
    /// `balChg` carries it and `pnl` may too. Reading `balChg` first booked
    /// every isolated settlement as nothing — on a book that is all isolated,
    /// that is every settlement.
    static func fundingAmount(_ dict: [String: Any]) -> Double? {
        let pnl = number(dict, "pnl")
        let balanceChange = number(dict, "balChg")
        if let pnl, pnl != 0 { return pnl }
        if let balanceChange, balanceChange != 0 { return balanceChange }
        return pnl ?? balanceChange
    }

    // MARK: Ledger (through the CLI)

    /// The exchange's own ledger of this account, newest first.
    ///
    /// Read to sum what a window *realised* — the one period figure the
    /// exchange can vouch for; see `BilledPnL`. The live listing is one page
    /// of the last seven days. The archive reaches three months but is slow
    /// and lags the newest settlements, so it is read only when the live page
    /// was full and did not reach the earliest window anyone will ask about.
    /// The two overlap and are merged on bill id.
    public func bills(mode: TradingMode, limit: Int = 100, now: Date = Date()) async throws -> ExchangeBillListing {
        let live = Self.parseBills(json: try await runCLI(["account", "bills", "--limit", String(limit)], mode: mode))
        var byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var exhausted = live.count < limit
        let earliestAnchor = EquityWindow.allCases.map { $0.anchor(now: now) }.min() ?? now
        if !exhausted, (live.map(\.ts).min() ?? now) > earliestAnchor {
            let archive = Self.parseBills(json: try await runCLI(
                ["account", "bills", "--archive", "--limit", String(limit)],
                mode: mode, timeout: Self.archiveCommandTimeout))
            for bill in archive where byId[bill.id] == nil { byId[bill.id] = bill }
            exhausted = archive.count < limit
        }
        return ExchangeBillListing(bills: byId.values.sorted { $0.ts > $1.ts }, exhausted: exhausted, fetchedAt: now)
    }

    static func parseBills(json: String) -> [ExchangeBill] {
        var byId: [String: ExchangeBill] = [:]
        walkObjects(in: json) { dict in
            guard let id = dict["billId"] as? String, !id.isEmpty,
                  let ms = number(dict, "ts"),
                  let type = (dict["type"] as? String).flatMap(Int.init) ?? number(dict, "type").map({ Int($0) })
            else { return }
            byId[id] = ExchangeBill(
                id: id, ts: Date(timeIntervalSince1970: ms / 1_000), type: type,
                subType: (dict["subType"] as? String).flatMap(Int.init),
                instId: (dict["instId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                ccy: (dict["ccy"] as? String) ?? "",
                pnl: number(dict, "pnl") ?? 0,
                fee: number(dict, "fee") ?? 0,
                interest: number(dict, "interest") ?? 0,
                balanceChange: number(dict, "balChg") ?? 0,
                positionBalanceChange: number(dict, "posBalChg") ?? 0)
        }
        return byId.values.sorted { $0.ts > $1.ts }
    }

    /// What the *exchange* says a derivative instrument has earned, cost and
    /// paid, straight from the bill ledger.
    ///
    /// The book keeps its own running totals, and nothing ever compared them
    /// against the account. Two defects have now shipped that this comparison
    /// would have caught within the hour: funding re-booked on every restart,
    /// and a P&L booked at ten times its size because the contract multiplier
    /// had been fabricated. Both were arithmetic on our side of the wire, so
    /// every internal figure agreed with every other internal figure.
    /// Both windows, merged on the exchange's bill id.
    ///
    /// Neither alone is enough. The live listing only reaches back a few days,
    /// so a book older than that could never be checked; the archive reaches
    /// three months but lags the newest settlements. Asking for one and hoping
    /// would make the comparison silently partial, which is the failure mode
    /// this whole check exists to remove.
    public func bookTotals(
        mode: TradingMode, instTypes: [InstrumentType] = [.swap], limit: Int = 100
    ) async throws -> [String: ExchangeBookTotals] {
        var blobs: [String] = []
        // Bills are filed per instrument family; a book holding both
        // perpetuals and options needs both listings.
        for instType in instTypes where instType.isDerivative {
            let base = ["account", "bills", "--instType", instType.rawValue,
                        "--limit", String(limit)]
            blobs.append(try await runCLI(base, mode: mode))
            // The archive endpoint is genuinely slow — measured at 18.7s against
            // the 15s default, which meant it timed out on every run and `try?`
            // turned that into a short window. The review then reported "the bill
            // window does not reach far enough back", which was true and had
            // nothing to do with the actual failure. A degraded call has to fail as
            // itself, not as whatever its empty result happens to look like.
            blobs.append(try await runCLI(
                base + ["--archive"], mode: mode, timeout: Self.archiveCommandTimeout))
        }
        return Self.parseBookTotals(json: blobs)
    }

    static func parseBookTotals(json blobs: [String]) -> [String: ExchangeBookTotals] {
        // Keyed by bill id first: the two windows overlap, and adding the same
        // settlement twice is the exact defect this is meant to detect.
        var bills: [String: (
            inst: String, ts: Date, type: Int?, fee: Double, amount: Double, tradeId: String?
        )] = [:]
        for blob in blobs {
            walkObjects(in: blob) { dict in
                guard let billId = dict["billId"] as? String, !billId.isEmpty,
                      let inst = dict["instId"] as? String, !inst.isEmpty,
                      let ms = number(dict, "ts") else { return }
                let type = (dict["type"] as? String).flatMap(Int.init)
                    ?? number(dict, "type").map { Int($0) }
                bills[billId] = (
                    inst: inst,
                    ts: Date(timeIntervalSince1970: ms / 1000),
                    type: type,
                    fee: number(dict, "fee") ?? 0,
                    amount: type == 8
                        ? (fundingAmount(dict) ?? 0)
                        : (number(dict, "pnl") ?? 0),
                    tradeId: (dict["tradeId"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
        }

        var totals: [String: ExchangeBookTotals] = [:]
        for bill in bills.values {
            var row = totals[bill.inst]
                ?? ExchangeBookTotals(instId: bill.inst, earliestBillAt: bill.ts)
            row.earliestBillAt = Swift.min(row.earliestBillAt, bill.ts)
            if let tradeId = bill.tradeId { row.tradeIds.insert(tradeId) }
            // Fees are filed negative on the wire; the book holds them as a
            // positive cost.
            row.fees -= bill.fee
            switch bill.type {
            case 8: row.funding += bill.amount
            case 2: row.realisedPnL += bill.amount
            default: break
            }
            totals[bill.inst] = row
        }
        return totals
    }

    // MARK: Connection

    static func parseAccountConfig(json: String) -> AccountConfigInfo? {
        var result: AccountConfigInfo?
        walkObjects(in: json) { dict in
            guard result == nil,
                  let level = dict["acctLv"] as? String,
                  let posMode = dict["posMode"] as? String else { return }
            result = AccountConfigInfo(
                accountLevel: level,
                positionMode: posMode,
                permissions: (dict["perm"] as? String) ?? "",
                label: dict["label"] as? String,
                uid: dict["uid"] as? String)
        }
        return result
    }

    /// Public market ping through the CLI (no keys needed) — used by e2e.
    public func marketTicker(instId: String) async throws -> String {
        try await runCLI(["market", "ticker", instId], mode: .live, needsAuth: false)
    }

    func runCLI(
        _ arguments: [String], mode: TradingMode, needsAuth: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> String {
        guard let cli = resolveCLIPath() else { throw TradeError.cliNotFound }
        var args = arguments + ["--json"]
        if needsAuth {
            args.append(mode == .demo ? "--demo" : "--live")
            if let profile = profile(for: mode) { args += ["--profile", profile] }
        }
        return try await run(executable: cli, arguments: args, timeout: timeout)
    }

    // MARK: Subprocess plumbing

    /// Default ceiling on one CLI invocation. The runner ticks every 20s and
    /// some calls fall back to a second command, so this stays well under
    /// that: a real invocation takes well under a second.
    public static let defaultCommandTimeout: TimeInterval = 15

    /// The bill archive is not on the trading path — nothing waits on it but
    /// the hourly review — and it is slow enough that the trading ceiling
    /// would reject every call.
    public static let archiveCommandTimeout: TimeInterval = 60

    /// Run the CLI and hand back its stdout.
    ///
    /// The watchdog, the pipe draining and the guarantee that this returns *at
    /// all* live in `Subprocess`, which exists because getting them subtly
    /// wrong here once stopped the trading loop dead. See the note on that type.
    private func run(
        executable: String, arguments: [String], timeout: TimeInterval? = nil
    ) async throws -> String {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")

        let outcome: Subprocess.Outcome
        do {
            outcome = try await Subprocess.run(
                executable: executable, arguments: arguments,
                environment: env, timeout: timeout ?? commandTimeout)
        } catch Subprocess.Failure.timedOut(let seconds) {
            throw TradeError.cliFailed(
                exitCode: -1,
                stderr: "okx CLI 超过 \(Int(seconds)) 秒未返回，已终止："
                    + ([executable] + arguments).joined(separator: " "))
        } catch Subprocess.Failure.couldNotLaunch(let detail) {
            throw TradeError.cliFailed(exitCode: -1, stderr: detail)
        }

        let out = outcome.stdoutText
        guard outcome.exitCode == 0 else {
            throw TradeError.cliFailed(
                exitCode: outcome.exitCode,
                stderr: Self.failureText(stdout: out, stderr: outcome.stderrText))
        }
        return out
    }

    /// What a failed invocation actually said.
    ///
    /// The CLI prints the exchange's refusal — `sCode`, `sMsg` — to stdout as
    /// JSON, and its update nag to stderr. "stderr, else stdout" therefore
    /// handed the runner the nag and dropped the verdict: a 51198 refusal on
    /// the demo account was reported as an unconfirmed order, which is the
    /// one thing a definite refusal must never be reported as. Both streams
    /// are kept, and the nag is not.
    static func failureText(stdout: String, stderr: String) -> String {
        let signal = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { line in
                !line.contains("Update available for @okx_ai/okx-trade-cli")
                    && !line.contains("npm install -g @okx_ai/okx-trade-cli")
            }
            .joined(separator: "\n")
        return [stdout, signal]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: Output parsing
    //
    // The CLI wraps OKX responses differently across versions and flags
    // (`--env` adds another layer). Rather than chase envelope shapes, we walk
    // the JSON tree and pick up any object carrying the fields we need.

    // Positions, equity and balances are read by the kernel — the one reader
    // of these fields, shared with the live layer's socket pushes.

    static func parseBalances(json: String) -> [AccountBalance] {
        KernelAccount.balances(json)
    }

    /// Total account equity: the unified account's `totalEq`, else the
    /// valuation block's `totalBal` (see `KernelAccount`).
    static func parseTotalEquity(json: String) -> Double? {
        KernelAccount.totalEquity(json)
    }

    static func parseFills(json: String) -> [ExchangeFill] {
        var out: [ExchangeFill] = []
        walkObjects(in: json) { dict in
            guard let instId = dict["instId"] as? String, !instId.isEmpty,
                  let sideRaw = dict["side"] as? String, let side = OrderSide(rawValue: sideRaw),
                  let price = number(dict, "fillPx"), let size = number(dict, "fillSz"),
                  let ms = number(dict, "ts") else { return }
            let text = { (key: String) -> String? in
                (dict[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            let tradeId = text("tradeId")
            let ordId = text("ordId")
            out.append(ExchangeFill(
                id: tradeId ?? "\(ordId ?? instId)-\(Int(ms))",
                instId: instId,
                side: side,
                posSide: (dict["posSide"] as? String).flatMap(PositionSide.init(rawValue:)),
                price: price,
                size: size,
                fee: number(dict, "fee") ?? 0,
                feeCcy: dict["feeCcy"] as? String,
                ordId: ordId,
                clOrdId: text("clOrdId"),
                ts: Date(timeIntervalSince1970: ms / 1000),
                // Stamped on option fills only; empty strings elsewhere, which
                // `number` already reads as absent.
                priceUsd: number(dict, "fillPxUsd"),
                indexPrice: number(dict, "fillIdxPx"),
                // The venue's own line id and its realised figure. Both are
                // stamped on every family, and both are what lets a fill this
                // app never placed still be identified and priced.
                billId: text("billId"),
                tradeId: tradeId,
                pnl: number(dict, "fillPnl")))
        }
        return out.sorted { $0.ts < $1.ts }
    }

    /// OKX sends every number as a string; some CLI paths pass through doubles.
    static func number(_ dict: [String: Any], _ key: String) -> Double? {
        if let text = dict[key] as? String { return text.isEmpty ? nil : Double(text) }
        if let value = dict[key] as? Double { return value }
        if let value = dict[key] as? Int { return Double(value) }
        return nil
    }

    /// A switch the CLI passes through as JSON `true` or, on some envelopes,
    /// as the string `"true"`. Anything else is "not reported".
    static func flag(_ dict: [String: Any], _ key: String) -> Bool? {
        if let value = dict[key] as? Bool { return value }
        switch (dict[key] as? String)?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    static func walkObjects(in json: String, visit: ([String: Any]) -> Void) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return }
        walk(root, visit: visit)
    }

    private static func walk(_ object: Any, visit: ([String: Any]) -> Void) {
        if let dict = object as? [String: Any] {
            visit(dict)
            for value in dict.values { walk(value, visit: visit) }
        } else if let array = object as? [Any] {
            for value in array { walk(value, visit: visit) }
        }
    }
}
