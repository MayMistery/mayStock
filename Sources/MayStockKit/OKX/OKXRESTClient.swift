import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin async client for OKX v5 public REST market data.
/// Rate-limit aware: candle backfill paginates with ≥120ms spacing
/// (limit is 20 requests / 2 seconds).
public struct OKXRESTClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = OKXEndpoints.rest, session: URLSession? = nil) {
        self.baseURL = baseURL
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

    private func get<Row: Decodable>(
        _ type: Row.Type, path: String, query: [String: String]
    ) async throws -> [Row] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw OKXError.transport("bad url") }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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
    }

    /// Instrument metadata (tick size → price decimals). Also serves as
    /// validation when the user adds a new instrument.
    public func instrumentMeta(instId: String) async throws -> InstrumentMeta? {
        let instType = instId.hasSuffix("-SWAP") ? "SWAP" : "SPOT"
        let rows = try await get(InstrumentRow.self, path: "api/v5/public/instruments",
                                 query: ["instType": instType, "instId": instId])
        guard let row = rows.first else { return nil }
        return InstrumentMeta(
            instId: row.instId,
            tickSize: Double(row.tickSz) ?? 0.01,
            lotSize: Double(row.lotSz) ?? 0,
            minSize: Double(row.minSz) ?? 0,
            contractValue: row.ctVal.flatMap(Double.init))
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
