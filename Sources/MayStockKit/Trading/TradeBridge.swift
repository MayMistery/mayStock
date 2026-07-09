import Foundation

// MARK: - Order model

public struct SpotOrderRequest: Sendable, Equatable {
    public enum Side: String, Sendable { case buy, sell }
    public enum Kind: String, Sendable { case market, limit }
    /// How `size` is denominated for market orders.
    public enum SizeUnit: String, Sendable { case base, quote }

    public var instId: String
    public var side: Side
    public var kind: Kind
    public var size: Double
    public var sizeUnit: SizeUnit
    public var limitPrice: Double?

    public init(
        instId: String, side: Side, kind: Kind,
        size: Double, sizeUnit: SizeUnit = .quote, limitPrice: Double? = nil
    ) {
        self.instId = instId
        self.side = side
        self.kind = kind
        self.size = size
        self.sizeUnit = sizeUnit
        self.limitPrice = limitPrice
    }
}

public struct OrderResult: Sendable, Equatable {
    public let ordId: String
    public let raw: String
    public init(ordId: String, raw: String) {
        self.ordId = ordId
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

public enum TradeError: Error, CustomStringConvertible, Sendable {
    case cliNotFound
    case cliFailed(exitCode: Int32, stderr: String)
    case badOutput(String)
    case liveTradingLocked

    public var description: String {
        switch self {
        case .cliNotFound:
            return "未找到官方 okx CLI。安装：npm install -g @okx_ai/okx-trade-cli"
        case .cliFailed(let code, let stderr):
            return "okx CLI 退出码 \(code)：\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .badOutput(let raw):
            return "okx CLI 输出无法解析：\(raw.prefix(200))"
        case .liveTradingLocked:
            return "实盘交易未解锁（设置 → Trading）。当前仅允许 demo 模拟盘。"
        }
    }
}

// MARK: - Bridge

/// Wraps OKX's official CLI (Agent Trade Kit, `okx`) so MayStock never
/// touches API keys — credentials live in the CLI's own `~/.okx/config.toml`.
///
/// Safety model: every call carries an explicit `demo` flag. Live orders are
/// refused at this layer unless the caller passes `liveUnlocked: true`
/// (which the app only does after the user flips the setting *and* confirms
/// the individual order).
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
        let version = (try? await run(executable: path, arguments: ["--version"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
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

    // MARK: Commands

    public func placeSpotOrder(
        _ order: SpotOrderRequest, demo: Bool, liveUnlocked: Bool = false
    ) async throws -> OrderResult {
        if !demo && !liveUnlocked { throw TradeError.liveTradingLocked }

        var args = ["spot", "place",
                    "--instId", order.instId,
                    "--side", order.side.rawValue,
                    "--ordType", order.kind.rawValue,
                    "--sz", PriceFormatter.plain(order.size)]
        if order.kind == .limit, let px = order.limitPrice {
            args += ["--px", PriceFormatter.plain(px)]
        }
        if order.kind == .market {
            // Market orders: spend quote ccy when buying by quote size.
            args += ["--tgtCcy", order.sizeUnit == .quote ? "quote_ccy" : "base_ccy"]
        }
        let output = try await runCLI(args, demo: demo)
        return OrderResult(ordId: Self.extractOrdId(from: output) ?? "?", raw: output)
    }

    /// `okx account balance --json` → [(currency, available)] sorted by ccy.
    public func balances(demo: Bool) async throws -> [(ccy: String, available: Double)] {
        let output = try await runCLI(["account", "balance"], demo: demo)
        return Self.parseBalances(json: output)
    }

    /// Public market ping through the CLI (no keys needed) — used by e2e.
    public func marketTicker(instId: String) async throws -> String {
        try await runCLI(["market", "ticker", instId], demo: false, needsAuth: false)
    }

    func runCLI(_ arguments: [String], demo: Bool, needsAuth: Bool = true) async throws -> String {
        guard let cli = resolveCLIPath() else { throw TradeError.cliNotFound }
        var args = arguments + ["--json"]
        if demo && needsAuth { args.append("--demo") }
        if let profile, needsAuth { args += ["--profile", profile] }
        return try await run(executable: cli, arguments: args)
    }

    // MARK: Subprocess plumbing

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
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: TradeError.cliFailed(exitCode: -1, stderr: String(describing: error)))
                return
            }
            // Read on a background thread; pipes can fill before termination.
            DispatchQueue.global(qos: .userInitiated).async {
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let out = String(data: outData, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: TradeError.cliFailed(
                        exitCode: process.terminationStatus,
                        stderr: err.isEmpty ? out : err))
                }
            }
        }
    }

    // MARK: Output parsing (tolerant of envelope shapes)

    static func extractOrdId(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findString(key: "ordId", in: obj)
    }

    static func parseBalances(json: String) -> [(ccy: String, available: Double)] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var found: [(String, Double)] = []
        walk(root) { dict in
            if let ccy = dict["ccy"] as? String {
                let avail = (dict["availBal"] as? String).flatMap(Double.init)
                    ?? (dict["availBal"] as? Double)
                    ?? (dict["cashBal"] as? String).flatMap(Double.init)
                if let avail, avail > 0 {
                    found.append((ccy, avail))
                }
            }
        }
        var best: [String: Double] = [:]
        for (ccy, avail) in found { best[ccy] = max(best[ccy] ?? 0, avail) }
        return best.map { (ccy: $0.key, available: $0.value) }.sorted { $0.ccy < $1.ccy }
    }

    private static func findString(key: String, in object: Any) -> String? {
        var result: String?
        walk(object) { dict in
            if result == nil, let v = dict[key] as? String, !v.isEmpty { result = v }
        }
        return result
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
