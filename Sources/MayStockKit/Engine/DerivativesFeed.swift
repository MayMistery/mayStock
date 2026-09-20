import Foundation

/// Positioning and macro readings that OKX does not publish: who is crowded on
/// which side of the perpetual, and whether the long end of the curve is
/// helping or hurting a high-beta asset.
///
/// Two deliberate choices, both learned the hard way:
///
/// 1. **Every reading carries the time it was observed.** A quote that is
///    fifteen minutes stale looks exactly like a live one, and acting on that
///    difference produced a confidently wrong call about whether the macro side
///    was participating in a move. Staleness has to be visible.
/// 2. **The long end is read through instruments that trade, not through
///    delayed yield indices.** `^TNX` and friends lag by a quarter of an hour;
///    TLT and the Treasury futures do not.
///
/// All endpoints here are public and unauthenticated.
public struct DerivativesFeed: Sendable {

    private nonisolated(unsafe) let session: URLSession
    private let binanceFutures: URL
    private let quoteBase: URL

    public init(
        binanceFutures: URL = URL(string: "https://fapi.binance.com")!,
        quoteBase: URL = URL(string: "https://query1.finance.yahoo.com")!,
        session: URLSession? = nil
    ) {
        self.binanceFutures = binanceFutures
        self.quoteBase = quoteBase
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 25
            self.session = URLSession(configuration: config)
        }
    }

    public enum FeedError: Error, CustomStringConvertible {
        case transport(String)
        case decoding(String)
        case empty(String)

        public var description: String {
            switch self {
            case .transport(let m): return "网络失败：\(m)"
            case .decoding(let m): return "解析失败：\(m)"
            case .empty(let m): return "没有数据：\(m)"
            }
        }
    }

    private func get<T: Decodable>(
        _ type: T.Type, base: URL, path: String, query: [String: String]
    ) async throws -> T {
        var components = URLComponents(
            url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw FeedError.transport("bad url \(path)") }
        var request = URLRequest(url: url)
        // Some of these hosts refuse a request with no user agent.
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw FeedError.transport(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FeedError.decoding("\(path): \(error)")
        }
    }

    // MARK: - Perpetual positioning

    /// Who is leaning which way, from four angles that disagree often enough to
    /// be worth reading together.
    public struct Positioning: Sendable, Equatable {
        /// Top 20% of accounts by margin balance, weighted by position size.
        public let topByPosition: Double?
        /// The same cohort, one vote per account.
        ///
        /// Kept separate from `topByPosition` on purpose: when the two diverge
        /// — 1.64 by size against 1.20 by head count — that gap says the larger
        /// positions sit on one side, which neither number shows alone.
        public let topByAccount: Double?
        /// Every account on the venue, one vote each.
        public let allAccounts: Double?
        /// Aggressor flow: taker buy volume over taker sell volume.
        public let takerBuySell: Double?
        public let observedAt: Date

        /// Ratios above 1 mean longs lead.
        public var longsLead: Bool { (topByPosition ?? 1) > 1 }
    }

    private struct RatioRow: Decodable {
        let longShortRatio: String?
        let buySellRatio: String?
        let timestamp: Double?
    }

    /// Latest positioning snapshot. Each leg is fetched independently so one
    /// failing endpoint leaves the rest readable.
    public func positioning(
        symbol: String = "ETHUSDT", period: String = "1h"
    ) async throws -> Positioning {
        func ratio(_ path: String, _ key: KeyPath<RatioRow, String?>) async -> Double? {
            let rows = try? await get(
                [RatioRow].self, base: binanceFutures, path: path,
                query: ["symbol": symbol, "period": period, "limit": "1"])
            guard let text = rows?.last?[keyPath: key], let value = Double(text),
                  value.isFinite else { return nil }
            return value
        }
        async let byPosition = ratio("futures/data/topLongShortPositionRatio", \.longShortRatio)
        async let byAccount = ratio("futures/data/topLongShortAccountRatio", \.longShortRatio)
        async let all = ratio("futures/data/globalLongShortAccountRatio", \.longShortRatio)
        async let taker = ratio("futures/data/takerlongshortRatio", \.buySellRatio)

        let snapshot = Positioning(
            topByPosition: await byPosition, topByAccount: await byAccount,
            allAccounts: await all, takerBuySell: await taker, observedAt: Date())
        guard snapshot.topByPosition != nil || snapshot.topByAccount != nil
                || snapshot.allAccounts != nil || snapshot.takerBuySell != nil
        else { throw FeedError.empty("positioning \(symbol)") }
        return snapshot
    }

    /// Open interest over time, oldest first, for reading the trend rather than
    /// the level: rising OI into a rally is fresh money, falling OI is an
    /// unwind, and the difference decides whether a move has fuel.
    public struct OpenInterestPoint: Sendable, Equatable {
        public let time: Date
        public let contracts: Double
        public let notionalUsd: Double?
    }

    private struct OIRow: Decodable {
        let sumOpenInterest: String
        let sumOpenInterestValue: String?
        let timestamp: Double
    }

    public func openInterestHistory(
        symbol: String = "ETHUSDT", period: String = "1h", limit: Int = 8
    ) async throws -> [OpenInterestPoint] {
        let rows = try await get(
            [OIRow].self, base: binanceFutures, path: "futures/data/openInterestHist",
            query: ["symbol": symbol, "period": period, "limit": String(limit)])
        let points = rows.compactMap { row -> OpenInterestPoint? in
            guard let oi = Double(row.sumOpenInterest) else { return nil }
            return OpenInterestPoint(
                time: Date(timeIntervalSince1970: row.timestamp / 1000),
                contracts: oi, notionalUsd: row.sumOpenInterestValue.flatMap(Double.init))
        }
        guard !points.isEmpty else { throw FeedError.empty("open interest \(symbol)") }
        return points.sorted { $0.time < $1.time }
    }

    // MARK: - Macro

    /// One macro instrument, with the timestamp of the bar it came from.
    ///
    /// `asOf` is not decoration. A delayed feed is indistinguishable from a
    /// live one by price alone, and treating one as the other is how a stale
    /// reading becomes a wrong conclusion.
    public struct MacroQuote: Sendable, Equatable, Identifiable {
        public let symbol: String
        public let label: String
        public let price: Double
        public let previousClose: Double?
        public let asOf: Date
        /// What the instrument stands in for, in plain words.
        public let meaning: String

        public var id: String { symbol }
        public var changePct: Double? {
            guard let previousClose, previousClose > 0 else { return nil }
            return (price / previousClose - 1) * 100
        }
        public func isStale(now: Date = Date(), tolerance: TimeInterval = 300) -> Bool {
            now.timeIntervalSince(asOf) > tolerance
        }
    }

    /// The macro set, chosen so every member trades in real time.
    ///
    /// Yield indices are deliberately absent: they lag, and a lagging rate is
    /// worse than no rate because it invites a confident wrong reading of
    /// whether the long end is moving. TLT and the Treasury futures carry the
    /// same information without the delay.
    public static let macroSymbols: [(symbol: String, label: String, meaning: String)] = [
        ("TLT", "TLT 20年+", "长端实时代理，涨=长端收益率跌"),
        ("IEF", "IEF 7-10年", "中长端"),
        ("ZB=F", "30年期货", "长端，24h 交易"),
        ("ZN=F", "10年期货", "10年，24h 交易"),
        ("DX-Y.NYB", "美元指数", "美元强弱"),
        ("GC=F", "黄金", "与美元同看可辨实际利率方向"),
        ("^GSPC", "标普500", "风险偏好"),
        ("^IXIC", "纳斯达克", "高 beta 风险偏好"),
    ]

    private struct ChartEnvelope: Decodable {
        struct Chart: Decodable { let result: [Result]? }
        struct Result: Decodable {
            let meta: Meta
            let timestamp: [Double]?
            let indicators: Indicators?
        }
        struct Meta: Decodable {
            let regularMarketPrice: Double?
            let chartPreviousClose: Double?
            let previousClose: Double?
        }
        struct Indicators: Decodable {
            struct Quote: Decodable { let close: [Double?]? }
            let quote: [Quote]?
        }
        let chart: Chart
    }

    /// One macro instrument, stamped with the last bar's time rather than now.
    public func macroQuote(
        symbol: String, label: String, meaning: String
    ) async throws -> MacroQuote {
        let encoded = symbol.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? symbol
        let envelope = try await get(
            ChartEnvelope.self, base: quoteBase, path: "v8/finance/chart/\(encoded)",
            query: ["interval": "1m", "range": "1d"])
        guard let result = envelope.chart.result?.first,
              let price = result.meta.regularMarketPrice
        else { throw FeedError.empty(symbol) }
        // The final bar that actually carries a close — that is when this price
        // was true, whatever the wall clock says.
        var asOf = Date()
        if let stamps = result.timestamp,
           let closes = result.indicators?.quote?.first?.close {
            for index in stride(from: min(stamps.count, closes.count) - 1, through: 0, by: -1)
            where closes[index] != nil {
                asOf = Date(timeIntervalSince1970: stamps[index])
                break
            }
        }
        return MacroQuote(
            symbol: symbol, label: label, price: price,
            previousClose: result.meta.chartPreviousClose ?? result.meta.previousClose,
            asOf: asOf, meaning: meaning)
    }

    /// The whole macro set, skipping any instrument that fails rather than
    /// failing the lot.
    public func macroSnapshot() async -> [MacroQuote] {
        await withTaskGroup(of: MacroQuote?.self) { group in
            for entry in Self.macroSymbols {
                group.addTask {
                    try? await macroQuote(
                        symbol: entry.symbol, label: entry.label, meaning: entry.meaning)
                }
            }
            var quotes: [MacroQuote] = []
            for await quote in group { if let quote { quotes.append(quote) } }
            let order = Self.macroSymbols.map(\.symbol)
            return quotes.sorted {
                (order.firstIndex(of: $0.symbol) ?? 0) < (order.firstIndex(of: $1.symbol) ?? 0)
            }
        }
    }
}
