import Foundation
import Testing
@testable import MayStockKit

/// Serves Yahoo's chart endpoint for one made-up host: a chart for every
/// symbol except those listed as unknown, which get Yahoo's 404. Records the
/// paths asked for.
final class FakeYahoo: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var unknown: [String: Set<String>] = [:]
    nonisolated(unsafe) private static var asked: [String: [String]] = [:]

    static func client(unknown symbols: Set<String>) -> (YahooFinanceClient, host: String) {
        let host = "yahoo-\(UUID().uuidString.lowercased()).test"
        lock.withLock { unknown[host] = symbols; asked[host] = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeYahoo.self]
        let url = URL(string: "https://\(host)")!
        return (YahooFinanceClient(baseURL: url, searchURL: url, session: URLSession(configuration: configuration)), host)
    }

    static func paths(for host: String) -> [String] { lock.withLock { asked[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { request.url?.host.map { unknown[$0] != nil } ?? false }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let symbol = url.lastPathComponent
        let isUnknown: Bool = Self.lock.withLock {
            Self.asked[url.host!, default: []].append(url.path)
            return Self.unknown[url.host!]?.contains(symbol) ?? false
        }
        let now = Int(Date().timeIntervalSince1970)
        let body = isUnknown
            ? #"{"chart":{"result":null,"error":{"code":"Not Found","description":"No data found, symbol may be delisted"}}}"#
            : #"{"chart":{"result":[{"meta":{"symbol":"\#(symbol)","currency":"USD","exchangeName":"NMS","regularMarketPrice":100.0,"regularMarketTime":\#(now),"chartPreviousClose":99.0},"timestamp":[\#(now - 60)],"indicators":{"quote":[{"open":[99.5],"high":[100.5],"low":[99.0],"close":[100.0],"volume":[10]}]}}],"error":null}}"#
        let response = HTTPURLResponse(url: url, statusCode: isUnknown ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct LoggedOut: SchwabTokenSource {
    func accessToken() async throws -> String { throw SchwabAPIError.loggedOut("test") }
    func invalidate() async {}
    func status() async -> SchwabCredentialStatus? { nil }
}

private actor Events {
    private(set) var all: [MarketFeedEvent] = []
    func append(_ event: MarketFeedEvent) { all.append(event) }
}

@Suite("US equity feed: one symbol at a time")
struct EquityFeedIssueTests {

    /// One symbol that cannot be read while the others can is said on that
    /// symbol's row — and only there. The failure count used to be the
    /// feed's: any other symbol's success reset it, so the dead row logged
    /// nothing and said nothing. The class share is asked of Yahoo in its own
    /// spelling and comes back in the app's.
    @Test func aSymbolThatCannotBeReadIsSaidOnItsOwnRow() async throws {
        let (yahoo, host) = FakeYahoo.client(unknown: ["ZZZZ"])
        let feed = SchwabMarketFeed(schwab: SchwabRESTClient(tokens: LoggedOut()), yahoo: yahoo)
        let events = Events()
        await feed.setHandler { event in Task { await events.append(event) } }
        for symbol in ["AAPL", "BRK/B", "ZZZZ"] { await feed.subscribe(instId: symbol, bar: .m1) }

        var seen: [MarketFeedEvent] = []
        for _ in 0..<100 {
            seen = await events.all
            let issues = seen.compactMap { if case .issue(let id, _) = $0 { id } else { nil } }
            let quoted = Set(seen.compactMap { if case .ticker(let t) = $0 { t.instId } else { nil } })
            if !issues.isEmpty, quoted.isSuperset(of: ["AAPL", "BRK/B"]) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        for symbol in ["AAPL", "BRK/B", "ZZZZ"] { await feed.unsubscribe(instId: symbol, bar: .m1) }

        let issues = seen.compactMap { event -> (String, String?)? in
            if case .issue(let id, let reason) = event { (id, reason) } else { nil }
        }
        #expect(issues.map(\.0) == ["ZZZZ"], "\(issues)")
        #expect(issues.first?.1?.isEmpty == false)
        let quoted = Set(seen.compactMap { if case .ticker(let t) = $0 { t.instId } else { nil } })
        #expect(quoted == ["AAPL", "BRK/B"])
        #expect(FakeYahoo.paths(for: host).contains("/v8/finance/chart/BRK-B"))
        let states = seen.compactMap { if case .state(let s) = $0 { s } else { nil } }
        #expect(!states.contains(.degraded), "two of three symbols read: the feed is up")
    }

    /// A symbol subscribed while the feed waits out a closed market's minute
    /// is read at once, not at the next minute.
    @Test func aLaterSubscriptionIsReadWithoutWaitingOutTheInterval() async throws {
        let (yahoo, _) = FakeYahoo.client(unknown: [])
        let feed = SchwabMarketFeed(schwab: SchwabRESTClient(tokens: LoggedOut()), yahoo: yahoo)
        let events = Events()
        await feed.setHandler { event in Task { await events.append(event) } }
        let quoted = { () async -> Set<String> in
            Set(await events.all.compactMap { if case .ticker(let t) = $0 { t.instId } else { nil } })
        }
        await feed.subscribe(instId: "AAPL", bar: .m1)
        for _ in 0..<100 where await !quoted().contains("AAPL") { try await Task.sleep(for: .milliseconds(20)) }
        await feed.subscribe(instId: "MSFT", bar: .m1)
        let start = Date()
        for _ in 0..<150 where await !quoted().contains("MSFT") { try await Task.sleep(for: .milliseconds(20)) }
        await feed.unsubscribe(instId: "AAPL", bar: .m1)
        await feed.unsubscribe(instId: "MSFT", bar: .m1)
        #expect(await quoted() == ["AAPL", "MSFT"])
        #expect(Date().timeIntervalSince(start) < SchwabMarketFeed.tradingInterval,
                "read at once, not after the \(SchwabMarketFeed.closedInterval)-second closed-market wait")
    }

    /// One spelling per venue, from however a symbol arrives.
    @Test func aShareClassIsKeptInSchwabsSpelling() throws {
        for (typed, kept) in [("brk.b", "BRK/B"), ("BRK-B", "BRK/B"), ("BRK/B", "BRK/B"), ("bf.b", "BF/B"),
                              ("mu", "MU"), (" QQQ ", "QQQ"), ("ABCDEF.G", "ABCDEF.G")] {
            #expect(Venue.schwab.canonicalInstId(typed) == kept, "\(typed)")
        }
        #expect(Venue.okx.canonicalInstId("btc-usdt") == "BTC-USDT", "a pair is not a share class")
        #expect(Venue.okx.canonicalInstId("eth-usdt-swap") == "ETH-USDT-SWAP")
        #expect(YahooWire.yahooSymbol(for: "BRK/B") == "BRK-B")
        #expect(YahooWire.yahooSymbol(for: "MU") == "MU")
        #expect(YahooWire.instId(fromYahoo: "BRK-B") == "BRK/B")

        let manifest = try JSONDecoder().decode(StrategyMarket.self, from: Data(
            #"{"venue":"schwab","instId":"brk.b","instType":"STOCK","bar":"1D"}"#.utf8))
        #expect(manifest.instId == "BRK/B", "an imported manifest is held to the venue's spelling")
    }
}
