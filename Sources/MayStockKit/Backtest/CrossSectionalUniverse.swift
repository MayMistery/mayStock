import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One asset in a cross-sectional study.
public struct UniverseAsset: Sendable, Equatable, Identifiable {
    public let instId: String
    public let symbol: String
    /// Latest market capitalisation in USD, from CoinGecko.
    public let marketCapUsd: Double
    /// Circulating supply now. Historical caps are reconstructed from it —
    /// see the bias note on `CrossSectionalUniverse`.
    public let circulatingSupply: Double
    public let candles: [Candle]

    public var id: String { instId }

    public init(
        instId: String, symbol: String, marketCapUsd: Double,
        circulatingSupply: Double, candles: [Candle]
    ) {
        self.instId = instId
        self.symbol = symbol
        self.marketCapUsd = marketCapUsd
        self.circulatingSupply = circulatingSupply
        self.candles = candles
    }
}

/// The known biases in a universe built this way. Reported alongside every
/// result, because a cross-sectional backtest without them is worthless.
public struct UniverseBiases: Sendable, Equatable {
    /// Coins that no longer trade on OKX never enter the universe, so the study
    /// only ever sees survivors. This is the single largest source of
    /// overstatement in crypto factor research.
    public let survivorship: Bool
    /// Historical market caps use *today's* circulating supply, which was not
    /// knowable at the time. Affects the size factor's ranking, mildly for
    /// mature assets and badly for high-inflation ones.
    public let supplyLookAhead: Bool
    public let universeSize: Int
    public let requestedSize: Int
    public let droppedForHistory: Int
    /// Stablecoins, tokenised commodities and wrappers kept out of the sort.
    public let excludedPegged: [String]

    public init(
        survivorship: Bool, supplyLookAhead: Bool, universeSize: Int,
        requestedSize: Int, droppedForHistory: Int, excludedPegged: [String] = []
    ) {
        self.survivorship = survivorship
        self.supplyLookAhead = supplyLookAhead
        self.universeSize = universeSize
        self.requestedSize = requestedSize
        self.droppedForHistory = droppedForHistory
        self.excludedPegged = excludedPegged
    }

    public var notes: [String] {
        var out: [String] = []
        if survivorship {
            out.append("幸存者偏差：宇宙取自**今天**仍在 OKX 上市的币，"
                       + "退市与归零的币从未进入样本，横截面收益被系统性高估。")
        }
        if supplyLookAhead {
            out.append("流通量前视：历史市值 = 历史价格 × **当前**流通量。"
                       + "成熟币影响小，高通胀币会让规模排序失真。")
        }
        if droppedForHistory > 0 {
            out.append("\(droppedForHistory) 个币因历史长度不足被剔除"
                       + "（这本身又是一层幸存者筛选）。")
        }
        return out
    }
}

extension UniverseBuilder {
    /// Annualised close-to-close volatility in percent.
    static func annualisedVolatility(_ candles: [Candle]) -> Double {
        let closes = candles.map(\.close)
        guard closes.count > 2 else { return 0 }
        var returns: [Double] = []
        for index in 1..<closes.count where closes[index - 1] > 0 {
            returns.append(closes[index] / closes[index - 1] - 1)
        }
        let mean = Statistics.mean(returns)
        let deviation = Statistics.standardDeviation(returns, mean: mean)
        return deviation * 365.0.squareRoot() * 100
    }
}

public struct CrossSectionalUniverse: Sendable {
    public let assets: [UniverseAsset]
    public let biases: UniverseBiases
    /// Shared daily timeline every asset is sampled onto.
    public let calendar: [Date]

    public func asset(_ instId: String) -> UniverseAsset? {
        assets.first { $0.instId == instId }
    }
}

// MARK: - Builder

/// Assembles a tradeable cross-sectional universe: OKX price history for the
/// bars, CoinGecko for the market caps that define "size".
///
/// CoinGecko's free tier allows roughly two requests a minute and caps history
/// at 365 days, so the builder makes **one** call for the whole coin list and
/// reconstructs history from OKX candles rather than paging per coin.
public struct UniverseBuilder: Sendable {
    public let rest: OKXRESTClient
    private let session: URLSession

    public init(rest: OKXRESTClient = OKXRESTClient()) {
        self.rest = rest
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Pegged assets are not cryptocurrencies for factor purposes: a stablecoin
    /// has ~0 return and ~0 volatility, so it wins any risk-adjusted sort by
    /// default and pollutes whichever leg it lands in. Liu, Tsyvinski & Wu
    /// exclude them, and so does every serious crypto factor study.
    public static let peggedSymbols: Set<String> = [
        // USD stablecoins
        "USDT", "USDC", "USDS", "USD1", "USDG", "USDE", "USDD", "USDP", "USDY",
        "PYUSD", "RLUSD", "FDUSD", "TUSD", "DAI", "BUSD", "GUSD", "LUSD", "FRAX",
        "SUSD", "USDX", "USDF", "USDB", "CRVUSD", "USDO", "AUSD", "USDL",
        // Tokenised commodities
        "XAUT", "PAXG", "XAGT",
        // Staked / wrapped wrappers of an asset already in the universe
        "WBTC", "WETH", "STETH", "WSTETH", "WEETH", "CBBTC", "RETH", "WBETH",
    ]

    /// Annualised volatility below this means the asset is pegged to something,
    /// whatever it calls itself. Catches new stablecoins no list would have.
    public static let peggedVolatilityThreshold = 5.0

    private struct MarketRow: Decodable {
        let symbol: String
        let market_cap: Double?
        let circulating_supply: Double?
    }

    /// Build a universe of the `size` largest OKX-listed USDT spot pairs.
    public func build(
        size: Int = 40,
        days: Int = 365,
        bar: BarInterval = .d1,
        minimumBars: Int? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> CrossSectionalUniverse {
        onProgress?("拉取 OKX 现货标的列表")
        let listed = try await okxSpotSymbols()

        onProgress?("拉取市值（CoinGecko，单次请求 250 个币）")
        let ranked = try await coinGeckoMarkets()

        // Intersect: ranked by market cap, keep those OKX actually lists.
        var wanted: [(symbol: String, cap: Double, supply: Double)] = []
        var excludedPegged: [String] = []
        for row in ranked {
            let symbol = row.symbol.uppercased()
            guard listed.contains(symbol),
                  let cap = row.market_cap, cap > 0,
                  let supply = row.circulating_supply, supply > 0 else { continue }
            guard !wanted.contains(where: { $0.symbol == symbol }) else { continue }
            guard !Self.peggedSymbols.contains(symbol) else {
                excludedPegged.append(symbol)
                continue
            }
            wanted.append((symbol, cap, supply))
            if wanted.count >= size { break }
        }

        let requiredBars = minimumBars ?? Int(Double(days) * 0.8)
        var assets: [UniverseAsset] = []
        var dropped = 0

        for entry in wanted {
            let instId = "\(entry.symbol)-USDT"
            onProgress?("拉取 \(instId) 历史（\(assets.count + 1)/\(wanted.count)）")
            let target = Int((Double(days) * 86_400 / bar.seconds).rounded(.up))
            guard let candles = try? await rest.historyCandles(
                instId: instId, bar: bar, target: target),
                candles.count >= requiredBars else {
                dropped += 1
                continue
            }
            // Second line of defence: anything that barely moves is pegged to
            // something, whatever its ticker suggests.
            let volatility = Self.annualisedVolatility(candles)
            guard volatility >= Self.peggedVolatilityThreshold else {
                excludedPegged.append(entry.symbol)
                continue
            }
            assets.append(UniverseAsset(
                instId: instId, symbol: entry.symbol,
                marketCapUsd: entry.cap, circulatingSupply: entry.supply,
                candles: candles))
        }

        // Shared calendar: dates on which a majority of the universe traded, so
        // a coin with a gap cannot silently shift everyone else's alignment.
        var counts: [Date: Int] = [:]
        for asset in assets {
            for candle in asset.candles { counts[candle.ts, default: 0] += 1 }
        }
        let quorum = Swift.max(assets.count / 2, 1)
        let calendar = counts.filter { $0.value >= quorum }.keys.sorted()

        return CrossSectionalUniverse(
            assets: assets,
            biases: UniverseBiases(
                survivorship: true, supplyLookAhead: true,
                universeSize: assets.count, requestedSize: size,
                droppedForHistory: dropped,
                excludedPegged: excludedPegged.sorted()),
            calendar: calendar)
    }

    // MARK: Sources

    private struct InstrumentRow: Decodable {
        let instId: String
        let baseCcy: String?
        let quoteCcy: String?
        let state: String?
    }

    /// Base currencies OKX currently lists against USDT and is actively trading.
    func okxSpotSymbols() async throws -> Set<String> {
        let rows = try await rest.getRaw(
            InstrumentRow.self, path: "api/v5/public/instruments",
            query: ["instType": "SPOT"])
        return Set(rows.compactMap { row -> String? in
            guard row.quoteCcy == "USDT", row.state == nil || row.state == "live",
                  let base = row.baseCcy, !base.isEmpty else { return nil }
            return base.uppercased()
        })
    }

    private func coinGeckoMarkets() async throws -> [MarketRow] {
        var components = URLComponents(
            string: "https://api.coingecko.com/api/v3/coins/markets")!
        components.queryItems = [
            URLQueryItem(name: "vs_currency", value: "usd"),
            URLQueryItem(name: "order", value: "market_cap_desc"),
            URLQueryItem(name: "per_page", value: "250"),
            URLQueryItem(name: "page", value: "1"),
        ]
        guard let url = components.url else { throw OKXError.transport("bad CoinGecko url") }

        var request = URLRequest(url: url)
        request.setValue("MayStock/2.1 (factor research)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Same locale trap as blockchain.info — pin it rather than inherit it.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")

        let data: Data, response: URLResponse
        do {
            #if canImport(FoundationNetworking)
            (data, response) = try await session.compatData(for: request)
            #else
            (data, response) = try await session.data(for: request)
            #endif
        } catch {
            throw OKXError.transport("coingecko: \(error)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OKXError.transport(
                "coingecko HTTP \(http.statusCode)"
                + (http.statusCode == 429 ? "（免费档约 2 次/分钟，稍后重试）" : ""))
        }
        return try JSONDecoder().decode([MarketRow].self, from: data)
    }
}
