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

/// Why a backtest could not be set up at all.
public enum BacktestError: Error, CustomStringConvertible, Sendable, Equatable {
    /// The manifest states no costs and its venue has no cost model for its
    /// instrument, so there is nothing to charge. Simulating for free would
    /// be the optimistic reading, and optimistic readings are what make a
    /// backtest lie.
    case noCostModel(Venue, InstrumentType)

    public var description: String {
        switch self {
        case .noCostModel(let venue, let type):
            return "\(venue.displayName)没有\(type.displayName)的费率模型，清单也没有声明 costs，无法回测"
        }
    }
}

public struct BacktestConfig: Sendable {
    public var initialCapital: Double
    /// Maintenance margin rate for the liquidation check. Nil takes the
    /// instrument's documented default — OKX's tier-one rate on a perpetual,
    /// FINRA's 25% minimum on a margined stock.
    public var maintenanceMarginRate: Double?
    /// Real funding history; empty means funding is not modelled (flagged in the report).
    public var fundingRates: [FundingRate]
    /// Fees and slippage to charge when a manifest does not state its own,
    /// per venue. Defaults to a fresh OKX account (Lv1, taker) and Schwab's
    /// published equity levies — the most expensive realistic case for each,
    /// so results never flatter a beginner's account.
    public var feeSchedules: FeeSchedules
    /// Named non-OHLCV series from the manifest's `data` block, **already
    /// aligned to the candle array passed to `run`**. Slicing candles without
    /// slicing these identically would silently shift every signal.
    public var externalSeries: [String: [Double]]
    /// Target position per candle, supplied by an external script engine.
    /// When set it replaces expression evaluation; risk rules still apply.
    public var scriptTargets: [TradeDirection?]?

    public init(
        initialCapital: Double = 10_000,
        maintenanceMarginRate: Double? = nil,
        fundingRates: [FundingRate] = [],
        feeSchedules: FeeSchedules = FeeSchedules(),
        externalSeries: [String: [Double]] = [:],
        scriptTargets: [TradeDirection?]? = nil
    ) {
        self.initialCapital = initialCapital
        self.maintenanceMarginRate = maintenanceMarginRate
        self.fundingRates = fundingRates
        self.feeSchedules = feeSchedules
        self.externalSeries = externalSeries
        self.scriptTargets = scriptTargets
    }

    /// This configuration in the kernel's shape, with the cost model resolved
    /// for `manifest`.
    ///
    /// The one place the fee schedule meets the manifest: the kernel prefers
    /// the manifest's own `costs`, and is handed the venue schedule's model
    /// for the instrument as the fallback. A manifest with neither is refused
    /// here, before any bar is simulated.
    public func kernelConfig(for manifest: StrategyManifest) throws -> KernelBacktestConfig {
        let market = manifest.market
        let fallback = feeSchedules.schedule(for: market.venue).costs(for: market.instType)
        guard manifest.costs != nil || fallback != nil else {
            throw BacktestError.noCostModel(market.venue, market.instType)
        }
        return KernelBacktestConfig(
            initialCapital: initialCapital,
            maintenanceMarginRate: maintenanceMarginRate,
            fundingRates: fundingRates.map { KernelFundingRate(ts: $0.ts, rate: $0.rate) },
            fees: fallback?.fees,
            slippageBps: fallback?.slippageBps,
            externalSeries: externalSeries,
            scriptTargets: scriptTargets.map { targets in
                targets.map { direction in
                    switch direction {
                    case .some(.long): return 1
                    case .some(.short): return -1
                    case .none: return 0
                    }
                }
            })
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
    /// An option contract reached settlement and paid its intrinsic value.
    case expiry

    public var displayName: String { KernelExitReason(rawValue: rawValue)?.displayName ?? rawValue }
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
    /// Net PnL as a **percentage** of the equity that existed when the trade
    /// opened — 5.0 means +5%.
    public let returnPct: Double

    /// The same figure as a fraction, for anything that compounds it.
    public var returnFraction: Double { returnPct / 100 }
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
    /// The market the run was on — instrument, bar and venue. The venue is
    /// what decides how the curve annualises, so it travels with the result.
    public let market: StrategyMarket
    public var instId: String { market.instId }
    public var bar: BarInterval { market.bar }
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
    /// Gaps, duplicates and malformed bars in the history this ran over.
    ///
    /// A backtest over holed history is not so much wrong as *less than it
    /// appears*: a 60-bar lookback spanning a gap covers more than 60 bars of
    /// market. Live refuses such a series outright; a backtest cannot refuse
    /// retrospectively, so it reports.
    public let dataQuality: KernelDataQuality?
    public let metrics: BacktestMetrics

    /// What the drawdown looks like across plausible orderings of these same
    /// trades. Nil when there are too few trades to describe a distribution.
    ///
    /// Computed lazily: the resampling is thousands of passes over the trade
    /// list, and most callers of a `BacktestResult` never ask.
    public var drawdownDistribution: KernelResampleReport? {
        // Fractions, not percentages: these get compounded.
        let returns = trades.map(\.returnFraction)
        guard returns.count >= 10 else { return nil }
        return (try? TradingKernel.resampleTrades(returns: returns)) ?? nil
    }

    public init(
        strategyId: String, market: StrategyMarket, start: Date, end: Date,
        barCount: Int, initialCapital: Double, finalEquity: Double,
        trades: [BacktestTrade], equityCurve: [EquityPoint], liquidations: Int,
        warmupBars: Int, fundingUnmodelled: Bool,
        dataQuality: KernelDataQuality? = nil, metrics: BacktestMetrics
    ) {
        self.strategyId = strategyId
        self.market = market
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
        self.dataQuality = dataQuality
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
        let kernelConfig = try config.kernelConfig(for: strategy.manifest)
        return BacktestResult(
            kernel: try strategy.kernel.backtest(candles: candles, config: kernelConfig),
            market: strategy.manifest.market)
    }
}

// MARK: - Kernel bridging

extension BacktestResult {
    /// Adopt a kernel result. Timestamps come back as epoch milliseconds, and
    /// the market is passed separately because the kernel reports the bar as
    /// a string and the venue not at all.
    init(kernel: KernelBacktestResult, market: StrategyMarket) {
        self.init(
            strategyId: kernel.strategyId,
            market: market,
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
            dataQuality: kernel.dataQuality,
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
