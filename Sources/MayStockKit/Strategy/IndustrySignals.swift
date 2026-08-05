import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public, non-exchange data feeds that the wider market actually watches.
///
/// The OKX statistics endpoints cap out at 30–179 days, which is too short to
/// validate anything (see `docs/RESEARCH-SIGNALS.md`). The feeds here were
/// chosen on one criterion above all others: **years of free history, so a
/// signal can be tested rather than merely believed.**
///
/// | 来源 | 内容 | 起点 |
/// |------|------|------|
/// | alternative.me | Crypto Fear & Greed | 2018-02 |
/// | blockchain.info | Bitcoin network fundamentals | 2009-01 |
/// | FRED (St. Louis Fed) | DXY / S&P 500 / VIX / 10y | 1962–2016 |
/// | Coinbase | US spot price, for the Coinbase premium | 2015 |
///
/// None needs an API key, and none receives any account information — these are
/// plain public GETs for market research.
public enum IndustrySignalFeed: Sendable {
    case fearGreed
    case blockchainChart(String)
    case fred(String)
    case coinbasePremium
    case averageTransactionSize

    public var host: String {
        switch self {
        case .fearGreed: return "alternative.me"
        case .blockchainChart: return "blockchain.info"
        case .fred: return "fred.stlouisfed.org"
        case .coinbasePremium: return "coinbase.com / OKX"
        case .averageTransactionSize: return "blockchain.info"
        }
    }
}

/// Fetches the third-party feeds behind the industry-standard signal sources.
public struct IndustrySignalProvider: Sendable {
    private let session: URLSession
    public let okx: OKXRESTClient

    public init(okx: OKXRESTClient = OKXRESTClient()) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        self.okx = okx
    }

    public func fetch(_ feed: IndustrySignalFeed, days: Int) async throws -> [SeriesObservation] {
        switch feed {
        case .fearGreed:
            return try await fearGreed(days: days)
        case .blockchainChart(let chart):
            return try await blockchainChart(chart)
        case .fred(let seriesId):
            return try await fred(seriesId)
        case .coinbasePremium:
            return try await coinbasePremium(days: days)
        case .averageTransactionSize:
            return try await averageTransactionSize()
        }
    }

    // MARK: alternative.me — Fear & Greed

    private struct FearGreedEnvelope: Decodable {
        struct Row: Decodable {
            let value: String
            let timestamp: String
        }
        let data: [Row]
    }

    /// Daily 0–100 sentiment composite, published since 2018-02-01.
    private func fearGreed(days: Int) async throws -> [SeriesObservation] {
        // `limit=0` returns the entire history.
        let url = URL(string: "https://api.alternative.me/fng/?limit=0&format=json")!
        let data = try await get(url)
        let envelope = try JSONDecoder().decode(FearGreedEnvelope.self, from: data)
        return envelope.data.compactMap { row in
            guard let seconds = Double(row.timestamp), let value = Double(row.value) else { return nil }
            return SeriesObservation(ts: Date(timeIntervalSince1970: seconds), value: value)
        }
        .sorted { $0.ts < $1.ts }
    }

    // MARK: blockchain.info — network fundamentals

    private struct BlockchainChart: Decodable {
        struct Point: Decodable {
            let x: Double
            let y: Double
        }
        let values: [Point]
    }

    /// `sampled=false` is essential: the default thins the series to ~4-day
    /// spacing, which would silently turn a daily signal into a stale one.
    private func blockchainChart(_ chart: String) async throws -> [SeriesObservation] {
        let url = URL(string:
            "https://api.blockchain.info/charts/\(chart)?timespan=all&sampled=false&format=json")!
        let data = try await get(url)
        let payload = try JSONDecoder().decode(BlockchainChart.self, from: data)
        return payload.values
            .map { SeriesObservation(ts: Date(timeIntervalSince1970: $0.x), value: $0.y) }
            .sorted { $0.ts < $1.ts }
    }

    // MARK: FRED — macro

    /// The graph CSV endpoint needs no API key. Missing observations arrive as
    /// "." and are dropped, so weekends and holidays become gaps the aligner
    /// carries forward rather than zeros that would corrupt every indicator.
    private func fred(_ seriesId: String) async throws -> [SeriesObservation] {
        let url = URL(string: "https://fred.stlouisfed.org/graph/fredgraph.csv?id=\(seriesId)")!
        let data = try await get(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OKXError.decoding("FRED \(seriesId) 返回的不是文本")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")

        return text.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 2,
                  let date = formatter.date(from: String(parts[0])),
                  let value = Double(parts[1].trimmingCharacters(in: .whitespaces))
            else { return nil }
            return SeriesObservation(ts: date, value: value)
        }
        .sorted { $0.ts < $1.ts }
    }

    // MARK: Whale proxy

    /// Mean USD moved per on-chain transaction — total transfer value divided
    /// by transaction count, both from blockchain.info.
    ///
    /// This is the honest free stand-in for "what are the whales doing". A
    /// rising average means the same number of transfers is carrying more
    /// money, which is what large holders repositioning looks like from
    /// outside. It is a *proxy*: it cannot separate an exchange rebalancing its
    /// cold storage from a whale accumulating, and the metrics that can
    /// (exchange netflow, balances by cohort) are paywalled on every provider.
    private func averageTransactionSize() async throws -> [SeriesObservation] {
        async let volumeTask = blockchainChart("estimated-transaction-volume-usd")
        async let countTask = blockchainChart("n-transactions")
        let (volume, count) = try await (volumeTask, countTask)

        var countByDay: [Date: Double] = [:]
        for point in count { countByDay[Self.utcDay(point.ts)] = point.value }

        return volume.compactMap { point -> SeriesObservation? in
            guard let transactions = countByDay[Self.utcDay(point.ts)], transactions > 0
            else { return nil }
            return SeriesObservation(ts: point.ts, value: point.value / transactions)
        }
        .sorted { $0.ts < $1.ts }
    }

    // MARK: Coinbase premium

    private func coinbasePremium(days: Int) async throws -> [SeriesObservation] {
        async let coinbaseTask = coinbaseDailyCloses()
        async let okxTask = okx.historyCandles(
            instId: "BTC-USDT", bar: .d1, target: Swift.min(days + 30, 1_500))
        let (coinbase, okxCandles) = try await (coinbaseTask, okxTask)

        // Compare same-day closes; the spread is the premium US buyers pay.
        var okxByDay: [Date: Double] = [:]
        for candle in okxCandles { okxByDay[Self.utcDay(candle.ts)] = candle.close }

        return coinbase.compactMap { entry -> SeriesObservation? in
            guard let reference = okxByDay[Self.utcDay(entry.ts)], reference > 0 else { return nil }
            return SeriesObservation(ts: entry.ts, value: (entry.value / reference - 1) * 100)
        }
        .sorted { $0.ts < $1.ts }
    }

    /// Coinbase caps a candle request at 300 buckets, so a long history needs
    /// paging backwards through explicit start/end windows.
    private func coinbaseDailyCloses(pages: Int = 6) async throws -> [SeriesObservation] {
        var out: [SeriesObservation] = []
        var end = Date()
        let formatter = ISO8601DateFormatter()

        for _ in 0..<pages {
            let start = end.addingTimeInterval(-299 * 86_400)
            var components = URLComponents(
                string: "https://api.exchange.coinbase.com/products/BTC-USD/candles")!
            components.queryItems = [
                URLQueryItem(name: "granularity", value: "86400"),
                URLQueryItem(name: "start", value: formatter.string(from: start)),
                URLQueryItem(name: "end", value: formatter.string(from: end)),
            ]
            guard let url = components.url else { break }
            guard let data = try? await get(url),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[Double]],
                  !rows.isEmpty else { break }

            // [time, low, high, open, close, volume]
            for row in rows where row.count >= 5 {
                out.append(SeriesObservation(
                    ts: Date(timeIntervalSince1970: row[0]), value: row[4]))
            }
            end = start.addingTimeInterval(-86_400)
            try? await Task.sleep(nanoseconds: 250_000_000)   // be a good citizen
        }
        return out.sorted { $0.ts < $1.ts }
    }

    // MARK: Plumbing

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("MayStock/2.1 (strategy research)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // URLSession derives Accept-Language from the system locale, and
        // blockchain.info answers `400: Unknown language (zh-CN)` to anything it
        // does not recognise. Pinning English keeps these feeds working on a
        // non-English Mac — a failure that would otherwise only ever reproduce
        // on the user's machine, never on an English one.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")

        let data: Data, response: URLResponse
        do {
            #if canImport(FoundationNetworking)
            (data, response) = try await session.compatData(for: request)
            #else
            (data, response) = try await session.data(for: request)
            #endif
        } catch {
            throw OKXError.transport("\(url.host ?? "?"): \(error)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OKXError.transport("\(url.host ?? "?") HTTP \(http.statusCode)")
        }
        return data
    }

    static func utcDay(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400)
    }
}
