import Foundation
import Testing
@testable import MayStockKit

/// Answers requests for one made-up host with whatever its test scripted, in
/// order, and counts them. Routed by host so tests running side by side never
/// read each other's script.
final class ScriptedHTTP: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var served: [String: [String]] = [:]

    /// A client whose every request is answered from `replies`.
    static func client(_ replies: [Reply]) -> (OKXRESTClient, host: String) {
        let host = "okx-\(UUID().uuidString.lowercased()).test"
        lock.withLock { scripts[host] = replies; served[host] = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedHTTP.self]
        let client = OKXRESTClient(
            baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration))
        return (client, host)
    }

    /// The paths requested so far, in order.
    static func paths(for host: String) -> [String] { lock.withLock { served[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { request.url?.host.map { scripts[$0] != nil } ?? false }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let reply: Reply = Self.lock.withLock {
            let host = url.host!
            Self.served[host, default: []].append(url.path)
            guard var queue = Self.scripts[host], !queue.isEmpty else {
                return Reply(status: 200, body: #"{"code":"0","msg":"","data":[]}"#)
            }
            let next = queue.removeFirst()
            Self.scripts[host] = queue
            return next
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A page of `count` hourly candles ending at `newest` (ms), newest first.
    static func candlePage(count: Int, newest: Int64) -> Reply {
        let rows = (0..<count).map { offset -> String in
            let ts = newest - Int64(offset) * 3_600_000
            return #"["\#(ts)","100","101","99","100.5","10","1000","1000","1"]"#
        }
        return Reply(status: 200, body: #"{"code":"0","msg":"","data":[\#(rows.joined(separator: ","))]}"#)
    }
}

@Suite("Long history downloads")
struct HistoryDownloadTests {

    /// A rate limit in the middle of a download is waited out, not fatal: the
    /// download used to be one failed page away from failing the backtest.
    @Test func aPageRefusedForRateIsAskedAgain() async throws {
        let (client, host) = ScriptedHTTP.client([
            .init(status: 429, body: "{}"),
            ScriptedHTTP.candlePage(count: 50, newest: 1_800_000_000_000),
        ])
        let candles = try await client.historyCandles(instId: "BTC-USDT-SWAP", bar: .h1, target: 50)
        #expect(candles.count == 50)
        #expect(ScriptedHTTP.paths(for: host).prefix(2) == ["/api/v5/market/candles", "/api/v5/market/candles"])
    }

    /// A refusal of the request itself is the same next time: not retried.
    @Test func aRefusedRequestIsNotAskedAgain() async throws {
        let (client, host) = ScriptedHTTP.client([
            .init(status: 200, body: #"{"code":"51001","msg":"Instrument ID does not exist","data":[]}"#),
        ])
        await #expect(throws: OKXError.self) {
            _ = try await client.historyCandles(instId: "NOPE-USDT", bar: .h1, target: 50)
        }
        #expect(ScriptedHTTP.paths(for: host).count == 1)
    }

    @Test func whatPassesIsWhatIsRetried() {
        for (error, transient) in [
            (OKXError.http(status: 429), true), (.http(status: 503), true), (.http(status: 400), false),
            (.api(code: "50011", message: "Too Many Requests"), true), (.api(code: "51001", message: ""), false),
            (.transport("timed out"), true), (.decoding("bad"), false),
        ] as [(OKXError, Bool)] {
            #expect(error.isTransient == transient, "\(error)")
        }
    }

    /// Reports running together on one market download its history once, and
    /// a shorter request is served from a longer download.
    @Test func reportsOnOneMarketShareOneDownload() async throws {
        let memo = BacktestHistoryMemo()
        let fetches = Counter()
        let bars = (0..<100).map { i in
            Candle(ts: Date(timeIntervalSince1970: Double(i) * 3_600), open: 1, high: 1, low: 1, close: Double(i), volume: 1, confirmed: true)
        }
        let fetch: @Sendable (@escaping @Sendable (Int) -> Void) async throws -> [Candle] = { progress in
            await fetches.increment()
            try await Task.sleep(for: .milliseconds(50))
            progress(bars.count)
            return bars
        }
        async let first = memo.candles(venue: .okx, instId: "BTC-USDT-SWAP", bar: .h1, target: 100, progress: nil, fetch: fetch)
        async let second = memo.candles(venue: .okx, instId: "BTC-USDT-SWAP", bar: .h1, target: 100, progress: nil, fetch: fetch)
        let (a, b) = try await (first, second)
        #expect(a == b && a.count == 100)
        let shorter = try await memo.candles(venue: .okx, instId: "BTC-USDT-SWAP", bar: .h1, target: 30, progress: nil, fetch: fetch)
        #expect(shorter.map(\.close) == Array(bars.suffix(30)).map(\.close))
        #expect(await fetches.value == 1)
        _ = try await memo.candles(venue: .okx, instId: "ETH-USDT-SWAP", bar: .h1, target: 100, progress: nil, fetch: fetch)
        #expect(await fetches.value == 2, "another market is another download")
    }

    /// OKX keeps about three months of funding; a longer perpetual backtest
    /// charges none before that, and the report says how much it missed.
    @Test func aFundingRecordThatStartsLateIsSaid() {
        let day = 86_400.0
        let candles = (0..<(100 * 24)).map { i in
            Candle(ts: Date(timeIntervalSince1970: Double(i) * 3_600), open: 1, high: 1, low: 1, close: 1, volume: 1, confirmed: true)
        }
        let late = (0..<30).map { FundingRate(ts: Date(timeIntervalSince1970: (70 + Double($0)) * day), rate: 0.0001) }
        let note = FundingCoverage.note(instType: .swap, candles: candles, warmup: 0, fundingRates: late)
        #expect(note?.contains("此前 70 天") == true, "\(note ?? "nil")")
        #expect(note?.contains("70%") == true, "\(note ?? "nil")")
        // Measured from the first bar that trades: ten warm-up days owe nothing.
        let afterWarmup = FundingCoverage.note(instType: .swap, candles: candles, warmup: 10 * 24, fundingRates: late)
        #expect(afterWarmup?.contains("此前 60 天") == true, "\(afterWarmup ?? "nil")")
        let whole = (0..<300).map { FundingRate(ts: Date(timeIntervalSince1970: Double($0) * 8 * 3_600), rate: 0.0001) }
        #expect(FundingCoverage.note(instType: .swap, candles: candles, warmup: 0, fundingRates: whole) == nil)
        #expect(FundingCoverage.note(instType: .spot, candles: candles, warmup: 0, fundingRates: []) == nil)
        #expect(FundingCoverage.note(instType: .swap, candles: candles, warmup: 0, fundingRates: [])?
            .contains("没有资金费率记录") == true)
    }

    /// Cutting a history to its newest bars cuts every aligned series with it.
    @Test func trimmingHistoryKeepsSeriesAligned() {
        let candles = (0..<10).map { i in
            Candle(ts: Date(timeIntervalSince1970: Double(i)), open: 1, high: 1, low: 1, close: Double(i), volume: 1, confirmed: true)
        }
        let history = BacktestHistory(candles: candles, series: ["x": (0..<10).map(Double.init)])
        let trimmed = history.suffix(4)
        #expect(trimmed.candles.map(\.close) == [6, 7, 8, 9])
        #expect(trimmed.series["x"] == [6, 7, 8, 9])
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
