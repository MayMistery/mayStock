import Foundation

/// One optimise-then-trade cycle.
public struct WalkForwardFold: Sendable, Identifiable {
    public let id: Int
    public let inSampleStart: Date
    public let inSampleEnd: Date
    public let outOfSampleStart: Date
    public let outOfSampleEnd: Date
    public let parameters: [String: Double]
    public let inSample: BacktestMetrics
    public let outOfSample: BacktestMetrics
    public let outOfSampleTrades: [BacktestTrade]
    public let outOfSampleEquity: [EquityPoint]
    /// Bars removed from the end of the fitting window because the test's
    /// indicators are primed on them.
    public let purgedBars: Int
    /// Further bars left as a buffer for serial correlation.
    public let embargoedBars: Int

    public init(
        id: Int, inSampleStart: Date, inSampleEnd: Date,
        outOfSampleStart: Date, outOfSampleEnd: Date,
        parameters: [String: Double], inSample: BacktestMetrics, outOfSample: BacktestMetrics,
        outOfSampleTrades: [BacktestTrade], outOfSampleEquity: [EquityPoint],
        purgedBars: Int = 0, embargoedBars: Int = 0
    ) {
        self.id = id
        self.inSampleStart = inSampleStart
        self.inSampleEnd = inSampleEnd
        self.outOfSampleStart = outOfSampleStart
        self.outOfSampleEnd = outOfSampleEnd
        self.parameters = parameters
        self.inSample = inSample
        self.outOfSample = outOfSample
        self.outOfSampleTrades = outOfSampleTrades
        self.outOfSampleEquity = outOfSampleEquity
        self.purgedBars = purgedBars
        self.embargoedBars = embargoedBars
    }

    /// How much of the fitted edge survived contact with unseen data.
    public var efficiency: Double {
        let fitted = inSample.totalReturnPct
        guard abs(fitted) > 1e-9 else { return outOfSample.totalReturnPct > 0 ? 1 : 0 }
        return outOfSample.totalReturnPct / fitted
    }

    public var parameterSummary: String {
        parameters.keys.sorted()
            .map { "\($0)=\(PriceFormatter.plain(parameters[$0] ?? 0))" }
            .joined(separator: " ")
    }
}

public struct WalkForwardResult: Sendable {
    public let folds: [WalkForwardFold]
    /// Out-of-sample periods stitched together — the only equity curve here
    /// that represents money you could actually have made.
    public let stitchedEquity: [EquityPoint]
    public let stitchedMetrics: BacktestMetrics
    public let objective: OptimizationObjective
    public let totalTrials: Int
    public let warnings: [String]

    public init(
        folds: [WalkForwardFold], stitchedEquity: [EquityPoint],
        stitchedMetrics: BacktestMetrics, objective: OptimizationObjective,
        totalTrials: Int, warnings: [String]
    ) {
        self.folds = folds
        self.stitchedEquity = stitchedEquity
        self.stitchedMetrics = stitchedMetrics
        self.objective = objective
        self.totalTrials = totalTrials
        self.warnings = warnings
    }

    /// Mean out-of-sample return divided by mean in-sample return. Below 0.5
    /// is the accepted line for "the parameters were fitted to history".
    public var efficiency: Double {
        guard !folds.isEmpty else { return 0 }
        let fitted = folds.map(\.inSample.totalReturnPct).reduce(0, +) / Double(folds.count)
        let live = folds.map(\.outOfSample.totalReturnPct).reduce(0, +) / Double(folds.count)
        guard abs(fitted) > 1e-9 else { return live > 0 ? 1 : 0 }
        return live / fitted
    }

    public var profitableFolds: Int {
        folds.filter { $0.outOfSample.totalReturnPct > 0 }.count
    }

    /// Plain-language verdict. Deliberately blunt: a walk-forward that fails is
    /// the most useful result this tool produces.
    public var verdict: String {
        guard !folds.isEmpty else { return "数据不足，无法做走向前验证" }
        let consistency = Double(profitableFolds) / Double(folds.count)
        if stitchedMetrics.tradeCount == 0 { return "样本外没有任何交易，无从判断" }
        if stitchedMetrics.totalReturnPct <= 0 {
            return "样本外整体亏损 —— 参数是拟合出来的，不要投入真金"
        }
        if efficiency < 0.5 {
            return "样本外仅保留 \(PriceFormatter.percent(efficiency * 100)) 的样本内收益，"
                + "衰减过大，属于过拟合"
        }
        if consistency < 0.6 {
            return "仅 \(profitableFolds)/\(folds.count) 折样本外盈利，结论不稳定"
        }
        return "\(profitableFolds)/\(folds.count) 折样本外盈利，"
            + "效率 \(PriceFormatter.ratio(efficiency)) —— 在可检验范围内成立"
    }
}

/// Rolling optimise-then-trade validation.
///
/// The single most useful thing this codebase does. A plain backtest asks
/// "what were the best parameters for this history?" — a question whose answer
/// is always flattering and never actionable. Walk-forward asks the real one:
/// *if I had fitted parameters on data available at the time, and then traded
/// the next stretch blind, what would have happened?*
///
/// Published research puts the typical out-of-sample degradation around 26%,
/// and an efficiency ratio below 0.5 at "the system memorised history".
public struct WalkForwardAnalysis: Sendable {
    public let strategy: CompiledStrategy
    public let config: BacktestConfig
    public let objective: OptimizationObjective
    /// Number of optimise/trade cycles.
    public let folds: Int
    /// Share of each cycle spent fitting; the rest is traded blind.
    public let inSampleFraction: Double
    /// Extra bars dropped from the end of the fitting window, on top of the
    /// indicator lookback that is always purged.
    ///
    /// The embargo exists because purging only removes the bars the test
    /// *mechanically* depends on. Prices are serially correlated, so the bars
    /// either side of the boundary describe nearly the same market state, and
    /// parameters fitted right up to the edge are fitted to the test.
    /// Expressed as a share of each fold, following López de Prado's 1%.
    public let embargoFraction: Double

    public init(
        strategy: CompiledStrategy,
        config: BacktestConfig = BacktestConfig(),
        objective: OptimizationObjective = OptimizationObjective(),
        folds: Int = 4,
        inSampleFraction: Double = 0.7,
        embargoFraction: Double = 0.01
    ) {
        self.strategy = strategy
        self.config = config
        self.objective = objective
        self.folds = Swift.max(folds, 1)
        self.inSampleFraction = Swift.min(Swift.max(inSampleFraction, 0.3), 0.9)
        self.embargoFraction = Swift.min(Swift.max(embargoFraction, 0), 0.2)
    }

    public func run(
        candles: [Candle],
        grid: ParameterGrid? = nil,
        limit: Int = 5_000,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> WalkForwardResult {
        let searchGrid = grid ?? ParameterGrid(manifest: strategy.manifest)
        var warnings: [String] = []
        let warmup = strategy.warmupBars

        // Each fold needs warm-up plus a tradeable in-sample and out-of-sample
        // stretch; below that the exercise is theatre.
        let usable = candles.count - warmup
        let perFold = usable / folds
        guard perFold > warmup + 40 else {
            return WalkForwardResult(
                folds: [], stitchedEquity: [], stitchedMetrics: .empty,
                objective: objective, totalTrials: 0,
                warnings: ["历史长度不足以切成 \(folds) 折（每折至少需要 \(warmup + 40) 根 K 线）"])
        }

        var completed: [WalkForwardFold] = []
        var stitched: [EquityPoint] = []
        var runningEquity = config.initialCapital
        var trials = 0

        for index in 0..<folds {
            onProgress?(index + 1, folds)
            let foldStart = index * perFold
            let foldEnd = Swift.min(foldStart + perFold, candles.count)
            let split = foldStart + Int(Double(foldEnd - foldStart) * inSampleFraction)
            guard split - foldStart > warmup + 10, foldEnd - split > warmup + 10 else { continue }


            // Purge, then embargo, then test.
            //
            // The out-of-sample slice has to carry its own warm-up so that
            // indicators are primed exactly as they would be live — which means
            // the bars immediately before the split feed the test's first
            // signals. Fitting on those same bars is the textbook leak: the
            // training set contains observations the test set depends on.
            //
            // So the fitting window stops `warmup` bars short of them (the
            // purge), and stops another `embargo` bars short of that, because
            // purging only removes what the test mechanically needs and prices
            // either side of a boundary still describe the same market.
            let embargo = Int(Double(perFold) * embargoFraction)
            let fitEnd = split - warmup - embargo
            guard fitEnd - foldStart > warmup + 10 else { continue }

            let inSampleCandles = Array(candles[foldStart..<fitEnd])
            let outStart = Swift.max(split - warmup, 0)
            let outOfSampleCandles = Array(candles[outStart..<foldEnd])

            // 1. Fit on the in-sample stretch only. External series are sliced
            //    in lockstep — a shifted series would silently corrupt signals.
            var inSampleConfig = config.slicing(foldStart..<fitEnd)
            inSampleConfig.initialCapital = runningEquity
            var foldConfig = config.slicing(outStart..<foldEnd)
            foldConfig.initialCapital = runningEquity
            let optimiser = StrategyOptimizer(
                strategy: strategy, config: inSampleConfig, objective: objective)
            let search = optimiser.run(candles: inSampleCandles, grid: searchGrid, limit: limit)
            trials += search.evaluated
            guard let winner = search.best ?? search.candidates.first else { continue }

            // 2. Trade the next stretch blind with those parameters.
            guard let fitted = try? strategy.with(parameterValues: winner.parameters)
            else { continue }
            guard let outResult = try? BacktestEngine(strategy: fitted, config: foldConfig)
                .run(candles: outOfSampleCandles) else { continue }

            completed.append(WalkForwardFold(
                id: index,
                inSampleStart: inSampleCandles.first?.ts ?? Date(),
                inSampleEnd: inSampleCandles.last?.ts ?? Date(),
                outOfSampleStart: outResult.start,
                outOfSampleEnd: outResult.end,
                parameters: winner.parameters,
                inSample: winner.metrics,
                outOfSample: outResult.metrics,
                outOfSampleTrades: outResult.trades,
                outOfSampleEquity: outResult.equityCurve,
                purgedBars: warmup,
                embargoedBars: embargo))

            stitched.append(contentsOf: outResult.equityCurve)
            runningEquity = outResult.finalEquity
        }

        guard !completed.isEmpty else {
            return WalkForwardResult(
                folds: [], stitchedEquity: [], stitchedMetrics: .empty,
                objective: objective, totalTrials: trials,
                warnings: warnings + ["没有任何一折能同时给出样本内最优与样本外结果"])
        }

        let allTrades = completed.flatMap(\.outOfSampleTrades)
        let stitchedMetrics = BacktestMetrics(
            trades: allTrades,
            equityCurve: stitched,
            initialCapital: config.initialCapital,
            bar: strategy.market.bar,
            freeParameterCount: strategy.freeParameterCount)

        if searchGrid.size > 1 {
            warnings.append("每折在 \(searchGrid.size) 组参数中择优，共尝试 \(trials) 次")
        }
        // Stated rather than assumed. A walk-forward whose purge and embargo
        // are not written down cannot be compared with another one, and the
        // difference between them is the difference between a real
        // out-of-sample test and a slightly delayed in-sample one.
        if let first = completed.first {
            warnings.append(
                "协议：滚动窗口 \(completed.count) 折，样本内占 "
                + "\(PriceFormatter.percent(inSampleFraction * 100, decimals: 0))，"
                + "purge \(first.purgedBars) 根（测试期指标的预热窗口），"
                + "embargo \(first.embargoedBars) 根（序列相关缓冲）")
        }
        if completed.count < folds {
            warnings.append("\(folds) 折中仅 \(completed.count) 折数据充足")
        }

        return WalkForwardResult(
            folds: completed,
            stitchedEquity: stitched,
            stitchedMetrics: stitchedMetrics,
            objective: objective,
            totalTrials: trials,
            warnings: warnings)
    }
}
