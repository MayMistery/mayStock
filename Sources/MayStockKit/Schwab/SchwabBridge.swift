import Foundation

/// The subprocess contract with `schwabctl`.
///
/// Same boundary as the `okx` CLI: the app never holds a long-lived
/// credential. `schwabctl` keeps the app secret and the refresh token in the
/// keychain, mints thirty-minute access tokens on request, and is the only
/// process that sends an order to Schwab. Every command prints JSON and, on
/// failure, a JSON error envelope with a machine-readable code — so a
/// refusal here is a verdict, never a parse of a stack trace.
public struct SchwabBridge: Sendable {
    public var explicitCLIPath: String?
    public var commandTimeout: TimeInterval

    /// Slightly above the OKX bridge's: a call is an HTTPS round trip to
    /// Schwab plus, once every thirty minutes, a token refresh.
    public static let defaultCommandTimeout: TimeInterval = 25

    public init(explicitCLIPath: String? = nil, commandTimeout: TimeInterval = SchwabBridge.defaultCommandTimeout) {
        self.explicitCLIPath = explicitCLIPath
        self.commandTimeout = commandTimeout
    }

    public init(prefs: TradingPrefs, commandTimeout: TimeInterval = SchwabBridge.defaultCommandTimeout) {
        self.init(explicitCLIPath: prefs.schwabCLIPath, commandTimeout: commandTimeout)
    }

    // MARK: Locating the binary

    /// Where `schwabctl` is looked for, in order: the explicit path, next to
    /// the running executable (the app bundle's `MacOS/` directory, or the
    /// SwiftPM build directory for the lab and the tests), the usual bin
    /// directories, then PATH.
    public func resolveCLIPath() -> String? {
        let fm = FileManager.default
        if let explicitCLIPath, fm.isExecutableFile(atPath: explicitCLIPath) { return explicitCLIPath }
        var candidates: [String] = []
        if let executable = Bundle.main.executableURL {
            let directory = executable.deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent("schwabctl").path)
            // A SwiftPM build: the lab, the e2e driver and a `swift run` sit in
            // `.build/release`, and the staged binary next door.
            candidates.append(directory.appendingPathComponent("../schwabctl/schwabctl").standardizedFileURL.path)
        }
        candidates += [
            "/Applications/MayStock.app/Contents/MacOS/schwabctl",
            "/opt/homebrew/bin/schwabctl",
            "/usr/local/bin/schwabctl",
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/schwabctl").path,
        ]
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) { return candidate }
        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                let candidate = String(dir) + "/schwabctl"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    public func detectCLI() async -> CLIInfo? {
        guard let path = resolveCLIPath() else { return nil }
        let output = (try? await runRaw(executable: path, arguments: ["version", "--json"])) ?? Data()
        let version = (try? JSONSerialization.jsonObject(with: output) as? [String: Any])?["version"] as? String
        return CLIInfo(path: path, version: version ?? "unknown")
    }

    // MARK: Commands

    public func status() async throws -> SchwabCredentialStatus {
        try Self.decode(SchwabCredentialStatus.self, from: try await run(["status"]))
    }

    public func token() async throws -> SchwabAccessToken {
        try Self.decode(SchwabAccessToken.self, from: try await run(["token"]))
    }

    public func account() async throws -> SchwabAccount {
        try SchwabWire.account(from: try await run(["account"]))
    }

    public func orders(from: Date, to: Date) async throws -> [SchwabOrder] {
        try SchwabWire.orders(from: try await run(["orders", "--from", SchwabAPI.stamp(from), "--to", SchwabAPI.stamp(to)]))
    }

    public func order(id: String) async throws -> SchwabOrder {
        try SchwabWire.order(from: try await run(["order", "--id", id]))
    }

    /// Place, returning Schwab's order id. Refused here without the unlock,
    /// and refused again by the CLI without `--live`: there is no demo
    /// account on Schwab for a mistake to land in.
    public func place(_ spec: SchwabOrderSpec, liveUnlocked: Bool) async throws -> String {
        guard liveUnlocked else { throw TradeError.liveTradingLocked }
        let data = try await run(["place", "--body", "-"], stdin: spec.bodyData, live: true)
        return try Self.orderId(in: data)
    }

    public func replace(id: String, with spec: SchwabOrderSpec, liveUnlocked: Bool) async throws -> String {
        guard liveUnlocked else { throw TradeError.liveTradingLocked }
        let data = try await run(["replace", "--id", id, "--body", "-"], stdin: spec.bodyData, live: true)
        return try Self.orderId(in: data)
    }

    public func cancel(id: String, liveUnlocked: Bool) async throws {
        guard liveUnlocked else { throw TradeError.liveTradingLocked }
        _ = try await run(["cancel", "--id", id], live: true)
    }

    public func fills(from: Date, to: Date, symbol: String? = nil) async throws -> [ExchangeFill] {
        var args = ["fills", "--from", SchwabAPI.stamp(from), "--to", SchwabAPI.stamp(to)]
        if let symbol { args += ["--symbol", symbol] }
        return try SchwabWire.fills(from: try await run(args))
    }

    public func hours(on date: Date) async throws -> USSessionHours {
        let day = SchwabAPI.newYorkDay(date)
        return try SchwabWire.sessionHours(from: try await run(["hours", "--date", day]), day: day)
    }

    // MARK: Plumbing

    static func orderId(in data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["orderId"] as? String, !id.isEmpty else {
            throw SchwabBridgeError.badOutput(String(data: data, encoding: .utf8) ?? "")
        }
        return id
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw SchwabBridgeError.badOutput(String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Run one command and return its stdout, or the error it reported.
    ///
    /// `--json` is appended to every call; `--live` only when the caller is
    /// sending an order, and never by default.
    func run(_ arguments: [String], stdin: Data? = nil, live: Bool = false) async throws -> Data {
        guard let cli = resolveCLIPath() else { throw SchwabBridgeError.cliNotFound }
        var args = arguments + ["--json"]
        if live { args.append("--live") }
        return try await runRaw(executable: cli, arguments: args, stdin: stdin)
    }

    private func runRaw(executable: String, arguments: [String], stdin: Data? = nil) async throws -> Data {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        let outcome: Subprocess.Outcome
        do {
            outcome = try await Subprocess.run(
                executable: executable, arguments: arguments, environment: env,
                stdin: stdin, timeout: commandTimeout)
        } catch Subprocess.Failure.timedOut(let seconds) {
            throw SchwabBridgeError.cliFailed(
                exitCode: -1, detail: "schwabctl 超过 \(Int(seconds)) 秒未返回，已终止：" + ([executable] + arguments).joined(separator: " "))
        } catch Subprocess.Failure.couldNotLaunch(let detail) {
            throw SchwabBridgeError.cliFailed(exitCode: -1, detail: detail)
        }
        guard outcome.exitCode == 0 else {
            throw Self.failure(exitCode: outcome.exitCode, stdout: outcome.stdout, stderr: outcome.stderrText)
        }
        return outcome.stdout
    }

    /// The CLI's own verdict, when it printed one. The envelope's code is
    /// the contract: `not_logged_in` and `not_configured` mean nothing
    /// authenticated can work, `refused` means the live gate, `rejected`
    /// means Schwab saw the order and said no — final, nothing in flight.
    static func failure(exitCode: Int32, stdout: Data, stderr: String) -> Error {
        if let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? String) ?? ""
            let message = (error["message"] as? String) ?? ""
            switch code {
            case "not_logged_in", "not_configured":
                return SchwabAPIError.loggedOut(message)
            case "refused":
                return TradeError.liveTradingLocked
            case "rejected":
                return TradeError.rejected(venue: Venue.schwab.displayName, reason: message)
            case "rate_limited":
                return SchwabAPIError.rateLimited
            case "http":
                let status = (error["status"] as? Int) ?? 0
                if (400..<500).contains(status), let _ = error["order"] {
                    return TradeError.rejected(venue: Venue.schwab.displayName, reason: "HTTP \(status)：\(message)")
                }
                return SchwabAPIError.http(status: status, body: message)
            default:
                return SchwabBridgeError.cliFailed(exitCode: exitCode, detail: message.isEmpty ? code : message)
            }
        }
        let detail = [stderr, String(data: stdout, encoding: .utf8) ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return SchwabBridgeError.cliFailed(exitCode: exitCode, detail: detail)
    }
}

public enum SchwabBridgeError: Error, CustomStringConvertible, Sendable, Equatable {
    case cliNotFound
    case cliFailed(exitCode: Int32, detail: String)
    case badOutput(String)

    public var description: String {
        switch self {
        case .cliNotFound:
            return "未找到 schwabctl（随 MayStock 安装在 /Applications/MayStock.app/Contents/MacOS/，或运行 ./Scripts/make.sh install）"
        case .cliFailed(let code, let detail):
            return "schwabctl 退出码 \(code)：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .badOutput(let raw):
            return "schwabctl 输出无法解析：\(raw.prefix(200))"
        }
    }
}

/// Access tokens for the app, minted by `schwabctl` and cached until they
/// are about to expire. The refresh token never crosses the process line.
public actor SchwabCLITokenSource: SchwabTokenSource {
    private var bridge: SchwabBridge
    private var cached: SchwabAccessToken?
    private var inflight: Task<SchwabAccessToken, Error>?

    public init(bridge: SchwabBridge) {
        self.bridge = bridge
    }

    /// The settings changed — a new `schwabctl` path — so the next token
    /// comes from the new binary, not the cached one.
    public func update(bridge: SchwabBridge) {
        self.bridge = bridge
        cached = nil
    }

    public func accessToken() async throws -> String {
        let now = Date()
        if let cached, cached.valid(at: now) { return cached.accessToken }
        if let inflight { return try await inflight.value.accessToken }
        let bridge = self.bridge
        let task = Task { try await bridge.token() }
        inflight = task
        defer { inflight = nil }
        do {
            let token = try await task.value
            cached = token
            return token.accessToken
        } catch let error as SchwabBridgeError {
            // The CLI missing or crashing is not a login problem, but it has
            // the same consequence for a reader: no token, so fall back.
            throw SchwabAPIError.loggedOut(error.description)
        }
    }

    public func invalidate() {
        cached = nil
    }

    public func status() async -> SchwabCredentialStatus? {
        try? await bridge.status()
    }
}
