import Foundation

public struct IntelligenceQuote: Codable, Sendable {
    public var instId: String
    public var price: Double
    public var change24h: Double?
    public var asOf: Date
    public init(ticker: Ticker) {
        instId = ticker.instId
        price = ticker.last
        // A stock's change is against the previous close, not 24 hours ago.
        change24h = ticker.basis == .rolling24h ? ticker.changePct : nil
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
    public var watchlist: [String]
    public var quotes: [IntelligenceQuote]
    public var knownEvents: [IntelligenceKnownEvent]

    public init(kind: IntelligenceKind, now: Date, settings: IntelligenceSettings,
                watchlist: [String], quotes: [IntelligenceQuote], knownEvents: [IntelligenceKnownEvent]) {
        self.kind = kind; self.now = now; timezone = settings.timezone
        horizonHours = settings.horizonHours; self.watchlist = watchlist
        self.quotes = quotes; self.knownEvents = knownEvents
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
                stdin: try IntelligenceJSON.encoder().encode(request), timeout: 600, maxOutputBytes: 4_000_000)
        } catch Subprocess.Failure.timedOut {
            throw IntelligenceBridgeError.failed("研究超时，已保留上次结果；稍后重试。")
        } catch {
            throw IntelligenceBridgeError.failed("情报运行环境启动失败，请检查 Python SDK 安装。")
        }
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
