import Foundation

// MARK: - Order model

public enum OrderSide: String, Sendable, Equatable, Codable {
    case buy, sell

    public var sign: Double { self == .buy ? 1 : -1 }
    public var displayName: String { self == .buy ? "买入" : "卖出" }
}

public enum OrderKind: String, Sendable, Equatable, Codable {
    case market, limit
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
        clOrdId: String? = nil
    ) {
        self.stopTriggerPrice = stopTriggerPrice
        self.takeProfitTriggerPrice = takeProfitTriggerPrice
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

    public var id: String { instId + posSide.rawValue }

    public init(
        instId: String, posSide: PositionSide, quantity: Double, averagePrice: Double,
        markPrice: Double?, unrealisedPnL: Double, leverage: Double?, liquidationPrice: Double?
    ) {
        self.instId = instId
        self.posSide = posSide
        self.quantity = quantity
        self.averagePrice = averagePrice
        self.markPrice = markPrice
        self.unrealisedPnL = unrealisedPnL
        self.leverage = leverage
        self.liquidationPrice = liquidationPrice
    }
}

public struct ExchangeFill: Sendable, Equatable, Identifiable {
    public let id: String
    public let instId: String
    public let side: OrderSide
    public let posSide: PositionSide?
    public let price: Double
    public let size: Double
    /// Fee in `feeCcy`. OKX reports charges as negative numbers.
    public let fee: Double
    public let feeCcy: String?
    public let ordId: String?
    public let clOrdId: String?
    public let ts: Date

    public init(
        id: String, instId: String, side: OrderSide, posSide: PositionSide?,
        price: Double, size: Double, fee: Double, feeCcy: String?,
        ordId: String?, clOrdId: String?, ts: Date
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
    }
}

// MARK: - Errors

public enum TradeError: Error, CustomStringConvertible, Sendable {
    case cliNotFound
    case cliFailed(exitCode: Int32, stderr: String)
    case badOutput(String)
    case liveTradingLocked
    case notConfigured

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
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "OKX \(code)：\(text.prefix(180))"
    }

    /// First non-zero OKX status code in a CLI error payload, if any.
    static func okxCode(in text: String) -> String? {
        let pattern = #"\"(?:sCode|code)\"\s*:\s*\"?(\d+)\"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let found = Range(match.range(at: 1), in: text) else { continue }
            let code = String(text[found])
            if code != "0" { return code }
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
    public var profile: String?

    public init(explicitCLIPath: String? = nil, profile: String? = nil) {
        self.explicitCLIPath = explicitCLIPath
        self.profile = profile
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
        // The CLI prepends an update banner; the version is the last real line.
        let version = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? "unknown"
        return CLIInfo(path: path, version: version)
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

    public func place(
        _ order: OrderRequest, mode: TradingMode, liveUnlocked: Bool = false
    ) async throws -> OrderResult {
        if mode == .live && !liveUnlocked { throw TradeError.liveTradingLocked }

        let module = order.instType == .swap ? "swap" : "spot"
        var args = [module, "place",
                    "--instId", order.instId,
                    "--side", order.side.rawValue,
                    "--ordType", order.kind.rawValue,
                    "--sz", PriceFormatter.plain(order.size)]
        if order.kind == .limit, let price = order.limitPrice {
            args += ["--px", PriceFormatter.plain(price)]
        }
        if order.instType == .spot, order.kind == .market {
            // Market orders: spend quote ccy when buying by quote size.
            args += ["--tgtCcy", order.sizeUnit == .quote ? "quote_ccy" : "base_ccy"]
        }
        if let posSide = order.posSide, order.instType == .swap {
            args += ["--posSide", posSide.rawValue]
        }
        if order.reduceOnly, order.instType == .swap {
            args += ["--reduceOnly", "true"]
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
        let module = instType == .swap ? "swap" : "spot"
        _ = try await runCLI([module, "cancel", instId, "--ordId", ordId], mode: mode)
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

    /// Resolve an order by its client id.
    ///
    /// A timeout is not a rejection: the request may have reached the exchange
    /// and filled. Absent from the listing is the *only* answer that makes a
    /// retry safe, so that is the only case reported as `.unknown`.
    public func orderStatus(
        instId: String, instType: InstrumentType, clOrdId: String, mode: TradingMode
    ) async throws -> VenueOrderStatus {
        let module = instType == .swap ? "swap" : "spot"
        let output = try await runCLI(
            [module, "orders", "--instId", instId, "--state", "all"], mode: mode)
        return Self.parseOrderStatus(json: output, clOrdId: clOrdId)
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
        let module = instType == .swap ? "swap" : "spot"
        var args = [module, "fills"]
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
                  let amount = number(dict, "balChg") ?? number(dict, "pnl"),
                  let ms = number(dict, "ts") else { return }
            found.append(FundingPayment(
                id: billId, instId: inst, amount: amount,
                ccy: (dict["ccy"] as? String) ?? "USDT",
                ts: Date(timeIntervalSince1970: ms / 1000)))
        }
        return found.sorted { $0.ts < $1.ts }
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
        let module = instType == .swap ? "swap" : "spot"
        let output = try await runCLI(
            [module, "algo", "orders", "--instId", instId], mode: mode)
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
        let module = instType == .swap ? "swap" : "spot"
        _ = try await runCLI(
            [module, "algo", "amend", "--instId", instId, "--algoId", algoId,
             "--newSlTriggerPx", PriceFormatter.plain(stopPrice), "--newSlOrdPx", "-1"],
            mode: mode)
    }

    /// Attach a standalone reduce-only stop to a position that has none.
    public func placeProtectiveOrder(
        instId: String, instType: InstrumentType, posSide: PositionSide?,
        size: Double, stopPrice: Double, mode: TradingMode, liveUnlocked: Bool = false
    ) async throws {
        if mode == .live && !liveUnlocked { throw TradeError.liveTradingLocked }
        let module = instType == .swap ? "swap" : "spot"
        // The order that closes a long is a sell, and vice versa.
        let side: OrderSide = posSide == .short ? .buy : .sell
        var args = [module, "algo", "place", "--instId", instId,
                    "--side", side.rawValue, "--sz", PriceFormatter.plain(size),
                    "--ordType", "conditional",
                    "--slTriggerPx", PriceFormatter.plain(stopPrice),
                    "--slOrdPx", "-1", "--reduceOnly"]
        if let posSide, instType == .swap { args += ["--posSide", posSide.rawValue] }
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

    func runCLI(_ arguments: [String], mode: TradingMode, needsAuth: Bool = true) async throws -> String {
        guard let cli = resolveCLIPath() else { throw TradeError.cliNotFound }
        var args = arguments + ["--json"]
        if needsAuth {
            args.append(mode == .demo ? "--demo" : "--live")
            if let profile { args += ["--profile", profile] }
        }
        return try await run(executable: cli, arguments: args)
    }

    // MARK: Subprocess plumbing

    /// Hard ceiling on one CLI invocation. The runner ticks every 20s and some
    /// calls fall back to a second command, so this stays well under that: a
    /// real invocation takes well under a second.
    public static let commandTimeout: TimeInterval = 15

    private func run(executable: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { continuation in
            let outcome = SingleResume()
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: TradeError.cliFailed(
                    exitCode: -1, stderr: String(describing: error)))
                return
            }

            // Drain both pipes **concurrently**. Reading stdout to completion
            // before touching stderr deadlocks the moment the child fills the
            // stderr buffer — and the okx CLI writes an update banner there.
            let collected = PipeBuffers()
            let group = DispatchGroup()
            for (pipe, isStdout) in [(stdout, true), (stderr, false)] {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    collected.store(data, isStdout: isStdout)
                    group.leave()
                }
            }

            // Watchdog: a wedged CLI gets killed rather than hanging the caller
            // forever. Without this the strategy runner stops silently.
            let timeout = Self.commandTimeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                if outcome.claim() {
                    continuation.resume(throwing: TradeError.cliFailed(
                        exitCode: -1,
                        stderr: "okx CLI 超过 \(Int(timeout)) 秒未返回，已终止："
                            + ([executable] + arguments).joined(separator: " ")))
                }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                group.wait()
                process.waitUntilExit()
                guard outcome.claim() else { return }   // the watchdog got there first
                let out = collected.stdoutText
                if process.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let err = collected.stderrText
                    continuation.resume(throwing: TradeError.cliFailed(
                        exitCode: process.terminationStatus,
                        stderr: err.isEmpty ? out : err))
                }
            }
        }
    }

    /// Guarantees exactly one of {completion, watchdog} resumes the continuation.
    private final class SingleResume: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }

    /// Thread-safe collection point for the two pipe readers.
    private final class PipeBuffers: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()

        func store(_ data: Data, isStdout: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isStdout { out = data } else { err = data }
        }

        var stdoutText: String {
            lock.lock(); defer { lock.unlock() }
            return String(data: out, encoding: .utf8) ?? ""
        }

        var stderrText: String {
            lock.lock(); defer { lock.unlock() }
            return String(data: err, encoding: .utf8) ?? ""
        }
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
                liquidationPrice: number(dict, "liqPx")))
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
                ts: Date(timeIntervalSince1970: ms / 1000)))
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
