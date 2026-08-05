import Foundation

/// Forward-return statistics for one signal at one horizon.
public struct SignalIC: Sendable, Equatable {
    public let horizonBars: Int
    public let observations: Int
    /// Pearson correlation between the signal and the forward return.
    public let pearson: Double
    /// Spearman (rank) correlation — robust to the fat tails and outliers that
    /// dominate funding rates and volume series.
    public let spearman: Double
    /// Naive t-statistic of the Spearman IC, treating every bar as independent.
    /// **Almost always overstated** — see `adjustedTStatistic`.
    public let tStatistic: Double
    /// Mean forward return (%) in each signal quintile, lowest signal first.
    public let quintileReturns: [Double]

    public init(
        horizonBars: Int, observations: Int, pearson: Double,
        spearman: Double, tStatistic: Double, quintileReturns: [Double]
    ) {
        self.horizonBars = horizonBars
        self.observations = observations
        self.pearson = pearson
        self.spearman = spearman
        self.tStatistic = tStatistic
        self.quintileReturns = quintileReturns
    }

    /// Top-quintile minus bottom-quintile forward return, in percent. The
    /// number a long/short version of the signal would try to harvest.
    public var spread: Double {
        guard let first = quintileReturns.first, let last = quintileReturns.last else { return 0 }
        return last - first
    }

    /// Monotone quintiles are what separates a real signal from a lucky split.
    public var isMonotonic: Bool {
        guard quintileReturns.count > 2 else { return false }
        let rising = zip(quintileReturns, quintileReturns.dropFirst()).allSatisfy { $0 <= $1 }
        let falling = zip(quintileReturns, quintileReturns.dropFirst()).allSatisfy { $0 >= $1 }
        return rising || falling
    }

    /// Consecutive `h`-bar forward returns share `h − 1` bars, so the sample is
    /// nowhere near as large as the bar count suggests. The number of genuinely
    /// independent observations is roughly `n / h`.
    public var effectiveObservations: Int {
        Swift.max(observations / Swift.max(horizonBars, 1), 1)
    }

    /// t-statistic corrected for that overlap (`t / √h`).
    ///
    /// **This is the number to read.** Skipping this correction is the single
    /// most common way a crypto "signal study" manufactures significance: with
    /// 7-day forward returns on daily bars, the naive t is inflated by ~2.6×,
    /// which turns noise into a publishable-looking result.
    public var adjustedTStatistic: Double {
        tStatistic / Double(Swift.max(horizonBars, 1)).squareRoot()
    }

    public var isSignificant: Bool { abs(adjustedTStatistic) > 2 }

    /// Threshold |t| must clear once `trials` signal/horizon pairs were tested.
    /// Testing 18 combinations and reporting the best is a lottery, not research.
    public static func multipleTestingThreshold(trials: Int) -> Double {
        guard trials > 1 else { return 2 }
        // Šidák-corrected two-sided 5% level, normal approximation.
        return abs(Statistics.inverseNormalCDF(1 - (1 - pow(0.95, 1 / Double(trials))) / 2))
    }
}

/// Does a signal contain information about future returns?
///
/// A strategy backtest answers this badly: it collapses hundreds of bars into a
/// handful of trades, so a genuinely predictive signal and a worthless one can
/// produce the same five-trade P&L. Correlating the signal against forward
/// returns uses *every* bar, which is why it is the first thing a research desk
/// computes and the last thing a retail backtester ever sees.
///
/// **No look-ahead**: the signal at bar `i` is paired with the return from bar
/// `i` to bar `i + horizon`, both measured on closes, so the signal always
/// predates the return it is scored against.
public enum SignalAnalysis {

    public static func informationCoefficient(
        signal: [Double], candles: [Candle], horizonBars: Int
    ) -> SignalIC {
        let closes = candles.map(\.close)
        var signalValues: [Double] = []
        var forwardReturns: [Double] = []

        let usable = Swift.min(signal.count, closes.count) - horizonBars
        if usable > 0 {
            for index in 0..<usable {
                let value = signal[index]
                let now = closes[index]
                let later = closes[index + horizonBars]
                guard !value.isNaN, now > 0, later > 0 else { continue }
                signalValues.append(value)
                forwardReturns.append((later / now - 1) * 100)
            }
        }

        guard signalValues.count > 10 else {
            return SignalIC(horizonBars: horizonBars, observations: signalValues.count,
                            pearson: 0, spearman: 0, tStatistic: 0, quintileReturns: [])
        }

        let pearson = PortfolioBacktest.pearson(signalValues, forwardReturns)
        let spearman = PortfolioBacktest.pearson(ranks(of: signalValues), ranks(of: forwardReturns))

        // t = r √(n−2) / √(1−r²) — the standard significance test for a correlation.
        let n = Double(signalValues.count)
        let denominator = (1 - spearman * spearman).squareRoot()
        let tStatistic = denominator > 1e-12 ? spearman * (n - 2).squareRoot() / denominator : 0

        return SignalIC(
            horizonBars: horizonBars,
            observations: signalValues.count,
            pearson: pearson,
            spearman: spearman,
            tStatistic: tStatistic,
            quintileReturns: quintiles(signal: signalValues, forward: forwardReturns, buckets: 5))
    }

    /// Mean forward return per signal bucket, lowest signal value first.
    public static func quintiles(signal: [Double], forward: [Double], buckets: Int) -> [Double] {
        guard signal.count == forward.count, signal.count >= buckets * 2 else { return [] }
        let order = signal.indices.sorted { signal[$0] < signal[$1] }
        let size = order.count / buckets
        guard size > 0 else { return [] }

        return (0..<buckets).map { bucket in
            let lower = bucket * size
            let upper = bucket == buckets - 1 ? order.count : (bucket + 1) * size
            let slice = order[lower..<upper]
            guard !slice.isEmpty else { return 0 }
            return slice.reduce(0.0) { $0 + forward[$1] } / Double(slice.count)
        }
    }

    /// Average ranks, with ties sharing the mean rank.
    public static func ranks(of values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var result = [Double](repeating: 0, count: values.count)
        var index = 0
        while index < order.count {
            var end = index
            while end + 1 < order.count, values[order[end + 1]] == values[order[index]] { end += 1 }
            let shared = Double(index + end) / 2 + 1
            for position in index...end { result[order[position]] = shared }
            index = end + 1
        }
        return result
    }

    /// Plain-language reading of an IC result, judged on the corrected statistic.
    public static func verdict(_ ic: SignalIC, trials: Int = 1) -> String {
        guard ic.observations > 10 else { return "样本太少，无法判断" }
        let adjusted = abs(ic.adjustedTStatistic)
        let threshold = SignalIC.multipleTestingThreshold(trials: trials)

        if adjusted <= 2 {
            return "不显著（重叠修正后 |t| = \(PriceFormatter.decimals(adjusted, 2)) ≤ 2，"
                + "有效样本仅 \(ic.effectiveObservations)）—— 该信号对未来收益没有可辨别的信息"
        }
        if adjusted <= threshold {
            return "修正后 |t| = \(PriceFormatter.decimals(adjusted, 2))，"
                + "但一共试了 \(trials) 个信号×窗口组合，多重检验门槛是 "
                + "\(PriceFormatter.decimals(threshold, 2)) —— 尚不能排除是撞上的"
        }
        let direction = ic.spearman > 0 ? "同向" : "反向"
        let monotone = ic.isMonotonic ? "且分位收益单调" : "但分位收益不单调，边际可能来自个别极端值"
        return "\(direction)显著（修正后 t = \(PriceFormatter.decimals(ic.adjustedTStatistic, 2))，"
            + "有效样本 \(ic.effectiveObservations)）\(monotone)，"
            + "首尾分位差 \(PriceFormatter.decimals(ic.spread, 3))%"
    }
}
