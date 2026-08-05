import Foundation

// MARK: - Sources

/// Public OKX data beyond OHLCV that a strategy may reference by name.
///
/// **History is the binding constraint here, not availability.** OKX's trading
/// statistics ("rubik") endpoints return a fixed window and do not paginate:
/// roughly 30 days on hourly periods and 179 days on daily ones. Funding rate
/// is the exception — it paginates back years. Every source therefore declares
/// `historyLimitDays` so the tooling can say *this window cannot be validated*
/// instead of quietly backtesting on three weeks of data.
public enum AlternativeSeriesSource: String, Codable, Sendable, CaseIterable {
    /// Realised funding rate of a perpetual, as a fraction (0.0001 = 0.01%).
    case fundingRate
    /// Open interest in USD for a currency.
    case openInterestUsd
    /// Traded volume in USD for a currency.
    case volumeUsd
    /// Ratio of accounts net long to net short. > 1 means the crowd is long.
    case longShortRatio
    case takerBuyVolume
    case takerSellVolume
    /// `(buy − sell) / (buy + sell)`, in −1…+1. Aggressive order-flow tilt.
    case takerImbalance
    /// Margin lending ratio (borrowed base vs quote).
    case marginLoanRatio
    /// Another instrument's close — cross-asset filters and ratio trades.
    case instrumentClose

    // — Industry-standard feeds. Chosen for depth: every one has years of free
    //   history, unlike the exchange statistics above. See `IndustrySignals`.

    /// Crypto Fear & Greed composite, 0–100. Daily since 2018-02.
    case fearGreed
    /// Bitcoin addresses active on-chain — the classic adoption proxy.
    case activeAddresses
    case transactionCount
    case hashRate
    case minerRevenue
    case onChainVolumeUsd
    /// Trade-weighted US dollar index. Crypto's most-watched macro headwind.
    case dollarIndex
    case sp500
    /// CBOE volatility index — the market-wide risk appetite gauge.
    case vix
    case treasury10y
    /// Coinbase BTC-USD vs OKX BTC-USDT, in percent. US demand proxy.
    case coinbasePremium
    /// Mean USD value per on-chain transfer — the free proxy for whale activity.
    /// Real whale metrics (exchange netflow, balances of addresses > 1k BTC)
    /// need UTXO-level data and are paywalled everywhere.
    case avgTransactionSize

    public var displayName: String {
        switch self {
        case .fundingRate: return "资金费率"
        case .openInterestUsd: return "持仓量(USD)"
        case .volumeUsd: return "成交额(USD)"
        case .longShortRatio: return "多空账户比"
        case .takerBuyVolume: return "主动买入量"
        case .takerSellVolume: return "主动卖出量"
        case .takerImbalance: return "主动买卖失衡"
        case .marginLoanRatio: return "杠杆借贷比"
        case .instrumentClose: return "其它标的收盘价"
        case .fearGreed: return "恐惧贪婪指数"
        case .activeAddresses: return "链上活跃地址"
        case .transactionCount: return "链上交易笔数"
        case .hashRate: return "全网算力"
        case .minerRevenue: return "矿工收入"
        case .onChainVolumeUsd: return "链上转账额"
        case .dollarIndex: return "美元指数"
        case .sp500: return "标普 500"
        case .vix: return "VIX 恐慌指数"
        case .treasury10y: return "10 年美债收益率"
        case .coinbasePremium: return "Coinbase 溢价"
        case .avgTransactionSize: return "平均单笔转账额(巨鲸代理)"
        }
    }

    /// Which third-party feed backs this source, or nil for the OKX ones.
    public var industryFeed: IndustrySignalFeed? {
        switch self {
        case .fearGreed: return .fearGreed
        case .activeAddresses: return .blockchainChart("n-unique-addresses")
        case .transactionCount: return .blockchainChart("n-transactions")
        case .hashRate: return .blockchainChart("hash-rate")
        case .minerRevenue: return .blockchainChart("miners-revenue")
        case .onChainVolumeUsd: return .blockchainChart("estimated-transaction-volume-usd")
        case .dollarIndex: return .fred("DTWEXBGS")
        case .sp500: return .fred("SP500")
        case .vix: return .fred("VIXCLS")
        case .treasury10y: return .fred("DGS10")
        case .coinbasePremium: return .coinbasePremium
        case .avgTransactionSize: return .averageTransactionSize
        default: return nil
        }
    }

    /// True for the deep third-party feeds, false for the shallow OKX ones.
    public var isIndustryFeed: Bool { industryFeed != nil }

    /// Where the data comes from, for the UI and the docs.
    public var provider: String {
        switch industryFeed {
        case .some(let feed): return feed.host
        case .none: return "OKX"
        }
    }

    /// Whether the source is keyed by instrument (`instId`) or currency (`ccy`).
    public var needsInstrument: Bool {
        self == .fundingRate || self == .instrumentClose
    }

    /// Sources that describe the whole market rather than one instrument.
    public var isGlobal: Bool { isIndustryFeed && self != .coinbasePremium }

    /// Longest history the endpoint will return, in days, at the given bar.
    /// Nil means "as deep as candles" (paginates without a server-side cap).
    ///
    /// Measured against the live API, not read off documentation:
    /// `maystock-lab signals` re-runs the measurement any time.
    public func historyLimitDays(bar: BarInterval) -> Int? {
        // Every industry feed carries years of history; that is why they were
        // chosen over the exchange statistics.
        if isIndustryFeed { return nil }
        switch self {
        case .instrumentClose:
            return nil                       // candles paginate for years
        case .fundingRate:
            // OKX serves exactly three months of settlements (3/day × ~93).
            return 90
        default:
            // Rubik endpoints: ~720 points at 5m/1H, ~180 at 1D.
            switch bar {
            case .m1, .m5, .m15: return 2    // 720 × 5m
            case .h1: return 30              // 720 × 1H
            case .h4, .d1, .w1: return 179   // 180 × 1D
            }
        }
    }

    /// The `period` query value these endpoints accept (5m / 1H / 1D only).
    public static func rubikPeriod(for bar: BarInterval) -> String {
        switch bar {
        case .m1, .m5, .m15: return "5m"
        case .h1: return "1H"
        case .h4, .d1, .w1: return "1D"
        }
    }
}

/// One named external series a manifest wants alongside its candles.
public struct AlternativeSeriesSpec: Codable, Sendable, Equatable {
    public var source: AlternativeSeriesSource
    /// Required for `fundingRate` / `instrumentClose`.
    public var instId: String?
    /// Required for the currency-keyed statistics; derived from the strategy's
    /// own instrument when omitted (BTC-USDT → BTC).
    public var ccy: String?
    /// `SPOT` or `SWAP` for taker-volume; defaults to SPOT.
    public var instType: InstrumentType?

    public init(
        source: AlternativeSeriesSource, instId: String? = nil,
        ccy: String? = nil, instType: InstrumentType? = nil
    ) {
        self.source = source
        self.instId = instId
        self.ccy = ccy
        self.instType = instType
    }

    /// Fill in whatever the manifest left implicit, using the strategy's market.
    public func resolved(against market: StrategyMarket) -> AlternativeSeriesSpec {
        var copy = self
        if copy.ccy == nil {
            copy.ccy = StrategyLedger.currencies(of: instId ?? market.instId).base
        }
        if copy.instId == nil, source.needsInstrument {
            copy.instId = source == .fundingRate
                ? Self.perpetual(for: market.instId)
                : market.instId
        }
        if copy.instType == nil { copy.instType = market.instType }
        return copy
    }

    /// "BTC-USDT" → "BTC-USDT-SWAP"; already-perpetual ids pass through.
    static func perpetual(for instId: String) -> String {
        instId.hasSuffix("-SWAP") ? instId : instId + "-SWAP"
    }

    public var description: String {
        var parts = [source.displayName]
        if let instId { parts.append(instId) }
        else if let ccy { parts.append(ccy) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Observations

public struct SeriesObservation: Sendable, Equatable {
    public let ts: Date
    public let value: Double

    public init(ts: Date, value: Double) {
        self.ts = ts
        self.value = value
    }
}

/// How much of a backtest window a series could actually cover.
public struct SeriesCoverage: Sendable, Equatable {
    public let name: String
    public let spec: AlternativeSeriesSpec
    public let observations: Int
    public let earliest: Date?
    public let latest: Date?
    /// Share of candles that received a real value rather than NaN.
    public let coverageRatio: Double

    public var isUsable: Bool { coverageRatio >= 0.9 }

    public var summary: String {
        guard observations > 0 else { return "\(name)：无数据" }
        let span = (latest?.timeIntervalSince(earliest ?? Date()) ?? 0) / 86_400
        return "\(name)（\(spec.description)）：\(observations) 点 · 跨度 \(Int(span)) 天"
            + " · 覆盖 \(PriceFormatter.percent(coverageRatio * 100))"
    }
}

// MARK: - Alignment

public enum SeriesAligner {
    /// Project observations onto a candle timeline, carrying the last known
    /// value forward.
    ///
    /// **No look-ahead by construction**: a candle at `ts` may only see
    /// observations stamped at or before `ts`. Since `ts` is the bar's *open*
    /// and signals are evaluated at its *close*, anything used was already
    /// published when the decision was made. Bars before the first observation
    /// stay NaN, which the evaluator treats as "unknown" and never trades on.
    public static func align(
        _ observations: [SeriesObservation], to candles: [Candle]
    ) -> [Double] {
        var out = [Double](repeating: .nan, count: candles.count)
        guard !observations.isEmpty, !candles.isEmpty else { return out }
        let sorted = observations.sorted { $0.ts < $1.ts }

        var cursor = 0
        var current = Double.nan
        for (index, candle) in candles.enumerated() {
            while cursor < sorted.count, sorted[cursor].ts <= candle.ts {
                current = sorted[cursor].value
                cursor += 1
            }
            out[index] = current
        }
        return out
    }

    public static func coverage(
        name: String, spec: AlternativeSeriesSpec,
        observations: [SeriesObservation], aligned: [Double]
    ) -> SeriesCoverage {
        let valid = aligned.filter { !$0.isNaN }.count
        let timestamps = observations.map(\.ts)
        return SeriesCoverage(
            name: name, spec: spec, observations: observations.count,
            earliest: timestamps.min(), latest: timestamps.max(),
            coverageRatio: aligned.isEmpty ? 0 : Double(valid) / Double(aligned.count))
    }
}

// MARK: - Provider

/// Fetches the public OKX statistics behind `AlternativeSeriesSource`.
public struct AlternativeDataProvider: Sendable {
    public let rest: OKXRESTClient

    public init(rest: OKXRESTClient = OKXRESTClient()) {
        self.rest = rest
    }

    /// Fetch one declared series, already resolved against the market.
    public func fetch(
        _ spec: AlternativeSeriesSpec, bar: BarInterval, days: Int
    ) async throws -> [SeriesObservation] {
        // Third-party feeds first — they are the ones with usable history.
        if let feed = spec.source.industryFeed {
            return try await IndustrySignalProvider(okx: rest).fetch(feed, days: days)
        }
        let period = AlternativeSeriesSource.rubikPeriod(for: bar)
        switch spec.source {
        case .fundingRate:
            let instId = spec.instId ?? AlternativeSeriesSpec.perpetual(for: "BTC-USDT")
            let since = Date().addingTimeInterval(-Double(days) * 86_400)
            let rates = try await rest.fundingRateHistory(
                instId: instId, since: since, limit: days * 3 + 20)
            return rates.map { SeriesObservation(ts: $0.ts, value: $0.rate) }

        case .instrumentClose:
            let instId = spec.instId ?? "BTC-USDT"
            let bars = Int((Double(days) * 86_400 / bar.seconds).rounded(.up))
            let candles = try await rest.historyCandles(
                instId: instId, bar: bar, target: Swift.min(bars, BacktestRunner.maxBars))
            return candles.map { SeriesObservation(ts: $0.ts, value: $0.close) }

        case .longShortRatio:
            return try await rest.tradingStatistic(
                path: "api/v5/rubik/stat/contracts/long-short-account-ratio",
                query: ["ccy": spec.ccy ?? "BTC", "period": period], column: 1)

        case .marginLoanRatio:
            return try await rest.tradingStatistic(
                path: "api/v5/rubik/stat/margin/loan-ratio",
                query: ["ccy": spec.ccy ?? "BTC", "period": period], column: 1)

        case .openInterestUsd:
            return try await rest.tradingStatistic(
                path: "api/v5/rubik/stat/contracts/open-interest-volume",
                query: ["ccy": spec.ccy ?? "BTC", "period": period], column: 1)

        case .volumeUsd:
            return try await rest.tradingStatistic(
                path: "api/v5/rubik/stat/contracts/open-interest-volume",
                query: ["ccy": spec.ccy ?? "BTC", "period": period], column: 2)

        case .takerSellVolume:
            return try await rest.tradingStatistic(
                path: "api/v5/rubik/stat/taker-volume",
                query: ["ccy": spec.ccy ?? "BTC", "period": period,
                        "instType": (spec.instType ?? .spot).rawValue], column: 1)

        case .takerBuyVolume:
            return try await rest.tradingStatistic(
                path: "api/v5/rubik/stat/taker-volume",
                query: ["ccy": spec.ccy ?? "BTC", "period": period,
                        "instType": (spec.instType ?? .spot).rawValue], column: 2)

        case .takerImbalance:
            let query = ["ccy": spec.ccy ?? "BTC", "period": period,
                         "instType": (spec.instType ?? .spot).rawValue]
            async let sellTask = rest.tradingStatistic(
                path: "api/v5/rubik/stat/taker-volume", query: query, column: 1)
            async let buyTask = rest.tradingStatistic(
                path: "api/v5/rubik/stat/taker-volume", query: query, column: 2)
            let (sells, buys) = try await (sellTask, buyTask)
            let sellByTs = Dictionary(sells.map { ($0.ts, $0.value) }, uniquingKeysWith: { a, _ in a })
            return buys.compactMap { buy in
                guard let sell = sellByTs[buy.ts] else { return nil }
                let total = buy.value + sell
                guard total > 0 else { return nil }
                return SeriesObservation(ts: buy.ts, value: (buy.value - sell) / total)
            }

        default:
            // Industry feeds were handled above; nothing else can reach here.
            return []
        }
    }

    /// Fetch every declared series and align it to the candles.
    public func load(
        specs: [String: AlternativeSeriesSpec], market: StrategyMarket,
        candles: [Candle], days: Int
    ) async -> (series: [String: [Double]], coverage: [SeriesCoverage]) {
        var series: [String: [Double]] = [:]
        var coverage: [SeriesCoverage] = []

        for (name, raw) in specs.sorted(by: { $0.key < $1.key }) {
            let spec = raw.resolved(against: market)
            let observations = (try? await fetch(spec, bar: market.bar, days: days)) ?? []
            let aligned = SeriesAligner.align(observations, to: candles)
            series[name] = aligned
            coverage.append(SeriesAligner.coverage(
                name: name, spec: spec, observations: observations, aligned: aligned))
        }
        return (series, coverage)
    }
}

// MARK: - REST support

extension OKXRESTClient {
    /// OKX's "rubik" statistics return bare arrays: `[ts, v1, v2…]`.
    /// `column` selects which field to read.
    public func tradingStatistic(
        path: String, query: [String: String], column: Int
    ) async throws -> [SeriesObservation] {
        let rows = try await getRaw([String].self, path: path, query: query)
        return rows.compactMap { row in
            guard row.count > column,
                  let ms = Double(row[0]), let value = Double(row[column]) else { return nil }
            return SeriesObservation(ts: Date(timeIntervalSince1970: ms / 1000), value: value)
        }
        .sorted { $0.ts < $1.ts }
    }
}
