import Foundation
import MayStockKit

/// Always logged out, whatever `schwabctl` holds: the US-equity fallback run
/// on purpose rather than only on the day the login lapses.
private struct AlwaysLoggedOut: SchwabTokenSource {
    func accessToken() async throws -> String { throw SchwabAPIError.loggedOut("e2e 强制走 Yahoo 兜底") }
    func invalidate() async {}
    func status() async -> SchwabCredentialStatus? { nil }
}

extension E2EMain {
    /// The watchlist's market data, live, through what the app builds.
    ///
    /// 1. A mixed watchlist through `MarketHub.standard()` — the app's hub,
    ///    feeds and sources: a ticker arrives for every symbol; the venue's
    ///    source as the feed reports it; the session's phase; inside a
    ///    trading phase, how old the quote is; any row issue.
    /// 2. Every bar each venue supports backfills from its source.
    /// 3. The US-equity fallback forced with a token source that is always
    ///    logged out: Yahoo's quotes, candles, search and live feed, whatever
    ///    state the Schwab login is in.
    ///
    /// Symbols name their venue by spelling — an OKX pair carries `-USD` —
    /// or explicitly as `okx:ID` / `schwab:ID`.
    @MainActor
    static func marketsDoctor(seconds: Int, symbols requested: [String]) async -> Bool {
        let symbols = requested.isEmpty ? ["BTC-USDT", "ETH-USDT-SWAP", "MU", "QQQ", "BRK.B"] : requested
        let items = symbols.map { raw -> WatchItem in
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            let venue = parts.count == 2
                ? (Venue(rawValue: parts[0].lowercased()) ?? .schwab)
                : (raw.uppercased().contains("-USD") ? Venue.okx : Venue.schwab)
            return WatchItem(venue: venue, instId: venue.canonicalInstId(parts.last ?? raw))
        }
        print("MayStock E2E markets · \(items.map { "\($0.venue.rawValue):\($0.instId)" }.joined(separator: " ")) · \(Date())")
        var allOK = true

        // 1. Live, through the app's hub.
        let hub = MarketHub.standard()
        hub.setWatchlist(items)
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline, items.contains(where: { hub.session(for: $0.instId)?.ticker == nil }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        // A few more seconds, so a poll after the first can report trouble.
        try? await Task.sleep(for: .seconds(4))
        for item in items {
            guard let session = hub.session(for: item.instId) else {
                fail("\(item.instId)", "没有会话"); allOK = false; continue
            }
            let source = hub.sourceName(for: item.venue)
            guard let ticker = session.ticker else {
                fail("\(item.instId) 报价", "\(seconds) 秒内没有报价 · \(source)"
                     + (session.issue.map { " · \($0)" } ?? "")); allOK = false
                continue
            }
            let phase = session.marketPhase
            let age = Date().timeIntervalSince(ticker.ts)
            var detail = "\(PriceFormatter.auto(ticker.last)) · \(source)"
            detail += phase.map { " · \($0.displayName)" } ?? ""
            detail += " · 报价时间 \(Int(age)) 秒前"
            let trading = phase.map(\.isTrading) ?? true
            // A trading quote older than this is not live: 15 minutes is
            // what an exchange's delayed feed looks like.
            let limit: TimeInterval = item.venue.tradesContinuously ? 30 : 120
            if let issue = session.issue {
                fail("\(item.instId) 报价", detail + " · 行上有问题：\(issue)"); allOK = false
            } else if trading, age > limit {
                fail("\(item.instId) 报价", detail + " · 交易时段内报价超过 \(Int(limit)) 秒"); allOK = false
            } else {
                pass("\(item.instId) 报价", detail)
            }
        }
        hub.setWatchlist([])

        // 2. Every bar each venue supports, from its source.
        let sources = MarketDataSources()
        for item in items {
            let source = sources.source(for: item.venue)
            var missing: [String] = []
            for bar in item.venue.supportedBars {
                let candles = (try? await source.candles(instId: item.instId, bar: bar, target: 50)) ?? []
                if candles.isEmpty { missing.append(bar.rawValue) }
            }
            if missing.isEmpty {
                pass("\(item.instId) K 线", item.venue.supportedBars.map(\.rawValue).joined(separator: " "))
            } else {
                fail("\(item.instId) K 线", "回填为空：\(missing.joined(separator: " "))"); allOK = false
            }
        }

        // 3. The equity fallback, forced.
        let equities = items.filter { $0.venue == .schwab }.map(\.instId)
        if let first = equities.first {
            let fallback = SchwabMarketDataSource(
                schwab: SchwabRESTClient(tokens: AlwaysLoggedOut()), yahoo: sources.yahoo)
            do {
                let ticker = try await fallback.ticker(instId: first)
                pass("兜底报价 \(first)", "\(PriceFormatter.auto(ticker.last)) · 报价时间 \(Int(Date().timeIntervalSince(ticker.ts))) 秒前")
            } catch {
                fail("兜底报价 \(first)", String(describing: error)); allOK = false
            }
            let candles = (try? await fallback.candles(instId: first, bar: .m5, target: 50)) ?? []
            (candles.isEmpty ? fail : pass)("兜底 K 线 \(first)", "\(candles.count) 根 5m")
            if candles.isEmpty { allOK = false }
            let matches = (try? await fallback.search(first)) ?? []
            if matches.contains(where: { $0.instId == first }) {
                pass("兜底搜索 \(first)", matches.prefix(3).map(\.instId).joined(separator: " "))
            } else {
                fail("兜底搜索 \(first)", "结果里没有 \(first)：\(matches.prefix(5).map(\.instId))"); allOK = false
            }

            let feed = SchwabMarketFeed(schwab: SchwabRESTClient(tokens: AlwaysLoggedOut()), yahoo: sources.yahoo)
            let seen = SeenTickers()
            await feed.setHandler { event in
                switch event {
                case .ticker(let ticker): Task { await seen.add(ticker.instId) }
                case .source(let name): Task { await seen.note(name) }
                case .issue(let instId, let reason): Task { await seen.issue(instId, reason) }
                default: break
                }
            }
            for symbol in equities { await feed.subscribe(instId: symbol, bar: .m1) }
            let feedDeadline = Date().addingTimeInterval(TimeInterval(seconds))
            while Date() < feedDeadline, await seen.ids.count < equities.count {
                try? await Task.sleep(for: .milliseconds(250))
            }
            for symbol in equities { await feed.unsubscribe(instId: symbol, bar: .m1) }
            let ids = await seen.ids
            let issues = await seen.issues
            if Set(equities).isSubset(of: ids), issues.isEmpty {
                pass("兜底行情推送", "\(ids.sorted().joined(separator: " ")) · \(await seen.source ?? "—")")
            } else {
                fail("兜底行情推送", "收到 \(ids.sorted())，问题 \(issues)"); allOK = false
            }
        }

        print(allOK ? "PASS" : "FAIL")
        return allOK
    }
}

private actor SeenTickers {
    private(set) var ids: Set<String> = []
    private(set) var source: String?
    private(set) var issues: [String: String] = [:]
    func add(_ id: String) { ids.insert(id) }
    func note(_ name: String) { source = name }
    func issue(_ id: String, _ reason: String?) { issues[id] = reason }
}
