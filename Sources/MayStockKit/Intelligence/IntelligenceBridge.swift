import Foundation

public struct IntelligenceQuote: Codable, Sendable {
    public var instId: String
    public var price: Double
    public var change24h: Double?
    public var asOf: Date
    public init(ticker: Ticker) {
        instId = ticker.instId
        price = ticker.last
        // Twenty-four hours, whatever the screen measures from; a stock
        // publishes no such reference and sends none.
        change24h = ticker.changePct(on: .rolling24h)
        asOf = ticker.ts
    }
}

public struct IntelligenceKnownEvent: Codable, Sendable {
    public var id: String
    public var title: String
    public var occurredAt: Date
    public init(event: IntelligenceEvent) {
        id = event.id; title = event.title; occurredAt = event.occurredAt
    }
}

public struct IntelligenceRequest: Codable, Sendable {
    public var kind: IntelligenceKind
    public var now: Date
    public var timezone: String
    public var horizonHours: Int
    public var model: String
    public var watchlist: [String]
    public var venues: [String: String]?
    public var quotes: [IntelligenceQuote]
    public var knownEvents: [IntelligenceKnownEvent]

    public init(kind: IntelligenceKind, now: Date, settings: IntelligenceSettings,
                watchlist: [String], quotes: [IntelligenceQuote], knownEvents: [IntelligenceKnownEvent],
                venues: [String: String]? = nil) {
        self.kind = kind; self.now = now; timezone = settings.timezone
        horizonHours = settings.horizonHours; self.watchlist = watchlist
        model = settings.model
        self.quotes = quotes; self.knownEvents = knownEvents
        self.venues = venues
    }

    private enum CodingKeys: String, CodingKey {
        case kind, now, timezone, horizonHours, model, watchlist, venues, quotes, knownEvents
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(IntelligenceKind.self, forKey: .kind)
        now = try values.decode(Date.self, forKey: .now)
        timezone = try values.decode(String.self, forKey: .timezone)
        horizonHours = try values.decode(Int.self, forKey: .horizonHours)
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? IntelligenceSettings.defaultModel
        watchlist = try values.decode([String].self, forKey: .watchlist)
        venues = try values.decodeIfPresent([String: String].self, forKey: .venues)
        quotes = try values.decode([IntelligenceQuote].self, forKey: .quotes)
        knownEvents = try values.decode([IntelligenceKnownEvent].self, forKey: .knownEvents)
    }
}

public enum IntelligenceJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

public struct IntelligenceBridge: Sendable {
    public let python: URL
    public let script: URL
    public init(python: URL, script: URL) { self.python = python; self.script = script }

    /// The runner's `notice` events on stderr (`runner.DIAGNOSTICS`,
    /// docs/INTELLIGENCE-CONTRACT.md), one engine-log line per stage: how many
    /// times it fired and the values each field took. Before this the app
    /// read stdout only, so a fetch that failed, a model error or an inherited
    /// route the run left out was written to a stream nobody kept. Lines that
    /// are not JSON, and `info` progress, are skipped.
    static func noticeLines(fromStderr data: Data) -> [String] {
        var stages: [String] = []
        var counts: [String: Int] = [:]
        var values: [String: [String: [String]]] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  event["level"] as? String == "notice", let stage = event["stage"] as? String else { continue }
            if counts[stage] == nil { stages.append(stage) }
            counts[stage, default: 0] += 1
            for (key, value) in event where !["stage", "level", "at"].contains(key) {
                guard let text = loggable(value) else { continue }
                var seen = values[stage, default: [:]][key, default: []]
                if !seen.contains(text), seen.count < 6 { seen.append(text) }
                values[stage, default: [:]][key] = seen
            }
        }
        return stages.map { stage in
            let count = counts[stage] ?? 0
            let fields = (values[stage] ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.joined(separator: "、"))" }
            return "intelligence: \(stage)" + (count > 1 ? " ×\(count)" : "")
                + (fields.isEmpty ? "" : " · " + fields.joined(separator: " · "))
        }
    }

    /// A field's value as one short piece of text: strings, numbers,
    /// booleans and lists of them. Anything else is left out.
    private static func loggable(_ value: Any) -> String? {
        switch value {
        case let text as String:
            return String(text.prefix(80))
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        case let list as [Any]:
            let parts = list.compactMap(loggable)
            return parts.isEmpty ? nil : String(parts.joined(separator: ",").prefix(160))
        default:
            return nil
        }
    }

    public func generate(_ request: IntelligenceRequest) async throws -> IntelligenceReport {
        var environment = ProcessInfo.processInfo.environment
        // Finder launches have a minimal PATH. No login shell is needed.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        environment["PYTHONUNBUFFERED"] = "1"
        environment.removeValue(forKey: "CLAUDECODE")
        let output: Subprocess.Outcome
        do {
            output = try await Subprocess.run(executable: python.path, arguments: [script.path],
                environment: environment, workingDirectory: script.deletingLastPathComponent(),
                stdin: try IntelligenceJSON.encoder().encode(request), timeout: 900, maxOutputBytes: 4_000_000)
        } catch Subprocess.Failure.timedOut {
            throw IntelligenceBridgeError.failed("研究超时，已保留上次结果；稍后重试。")
        } catch {
            throw IntelligenceBridgeError.failed("情报运行环境启动失败，请检查 Python SDK 安装。")
        }
        // What the run marked worth keeping — failures, degradations, routing
        // it deliberately did not take — goes to the engine log, success or not.
        for line in Self.noticeLines(fromStderr: output.stderr) { Log.warn(line) }
        guard output.exitCode == 0 else {
            // Only expose the runner's deliberately sanitized error envelope, never raw stderr.
            struct RunnerError: Decodable { var error: String }
            let message = (try? JSONDecoder().decode(RunnerError.self, from: output.stdout))?.error
            throw IntelligenceBridgeError.failed(message ?? "Claude 研究失败（退出码 \(output.exitCode)）；已保留上次结果。")
        }
        guard let report = try? IntelligenceJSON.decoder().decode(IntelligenceReport.self, from: output.stdout),
              report.kind == request.kind,
              abs(report.generatedAt.timeIntervalSince(request.now)) <= 900 else {
            throw IntelligenceBridgeError.failed("模型结果格式或时间无效，未覆盖上次结果。")
        }
        guard report.model == request.model else {
            throw IntelligenceBridgeError.failed("报告模型与本次请求不一致或未提供模型来源，未覆盖上次结果。")
        }
        return report
    }
}

public enum IntelligenceBridgeError: LocalizedError {
    case failed(String)
    public var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
