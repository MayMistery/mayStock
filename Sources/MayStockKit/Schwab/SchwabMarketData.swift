import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Token source

/// Where a Schwab access token comes from.
///
/// In the app it is `schwabctl token`; inside `schwabctl` it is the keychain.
/// Either way the thing on the other side of this protocol is the only thing
/// that can mint one, and the client never learns how.
public protocol SchwabTokenSource: Sendable {
    /// A token good for at least a couple of minutes, or `.loggedOut`.
    func accessToken() async throws -> String
    /// The last token was refused; forget it so the next call asks again.
    func invalidate() async
    /// The login's state, for the account page. Nil when the source has no
    /// way to say — a static token inside `schwabctl` has none.
    func status() async -> SchwabCredentialStatus?
}

/// A token handed in whole — what `schwabctl` uses once it has refreshed.
public struct SchwabStaticToken: SchwabTokenSource {
    public let token: String

    public init(_ token: String) { self.token = token }

    public func accessToken() async throws -> String { token }
    public func invalidate() async {}
    public func status() async -> SchwabCredentialStatus? { nil }
}

// MARK: - REST client

/// Every Schwab endpoint the app and `schwabctl` call, behind one token
/// source. A 401 is retried exactly once after asking the source for a
/// fresh token; a second refusal is reported as such.
public actor SchwabRESTClient {
    public nonisolated let venue = Venue.schwab
    private let tokens: any SchwabTokenSource
    private let http: SchwabHTTP
    /// Session hours by New York day, read once per day.
    private var hoursByDay: [String: USSessionHours] = [:]

    public init(tokens: any SchwabTokenSource, http: SchwabHTTP = SchwabHTTP()) {
        self.tokens = tokens
        self.http = http
    }

    public nonisolated var tokenSource: any SchwabTokenSource { tokens }

    // MARK: Transport

    /// GET with the current token, retrying once on a refused token.
    public func get(_ url: URL) async throws -> Data {
        try await send("GET", url, body: nil).data
    }

    public func send(_ method: String, _ url: URL, body: Data?) async throws -> (data: Data, response: HTTPURLResponse) {
        let token = try await tokens.accessToken()
        do {
            return try await http.send(method, url, token: token, body: body)
        } catch SchwabAPIError.unauthorised {
            await tokens.invalidate()
            let fresh = try await tokens.accessToken()
            return try await http.send(method, url, token: fresh, body: body)
        }
    }

    // MARK: Market data

    public func quotes(_ symbols: [String], now: Date = Date()) async throws -> [String: Ticker] {
        guard !symbols.isEmpty else { return [:] }
        let hours = try? await sessionHours(on: now)
        let data = try await get(SchwabAPI.quotes(symbols: symbols))
        return try SchwabWire.tickers(from: data, hours: hours, now: now)
    }

    /// Candles in `[start, end]`, oldest first. Regular session only, which
    /// is what the kernel calendar counts.
    public func candles(symbol: String, bar: BarInterval, start: Date, end: Date, now: Date = Date()) async throws -> [Candle] {
        guard let url = SchwabAPI.priceHistory(symbol: symbol, bar: bar, start: start, end: end) else {
            throw SchwabAPIError.unsupported("\(bar.rawValue) K 线")
        }
        let data = try await get(url)
        return try SchwabWire.candles(from: data, symbol: symbol, bar: bar, now: now)
    }

    /// The sessions of the New York day `date` falls on.
    public func sessionHours(on date: Date) async throws -> USSessionHours {
        let day = SchwabAPI.newYorkDay(date)
        if let cached = hoursByDay[day] { return cached }
        let data = try await get(SchwabAPI.marketHours(date: day))
        let hours = try SchwabWire.sessionHours(from: data, day: day)
        hoursByDay[day] = hours
        return hours
    }

    /// Symbols starting with the query, plus names containing it.
    ///
    /// Schwab answers "nothing matches" with an empty list, so every error is
    /// a failure and is thrown. It used to be swallowed into "no results",
    /// and that hid the one error the source falls back on: logged out, the
    /// watchlist said a US symbol did not exist instead of asking Yahoo.
    public func search(_ query: String) async throws -> [InstrumentMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let upper = trimmed.uppercased()
        var matches: [InstrumentMatch] = []
        let bySymbol = try await get(SchwabAPI.instruments(NSRegularExpression.escapedPattern(for: upper) + ".*", projection: .symbolRegex))
        matches += try SchwabWire.matches(from: bySymbol)
        if matches.count < 8, trimmed.count >= 2 {
            let byName = try await get(SchwabAPI.instruments(trimmed, projection: .descriptionSearch))
            matches += try SchwabWire.matches(from: byName)
        }
        var seen: Set<String> = []
        return matches.filter { seen.insert($0.instId).inserted }
            .sorted { lhs, rhs in
                let lhsExact = lhs.instId == upper, rhsExact = rhs.instId == upper
                if lhsExact != rhsExact { return lhsExact }
                return lhs.instId.count == rhs.instId.count ? lhs.instId < rhs.instId : lhs.instId.count < rhs.instId.count
            }
    }

    // MARK: Accounts and orders

    public func accountNumbers() async throws -> (raw: Data, refs: [SchwabAccountRef]) {
        let data = try await get(SchwabAPI.accountNumbers)
        return (data, try SchwabWire.accountNumbers(from: data))
    }

    public func account(hash: String) async throws -> (raw: Data, account: SchwabAccount) {
        let data = try await get(SchwabAPI.account(hash: hash))
        return (data, try SchwabWire.account(from: data))
    }

    public func orders(hash: String, from: Date, to: Date, status: String? = nil) async throws -> (raw: Data, orders: [SchwabOrder]) {
        let data = try await get(SchwabAPI.orders(hash: hash, from: from, to: to, status: status))
        return (data, try SchwabWire.orders(from: data))
    }

    public func order(hash: String, id: String) async throws -> (raw: Data, order: SchwabOrder) {
        let data = try await get(SchwabAPI.order(hash: hash, id: id))
        return (data, try SchwabWire.order(from: data))
    }

    /// Place, and return the order id Schwab assigned. The body is empty on
    /// success; the id is in the `Location` header.
    public func placeOrder(hash: String, body: Data) async throws -> String {
        let (data, response) = try await send("POST", SchwabAPI.placeOrder(hash: hash), body: body)
        guard let id = SchwabWire.orderId(fromLocation: response.value(forHTTPHeaderField: "Location")) else {
            throw SchwabAPIError.decoding("下单响应没有 Location 头：\(String(data: data, encoding: .utf8) ?? "")")
        }
        return id
    }

    public func replaceOrder(hash: String, id: String, body: Data) async throws -> String {
        let (data, response) = try await send("PUT", SchwabAPI.order(hash: hash, id: id), body: body)
        guard let newId = SchwabWire.orderId(fromLocation: response.value(forHTTPHeaderField: "Location")) else {
            throw SchwabAPIError.decoding("改单响应没有 Location 头：\(String(data: data, encoding: .utf8) ?? "")")
        }
        return newId
    }

    public func cancelOrder(hash: String, id: String) async throws {
        _ = try await send("DELETE", SchwabAPI.order(hash: hash, id: id), body: nil)
    }

    public func transactions(hash: String, from: Date, to: Date, symbol: String? = nil) async throws -> (raw: Data, fills: [ExchangeFill]) {
        let data = try await get(SchwabAPI.transactions(hash: hash, from: from, to: to, symbol: symbol))
        return (data, try SchwabWire.fills(from: data))
    }
}

// MARK: - One-off source with fallback

/// The US-equity data source: Schwab's own feed when the login is good,
/// Yahoo's chart endpoint otherwise. The switch is logged each time it flips
/// so a chart drawn from the interim source is never mistaken for the
/// official one.
public struct SchwabMarketDataSource: MarketDataSource {
    public let venue = Venue.schwab
    public let schwab: SchwabRESTClient
    public let yahoo: YahooFinanceClient
    private let notice = FallbackNotice(label: "行情")

    public init(schwab: SchwabRESTClient, yahoo: YahooFinanceClient = YahooFinanceClient()) {
        self.schwab = schwab
        self.yahoo = yahoo
    }

    /// The days of history a Schwab call for `target` bars has to cover.
    /// Generous on purpose: a window that comes up short is trimmed, one
    /// that comes up empty means the retention limit, not the bar count.
    static func daysCovering(_ target: Int, bar: BarInterval) -> Int {
        let sessionsPerBar: Double
        switch bar {
        case .m1: sessionsPerBar = 1.0 / 390
        case .m5: sessionsPerBar = 1.0 / 78
        case .m15: sessionsPerBar = 1.0 / 26
        case .h1: sessionsPerBar = 1.0 / 7
        case .h4, .d1: sessionsPerBar = 1
        case .w1: sessionsPerBar = 5
        }
        let sessions = Double(target) * sessionsPerBar
        return Int((sessions * 7 / 5).rounded(.up)) + 5
    }

    public func ticker(instId: String) async throws -> Ticker {
        do {
            let tickers = try await schwab.quotes([instId])
            guard let ticker = tickers[instId] else { throw MarketDataError.unknownInstrument(instId) }
            await notice.recovered()
            return ticker
        } catch let error as SchwabAPIError where Self.fallsBack(error) {
            await notice.degraded(error)
            return try await yahoo.ticker(instId: instId)
        }
    }

    public func candles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle] {
        let now = Date()
        do {
            let days = Self.daysCovering(target, bar: bar)
            let candles = try await schwab.candles(
                symbol: instId, bar: bar, start: now.addingTimeInterval(-Double(days) * 86_400), end: now, now: now)
            await notice.recovered()
            return Array(candles.suffix(target))
        } catch let error as SchwabAPIError where Self.fallsBack(error) {
            await notice.degraded(error)
            return try await yahoo.candles(instId: instId, bar: bar, target: target)
        }
    }

    public func historyCandles(
        instId: String, bar: BarInterval, target: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> [Candle] {
        let now = Date()
        do {
            var gathered: [Candle] = []
            var end = now
            // Schwab serves months of minute bars in one call (a 60-day
            // one-minute request came back with 12,000 rows), so the windows
            // are wide; walking back window by window still finds the
            // retention edge, which is an empty window.
            let windowDays = bar.seconds >= BarInterval.d1.seconds ? 365 * 5 : 60
            for _ in 0..<200 {
                let start = end.addingTimeInterval(-Double(windowDays) * 86_400)
                let chunk = try await schwab.candles(symbol: instId, bar: bar, start: start, end: end, now: now)
                if chunk.isEmpty { break }
                gathered = chunk + gathered.filter { $0.ts > (chunk.last?.ts ?? .distantPast) }
                progress?(gathered.count)
                if gathered.count >= target { break }
                end = start
            }
            await notice.recovered()
            var deduped: [Candle] = []
            deduped.mergeCandles(gathered, cap: Int.max)
            return Array(deduped.suffix(target))
        } catch let error as SchwabAPIError where Self.fallsBack(error) {
            await notice.degraded(error)
            return try await yahoo.historyCandles(instId: instId, bar: bar, target: target, progress: progress)
        }
    }

    /// US equities trade in whole shares at a cent tick; the lookup is only
    /// whether the symbol exists.
    public func instrumentMeta(instId: String) async throws -> InstrumentMeta? {
        do {
            let tickers = try await schwab.quotes([instId])
            await notice.recovered()
            guard tickers[instId] != nil else { return nil }
            return Self.equityMeta(instId)
        } catch let error as SchwabAPIError where Self.fallsBack(error) {
            await notice.degraded(error)
            return try await yahoo.instrumentMeta(instId: instId)
        }
    }

    public static func equityMeta(_ instId: String) -> InstrumentMeta {
        InstrumentMeta(instId: instId, tickSize: 0.01, lotSize: 1, minSize: 1, contractValue: nil)
    }

    public func book(instId: String, depth: Int) async throws -> OrderBook? { nil }

    public func search(_ query: String) async throws -> [InstrumentMatch] {
        do {
            let matches = try await schwab.search(query)
            await notice.recovered()
            return matches
        } catch let error as SchwabAPIError where Self.fallsBack(error) {
            await notice.degraded(error)
            return try await yahoo.search(query)
        }
    }

    /// Only a missing login sends a read to Yahoo. A network error or a
    /// refusal from a valid session is Schwab's answer, and is reported.
    static func fallsBack(_ error: SchwabAPIError) -> Bool {
        if case .loggedOut = error { return true }
        return false
    }
}

/// Logs the flip between the official source and the interim one, once per
/// flip rather than once per read.
actor FallbackNotice {
    private let label: String
    private var degraded = false

    init(label: String) { self.label = label }

    func degraded(_ error: SchwabAPIError) {
        guard !degraded else { return }
        degraded = true
        Log.warn("schwab: \(label)改用 Yahoo Finance —— \(error)")
    }

    func recovered() {
        guard degraded else { return }
        degraded = false
        Log.warn("schwab: \(label)恢复为嘉信官方数据")
    }
}

// MARK: - Live feed

/// Live US-equity prices: Schwab's quotes endpoint polled in one batch for
/// every subscribed symbol, Yahoo per symbol while there is no login.
///
/// The cadence follows the session — every few seconds while any session is
/// open, once a minute when closed — and each backend switch is announced
/// as a `.source` event so the footer can say which prices these are.
public actor SchwabMarketFeed: MarketFeed {
    public nonisolated let venue = Venue.schwab
    private let schwab: SchwabRESTClient
    private let yahoo: YahooFinanceClient
    private var handler: (@Sendable (MarketFeedEvent) -> Void)?
    private var polls: [String: Poll] = [:]
    private var loop: Task<Void, Never>?
    private var state: FeedState = .idle
    /// Passes in a row that read no symbol at all — the feed's own health.
    /// One symbol failing while the others read is that symbol's problem
    /// (`Poll.failures`), and used to reset this count for everyone.
    private var failedPasses = 0
    private var source: Source?
    /// A symbol was subscribed since the current pass took its list.
    private var subscribedSincePass = false

    public static let tradingInterval: TimeInterval = 3
    public static let closedInterval: TimeInterval = 60
    static let candleRefresh: TimeInterval = 30
    static let degradeAfter = 3
    /// A symbol that keeps failing is logged on its first failure and every
    /// this-many after, so the log says it is still failing without a line
    /// every three seconds.
    static let relogEvery = 20

    public static let officialSourceName = "嘉信官方行情"
    public static let interimSourceName = "Yahoo Finance（嘉信未登录）"

    private enum Source { case schwab, yahoo }

    private struct Poll {
        var bar: BarInterval
        var lastCandleRefresh = Date.distantPast
        /// Reads in a row this symbol failed, and the reason last shown.
        var failures = 0
        var issue: String?
    }

    public init(schwab: SchwabRESTClient, yahoo: YahooFinanceClient = YahooFinanceClient()) {
        self.schwab = schwab
        self.yahoo = yahoo
    }

    public func setHandler(_ handler: @escaping @Sendable (MarketFeedEvent) -> Void) {
        self.handler = handler
    }

    public func subscribe(instId: String, bar: BarInterval) {
        guard polls[instId] == nil else { return }
        polls[instId] = Poll(bar: bar)
        subscribedSincePass = true
        if state == .idle { setState(.connecting) }
        if loop == nil {
            loop = Task { [weak self] in
                guard let self else { return }
                await self.run()
            }
        }
    }

    public func unsubscribe(instId: String, bar: BarInterval) {
        polls.removeValue(forKey: instId)
        if polls.isEmpty {
            loop?.cancel()
            loop = nil
            setState(.idle)
        }
    }

    public func switchBar(instId: String, from old: BarInterval, to new: BarInterval) {
        polls[instId]?.bar = new
        polls[instId]?.lastCandleRefresh = .distantPast
    }

    // MARK: Polling

    /// Read, then wait out the interval — unless a symbol is subscribed in
    /// the meantime, which is read at once. The first subscription starts the
    /// loop, and its first pass used to take only the symbols subscribed by
    /// then: the rest of a watchlist waited a whole interval, a minute while
    /// the market is closed (measured with `maystock-e2e markets`).
    private func run() async {
        while !Task.isCancelled, !polls.isEmpty {
            let interval = await readOnce()
            let wakeAt = Date().addingTimeInterval(interval)
            while Date() < wakeAt, !subscribedSincePass, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// One pass over every subscription; returns how long to wait.
    private func readOnce() async -> TimeInterval {
        let now = Date()
        subscribedSincePass = false
        let symbols = Array(polls.keys).sorted()
        guard !symbols.isEmpty else { return Self.closedInterval }
        var trading = false
        var read = 0
        do {
            let tickers = try await schwab.quotes(symbols, now: now)
            announce(.schwab)
            for symbol in symbols {
                guard let ticker = tickers[symbol] else {
                    noteFailure(symbol, reason: "嘉信没有给出这个代码的可用报价（缺价格或时间）")
                    continue
                }
                noteRead(symbol)
                read += 1
                handler?(.ticker(ticker))
                if ticker.phase?.isTrading ?? false { trading = true }
                await refreshCandles(symbol: symbol, trading: ticker.phase?.isTrading ?? false, now: now) { bar in
                    let days = SchwabMarketDataSource.daysCovering(3, bar: bar)
                    let candles = try await self.schwab.candles(
                        symbol: symbol, bar: bar, start: now.addingTimeInterval(-Double(days) * 86_400), end: now, now: now)
                    return Array(candles.suffix(3))
                }
            }
        } catch let error as SchwabAPIError where SchwabMarketDataSource.fallsBack(error) {
            announce(.yahoo)
            for symbol in symbols {
                do {
                    let chart = try await yahoo.chart(symbol: symbol, interval: "1m", period: .range("1d"), includePrePost: true)
                    guard let ticker = YahooWire.ticker(from: chart, now: now) else {
                        throw MarketDataError.decoding("\(symbol) 没有价格")
                    }
                    noteRead(symbol)
                    read += 1
                    handler?(.ticker(ticker))
                    let symbolTrading = ticker.phase?.isTrading ?? false
                    if symbolTrading { trading = true }
                    if polls[symbol]?.bar == .m1 {
                        let recent = YahooWire.candles(from: chart, bar: .m1, now: now).suffix(3)
                        if !recent.isEmpty { handler?(.candles(instId: symbol, bar: .m1, candles: Array(recent))) }
                    } else {
                        await refreshCandles(symbol: symbol, trading: symbolTrading, now: now) { bar in
                            try await self.yahoo.candles(instId: symbol, bar: bar, target: 3)
                        }
                    }
                } catch {
                    noteFailure(symbol, reason: String(describing: error))
                }
            }
        } catch {
            notePass(read: 0, error: error)
            return 10
        }
        notePass(read: read, error: nil)
        return trading ? Self.tradingInterval : Self.closedInterval
    }

    private func refreshCandles(
        symbol: String, trading: Bool, now: Date,
        read: (BarInterval) async throws -> [Candle]
    ) async {
        guard let poll = polls[symbol] else { return }
        let due = poll.lastCandleRefresh == .distantPast
            || (trading && now.timeIntervalSince(poll.lastCandleRefresh) >= Self.candleRefresh)
        guard due else { return }
        do {
            let recent = try await read(poll.bar)
            polls[symbol]?.lastCandleRefresh = now
            if !recent.isEmpty { handler?(.candles(instId: symbol, bar: poll.bar, candles: recent)) }
        } catch {
            Log.warn("schwab feed: \(symbol) \(poll.bar.rawValue) K 线刷新失败：\(error)")
        }
    }

    private func announce(_ new: Source) {
        guard new != source else { return }
        source = new
        let name = new == .schwab ? Self.officialSourceName : Self.interimSourceName
        Log.warn("schwab feed: 行情来源 → \(name)")
        handler?(.source(name))
    }

    /// The feed is up while any symbol reads; it degrades after passes in a
    /// row that read none.
    private func notePass(read: Int, error: Error?) {
        if read > 0 {
            failedPasses = 0
            setState(.connected)
            return
        }
        failedPasses += 1
        if failedPasses == Self.degradeAfter {
            Log.warn("schwab feed: 连续 \(failedPasses) 轮一个报价都没读到，行情降级：\(error.map { String(describing: $0) } ?? "每个代码都读取失败")")
            setState(.degraded)
        }
    }

    /// One symbol failed: said on its row (`.issue`), and in the log on the
    /// first failure and every `relogEvery` after.
    private func noteFailure(_ symbol: String, reason: String) {
        guard var poll = polls[symbol] else { return }
        poll.failures += 1
        if poll.failures == 1 || poll.failures % Self.relogEvery == 0 {
            Log.warn("schwab feed: \(symbol) 读不到报价\(poll.failures > 1 ? "（已连续 \(poll.failures) 次）" : "")：\(reason)")
        }
        if poll.issue != reason {
            poll.issue = reason
            handler?(.issue(instId: symbol, reason: reason))
        }
        polls[symbol] = poll
    }

    private func noteRead(_ symbol: String) {
        guard var poll = polls[symbol], poll.failures > 0 else { return }
        Log.warn("schwab feed: \(symbol) 恢复报价（此前连续 \(poll.failures) 次失败）")
        poll.failures = 0
        poll.issue = nil
        polls[symbol] = poll
        handler?(.issue(instId: symbol, reason: nil))
    }

    private func setState(_ new: FeedState) {
        guard new != state else { return }
        state = new
        handler?(.state(new))
    }
}
