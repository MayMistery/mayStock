import Foundation
import Testing
@testable import MayStockKit

@Suite("Intelligence time and bridge contracts")
struct IntelligenceTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func quotePreservesRollingChangeAndOmitsPreviousCloseChange() throws {
        let marketTime = date("2026-09-04T20:00:00Z")
        let crypto = Ticker(instId: "BTC-USDT", last: 110, bid: nil, ask: nil,
                            reference: 100, high: 112, low: 98, volume: 1_000,
                            basis: .rolling24h, ts: marketTime)
        let stock = Ticker(instId: "TSLA", last: 110, bid: nil, ask: nil,
                           reference: 100, high: 112, low: 98, volume: 1_000,
                           basis: .previousClose, phase: .afterHours, ts: marketTime)
        let cryptoQuote = IntelligenceQuote(ticker: crypto)
        let stockQuote = IntelligenceQuote(ticker: stock)
        #expect(cryptoQuote.change24h == 10)
        #expect(stockQuote.change24h == nil)
        #expect(stockQuote.price == 110 && stockQuote.asOf == marketTime)
        let stockJSON = try #require(JSONSerialization.jsonObject(
            with: IntelligenceJSON.encoder().encode(stockQuote)) as? [String: Any])
        let cryptoJSON = try #require(JSONSerialization.jsonObject(
            with: IntelligenceJSON.encoder().encode(cryptoQuote)) as? [String: Any])
        #expect(stockJSON["change24h"] == nil, "previous-close change must not reach the model as 24h change")
        #expect(cryptoJSON["change24h"] as? Double == 10)
    }

    @Test func calendarIncludes38LocalDaysAcrossDST() {
        let days = IntelligenceSchedule.days(now: date("2026-03-08T16:00:00Z"), timezone: "America/New_York")
        #expect(days.count == 38)
        let calendar = IntelligenceSchedule.calendar(timezone: "America/New_York")
        #expect(days.allSatisfy { calendar.component(.hour, from: $0) == 0 })
        #expect(calendar.component(.day, from: days[7]) == 8)
        #expect(zip(days, days.dropFirst()).contains { $1.timeIntervalSince($0) == 23 * 3_600 })
    }

    @Test func dailyUsesSelectedZoneAndBootstraps() {
        let now = date("2026-09-08T00:05:00Z") // 08:05 Taipei
        let settings = IntelligenceSettings()
        #expect(IntelligenceSchedule.nextRun(kind: .daily, now: now, lastSuccess: nil, settings: settings) == now)
        #expect(IntelligenceSchedule.nextRun(kind: .daily, now: now,
            lastSuccess: date("2026-09-07T00:01:00Z"), settings: settings) == date("2026-09-08T00:00:00Z"))
        #expect(IntelligenceSchedule.nextRun(kind: .daily, now: now,
            lastSuccess: now, settings: settings) == date("2026-09-09T00:00:00Z"))
        #expect(IntelligenceSchedule.nextRun(kind: .daily, now: now,
            lastSuccess: date("2026-09-07T23:59:00Z"), settings: settings) == date("2026-09-08T00:00:00Z"))
    }

    @Test func intradayCadenceSurvivesRestartAndDoesNotStretchWindows() {
        let old = date("2026-09-08T00:00:00Z")
        let now = old.addingTimeInterval(5 * 3_600)
        let settings = IntelligenceSettings()
        #expect(IntelligenceSchedule.nextRun(kind: .flash, now: now, lastSuccess: old, settings: settings)
                == old.addingTimeInterval(1_800))
        #expect(IntelligenceSchedule.nextRun(kind: .hourly, now: now, lastSuccess: old, settings: settings)
                == old.addingTimeInterval(3_600))
        // Request.now is always now, not the missed scheduled time.
        let request = IntelligenceRequest(kind: .flash, now: now, settings: settings,
            watchlist: ["BTC-USDT", "ETH-USDT"], quotes: [], knownEvents: [])
        #expect(request.now == now)
        #expect(request.watchlist.count == 2)
    }

    @Test func pythonNumericDatesRoundTripWithoutAppleEpochShift() throws {
        let json = #"{"id":"r1","kind":"hourly","generatedAt":1788825600,"windowStart":1788822000,"windowEnd":1788825600,"title":"局势更新","summary":"","coverage":"partial","events":[{"id":"e1","title":"已发生事件","category":"geopolitics","importance":"high","status":"occurred","occurredAt":1788825540,"timePrecision":"minute","publishedAt":null,"summary":"","impact":"","sources":[{"title":"来源","url":"https://example.org/event","publisher":"Example","retrievedAt":1788825600,"evidence":"发生时间证据"}]}],"predictions":[{"instId":"ETH-USDT","direction":"insufficient","confidence":"low","horizonHours":24,"generatedAt":1788825600,"referencePrice":null,"drivers":[],"invalidation":"无行情","eventIds":[]}]}"#
        let decoded = try IntelligenceJSON.decoder().decode(IntelligenceReport.self, from: Data(json.utf8))
        #expect(decoded.generatedAt.timeIntervalSince1970 == 1_788_825_600)
        #expect(decoded.events[0].publishedAt == nil)
        #expect(decoded.predictions[0].referencePrice == nil)
        #expect(decoded.coverageComplete == nil) // Existing archives stay readable.
        #expect(decoded.model == nil) // A new setting must not invent old report provenance.
        #expect(decoded.analysis == nil && decoded.findings.isEmpty)
        #expect(decoded.predictions[0].findingIds == nil)
        let data = try IntelligenceJSON.encoder().encode(decoded)
        #expect(try IntelligenceJSON.decoder().decode(IntelligenceReport.self, from: data) == decoded)
        var partial = decoded
        partial.coverageComplete = false
        let updated = try IntelligenceJSON.encoder().encode(partial)
        #expect(try IntelligenceJSON.decoder().decode(IntelligenceReport.self, from: updated).coverageComplete == false)
    }
}

/// The runner's notices reach the engine log; its progress does not.
@Suite("Intelligence runner notices")
struct IntelligenceRunnerNoticeTests {
    @Test("每个 notice 阶段一行：次数和各字段的取值；info、非 JSON、对象字段都不进日志")
    func noticesBecomeOneLinePerStage() {
        let stderr = """
        Traceback-like noise that is not JSON
        {"stage":"fetch_start","level":"info","at":1,"host":"a.test"}
        {"stage":"fetch_failed","level":"notice","at":2,"host":"a.test"}
        {"stage":"fetch_failed","level":"notice","at":3,"host":"b.test"}
        {"stage":"fetch_failed","level":"notice","at":4,"host":"a.test"}
        {"stage":"model_failure","level":"notice","at":5,"code":"MODEL_RATE_LIMIT","apiStatus":429,"assistantError":null,"nested":{"secret":"SENTINEL"}}
        {"stage":"connection_environment_ignored","level":"notice","at":6,"source":"connection","ignoredEnvironmentKeys":["ANTHROPIC_BASE_URL","CLAUDECODE"],"isRelay":true}
        """
        let lines = IntelligenceBridge.noticeLines(fromStderr: Data(stderr.utf8))
        #expect(lines == [
            "intelligence: fetch_failed ×3 · host=a.test、b.test",
            "intelligence: model_failure · apiStatus=429 · code=MODEL_RATE_LIMIT",
            "intelligence: connection_environment_ignored · ignoredEnvironmentKeys=ANTHROPIC_BASE_URL,CLAUDECODE · isRelay=true · source=connection",
        ])
        #expect(!lines.joined().contains("SENTINEL"))
        #expect(IntelligenceBridge.noticeLines(fromStderr: Data()).isEmpty)
    }
}

/// The connection file is changed only through the runtime's own check, and
/// never loses what the page does not edit.
@Suite("Intelligence connection file")
struct IntelligenceConnectionFileTests {
    /// A stand-in runtime: `--doctor` rejects a candidate containing "reject",
    /// and reports the route source the way the runtime does.
    private func fixture() throws -> (dir: URL, bridge: IntelligenceBridge, file: IntelligenceConnectionFile) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maystock-connection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("runner.sh")
        try """
        case "$1" in
          --doctor)
            f="$MAYSTOCK_INTELLIGENCE_CONNECTION"
            if [ -n "$f" ] && grep -q reject "$f"; then echo '{"error":"CONNECTION_CONFIG: rejected for the test"}'; exit 1; fi
            if [ -n "$f" ]; then src=connection; else src=native; fi
            echo "{\\"source\\":\\"$src\\",\\"origin\\":null,\\"headerNames\\":[],\\"ignoredEnvironmentKeys\\":[],\\"routingConfigured\\":false}" ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        let bridge = IntelligenceBridge(python: URL(fileURLWithPath: "/bin/sh"), script: script)
        let file = IntelligenceConnectionFile(url: dir.appendingPathComponent("Intelligence/connection.json"))
        return (dir, bridge, file)
    }

    private func write(_ object: [String: Any], to file: IntelligenceConnectionFile) throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: file.url)
    }

    @Test("改一项：别的键原样保留（含非字符串值），权限 0600，路由按运行环境的回答")
    func updateKeepsEverythingElse() async throws {
        let (dir, bridge, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(["ANTHROPIC_AUTH_TOKEN": "keep-me", "nested": ["a": 1], "ANTHROPIC_BASE_URL": "https://old.test"], to: file)
        let route = try await file.update(baseURL: " https://new.test ", headers: nil, using: bridge)
        #expect(route.source == "connection")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        #expect(object["ANTHROPIC_BASE_URL"] as? String == "https://new.test")
        #expect(object["ANTHROPIC_AUTH_TOKEN"] as? String == "keep-me")
        #expect((object["nested"] as? [String: Any])?["a"] as? Int == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("运行环境拒绝的候选不替换原文件，也不留下候选文件")
    func aRejectedCandidateLeavesTheFileAsItWas() async throws {
        let (dir, bridge, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(["ANTHROPIC_BASE_URL": "https://old.test"], to: file)
        let before = try Data(contentsOf: file.url)
        await #expect(throws: IntelligenceBridgeError.self) {
            _ = try await file.update(baseURL: "https://reject.test", headers: nil, using: bridge)
        }
        #expect(try Data(contentsOf: file.url) == before)
        let left = try FileManager.default.contentsOfDirectory(atPath: file.url.deletingLastPathComponent().path)
        #expect(left == ["connection.json"])
    }

    @Test("两项都清空就移除文件，不写成 {}；空串只删那一项")
    func emptyingRemovesTheFile() async throws {
        let (dir, bridge, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(["ANTHROPIC_BASE_URL": "https://old.test", "ANTHROPIC_CUSTOM_HEADERS": "x-relay-api-key: abc"], to: file)
        _ = try await file.update(baseURL: "", headers: nil, using: bridge)
        #expect(try file.route().baseURL == nil && file.route().headers == "x-relay-api-key: abc")
        let route = try await file.update(baseURL: nil, headers: "", using: bridge)
        #expect(!file.exists, "an empty route file would mean the native login")
        #expect(route.source == "native")
    }

    @Test("掩码只留长值的末四位；没有冒号的行整行遮住")
    func maskedHeadersRevealNothingShort() {
        let masked = IntelligenceConnectionFile.maskedHeaders("x-relay-passthrough: anthropic\nx-relay-api-key: sk-0123456789abcd\nnot-a-header-line-secret")
        #expect(masked == "x-relay-passthrough: ••••opic\nx-relay-api-key: ••••abcd\n••••")
        #expect(IntelligenceConnectionFile.maskedHeaders("k: short") == "k: ••••")
    }
}
