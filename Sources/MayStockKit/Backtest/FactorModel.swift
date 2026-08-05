import Foundation

// MARK: - Factors

/// The three factors Liu, Tsyvinski & Wu (JF 2022) found explain the cross
/// section of cryptocurrency returns.
///
/// These are **cross-sectional**: they rank assets against each other at a
/// point in time, rather than timing one asset. That distinction is the whole
/// reason this file exists — everything else in the toolkit times a single
/// instrument, and the published evidence for that is far weaker.
public enum CrossSectionalFactor: String, Sendable, CaseIterable, Codable, Identifiable {
    /// Equal-weight universe return. The thing everything else is measured against.
    case market
    /// Small minus big: −log(market cap), so smaller scores higher.
    case size
    /// Past return over the lookback, **skipping the most recent period** to
    /// step around short-horizon reversal.
    case momentum
    /// Past return with no skip — kept for comparison, since the skip is
    /// exactly the kind of choice that deserves to be checked rather than assumed.
    case momentumNoSkip

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .market: return "市场"
        case .size: return "规模"
        case .momentum: return "动量(跳过最近一期)"
        case .momentumNoSkip: return "动量(不跳过)"
        }
    }

    public var isRankable: Bool { self != .market }
}

// MARK: - Results

public struct FactorPeriodReturn: Sendable, Equatable {
    public let date: Date
    /// Equal-weight return of the whole universe, in percent.
    public let marketReturn: Double
    /// Top-quintile minus bottom-quintile, in percent, net of costs.
    public let longShortReturn: Double
    /// Top quintile only, in percent, net of costs.
    public let longOnlyReturn: Double
    public let assetsRanked: Int
    /// Names held in the long leg, for turnover accounting.
    public let longLeg: [String]
}

public struct FactorBacktestResult: Sendable {
    public let factor: CrossSectionalFactor
    public let periods: [FactorPeriodReturn]
    public let longShortEquity: [EquityPoint]
    public let longOnlyEquity: [EquityPoint]
    public let marketEquity: [EquityPoint]
    public let longShortMetrics: BacktestMetrics
    public let longOnlyMetrics: BacktestMetrics
    public let marketMetrics: BacktestMetrics
    /// Average share of the long leg replaced each rebalance.
    public let turnover: Double
    public let costPerRebalancePct: Double
    public let biases: UniverseBiases

    /// t-statistic of the mean long/short period return. The standard test for
    /// "is this factor premium different from zero?".
    public var longShortTStatistic: Double {
        let returns = periods.map(\.longShortReturn)
        guard returns.count > 2 else { return 0 }
        let mean = Statistics.mean(returns)
        let deviation = Statistics.standardDeviation(returns, mean: mean)
        guard deviation > 0 else { return 0 }
        return mean / (deviation / Double(returns.count).squareRoot())
    }

    public var meanLongShortReturn: Double {
        Statistics.mean(periods.map(\.longShortReturn))
    }

    /// Non-overlapping rebalances, so no √h deflation is needed here — but the
    /// multiple-testing threshold still applies.
    public var verdict: String {
        guard periods.count > 5 else { return "调仓次数太少，无法判断" }
        let t = longShortTStatistic
        if abs(t) <= 2 {
            return "多空组合收益不显著（t = \(PriceFormatter.decimals(t, 2))）"
                + " —— 该因子在这个宇宙里没有可辨别的溢价"
        }
        if longShortMetrics.totalReturnPct <= 0 {
            return "t 值达标但累计为负，方向与文献相反，不足以采信"
        }
        return "多空溢价显著（t = \(PriceFormatter.decimals(t, 2))），"
            + "但请先读幸存者偏差说明再决定是否当真"
    }
}

// MARK: - Engine

/// Ranks a universe by a factor each period, forms quintile portfolios, and
/// measures what they would have paid — after costs.
///
/// Execution model matches the rest of the toolkit: scores are computed from
/// data up to the rebalance bar, and the resulting portfolio earns the *next*
/// period's return. A factor study that scores and earns in the same period is
/// measuring nothing but its own arithmetic.
public struct FactorModel: Sendable {
    public let universe: CrossSectionalUniverse
    /// Bars between rebalances (7 = weekly on daily bars).
    public let rebalanceBars: Int
    /// Lookback for momentum, in bars.
    public let lookbackBars: Int
    /// Bars skipped between the lookback and the rebalance.
    public let skipBars: Int
    /// Fraction of the universe in each leg (0.2 = quintiles).
    public let legFraction: Double
    public let feeSchedule: OKXFeeSchedule

    public init(
        universe: CrossSectionalUniverse,
        rebalanceBars: Int = 7,
        lookbackBars: Int = 28,
        skipBars: Int = 7,
        legFraction: Double = 0.2,
        feeSchedule: OKXFeeSchedule = OKXFeeSchedule()
    ) {
        self.universe = universe
        self.rebalanceBars = Swift.max(rebalanceBars, 1)
        self.lookbackBars = Swift.max(lookbackBars, 1)
        self.skipBars = Swift.max(skipBars, 0)
        self.legFraction = Swift.min(Swift.max(legFraction, 0.05), 0.5)
        self.feeSchedule = feeSchedule
    }

    public func run(factor: CrossSectionalFactor, initialCapital: Double = 30_000) -> FactorBacktestResult {
        let calendar = universe.calendar
        // Closes per asset, sampled onto the shared calendar.
        var closes: [String: [Double]] = [:]
        for asset in universe.assets {
            closes[asset.instId] = Self.sample(asset.candles, onto: calendar)
        }

        let warmup = lookbackBars + skipBars
        var periods: [FactorPeriodReturn] = []
        var previousLongLeg: Set<String> = []
        var turnoverTotal = 0.0
        var turnoverCount = 0

        // One round trip per name that changes: sell the old, buy the new.
        let roundTrip = feeSchedule.roundTripCostPct(for: .spot)

        var index = warmup
        while index + rebalanceBars < calendar.count {
            defer { index += rebalanceBars }

            // --- Score every asset using data up to `index` only.
            var scored: [(instId: String, score: Double, forward: Double)] = []
            for asset in universe.assets {
                guard let series = closes[asset.instId],
                      let score = score(factor: factor, asset: asset, series: series, at: index),
                      let forward = forwardReturn(series, from: index, bars: rebalanceBars)
                else { continue }
                scored.append((asset.instId, score, forward))
            }
            guard scored.count >= 10 else { continue }

            let marketReturn = scored.reduce(0) { $0 + $1.forward } / Double(scored.count)

            guard factor.isRankable else {
                periods.append(FactorPeriodReturn(
                    date: calendar[index], marketReturn: marketReturn,
                    longShortReturn: 0, longOnlyReturn: marketReturn,
                    assetsRanked: scored.count, longLeg: scored.map(\.instId)))
                continue
            }

            // --- Quintile sort. High score = long leg.
            let sorted = scored.sorted { $0.score > $1.score }
            let legSize = Swift.max(Int(Double(sorted.count) * legFraction), 1)
            let longLeg = Array(sorted.prefix(legSize))
            let shortLeg = Array(sorted.suffix(legSize))

            let longReturn = longLeg.reduce(0) { $0 + $1.forward } / Double(longLeg.count)
            let shortReturn = shortLeg.reduce(0) { $0 + $1.forward } / Double(shortLeg.count)

            // --- Costs: charge only the names that actually changed hands.
            let longNames = Set(longLeg.map(\.instId))
            let changed = previousLongLeg.isEmpty
                ? longNames.count
                : longNames.subtracting(previousLongLeg).count
            let turnoverFraction = Double(changed) / Double(longNames.count)
            if !previousLongLeg.isEmpty {
                turnoverTotal += turnoverFraction
                turnoverCount += 1
            }
            previousLongLeg = longNames

            let longCost = roundTrip * turnoverFraction
            // The short leg turns over on the same schedule and pays the same
            // fees; borrow cost is not modelled and is flagged in the report.
            let longShortCost = longCost * 2

            periods.append(FactorPeriodReturn(
                date: calendar[index],
                marketReturn: marketReturn,
                longShortReturn: longReturn - shortReturn - longShortCost,
                longOnlyReturn: longReturn - longCost,
                assetsRanked: scored.count,
                longLeg: longLeg.map(\.instId)))
        }

        func compound(_ values: [Double], dates: [Date]) -> [EquityPoint] {
            var equity = initialCapital
            var out: [EquityPoint] = []
            for (value, date) in zip(values, dates) {
                equity *= (1 + value / 100)
                out.append(EquityPoint(ts: date, equity: equity, price: 1))
            }
            return out
        }

        let dates = periods.map(\.date)
        let longShortEquity = compound(periods.map(\.longShortReturn), dates: dates)
        let longOnlyEquity = compound(periods.map(\.longOnlyReturn), dates: dates)
        let marketEquity = compound(periods.map(\.marketReturn), dates: dates)

        // Rebalance periods are the natural bar here, so annualisation uses the
        // rebalance interval rather than the underlying candle interval.
        let periodBar: BarInterval = rebalanceBars >= 7 ? .w1 : .d1

        func metrics(_ curve: [EquityPoint]) -> BacktestMetrics {
            BacktestMetrics(trades: [], equityCurve: curve, initialCapital: initialCapital,
                            bar: periodBar, freeParameterCount: 2)
        }

        return FactorBacktestResult(
            factor: factor,
            periods: periods,
            longShortEquity: longShortEquity,
            longOnlyEquity: longOnlyEquity,
            marketEquity: marketEquity,
            longShortMetrics: metrics(longShortEquity),
            longOnlyMetrics: metrics(longOnlyEquity),
            marketMetrics: metrics(marketEquity),
            turnover: turnoverCount > 0 ? turnoverTotal / Double(turnoverCount) : 0,
            costPerRebalancePct: roundTrip,
            biases: universe.biases)
    }

    // MARK: Scoring

    func score(
        factor: CrossSectionalFactor, asset: UniverseAsset, series: [Double], at index: Int
    ) -> Double? {
        switch factor {
        case .market:
            return 0
        case .size:
            // Historical cap from today's supply — the documented bias.
            guard index < series.count, series[index] > 0, asset.circulatingSupply > 0 else { return nil }
            let cap = series[index] * asset.circulatingSupply
            guard cap > 0 else { return nil }
            return -log(cap)          // small minus big
        case .momentum:
            return pastReturn(series, endingAt: index - skipBars, bars: lookbackBars)
        case .momentumNoSkip:
            return pastReturn(series, endingAt: index, bars: lookbackBars)
        }
    }

    private func pastReturn(_ series: [Double], endingAt end: Int, bars: Int) -> Double? {
        let start = end - bars
        guard start >= 0, end < series.count,
              series[start] > 0, series[end] > 0 else { return nil }
        return (series[end] / series[start] - 1) * 100
    }

    private func forwardReturn(_ series: [Double], from index: Int, bars: Int) -> Double? {
        let end = index + bars
        guard end < series.count, series[index] > 0, series[end] > 0 else { return nil }
        return (series[end] / series[index] - 1) * 100
    }

    /// Last-observation-carried-forward onto the shared calendar; leading gaps
    /// stay NaN so an asset cannot contribute before it started trading.
    static func sample(_ candles: [Candle], onto calendar: [Date]) -> [Double] {
        var out = [Double](repeating: .nan, count: calendar.count)
        guard !candles.isEmpty else { return out }
        let sorted = candles.sorted { $0.ts < $1.ts }
        var cursor = 0
        var current = Double.nan
        for (index, date) in calendar.enumerated() {
            while cursor < sorted.count, sorted[cursor].ts <= date {
                current = sorted[cursor].close
                cursor += 1
            }
            out[index] = current
        }
        return out
    }
}
