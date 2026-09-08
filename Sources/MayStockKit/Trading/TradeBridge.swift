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

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

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
    /// Exchange-reported total equity, in the account's valuation currency.
    /// Nil when the CLI does not report one — callers then value the balances
    /// themselves rather than inventing a number.
    public let totalEquity: Double?

    public init(balances: [AccountBalance], totalEquity: Double?) {
        self.balances = balances
        self.totalEquity = totalEquity
    }

    public func balance(of ccy: String) -> AccountBalance? {
        balances.first { $0.ccy == ccy }
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
    public let unrealisedPnL: Double
    public let leverage: Double?
    public let liquidationPrice: Double?
    /// The exchange's own statement of what the position controls, in USD
    /// (`notionalUsd`). Nil when the venue does not report one.
    public let notionalUsd: Double?
    /// The family the exchange files the position under — `SWAP`, `FUTURES`,
    /// `OPTION`, `MARGIN` — as it spells it. Read rather than inferred from
    /// the id, so a delivery future is not mistaken for spot.
    public let instType: String

    public var id: String { instId + posSide.rawValue }

    public init(
        instId: String, posSide: PositionSide, quantity: Double, averagePrice: Double,
        markPrice: Double?, unrealisedPnL: Double, leverage: Double?, liquidationPrice: Double?,
        notionalUsd: Double? = nil, instType: String = ""
    ) {
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

    public init(
        id: String, instId: String, side: OrderSide, posSide: PositionSide?,
        price: Double, size: Double, fee: Double, feeCcy: String?,
        ordId: String?, clOrdId: String?, ts: Date,
        priceUsd: Double? = nil, indexPrice: Double? = nil
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
    }
}

// MARK: - Errors

public enum TradeError: Error, CustomStringConvertible, Sendable {
    case cliNotFound
    case cliFailed(exitCode: Int32, stderr: String)
    case badOutput(String)
    case liveTradingLocked
    case notConfigured
    /// An order reached the OKX bridge for a family OKX does not list — a
    /// routing bug rather than a market condition. Named here so it reads as
    /// one, instead of as an opaque CLI usage error.
    case unsupportedInstrument(InstrumentType)

    public var description: String {
        switch self {
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
            return "OKX 不交易\(instType.displayName)，这笔请求不该走到 okx CLI"
        }
    }

    /// The exchange's own verdict, when the failure carries one.
    ///
    /// A CLI that could not start, timed out, or died on a socket error says
    /// nothing about whether the order reached OKX — that outcome is *unknown*
    /// and has to be resolved by asking. A response carrying a non-zero OKX
    /// code says something definite: the exchange saw the order and refused it.
    /// Only the second kind may be treated as "this did not happen".
    public var exchangeRejection: String? {
        guard case .cliFailed(let exitCode, let stderr) = self, exitCode > 0,
              let code = Self.okxCode(in: stderr) else { return nil }
        let words = Self.okxMessage(in: stderr)
            ?? stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "OKX \(code)：\(words.prefix(180))"
    }

    /// The exchange's own words for a refusal, when the payload carries them.
    ///
    /// Three places they can be, matching the three shapes `okxCode` reads:
    /// `sMsg` on a per-order result, `msg` on the envelope, and the `Error:`
    /// line of a failure the CLI formatted itself. Without any of them the
    /// raw payload is all there is, and the caller shows that instead — a
    /// message that starts with a JSON bracket is worse than one that says
    /// "insufficient BTC margin", but better than one that says nothing.
    static func okxMessage(in text: String) -> String? {
        let patterns = [
            #"\"sMsg\"\s*:\s*\"([^\"]+)\""#,
            #"\"msg\"\s*:\s*\"([^\"]+)\""#,
            #"(?m)^\s*Error:\s*(.+?)\s*$"#,
        ]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: range) {
                guard let found = Range(match.range(at: 1), in: text) else { continue }
                let words = text[found].trimmingCharacters(in: .whitespacesAndNewlines)
                if !words.isEmpty { return words }
            }
        }
        return nil
    }

    /// What to do about it, for the failures whose cause is known.
    ///
    /// The exchange's message is accurate but terse — "APIKey does not match
    /// current environment" does not say that demo and live keys are issued
    /// separately, which is the thing the reader has to know to fix it.
    public var hint: String? {
        guard case .cliFailed(_, let stderr) = self else { return nil }
        return Self.hint(forCLIOutput: stderr)
    }

    /// Advice keyed on the exchange's own code or message, whichever the CLI
    /// passed through.
    public static func hint(forCLIOutput text: String) -> String? {
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
        if lower.contains("未返回") || lower.contains("timed out") || lower.contains("timeout")
            || lower.contains("enotfound") || lower.contains("econnrefused") {
            return "网络或代理问题：CLI 没能连上 OKX。"
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

/// Wraps OKX's official CLI (Agent Trade Kit, `okx`) so MayStock never touches
/// API keys — credentials live in the CLI's own `~/.okx/config.toml`.
///
/// Safety model: every call carries an explicit `TradingMode`. Live orders are
/// refused at this layer unless the caller passes `liveUnlocked: true`, which
/// the app only does after the user flips the global setting *and* arms the
/// individual strategy.
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

    // MARK: Trading

    /// The `okx` CLI module that trades this family, or a refusal naming the
    /// family OKX does not list. Every command below starts with one, so a
    /// stock that somehow reached this bridge is turned back here rather than
    /// sent to a subcommand that does not exist.
    private static func module(for instType: InstrumentType) throws -> String {
        guard let module = instType.cliModule else {
            throw TradeError.unsupportedInstrument(instType)
        }
        return module
    }

    public func place(
        _ order: OrderRequest, mode: TradingMode, liveUnlocked: Bool = false
    ) async throws -> OrderResult {
        if mode == .live && !liveUnlocked { throw TradeError.liveTradingLocked }

        var args = [try Self.module(for: order.instType), "place",
                    "--instId", order.instId,
                    "--side", order.side.rawValue,
                    "--ordType", order.kind.rawValue,
                    "--sz", PriceFormatter.plain(order.size)]
        if order.kind.isPriced, let price = order.limitPrice {
            args += ["--px", PriceFormatter.plain(price)]
        }
        if let tradeMode = order.tradeMode {
            args += ["--tdMode", tradeMode]
        }
        if order.instType == .spot, order.kind == .market {
            // Market orders: spend quote ccy when buying by quote size.
            args += ["--tgtCcy", order.sizeUnit == .quote ? "quote_ccy" : "base_ccy"]
        }
        if let posSide = order.posSide, order.instType.usesPositionSide {
            args += ["--posSide", posSide.rawValue]
        }
        if order.reduceOnly, order.instType.isDerivative {
            // A bare flag, as the CLI documents it for every module.
            args += ["--reduceOnly"]
        }
        // `-1` is OKX's "fill at market once triggered". A limit exit could sit
        // unfilled through the move it was meant to escape.
        if let stop = order.stopTriggerPrice, stop > 0 {
            args += ["--slTriggerPx", PriceFormatter.plain(stop), "--slOrdPx", "-1"]
        }
        if let target = order.takeProfitTriggerPrice, target > 0 {
            args += ["--tpTriggerPx", PriceFormatter.plain(target), "--tpOrdPx", "-1"]
        }
        if let clOrdId = order.clOrdId {
            args += ["--clOrdId", clOrdId]
        }

        let output = try await runCLI(args, mode: mode)
        guard let ordId = Self.findString(key: "ordId", in: output), !ordId.isEmpty else {
            throw TradeError.badOutput(output)
        }
        return OrderResult(ordId: ordId, clOrdId: order.clOrdId, raw: output)
    }

    public func cancel(
        instId: String, instType: InstrumentType, ordId: String,
        mode: TradingMode, liveUnlocked: Bool = false
    ) async throws {
        if mode == .live && !liveUnlocked { throw TradeError.liveTradingLocked }
        _ = try await runCLI(
            [try Self.module(for: instType), "cancel", instId, "--ordId", ordId], mode: mode)
    }

    /// How the account is configured for derivatives.
    public func accountTradingConfig(mode: TradingMode) async throws -> AccountTradingConfig {
        let output = try await runCLI(["account", "config"], mode: mode)
        guard let config = Self.parseAccountTradingConfig(json: output) else {
            throw TradeError.badOutput(output)
        }
        return config
    }

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

    // MARK: Account

    /// `okx account balance-all` — trading + funding balances with valuation.
    /// Falls back to `account balance` on CLI versions without the aggregate.
    public func accountSnapshot(mode: TradingMode) async throws -> AccountSnapshot {
        let output: String
        if let aggregate = try? await runCLI(["account", "balance-all"], mode: mode) {
            output = aggregate
        } else {
            output = try await runCLI(["account", "balance"], mode: mode)
        }
        return AccountSnapshot(
            balances: Self.parseBalances(json: output),
            totalEquity: Self.parseTotalEquity(json: output))
    }

    public func balances(mode: TradingMode) async throws -> [AccountBalance] {
        try await accountSnapshot(mode: mode).balances
    }

    /// Open derivative positions. Spot has no position concept — its exposure
    /// is simply the base-currency balance.
    public func positions(mode: TradingMode, instType: InstrumentType = .swap) async throws -> [ExchangePosition] {
        let output = try await runCLI(
            ["account", "positions", "--instType", instType.rawValue], mode: mode)
        return Self.parsePositions(json: output)
    }

    /// Every position the exchange holds, whatever family — perpetuals,
    /// delivery futures, options, margin — in one unfiltered listing. The
    /// per-family call above only knows the families this app trades; an
    /// account can hold more than that, and all of it is price risk.
    public func allPositions(mode: TradingMode) async throws -> [ExchangePosition] {
        Self.parsePositions(json: try await runCLI(["account", "positions"], mode: mode))
    }

    /// Resolve an order by its client id.
    ///
    /// A timeout is not a rejection: the request may have reached the exchange
    /// and filled. Absent from the listing is the *only* answer that makes a
    /// retry safe, so that is the only case reported as `.unknown`.
    ///
    /// Two listings, because the CLI keeps them apart: `orders` is the working
    /// book and `orders --history` the last week of finished ones. An order
    /// that filled is in the second and not the first, so asking only the
    /// first — which is what this used to do, with a `--state all` flag the
    /// CLI silently ignored — answered "never seen" for every filled order.
    public func orderStatus(
        instId: String, instType: InstrumentType, clOrdId: String, mode: TradingMode
    ) async throws -> VenueOrderStatus {
        let module = try Self.module(for: instType)
        let working = try await runCLI([module, "orders", "--instId", instId], mode: mode)
        let status = Self.parseOrderStatus(json: working, clOrdId: clOrdId)
        if status != .unknown { return status }
        let finished = try await runCLI(
            [module, "orders", "--instId", instId, "--history"], mode: mode)
        return Self.parseOrderStatus(json: finished, clOrdId: clOrdId)
    }

    static func parseOrderStatus(json: String, clOrdId: String) -> VenueOrderStatus {
        var result: VenueOrderStatus = .unknown
        walkObjects(in: json) { dict in
            guard (dict["clOrdId"] as? String) == clOrdId else { return }
            let filled = number(dict, "accFillSz") ?? number(dict, "fillSz") ?? 0
            let average = number(dict, "avgPx") ?? number(dict, "fillPx") ?? 0
            switch (dict["state"] as? String) ?? "" {
            case "filled", "partially_filled":
                result = .filled(filledSize: filled, averagePrice: average)
            case "canceled", "mmp_canceled":
                // A cancel after a partial fill still left us holding something.
                result = filled > 0
                    ? .filled(filledSize: filled, averagePrice: average) : .canceled
            case "live", "pending":
                result = .live
            default:
                result = filled > 0
                    ? .filled(filledSize: filled, averagePrice: average) : .live
            }
        }
        return result
    }

    /// Recent fills. This is what makes per-strategy attribution auditable:
    /// each row carries the `clOrdId` we tagged the order with.
    public func fills(
        instId: String? = nil, instType: InstrumentType = .spot, mode: TradingMode
    ) async throws -> [ExchangeFill] {
        var args = [try Self.module(for: instType), "fills"]
        if let instId { args += ["--instId", instId] }
        let output = try await runCLI(args, mode: mode)
        return Self.parseFills(json: output)
    }

    /// Funding settlements charged on perpetual positions.
    ///
    /// The backtester models funding from real rate history; live ignored it
    /// entirely, which for a short held across several days is not a rounding
    /// error — it is the position's whole edge, paid out eight-hourly.
    ///
    /// OKX files these under bill type 8; `balChg` carries the signed amount,
    /// negative when we paid.
    public func fundingPayments(
        instId: String?, mode: TradingMode, limit: Int = 100
    ) async throws -> [FundingPayment] {
        var args = ["account", "bills", "--instType", "SWAP", "--limit", String(limit)]
        if let instId { args += ["--instId", instId] }
        let output = try await runCLI(args, mode: mode)
        return Self.parseFundingPayments(json: output, instId: instId)
    }

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

    /// Prove that a mode's credentials reach *its* environment.
    ///
    /// One authenticated read — the balance — is the whole test: it fails on
    /// a missing profile, a key from the other environment, a wrong secret or
    /// passphrase, and a frozen key, each with the exchange's own words. The
    /// account configuration is read afterwards on a best-effort basis, because
    /// the position mode decides whether perpetual orders are accepted at all
    /// and that is worth showing next to the green tick.
    public func verifyConnection(mode: TradingMode) async throws -> VenueConnectionReport {
        let snapshot = try await accountSnapshot(mode: mode)
        let config = try? await accountConfig(mode: mode)
        return VenueConnectionReport(
            mode: mode,
            profile: profile(for: mode),
            checkedAt: Date(),
            totalEquity: snapshot.totalEquity,
            balanceCount: snapshot.balances.count,
            account: config)
    }

    /// `okx account config` — the account's level, position mode and the key's
    /// permissions. Read-only.
    public func accountConfig(mode: TradingMode) async throws -> AccountConfigInfo {
        let output = try await runCLI(["account", "config"], mode: mode)
        guard let info = Self.parseAccountConfig(json: output) else {
            throw TradeError.badOutput(output)
        }
        return info
    }

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

    // MARK: Open orders

    /// Every order the exchange is holding open on this account: the normal
    /// book and the algo book of each family the CLI has a module for.
    ///
    /// A book that cannot be listed is reported by name rather than skipped.
    /// The CLI's option algo listing, for one, is refused by the exchange
    /// ("Parameter instType error"), and an empty list in its place would
    /// read as "nothing armed" on an account that may well have a stop there.
    /// Only when no book at all could be read is the failure an error.
    public func openOrders(mode: TradingMode) async throws -> OpenOrderListing {
        var listing = OpenOrderListing()
        var firstError: Error?
        var attempted = 0
        for instType in InstrumentType.allCases {
            guard let module = instType.cliModule else { continue }
            for book in ExchangeOpenOrder.Book.allCases {
                attempted += 1
                let arguments = book == .order ? [module, "orders"] : [module, "algo", "orders"]
                do {
                    let output = try await runCLI(arguments, mode: mode)
                    listing.orders += Self.parseOpenOrders(json: output, book: book)
                } catch {
                    firstError = firstError ?? error
                    listing.unavailable.append("\(instType.displayName)\(book.displayName)")
                    Log.warn("bridge: 读取\(instType.displayName)\(book.displayName)失败：\(error)")
                }
            }
        }
        if listing.unavailable.count == attempted, let firstError { throw firstError }
        listing.orders.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        return listing
    }

    /// States in which an order is still on the book. The listing endpoints
    /// only return open orders, but their history variants share the shape,
    /// and a finished order must never be shown as armed.
    static let openOrderStates: Set<String> = [
        "live", "partially_filled", "effective", "partially_effective", "pause",
    ]

    static func parseOpenOrders(json: String, book: ExchangeOpenOrder.Book) -> [ExchangeOpenOrder] {
        var out: [ExchangeOpenOrder] = []
        walkObjects(in: json) { dict in
            guard let id = dict[book == .algo ? "algoId" : "ordId"] as? String, !id.isEmpty,
                  let instId = dict["instId"] as? String, !instId.isEmpty,
                  let sideRaw = dict["side"] as? String, let side = OrderSide(rawValue: sideRaw)
            else { return }
            let state = (dict["state"] as? String) ?? ""
            guard state.isEmpty || openOrderStates.contains(state) else { return }

            let stop = number(dict, "slTriggerPx")
            let target = number(dict, "tpTriggerPx")
            // A leg priced at -1 fills at market; only a real level is a price.
            let legPrice = [number(dict, "tpOrdPx"), number(dict, "slOrdPx")].compactMap { $0 }.first { $0 > 0 }
            let price = number(dict, "px") ?? number(dict, "orderPx") ?? legPrice
            let trigger = number(dict, "triggerPx") ?? number(dict, "moveTriggerPx")
                ?? (stop != nil && target != nil ? nil : (stop ?? target))
            let createdAt = number(dict, "cTime").map { Date(timeIntervalSince1970: $0 / 1_000) }
            out.append(ExchangeOpenOrder(
                id: id, book: book, instId: instId,
                ordType: (dict["ordType"] as? String) ?? "",
                side: side,
                posSide: (dict["posSide"] as? String).flatMap(PositionSide.init(rawValue:)),
                price: price, triggerPrice: trigger,
                stopTriggerPrice: stop, takeProfitTriggerPrice: target,
                size: number(dict, "sz"),
                closeFraction: number(dict, "closeFraction"),
                filledSize: number(dict, "fillSz") ?? number(dict, "actualSz") ?? 0,
                state: state,
                reduceOnly: flag(dict, "reduceOnly") ?? false,
                clOrdId: (dict["clOrdId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                createdAt: createdAt))
        }
        return out
    }

    // MARK: Protective orders

    /// Stops and take-profits the exchange is currently holding.
    ///
    /// `--ordType conditional,oco` covers both the single stop attached to an
    /// entry and the paired stop/target; anything else in the algo book (grid
    /// bots, TWAP) is somebody else's and is not reported here.
    public func protectiveOrders(
        instId: String, instType: InstrumentType, mode: TradingMode
    ) async throws -> [VenueProtectiveOrder] {
        let output = try await runCLI(
            [try Self.module(for: instType), "algo", "orders", "--instId", instId], mode: mode)
        return Self.parseProtectiveOrders(json: output, instId: instId)
    }

    static func parseProtectiveOrders(json: String, instId: String) -> [VenueProtectiveOrder] {
        var found: [VenueProtectiveOrder] = []
        walkObjects(in: json) { dict in
            guard let algoId = dict["algoId"] as? String, !algoId.isEmpty,
                  (dict["instId"] as? String) == instId else { return }
            let stop = number(dict, "slTriggerPx")
            let target = number(dict, "tpTriggerPx")
            // An algo order with neither leg is not protecting anything.
            guard stop != nil || target != nil else { return }
            found.append(VenueProtectiveOrder(
                algoId: algoId, instId: instId,
                stopTriggerPrice: stop, takeProfitTriggerPrice: target,
                size: number(dict, "sz") ?? 0,
                posSide: (dict["posSide"] as? String).flatMap(PositionSide.init(rawValue:))))
        }
        return found
    }

    /// Move an existing stop's trigger price, leaving everything else alone.
    public func amendProtectiveOrder(
        instId: String, instType: InstrumentType, algoId: String,
        stopPrice: Double, mode: TradingMode, liveUnlocked: Bool = false
    ) async throws {
        if mode == .live && !liveUnlocked { throw TradeError.liveTradingLocked }
        _ = try await runCLI(
            [try Self.module(for: instType), "algo", "amend", "--instId", instId, "--algoId", algoId,
             "--newSlTriggerPx", PriceFormatter.plain(stopPrice), "--newSlOrdPx", "-1"],
            mode: mode)
    }

    /// Attach a standalone reduce-only stop to a position that has none.
    public func placeProtectiveOrder(
        instId: String, instType: InstrumentType, posSide: PositionSide?,
        size: Double, stopPrice: Double, mode: TradingMode, liveUnlocked: Bool = false
    ) async throws {
        if mode == .live && !liveUnlocked { throw TradeError.liveTradingLocked }
        // The order that closes a long is a sell, and vice versa.
        let side: OrderSide = posSide == .short ? .buy : .sell
        var args = [try Self.module(for: instType), "algo", "place", "--instId", instId,
                    "--side", side.rawValue, "--sz", PriceFormatter.plain(size),
                    "--ordType", "conditional",
                    "--slTriggerPx", PriceFormatter.plain(stopPrice),
                    "--slOrdPx", "-1", "--reduceOnly"]
        if let posSide, instType.usesPositionSide { args += ["--posSide", posSide.rawValue] }
        _ = try await runCLI(args, mode: mode)
    }

    /// This account's actual fee rates. The published tier table is a good
    /// default, but promotions, OKB discounts and sub-account terms all move
    /// the real number — so when credentials exist, ask.
    public func feeRates(instType: InstrumentType, mode: TradingMode) async throws -> AccountFeeRates {
        let output = try await runCLI(
            ["account", "fees", "--instType", instType.rawValue], mode: mode)
        guard let rates = Self.parseFeeRates(json: output, instType: instType) else {
            throw TradeError.badOutput(output)
        }
        return rates
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

    static func parseBalances(json: String) -> [AccountBalance] {
        var best: [String: AccountBalance] = [:]
        walkObjects(in: json) { dict in
            guard let ccy = dict["ccy"] as? String, !ccy.isEmpty else { return }
            let available = number(dict, "availBal") ?? number(dict, "availEq") ?? 0
            let total = number(dict, "cashBal") ?? number(dict, "bal") ?? number(dict, "eq") ?? available
            guard available > 0 || total > 0 else { return }
            let candidate = AccountBalance(
                ccy: ccy, available: available, total: total,
                valuationUsd: number(dict, "eqUsd") ?? number(dict, "valuationUsd"))
            // The same currency appears in trading and funding sections; keep
            // the larger holding rather than whichever the walker hit last.
            if let existing = best[ccy], existing.total >= total { return }
            best[ccy] = candidate
        }
        return best.values.sorted { $0.ccy < $1.ccy }
    }

    /// Total account equity, wherever the CLI happened to put it.
    ///
    /// `balance-all` reports `trading.totalEq` alongside a separate
    /// `valuation.totalBal`; the plain `balance` command reports only the
    /// former. Prefer unified-account equity and fall back to the valuation
    /// block, because the two disagree slightly and picking whichever the tree
    /// walk hit last would make the number flicker.
    static func parseTotalEquity(json: String) -> Double? {
        var accountEquity: Double?
        var valuation: Double?
        walkObjects(in: json) { dict in
            if let value = number(dict, "totalEq"), value > 0 {
                accountEquity = Swift.max(accountEquity ?? 0, value)
            }
            if let value = number(dict, "totalBal"), value > 0 {
                valuation = Swift.max(valuation ?? 0, value)
            }
        }
        return accountEquity ?? valuation
    }

    static func parsePositions(json: String) -> [ExchangePosition] {
        var out: [ExchangePosition] = []
        walkObjects(in: json) { dict in
            guard let instId = dict["instId"] as? String, !instId.isEmpty,
                  let raw = number(dict, "pos"), raw != 0 else { return }
            let side = PositionSide(rawValue: (dict["posSide"] as? String) ?? "net") ?? .net
            // In long/short mode OKX reports a positive size on the short leg.
            let signed = side == .short ? -abs(raw) : raw
            out.append(ExchangePosition(
                instId: instId,
                posSide: side,
                quantity: signed,
                averagePrice: number(dict, "avgPx") ?? 0,
                markPrice: number(dict, "markPx"),
                unrealisedPnL: number(dict, "upl") ?? 0,
                leverage: number(dict, "lever"),
                liquidationPrice: number(dict, "liqPx"),
                notionalUsd: number(dict, "notionalUsd"),
                instType: (dict["instType"] as? String) ?? ""))
        }
        return out
    }

    static func parseFills(json: String) -> [ExchangeFill] {
        var out: [ExchangeFill] = []
        walkObjects(in: json) { dict in
            guard let instId = dict["instId"] as? String, !instId.isEmpty,
                  let sideRaw = dict["side"] as? String, let side = OrderSide(rawValue: sideRaw),
                  let price = number(dict, "fillPx"), let size = number(dict, "fillSz"),
                  let ms = number(dict, "ts") else { return }
            let tradeId = (dict["tradeId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let ordId = (dict["ordId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let clOrdId = (dict["clOrdId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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
                clOrdId: clOrdId,
                ts: Date(timeIntervalSince1970: ms / 1000),
                // Stamped on option fills only; empty strings elsewhere, which
                // `number` already reads as absent.
                priceUsd: number(dict, "fillPxUsd"),
                indexPrice: number(dict, "fillIdxPx")))
        }
        return out.sorted { $0.ts < $1.ts }
    }

    /// OKX reports fees as signed fractions where **negative means a charge**
    /// (`"taker": "-0.001"` is 10 bps out of your pocket). We store costs as
    /// positive basis points, so the sign flips; a genuine maker rebate stays
    /// negative after the flip, which is exactly right.
    static func parseFeeRates(json: String, instType: InstrumentType) -> AccountFeeRates? {
        var result: AccountFeeRates?
        walkObjects(in: json) { dict in
            guard result == nil,
                  let taker = number(dict, "taker") ?? number(dict, "takerU"),
                  let maker = number(dict, "maker") ?? number(dict, "makerU") else { return }
            result = AccountFeeRates(
                instType: instType,
                makerBps: -maker * 10_000,
                takerBps: -taker * 10_000)
        }
        return result
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

    static func findString(key: String, in json: String) -> String? {
        var result: String?
        walkObjects(in: json) { dict in
            if result == nil, let value = dict[key] as? String, !value.isEmpty { result = value }
        }
        return result
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
