import Foundation

// MARK: - Objective

/// What "better" means when ranking parameter sets.
public struct OptimizationObjective: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case dailyReturn
        case sharpe
        case sortino
        case calmar
        case totalReturn
        case profitFactor
        /// Return per unit of drawdown, floored so a zero-drawdown fluke on a
        /// two-trade sample cannot win by dividing by almost nothing.
        case returnOverDrawdown

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .dailyReturn: return "日均收益"
            case .sharpe: return "夏普"
            case .sortino: return "索提诺"
            case .calmar: return "卡玛"
            case .totalReturn: return "总收益"
            case .profitFactor: return "盈亏比"
            case .returnOverDrawdown: return "收益/回撤"
            }
        }

        public func score(_ metrics: BacktestMetrics) -> Double {
            let value: Double
            switch self {
            case .dailyReturn: value = metrics.dailyReturnPct
            case .sharpe: value = metrics.sharpe
            case .sortino: value = metrics.sortino
            case .calmar: value = metrics.calmar
            case .totalReturn: value = metrics.totalReturnPct
            case .profitFactor: value = metrics.profitFactor
            case .returnOverDrawdown:
                value = metrics.totalReturnPct / Swift.max(metrics.maxDrawdownPct, 1)
            }
            return value.isFinite ? value : 0
        }
    }

    public var kind: Kind
    /// Reject candidates whose drawdown exceeds this, however good the return.
    public var maxDrawdownPct: Double?
    /// Reject candidates with too few trades to mean anything.
    public var minTrades: Int
    /// Reject candidates below this geometric daily return.
    public var minDailyReturnPct: Double?
    /// Reject candidates that merely tracked the asset.
    public var mustBeatBuyHold: Bool

    public init(
        kind: Kind = .calmar,
        maxDrawdownPct: Double? = nil,
        minTrades: Int = 10,
        minDailyReturnPct: Double? = nil,
        mustBeatBuyHold: Bool = false
    ) {
        self.kind = kind
        self.maxDrawdownPct = maxDrawdownPct
        self.minTrades = minTrades
        self.minDailyReturnPct = minDailyReturnPct
        self.mustBeatBuyHold = mustBeatBuyHold
    }

    /// Why a candidate was rejected, or nil when it passed.
    public func rejection(for metrics: BacktestMetrics) -> String? {
        if metrics.tradeCount < minTrades {
            return "交易仅 \(metrics.tradeCount) 笔（要求 ≥ \(minTrades)）"
        }
        if let limit = maxDrawdownPct, metrics.maxDrawdownPct > limit {
            return "回撤 \(PriceFormatter.percent(metrics.maxDrawdownPct, decimals: 1)) 超限"
        }
        if let floor = minDailyReturnPct, metrics.dailyReturnPct < floor {
            return "日均 \(PriceFormatter.percent(metrics.dailyReturnPct, decimals: 3)) 未达标"
        }
        if mustBeatBuyHold, !metrics.beatsBuyHold {
            return "跑输买入持有"
        }
        return nil
    }
}

// MARK: - Search space

/// The grid a search will walk.
public struct ParameterGrid: Sendable {
    public private(set) var axes: [(name: String, values: [Double])]

    public init(axes: [(name: String, values: [Double])]) {
        self.axes = axes.filter { !$0.values.isEmpty }
    }

    /// Build a grid from the parameters' declared `min`/`max`/`step`.
    /// Parameters without a range are held fixed — a manifest that doesn't say
    /// how far a knob may turn doesn't get it turned.
    public init(manifest: StrategyManifest, pointsPerAxis: Int = 8) {
        var axes: [(String, [Double])] = []
        for parameter in manifest.params.items {
            guard let lower = parameter.minimum, let upper = parameter.maximum, upper > lower
            else { continue }
            let step = parameter.step ?? ParameterGrid.naturalStep(
                lower: lower, upper: upper, points: pointsPerAxis)
            var values: [Double] = []
            var value = lower
            while value <= upper + 1e-9 {
                values.append((value * 1e6).rounded() / 1e6)
                value += step
            }
            if values.last != upper { values.append(upper) }
            axes.append((parameter.name, values))
        }
        self.init(axes: axes)
    }

    /// Integer-looking ranges step by whole numbers; fractional ones don't.
    static func naturalStep(lower: Double, upper: Double, points: Int) -> Double {
        let span = upper - lower
        let rough = span / Double(Swift.max(points - 1, 1))
        if span >= Double(points), rough >= 1 { return rough.rounded() }
        let magnitude = pow(10, floor(log10(Swift.max(rough, 1e-9))))
        let normalised = rough / magnitude
        let nice: Double = normalised < 1.5 ? 1 : normalised < 3.5 ? 2 : normalised < 7.5 ? 5 : 10
        return nice * magnitude
    }

    public var size: Int {
        axes.reduce(1) { $0 * $1.values.count }
    }

    public var isEmpty: Bool { axes.isEmpty }

    /// Cartesian product, as parameter dictionaries.
    public func combinations(limit: Int = 50_000) -> [[String: Double]] {
        guard !axes.isEmpty else { return [] }
        var result: [[String: Double]] = [[:]]
        for axis in axes {
            var expanded: [[String: Double]] = []
            expanded.reserveCapacity(result.count * axis.values.count)
            for partial in result {
                for value in axis.values {
                    var next = partial
                    next[axis.name] = value
                    expanded.append(next)
                    if expanded.count >= limit { return expanded }
                }
            }
            result = expanded
        }
        return result
    }

    public var description: String {
        axes.map { "\($0.name)×\($0.values.count)" }.joined(separator: " · ")
    }
}

// MARK: - Results

public struct OptimizationCandidate: Sendable, Identifiable {
    public let id: Int
    public let parameters: [String: Double]
    public let metrics: BacktestMetrics
    public let score: Double
    public let rejection: String?

    public var passes: Bool { rejection == nil }

    public var parameterSummary: String {
        parameters.keys.sorted()
            .map { "\($0)=\(PriceFormatter.plain(parameters[$0] ?? 0))" }
            .joined(separator: " ")
    }
}

public struct OptimizationResult: Sendable {
    public let objective: OptimizationObjective
    public let gridSize: Int
    public let evaluated: Int
    public let candidates: [OptimizationCandidate]
    public let warnings: [String]
    /// Whether the winner survives having been chosen from `evaluated` tries.
    public let deflatedSharpe: KernelDeflatedSharpe?
    /// Whether the *search* found anything, as opposed to the winner being
    /// the luckiest draw. Nil when there were too few comparable candidates.
    public let overfitProbability: KernelOverfitProbability?

    public var best: OptimizationCandidate? { candidates.first { $0.passes } }
    public var passing: [OptimizationCandidate] { candidates.filter(\.passes) }

    /// Sharpe you would expect the luckiest of `evaluated` coin-flipping
    /// strategies to show, purely by chance. If the best in-sample Sharpe is
    /// not comfortably above this, the search found noise.
    public var luckThresholdSharpe: Double {
        guard let sample = candidates.first?.metrics else { return 0 }
        let bars = Swift.max(sample.spanDays, 1)
        return TradingKernel.expectedMaxSharpeUnderNull(trials: evaluated, years: bars / 365.25)
    }
}

// MARK: - Optimizer

/// Grid search with the multiple-testing problem taken seriously.
///
/// Searching 5,000 parameter sets and reporting the best one is not research,
/// it is a lottery draw with the losing tickets thrown away. This optimizer
/// therefore always reports how many combinations were tried and what Sharpe
/// the luckiest of them would be expected to reach with **no edge at all** —
/// and `WalkForward` exists because even that check is not sufficient.
public struct StrategyOptimizer: Sendable {
    public let strategy: CompiledStrategy
    public let config: BacktestConfig
    public let objective: OptimizationObjective

    public init(
        strategy: CompiledStrategy,
        config: BacktestConfig = BacktestConfig(),
        objective: OptimizationObjective = OptimizationObjective()
    ) {
        self.strategy = strategy
        self.config = config
        self.objective = objective
    }

    public func run(
        candles: [Candle],
        grid: ParameterGrid? = nil,
        limit: Int = 20_000,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> OptimizationResult {
        let searchGrid = grid ?? ParameterGrid(manifest: strategy.manifest)
        var warnings: [String] = []
        var deflated: KernelDeflatedSharpe?
        var overfit: KernelOverfitProbability?

        guard !searchGrid.isEmpty else {
            return OptimizationResult(
                objective: objective, gridSize: 0, evaluated: 0, candidates: [],
                warnings: ["策略没有声明带 min/max 的参数，无可寻优空间"],
                deflatedSharpe: nil, overfitProbability: nil)
        }
        if searchGrid.size > limit {
            warnings.append("搜索空间 \(searchGrid.size) 组，超出上限，仅评估前 \(limit) 组")
        }

        let combinations = searchGrid.combinations(limit: limit)

        // One kernel call for the whole sweep.
        //
        // This used to be a Swift loop that, per grid point, re-encoded the
        // manifest, re-parsed every expression, ran the backtest and decoded a
        // full result — six thousand equity points and every trade — in order
        // to read six numbers off it. A parameter value does not change the
        // parsed expression, so the kernel clones the compiled strategy and
        // swaps the map instead, evaluates the grid across every core, and
        // returns metrics only.
        let costs = strategy.manifest.costs
            ?? config.feeSchedule.costs(for: strategy.manifest.market.instType)
        let outcome: KernelSweepOutcome
        do {
            outcome = try strategy.kernel.optimize(
                candles: candles,
                grid: combinations,
                config: KernelBacktestConfig(
                    initialCapital: config.initialCapital,
                    maintenanceMarginRate: config.maintenanceMarginRate,
                    fundingRates: config.fundingRates.map {
                        KernelFundingRate(ts: $0.ts, rate: $0.rate)
                    },
                    feeBps: costs.feeBps,
                    slippageBps: costs.slippageBps,
                    externalSeries: config.externalSeries,
                    scriptTargets: nil))
        } catch {
            return OptimizationResult(
                objective: objective, gridSize: searchGrid.size, evaluated: 0,
                candidates: [], warnings: warnings + ["寻优失败：\(error)"],
                deflatedSharpe: nil, overfitProbability: nil)
        }
        onProgress?(combinations.count, combinations.count)
        deflated = outcome.deflated
        overfit = outcome.overfit

        if outcome.skipped > 0 {
            warnings.append(
                "\(outcome.skipped) 组参数无法求值已跳过（多半是周期落在合法范围外）")
        }

        // Scoring and the constraint checks stay here: they are policy over
        // metrics the kernel already computed, not a second computation.
        var candidates = outcome.candidates.map { summary -> OptimizationCandidate in
            let metrics = BacktestMetrics(kernel: summary.metrics)
            return OptimizationCandidate(
                id: summary.index,
                parameters: summary.params,
                metrics: metrics,
                score: objective.kind.score(metrics),
                rejection: objective.rejection(for: metrics))
        }

        candidates.sort { lhs, rhs in
            if lhs.passes != rhs.passes { return lhs.passes }
            return lhs.score > rhs.score
        }

        // Multiple testing: with enough tries, something always looks good.
        if let best = candidates.first(where: { $0.passes }) {
            let span = Swift.max(best.metrics.spanDays, 1) / 365.25
            let luck = TradingKernel.expectedMaxSharpeUnderNull(
                trials: candidates.count, years: span)
            if best.metrics.sharpe <= luck {
                warnings.append(
                    "最优夏普 \(PriceFormatter.ratio(best.metrics.sharpe)) 未超过"
                    + "「\(candidates.count) 次尝试下纯运气的期望最好值 \(PriceFormatter.ratio(luck))」"
                    + " —— 这次搜索没有找到边际，只是挑出了最幸运的噪声")
            }
            let perParameter = Double(best.metrics.tradeCount) / Double(strategy.freeParameterCount)
            if perParameter < 30 {
                warnings.append(
                    "每个自由参数仅 \(PriceFormatter.decimals(perParameter, 1)) 笔交易，"
                    + "低于 30 笔的统计下限")
            }
            // Printed whether it passes or fails. Reporting only failures is
            // the same silence-reads-as-approval trap fixed elsewhere: a reader
            // who sees no line cannot tell "significant" from "never computed",
            // and the second is far more common than the first.
            if let deflated {
                warnings.append(
                    deflated.significant
                        ? "去膨胀夏普显著性 "
                            + "\(PriceFormatter.percent(deflated.probability * 100, decimals: 0))"
                            + "（≥ 95%）—— 试过 \(candidates.count) 组参数后仍可与运气区分"
                        : "去膨胀夏普显著性仅 "
                            + "\(PriceFormatter.percent(deflated.probability * 100, decimals: 0))"
                            + "，低于 95% —— 考虑到试过 \(candidates.count) 组参数，"
                            + "这个结果无法与运气区分")
            } else {
                warnings.append(
                    "去膨胀夏普无法计算（样本或收益序列不足）—— 这不是通过，是没测出来")
            }
        } else {
            warnings.append("没有任何参数组同时满足全部约束")
        }

        if let overfit, overfit.isOverfit {
            warnings.append(
                "回测过拟合概率 \(PriceFormatter.percent(overfit.pbo * 100, decimals: 0))"
                + " —— 样本内最优在样本外多半落到中位数以下，问题出在这次搜索本身，"
                + "而不是它挑中的那组参数")
        }

        return OptimizationResult(
            objective: objective,
            gridSize: searchGrid.size,
            evaluated: candidates.count,
            candidates: candidates,
            warnings: warnings,
            deflatedSharpe: deflated,
            overfitProbability: overfit)
    }
}

// MARK: - Statistics

public enum Statistics {

    // MARK: Descriptive
    //
    // Deliberately *not* part of the trading kernel: these are the ordinary
    // building blocks of correlation, information-coefficient and factor work.
    // The performance metrics a backtest reports live in the kernel, where
    // there is exactly one Sharpe and one drawdown.

    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Sample standard deviation (n−1), the convention for return series.
    public static func standardDeviation(_ values: [Double], mean m: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let sumSquares = values.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (sumSquares / Double(values.count - 1)).squareRoot()
    }

    public static func standardDeviation(_ values: [Double]) -> Double {
        standardDeviation(values, mean: mean(values))
    }

    /// Root-mean-square of the negative values only — the Sortino denominator.
    public static func downsideDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let sumSquares = values.reduce(0) { $0 + Swift.min($1, 0) * Swift.min($1, 0) }
        return (sumSquares / Double(values.count - 1)).squareRoot()
    }

    /// Inverse standard-normal CDF (Acklam's rational approximation,
    /// ~1e-9 absolute error) — needed for the expected-maximum calculation.
    public static func inverseNormalCDF(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return p <= 0 ? -Double.infinity : .infinity }
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                 -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                 3.754408661907416e+00]
        let plow = 0.02425, phigh = 1 - plow

        if p < plow {
            let q = (-2 * log(p)).squareRoot()
            return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        if p > phigh {
            let q = (-2 * log(1 - p)).squareRoot()
            return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        let q = p - 0.5
        let r = q * q
        return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
            / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
    }

}
