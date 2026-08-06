import Foundation

// MARK: - Inputs

/// One funding settlement on a perpetual swap (OKX settles every 8h).
public struct FundingRate: Sendable, Equatable {
    public let ts: Date
    /// Fraction of notional, e.g. `0.0001` = 0.01%. Longs pay when positive.
    public let rate: Double

    public init(ts: Date, rate: Double) {
        self.ts = ts
        self.rate = rate
    }
}

public struct BacktestConfig: Sendable {
    public var initialCapital: Double
    /// Maintenance margin rate used for the swap liquidation check.
    public var maintenanceMarginRate: Double
    /// Real funding history; empty means funding is not modelled (flagged in the report).
    public var fundingRates: [FundingRate]
    /// Fees and slippage to charge when a manifest does not state its own.
    /// Defaults to a fresh OKX account (Lv1, taker) — the most expensive
    /// realistic case, so results never flatter a beginner's account.
    public var feeSchedule: OKXFeeSchedule
    /// Named non-OHLCV series from the manifest's `data` block, **already
    /// aligned to the candle array passed to `run`**. Slicing candles without
    /// slicing these identically would silently shift every signal.
    public var externalSeries: [String: [Double]]
    /// Target position per candle, supplied by an external script engine.
    /// When set it replaces expression evaluation; risk rules still apply.
    public var scriptTargets: [TradeDirection?]?

    public init(
        initialCapital: Double = 10_000,
        maintenanceMarginRate: Double = 0.005,
        fundingRates: [FundingRate] = [],
        feeSchedule: OKXFeeSchedule = OKXFeeSchedule(),
        externalSeries: [String: [Double]] = [:],
        scriptTargets: [TradeDirection?]? = nil
    ) {
        self.initialCapital = initialCapital
        self.maintenanceMarginRate = maintenanceMarginRate
        self.fundingRates = fundingRates
        self.feeSchedule = feeSchedule
        self.externalSeries = externalSeries
        self.scriptTargets = scriptTargets
    }

    /// Same configuration against a sub-range of the candles, keeping every
    /// external series in step.
    public func slicing(_ range: Range<Int>) -> BacktestConfig {
        var copy = self
        let lower = Swift.max(range.lowerBound, 0)
        copy.externalSeries = externalSeries.mapValues { series in
            let upper = Swift.min(range.upperBound, series.count)
            return lower < upper ? Array(series[lower..<upper]) : []
        }
        if let targets = scriptTargets {
            let upper = Swift.min(range.upperBound, targets.count)
            copy.scriptTargets = lower < upper ? Array(targets[lower..<upper]) : []
        }
        return copy
    }
}

// MARK: - Outputs

public enum TradeDirection: String, Sendable, Equatable, Codable {
    case long, short

    public var sign: Double { self == .long ? 1 : -1 }
    public var displayName: String { self == .long ? "多" : "空" }

    /// Direction implied by a signed size, or nil when there is none to imply.
    public init?(sign: Double) {
        if sign > 0 { self = .long } else if sign < 0 { self = .short } else { return nil }
    }
}

public enum TradeExitReason: String, Sendable, Equatable, Codable {
    case signal, stopLoss, takeProfit, trailingStop, liquidation, dailyLossHalt, endOfData

    public var displayName: String {
        switch self {
        case .signal: return "信号平仓"
        case .stopLoss: return "止损"
        case .takeProfit: return "止盈"
        case .trailingStop: return "移动止损"
        case .liquidation: return "强平"
        case .dailyLossHalt: return "日内熔断"
        case .endOfData: return "回测结束"
        }
    }
}

public struct BacktestTrade: Sendable, Equatable, Identifiable {
    public let id: Int
    public let direction: TradeDirection
    public let entryTime: Date
    public let exitTime: Date
    public let entryPrice: Double
    public let exitPrice: Double
    public let quantity: Double
    public let notional: Double
    public let grossPnL: Double
    public let fees: Double
    public let funding: Double
    public let netPnL: Double
    /// Net PnL as a fraction of the equity that existed when the trade opened.
    public let returnPct: Double
    public let bars: Int
    public let exitReason: TradeExitReason

    public var isWin: Bool { netPnL > 0 }

    public init(
        id: Int, direction: TradeDirection, entryTime: Date, exitTime: Date,
        entryPrice: Double, exitPrice: Double, quantity: Double, notional: Double,
        grossPnL: Double, fees: Double, funding: Double, netPnL: Double,
        returnPct: Double, bars: Int, exitReason: TradeExitReason
    ) {
        self.id = id
        self.direction = direction
        self.entryTime = entryTime
        self.exitTime = exitTime
        self.entryPrice = entryPrice
        self.exitPrice = exitPrice
        self.quantity = quantity
        self.notional = notional
        self.grossPnL = grossPnL
        self.fees = fees
        self.funding = funding
        self.netPnL = netPnL
        self.returnPct = returnPct
        self.bars = bars
        self.exitReason = exitReason
    }
}

public struct EquityPoint: Sendable, Equatable {
    public let ts: Date
    public let equity: Double
    public let price: Double

    public init(ts: Date, equity: Double, price: Double) {
        self.ts = ts
        self.equity = equity
        self.price = price
    }
}

public struct BacktestResult: Sendable {
    public let strategyId: String
    public let instId: String
    public let bar: BarInterval
    public let start: Date
    public let end: Date
    public let barCount: Int
    public let initialCapital: Double
    public let finalEquity: Double
    public let trades: [BacktestTrade]
    public let equityCurve: [EquityPoint]
    public let liquidations: Int
    /// Warm-up bars consumed before the first tradeable bar.
    public let warmupBars: Int
    /// True when the strategy is a swap but no funding history was supplied.
    public let fundingUnmodelled: Bool
    public let metrics: BacktestMetrics

    public init(
        strategyId: String, instId: String, bar: BarInterval, start: Date, end: Date,
        barCount: Int, initialCapital: Double, finalEquity: Double,
        trades: [BacktestTrade], equityCurve: [EquityPoint], liquidations: Int,
        warmupBars: Int, fundingUnmodelled: Bool, metrics: BacktestMetrics
    ) {
        self.strategyId = strategyId
        self.instId = instId
        self.bar = bar
        self.start = start
        self.end = end
        self.barCount = barCount
        self.initialCapital = initialCapital
        self.finalEquity = finalEquity
        self.trades = trades
        self.equityCurve = equityCurve
        self.liquidations = liquidations
        self.warmupBars = warmupBars
        self.fundingUnmodelled = fundingUnmodelled
        self.metrics = metrics
    }
}

// MARK: - Engine

/// Bar-by-bar simulator — a thin front for the Rust kernel.
///
/// Execution model (see `docs/STRATEGY.md`):
/// - signals are evaluated on the **close of bar i**, using data up to i only;
/// - the resulting order fills at the **open of bar i+1**, plus slippage;
/// - protective exits are checked against bar highs/lows, and when several
///   could have triggered inside one bar the **worst** one is assumed.
///
/// The loop that implements all of that used to live here in Swift, duplicating
/// the live runner's own copy of the signal rules. Both now call the same
/// compiled kernel function, so a backtest and a live tick cannot disagree.
/// This type survives only to keep the call sites and result types Swift code
/// already uses.
public struct BacktestEngine: Sendable {
    public let strategy: CompiledStrategy
    public let config: BacktestConfig

    public init(strategy: CompiledStrategy, config: BacktestConfig = BacktestConfig()) {
        self.strategy = strategy
        self.config = config
    }

    public func run(candles: [Candle]) throws -> BacktestResult {
        let costs = strategy.manifest.costs
            ?? config.feeSchedule.costs(for: strategy.manifest.market.instType)
        let kernelConfig = KernelBacktestConfig(
            initialCapital: config.initialCapital,
            maintenanceMarginRate: config.maintenanceMarginRate,
            fundingRates: config.fundingRates.map {
                KernelFundingRate(ts: $0.ts, rate: $0.rate)
            },
            feeBps: costs.feeBps,
            slippageBps: costs.slippageBps,
            externalSeries: config.externalSeries,
            scriptTargets: config.scriptTargets.map { targets in
                targets.map { direction in
                    switch direction {
                    case .some(.long): return 1
                    case .some(.short): return -1
                    case .none: return 0
                    }
                }
            })
        return BacktestResult(
            kernel: try strategy.kernel.backtest(candles: candles, config: kernelConfig),
            bar: strategy.manifest.market.bar)
    }
}

// MARK: - Kernel bridging

extension BacktestResult {
    /// Adopt a kernel result. Timestamps come back as epoch milliseconds, and
    /// `bar` is passed separately because the kernel reports it as a string.
    init(kernel: KernelBacktestResult, bar: BarInterval) {
        self.init(
            strategyId: kernel.strategyId,
            instId: kernel.instId,
            bar: bar,
            start: kernel.startTime,
            end: kernel.endTime,
            barCount: kernel.barCount,
            initialCapital: kernel.initialCapital,
            finalEquity: kernel.finalEquity,
            trades: kernel.trades.map(BacktestTrade.init(kernel:)),
            equityCurve: kernel.equityCurve.map {
                EquityPoint(ts: $0.time, equity: $0.equity, price: $0.price)
            },
            liquidations: kernel.liquidations,
            warmupBars: kernel.warmupBars,
            fundingUnmodelled: kernel.fundingUnmodelled,
            metrics: BacktestMetrics(kernel: kernel.metrics))
    }
}

extension BacktestTrade {
    init(kernel t: KernelTrade) {
        self.init(
            id: t.id, direction: t.direction,
            entryTime: t.entryTime, exitTime: t.exitTime,
            entryPrice: t.entryPrice, exitPrice: t.exitPrice,
            quantity: t.quantity, notional: t.notional,
            grossPnL: t.grossPnL, fees: t.fees, funding: t.funding,
            netPnL: t.netPnL, returnPct: t.returnPct, bars: t.bars,
            exitReason: TradeExitReason(rawValue: t.exitReason.rawValue) ?? .signal)
    }
}
