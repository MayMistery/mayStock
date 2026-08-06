import Foundation

// MARK: - Engine declaration

/// How a manifest produces signals.
public enum StrategyEngineSpec: Codable, Sendable, Equatable {
    /// Expressions evaluated in-process. Cannot do anything but arithmetic.
    case declarative
    /// An external program. **Running one executes code that arrived with an
    /// imported file**, so it stays off until the user turns it on in Settings
    /// and is refused outright by the engine otherwise.
    case script(ScriptEngineSpec)

    private enum CodingKeys: String, CodingKey { case kind }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "declarative"
        switch kind {
        case "script": self = .script(try ScriptEngineSpec(from: decoder))
        case "declarative": self = .declarative
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "engine.kind 只支持 declarative 或 script")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .declarative:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("declarative", forKey: .kind)
        case .script(let spec):
            try spec.encode(to: encoder)
        }
    }

    public var isScript: Bool {
        if case .script = self { return true }
        return false
    }

    public var scriptSpec: ScriptEngineSpec? {
        if case .script(let spec) = self { return spec }
        return nil
    }
}

public struct ScriptEngineSpec: Codable, Sendable, Equatable {
    public var kind: String
    /// Interpreter or executable. Relative paths resolve against the manifest's
    /// directory when one is known.
    public var command: String
    public var args: [String]
    /// Hard kill after this many seconds. A hung script must not hang the app.
    public var timeoutSeconds: Double

    public init(command: String, args: [String] = [], timeoutSeconds: Double = 30) {
        self.kind = "script"
        self.command = command
        self.args = args
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey { case kind, command, args, timeoutSeconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = "script"
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 30
    }
}

public enum ScriptEngineError: Error, CustomStringConvertible, Sendable {
    case disabled
    case executableMissing(String)
    case timedOut(Double)
    case failed(exitCode: Int32, stderr: String)
    case badOutput(String)
    case lengthMismatch(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .disabled:
            return "外部脚本策略未启用。它会在本机执行导入文件带来的代码，"
                + "确认可信后在 设置 → 交易 → 允许外部脚本策略 中开启。"
        case .executableMissing(let path):
            return "脚本不存在或不可执行：\(path)"
        case .timedOut(let seconds):
            return "脚本超过 \(PriceFormatter.plain(seconds)) 秒未返回，已终止"
        case .failed(let code, let stderr):
            return "脚本退出码 \(code)：\(stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"
        case .badOutput(let detail):
            return "脚本输出无法解析：\(detail)"
        case .lengthMismatch(let expected, let got):
            return "脚本返回 \(got) 个信号，与 \(expected) 根 K 线不匹配"
        }
    }
}

// MARK: - Engine

/// Runs an external program to produce target positions.
///
/// Contract — one JSON object in on stdin, one JSON object out on stdout:
///
/// ```
/// in : {"schema":1,"instId":"BTC-USDT","bar":"1H","params":{…},
///       "candles":[{"ts":1700000000,"o":1,"h":2,"l":0.5,"c":1.5,"v":10}, …],
///       "series":{"funding":[…]}}
/// out: {"target":["flat","long","long",null, …]}
/// ```
///
/// `target[i]` is the position to hold **from bar i+1 onward** — the engine
/// applies it exactly like a declarative signal, so the same next-bar-open
/// execution and the same stops, cooldowns and budgets apply. A script cannot
/// place orders itself; it only ever answers "which way should I be pointed".
public struct ScriptStrategyEngine: Sendable {
    public let spec: ScriptEngineSpec
    /// Directory a relative `command` resolves against.
    public let workingDirectory: URL?
    /// Guard against a runaway script filling memory.
    public static let maxOutputBytes = 8 * 1024 * 1024

    public init(spec: ScriptEngineSpec, workingDirectory: URL? = nil) {
        self.spec = spec
        self.workingDirectory = workingDirectory
    }

    public func resolvedCommand() -> String {
        let path = (spec.command as NSString).expandingTildeInPath
        if path.hasPrefix("/") { return path }
        guard let workingDirectory else { return path }
        return workingDirectory.appendingPathComponent(path).path
    }

    /// Ask the script for a target position per candle.
    ///
    /// `enabled` is the user's explicit unlock; the engine refuses to spawn
    /// anything without it, so a manifest cannot opt itself in.
    public func targets(
        candles: [Candle],
        params: [String: Double],
        series: [String: [Double]] = [:],
        instId: String,
        bar: BarInterval,
        enabled: Bool
    ) async throws -> [TradeDirection?] {
        guard enabled else { throw ScriptEngineError.disabled }
        let executable = resolvedCommand()
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ScriptEngineError.executableMissing(executable)
        }

        let payload = try Self.encodeRequest(
            candles: candles, params: params, series: series, instId: instId, bar: bar)
        let output = try await run(executable: executable, input: payload)
        return try Self.decodeTargets(output, expected: candles.count)
    }

    // MARK: Wire format

    public static func encodeRequest(
        candles: [Candle], params: [String: Double], series: [String: [Double]],
        instId: String, bar: BarInterval
    ) throws -> Data {
        var root: [String: Any] = [
            "schema": 1,
            "instId": instId,
            "bar": bar.rawValue,
            "params": params,
        ]
        root["candles"] = candles.map { candle in
            [
                "ts": Int(candle.ts.timeIntervalSince1970),
                "o": candle.open, "h": candle.high, "l": candle.low,
                "c": candle.close, "v": candle.volume,
            ] as [String: Any]
        }
        if !series.isEmpty {
            // JSON has no NaN; "unknown" travels as null.
            root["series"] = series.mapValues { values in
                values.map { $0.isNaN ? NSNull() : NSNumber(value: $0) }
            }
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    public static func decodeTargets(_ data: Data, expected: Int) throws -> [TradeDirection?] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            throw ScriptEngineError.badOutput("顶层不是 JSON 对象：\(preview)")
        }
        guard let raw = root["target"] as? [Any] else {
            throw ScriptEngineError.badOutput("缺少 target 数组")
        }
        guard raw.count == expected else {
            throw ScriptEngineError.lengthMismatch(expected: expected, got: raw.count)
        }
        return try raw.map { entry -> TradeDirection? in
            if entry is NSNull { return nil }
            guard let text = entry as? String else {
                throw ScriptEngineError.badOutput("target 元素必须是 long/short/flat 或 null")
            }
            switch text.lowercased() {
            case "long": return .long
            case "short": return .short
            case "flat", "none", "": return nil
            default:
                throw ScriptEngineError.badOutput("未知的 target 值：\(text)")
            }
        }
    }

    // MARK: Subprocess

    /// Feed the script its input and collect its answer.
    ///
    /// The deadline, the pipe draining and the guarantee that this returns *at
    /// all* live in `Subprocess`; this used to carry its own copy, including
    /// the flaw that let a script which exits while a spawned child keeps
    /// stdout open suspend the caller for good. See the note on that type.
    private func run(executable: String, input: Data) async throws -> Data {
        let outcome: Subprocess.Outcome
        do {
            outcome = try await Subprocess.run(
                executable: executable, arguments: spec.args,
                workingDirectory: workingDirectory, stdin: input,
                timeout: spec.timeoutSeconds,
                maxOutputBytes: Self.maxOutputBytes)
        } catch Subprocess.Failure.timedOut(let seconds) {
            throw ScriptEngineError.timedOut(seconds)
        } catch Subprocess.Failure.outputTooLarge(let limit) {
            throw ScriptEngineError.badOutput("输出超过 \(limit / 1_048_576) MB 上限")
        } catch Subprocess.Failure.couldNotLaunch(let detail) {
            throw ScriptEngineError.failed(exitCode: -1, stderr: detail)
        }

        guard outcome.exitCode == 0 else {
            throw ScriptEngineError.failed(
                exitCode: outcome.exitCode, stderr: outcome.stderrText)
        }
        return outcome.stdout
    }
}
