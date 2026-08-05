import Foundation

/// One strategy's slice of a combined backtest.
public struct PortfolioLeg: Sendable {
    public let strategyId: String
    public let strategyName: String
    public let instId: String
    public let weight: Double
    public let result: BacktestResult

    public init(
        strategyId: String, strategyName: String, instId: String,
        weight: Double, result: BacktestResult
    ) {
        self.strategyId = strategyId
        self.strategyName = strategyName
        self.instId = instId
        self.weight = weight
        self.result = result
    }
}

/// Combined performance of several strategies sharing one pot of capital.
public struct PortfolioBacktestResult: Sendable {
    public let legs: [PortfolioLeg]
    public let initialCapital: Double
    public let equityCurve: [EquityPoint]
    public let metrics: BacktestMetrics
    /// Pairwise correlation of daily returns, keyed "A|B". Two legs that move
    /// together diversify nothing, whatever their individual numbers say.
    public let correlations: [String: Double]
    public let start: Date
    public let end: Date

    public var finalEquity: Double { equityCurve.last?.equity ?? initialCapital }

    /// Weighted mean of the legs' drawdowns, i.e. what the drawdown would be if
    /// the legs bottomed simultaneously. Comparing this with the portfolio's
    /// actual drawdown is the clearest measure of real diversification.
    public var undiversifiedDrawdownPct: Double {
        let total = legs.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        return legs.reduce(0) { $0 + $1.result.metrics.maxDrawdownPct * $1.weight } / total
    }

    public var diversificationBenefitPct: Double {
        undiversifiedDrawdownPct - metrics.maxDrawdownPct
    }
}

/// Combines independently-run strategy backtests into one portfolio curve.
///
/// Legs are marked on a shared calendar: at each timestamp every leg
/// contributes its own equity, so a portfolio drawdown reflects the legs
/// actually overlapping rather than the worst of each taken separately.
public enum PortfolioBacktest {

    public static func combine(
        legs: [PortfolioLeg], initialCapital: Double
    ) -> PortfolioBacktestResult {
        let active = legs.filter { $0.weight > 0 && !$0.result.equityCurve.isEmpty }
        guard !active.isEmpty else {
            return PortfolioBacktestResult(
                legs: legs, initialCapital: initialCapital, equityCurve: [],
                metrics: .empty, correlations: [:], start: Date(), end: Date())
        }

        let weightTotal = active.reduce(0) { $0 + $1.weight }

        // Shared timeline: every timestamp any leg reported, in order. Legs on
        // different intervals therefore still combine correctly.
        var timestamps = Set<Date>()
        for leg in active { timestamps.formUnion(leg.result.equityCurve.map(\.ts)) }
        let calendar = timestamps.sorted()
        guard let first = calendar.first, let last = calendar.last else {
            return PortfolioBacktestResult(
                legs: legs, initialCapital: initialCapital, equityCurve: [],
                metrics: .empty, correlations: [:], start: Date(), end: Date())
        }

        // Per-leg equity as a fraction of its own start, sampled onto the
        // shared calendar with last-observation-carried-forward.
        var normalised: [String: [Double]] = [:]
        var benchmark: [Double] = Array(repeating: 0, count: calendar.count)
        for leg in active {
            let curve = leg.result.equityCurve
            guard let base = curve.first, base.equity > 0, base.price > 0 else { continue }
            var series = [Double](repeating: 1, count: calendar.count)
            var priceSeries = [Double](repeating: 1, count: calendar.count)
            var cursor = 0
            var lastEquity = 1.0
            var lastPrice = 1.0
            for (index, ts) in calendar.enumerated() {
                while cursor < curve.count, curve[cursor].ts <= ts {
                    lastEquity = curve[cursor].equity / base.equity
                    lastPrice = curve[cursor].price / base.price
                    cursor += 1
                }
                series[index] = lastEquity
                priceSeries[index] = lastPrice
            }
            normalised[leg.strategyId] = series
            let share = leg.weight / weightTotal
            for index in calendar.indices { benchmark[index] += priceSeries[index] * share }
        }

        // Portfolio equity: each leg compounds inside its own allocation.
        var equityCurve: [EquityPoint] = []
        equityCurve.reserveCapacity(calendar.count)
        for (index, ts) in calendar.enumerated() {
            var equity = 0.0
            for leg in active {
                guard let series = normalised[leg.strategyId] else { continue }
                equity += initialCapital * (leg.weight / weightTotal) * series[index]
            }
            equityCurve.append(EquityPoint(ts: ts, equity: equity, price: benchmark[index]))
        }

        // Trades keep their identity but are renumbered across the portfolio.
        var trades: [BacktestTrade] = []
        for leg in active { trades.append(contentsOf: leg.result.trades) }
        trades.sort { $0.exitTime < $1.exitTime }
        let renumbered = trades.enumerated().map { index, trade in
            BacktestTrade(
                id: index + 1, direction: trade.direction,
                entryTime: trade.entryTime, exitTime: trade.exitTime,
                entryPrice: trade.entryPrice, exitPrice: trade.exitPrice,
                quantity: trade.quantity, notional: trade.notional,
                grossPnL: trade.grossPnL, fees: trade.fees, funding: trade.funding,
                netPnL: trade.netPnL, returnPct: trade.returnPct,
                bars: trade.bars, exitReason: trade.exitReason)
        }

        let bar = active.map(\.result.bar).min { $0.seconds < $1.seconds } ?? .h1
        let metrics = BacktestMetrics(
            trades: renumbered, equityCurve: equityCurve,
            initialCapital: initialCapital, bar: bar,
            freeParameterCount: active.count)

        return PortfolioBacktestResult(
            legs: legs, initialCapital: initialCapital,
            equityCurve: equityCurve, metrics: metrics,
            correlations: correlations(of: normalised),
            start: first, end: last)
    }

    /// Pearson correlation between each pair of legs' period returns.
    static func correlations(of series: [String: [Double]]) -> [String: Double] {
        let keys = series.keys.sorted()
        var result: [String: Double] = [:]
        for i in keys.indices {
            for j in (i + 1)..<keys.count {
                guard let a = series[keys[i]], let b = series[keys[j]] else { continue }
                let ra = returns(a), rb = returns(b)
                let n = Swift.min(ra.count, rb.count)
                guard n > 2 else { continue }
                result["\(keys[i])|\(keys[j])"] = pearson(Array(ra.prefix(n)), Array(rb.prefix(n)))
            }
        }
        return result
    }

    private static func returns(_ series: [Double]) -> [Double] {
        guard series.count > 1 else { return [] }
        var out: [Double] = []
        out.reserveCapacity(series.count - 1)
        for index in 1..<series.count where series[index - 1] != 0 {
            out.append(series[index] / series[index - 1] - 1)
        }
        return out
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Swift.min(a.count, b.count)
        guard n > 1 else { return 0 }
        let meanA = Statistics.mean(Array(a.prefix(n)))
        let meanB = Statistics.mean(Array(b.prefix(n)))
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for index in 0..<n {
            let da = a[index] - meanA, db = b[index] - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }
        let denominator = (varianceA * varianceB).squareRoot()
        return denominator > 0 ? covariance / denominator : 0
    }
}
