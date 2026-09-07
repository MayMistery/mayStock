import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin async client for OKX v5 public REST market data.
/// Rate-limit aware: candle backfill paginates with ≥120ms spacing
/// (limit is 20 requests / 2 seconds).
public struct OKXRESTClient: Sendable {
    public let baseURL: URL
    /// Read the demo environment's market data rather than the real market's.
    ///
    /// OKX serves both from the same host, told apart by a request header.
    /// The demo's spot and perpetual prices shadow the real ones, but its
    /// option books and marks are its own — a demo order priced from the real
    /// book can sit far outside the book it actually lands in.
    public let simulated: Bool
    private let session: URLSession

    public init(
        baseURL: URL = OKXEndpoints.rest, session: URLSession? = nil, simulated: Bool = false
    ) {
        self.baseURL = baseURL
        self.simulated = simulated
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Envelope

    private struct Envelope<Row: Decodable>: Decodable {
        let code: String
        let msg: String
        let data: [Row]
    }

    /// The request for one GET, carrying the environment header when this
    /// client reads the demo.
    func request(path: String, query: [String: String]) throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw OKXError.transport("bad url") }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if simulated {
            request.setValue("1", forHTTPHeaderField: "x-simulated-trading")
        }
        return request
    }

    private func get<Row: Decodable>(
        _ type: Row.Type, path: String, query: [String: String]
    ) async throws -> [Row] {
        let request = try request(path: path, query: query)

        let (data, response): (Data, URLResponse)
        do {
            #if canImport(FoundationNetworking)
            (data, response) = try await session.compatData(for: request)
            #else
            (data, response) = try await session.data(for: request)
            #endif
        } catch {
            throw OKXError.transport(String(describing: error))
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OKXError.transport("HTTP \(http.statusCode)")
        }
        let envelope: Envelope<Row>
        do {
            envelope = try JSONDecoder().decode(Envelope<Row>.self, from: data)
        } catch {
            throw OKXError.decoding(String(describing: error))
        }
        guard envelope.code == "0" else {
            throw OKXError.api(code: envelope.code, message: envelope.msg)
        }
        return envelope.data
    }

    /// Envelope-aware GET for callers outside this file (alternative data).
    public func getRaw<Row: Decodable>(
        _ type: Row.Type, path: String, query: [String: String]
    ) async throws -> [Row] {
        try await get(type, path: path, query: query)
    }

    // MARK: Market data

    private struct TickerRESTRow: Decodable {
        let instId: String
        let last: String
        let bidPx: String?
        let askPx: String?
        let open24h: String
        let high24h: String
        let low24h: String
        let vol24h: String
        let ts: String
    }

    public func ticker(instId: String) async throws -> Ticker {
        let rows = try await get(TickerRESTRow.self, path: "api/v5/market/ticker", query: ["instId": instId])
        guard let row = rows.first,
              let last = Double(row.last),
              let open = Double(row.open24h),
              let high = Double(row.high24h),
              let low = Double(row.low24h),
              let tsMs = Double(row.ts) else {
            throw OKXError.decoding("ticker")
        }
        return Ticker(
            instId: row.instId, last: last,
            bid: row.bidPx.flatMap(Double.init), ask: row.askPx.flatMap(Double.init),
            open24h: open, high24h: high, low24h: low,
            vol24h: Double(row.vol24h) ?? 0,
            ts: Date(timeIntervalSince1970: tsMs / 1000))
    }

    /// Backfill up to `target` candles (newest last), paginating the REST API
    /// with the `after` cursor. Safe under either 100- or 300-row page caps.
    public func candles(instId: String, bar: BarInterval, target: Int = 300) async throws -> [Candle] {
        var collected: [Candle] = []
        var after: String? = nil
        while collected.count < target {
            var query = ["instId": instId, "bar": bar.restBar, "limit": "100"]
            if let after { query["after"] = after }
            let rows = try await get([String].self, path: "api/v5/market/candles", query: query)
            let page = rows.compactMap(OKXWireDecoder.candle(fromRow:))
            guard !page.isEmpty else { break }
            collected.append(contentsOf: page)
            // Rows come newest-first; cursor is the oldest ts of this page.
            if let oldest = page.map(\.ts).min() {
                after = String(Int(oldest.timeIntervalSince1970 * 1000))
            }
            if page.count < 100 { break }
            try? await Task.sleep(nanoseconds: 120_000_000) // rate-limit spacing
        }
        return collected.sorted { $0.ts < $1.ts }
    }

    /// Deep history for backtesting: walks `/market/candles` and then
    /// `/market/history-candles` backwards until `target` rows are collected or
    /// the exchange runs out of data.
    ///
    /// `progress` reports rows gathered so far — a 365-day 1H window is ~88
    /// requests, which the caller should not present as a frozen UI.
    public func historyCandles(
        instId: String,
        bar: BarInterval,
        target: Int,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [Candle] {
        guard target > 0 else { return [] }
        var byTimestamp: [Date: Candle] = [:]
        var after: String? = nil
        var usingHistory = false
        // Generous ceiling: stops a bad cursor from looping forever while still
        // covering a year of 1H bars (~88 pages).
        let maxRequests = target / 50 + 40

        for _ in 0..<maxRequests {
            let path = usingHistory ? "api/v5/market/history-candles" : "api/v5/market/candles"
            var query = ["instId": instId, "bar": bar.restBar, "limit": usingHistory ? "100" : "300"]
            if let after { query["after"] = after }

            let rows = try await get([String].self, path: path, query: query)
            let page = rows.compactMap(OKXWireDecoder.candle(fromRow:))
            guard !page.isEmpty else {
                if usingHistory { break }
                usingHistory = true   // recent endpoint exhausted; go deeper
                continue
            }
            for candle in page { byTimestamp[candle.ts] = candle }
            progress?(byTimestamp.count)

            guard let oldest = page.map(\.ts).min() else { break }
            let cursor = String(Int(oldest.timeIntervalSince1970 * 1000))
            if cursor == after { break }   // no forward progress — stop
            after = cursor

            if byTimestamp.count >= target { break }
            if !usingHistory, page.count < 300 { usingHistory = true }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        let sorted = byTimestamp.values.sorted { $0.ts < $1.ts }
        return sorted.count > target ? Array(sorted.suffix(target)) : sorted
    }

    private struct FundingRateRow: Decodable {
        let fundingRate: String
        let fundingTime: String
    }

    /// Historical funding settlements for a perpetual swap, oldest first.
    /// Backtests of swap strategies charge these against open positions rather
    /// than assuming funding is free.
    public func fundingRateHistory(
        instId: String, since: Date, limit: Int = 1_000
    ) async throws -> [FundingRate] {
        var collected: [FundingRate] = []
        var after: String? = nil
        let maxRequests = limit / 100 + 2

        for _ in 0..<maxRequests {
            var query = ["instId": instId, "limit": "100"]
            if let after { query["after"] = after }
            let rows = try await get(FundingRateRow.self,
                                     path: "api/v5/public/funding-rate-history", query: query)
            guard !rows.isEmpty else { break }
            let page = rows.compactMap { row -> FundingRate? in
                guard let rate = Double(row.fundingRate), let ms = Double(row.fundingTime) else { return nil }
                return FundingRate(ts: Date(timeIntervalSince1970: ms / 1000), rate: rate)
            }
            collected.append(contentsOf: page)
            guard let oldest = page.map(\.ts).min() else { break }
            if oldest <= since || collected.count >= limit { break }
            let cursor = String(Int(oldest.timeIntervalSince1970 * 1000))
            if cursor == after { break }
            after = cursor
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return collected.filter { $0.ts >= since }.sorted { $0.ts < $1.ts }
    }

    private struct BookRESTRow: Decodable {
        let asks: [[String]]
        let bids: [[String]]
        let ts: String
    }

    /// Order book snapshot, up to 400 levels per side. Used by the depth chart.
    public func books(instId: String, depth: Int = 50) async throws -> OrderBook {
        let rows = try await get(BookRESTRow.self, path: "api/v5/market/books",
                                 query: ["instId": instId, "sz": String(depth)])
        guard let row = rows.first else { throw OKXError.decoding("books empty") }
        func levels(_ raw: [[String]]) -> [BookLevel] {
            raw.compactMap { entry in
                guard entry.count >= 2,
                      let price = Double(entry[0]), let size = Double(entry[1]) else { return nil }
                return BookLevel(price: price, size: size)
            }
        }
        return OrderBook(
            instId: instId, bids: levels(row.bids), asks: levels(row.asks),
            ts: Date(timeIntervalSince1970: (Double(row.ts) ?? 0) / 1000))
    }

    private struct InstrumentRow: Decodable {
        let instId: String
        let tickSz: String
        let lotSz: String
        let minSz: String
        let ctVal: String?
        let ctMult: String?
        let uly: String?
        let optType: String?
        let stk: String?
        let expTime: String?
        let settleCcy: String?
        let state: String?

        var meta: InstrumentMeta {
            InstrumentMeta(
                instId: instId,
                tickSize: Double(tickSz) ?? 0.01,
                lotSize: Double(lotSz) ?? 0,
                minSize: Double(minSz) ?? 0,
                contractValue: InstrumentMeta.contractValue(
                    ctVal: ctVal.flatMap(Double.init), ctMult: ctMult.flatMap(Double.init)))
        }

        /// The row as an option contract, or nil for any row that is not one.
        var contract: OptionContract? {
            guard let uly, !uly.isEmpty,
                  let kind = optType.flatMap({ $0 == "C" ? OptionKind.call : $0 == "P" ? .put : nil }),
                  let strike = stk.flatMap(Double.init), strike > 0,
                  let expiryMs = expTime.flatMap(Double.init),
                  let value = meta.contractValue else { return nil }
            return OptionContract(
                instId: instId, underlying: uly, kind: kind, strike: strike,
                expiry: Date(timeIntervalSince1970: expiryMs / 1000),
                contractValue: value,
                tickSize: Double(tickSz) ?? 0.0001,
                lotSize: Double(lotSz) ?? 1,
                minSize: Double(minSz) ?? 1,
                settleCurrency: settleCcy ?? Venue.okx.currencies(of: uly).base)
        }
    }

    /// Instrument metadata (tick size → price decimals). Also serves as
    /// validation when the user adds a new instrument.
    public func instrumentMeta(instId: String) async throws -> InstrumentMeta? {
        let instType = Venue.okx.instrumentType(of: instId)
        var query = ["instType": instType.rawValue, "instId": instId]
        // The instruments endpoint refuses an option lookup without its
        // underlying, even when the id is given in full.
        if let underlying = Venue.okx.optionUnderlying(of: instId) {
            query["uly"] = underlying
        }
        let rows = try await get(InstrumentRow.self, path: "api/v5/public/instruments", query: query)
        return rows.first?.meta
    }

    // MARK: Options

    /// Every live option on an underlying index, e.g. `BTC-USD`.
    public func optionChain(underlying: String) async throws -> [OptionContract] {
        let rows = try await get(
            InstrumentRow.self, path: "api/v5/public/instruments",
            query: ["instType": InstrumentType.option.rawValue, "uly": underlying])
        return rows
            .filter { ($0.state ?? "live") == "live" }
            .compactMap(\.contract)
    }

    private struct MarkPriceRow: Decodable {
        let instId: String
        let markPx: String
    }

    /// The exchange's mark for a derivative, in the unit it quotes the
    /// instrument in — the settlement coin for an option.
    public func markPrice(instId: String) async throws -> Double {
        let rows = try await get(
            MarkPriceRow.self, path: "api/v5/public/mark-price",
            query: ["instType": Venue.okx.instrumentType(of: instId).rawValue, "instId": instId])
        guard let row = rows.first, let mark = Double(row.markPx) else {
            throw OKXError.decoding("mark-price \(instId)")
        }
        return mark
    }

    private struct IndexTickerRow: Decodable {
        let instId: String
        let idxPx: String
    }

    /// The index an option settles against, e.g. `BTC-USD`.
    public func indexPrice(underlying: String) async throws -> Double {
        let rows = try await get(
            IndexTickerRow.self, path: "api/v5/market/index-tickers", query: ["instId": underlying])
        guard let row = rows.first, let price = Double(row.idxPx), price > 0 else {
            throw OKXError.decoding("index-tickers \(underlying)")
        }
        return price
    }

    /// The top of an option's book, decoded on its own terms.
    ///
    /// A contract that has never traded reports an empty `last`, and the
    /// general ticker decoder rightly refuses a ticker without one. An option
    /// order needs the bid and the ask, and either side may be empty too —
    /// reported as nil, not zero, because a zero would read as "free" to the
    /// sizing arithmetic downstream.
    struct OptionTickerRow: Decodable {
        let instId: String
        let bidPx: String?
        let askPx: String?
        let ts: String?

        var bid: Double? { bidPx.flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } }
        var ask: Double? { askPx.flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } }
        var time: Date { Date(timeIntervalSince1970: (ts.flatMap(Double.init) ?? 0) / 1000) }
    }

    /// Book, mark and index for one option, read together.
    public func optionQuote(instId: String) async throws -> OptionQuote {
        guard let underlying = Venue.okx.optionUnderlying(of: instId) else {
            throw OKXError.decoding("\(instId) 不是期权合约")
        }
        async let book = get(OptionTickerRow.self, path: "api/v5/market/ticker", query: ["instId": instId])
        async let mark = self.markPrice(instId: instId)
        async let index = self.indexPrice(underlying: underlying)
        let (rows, markPx, indexPx) = try await (book, mark, index)
        guard let top = rows.first else { throw OKXError.decoding("ticker \(instId)") }
        return OptionQuote(
            instId: instId,
            bid: top.bid,
            ask: top.ask,
            mark: markPx > 0 ? markPx : nil,
            indexPrice: indexPx,
            ts: top.time)
    }
}

#if canImport(FoundationNetworking)
// swift-corelibs-foundation lacks the async `data(for:)` overload on some
// versions; provide it via the completion-handler API (distinct name so it
// can't collide with newer toolchains that do ship the async overload).
extension URLSession {
    func compatData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: OKXError.transport("empty response"))
                }
            }
            task.resume()
        }
    }
}
#endif
