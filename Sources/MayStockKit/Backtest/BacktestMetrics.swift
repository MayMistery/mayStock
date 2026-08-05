import Foundation

/// Performance statistics for one backtest run.
///
/// Metric set follows what Freqtrade and Jesse report — the vocabulary traders
/// already read — plus a buy-and-hold benchmark so a strategy is judged against
/// simply owning the asset, not against zero.
public struct BacktestMetrics: Sendable, Equatable {
    // Returns
    public let totalReturnPct: Double
    public let absolutePnL: Double
    /// Compound annual growth rate. Meaningless on very short windows —
    /// check `annualisationReliable` before showing it.
    public let cagr: Double
    public let spanDays: Double

    // Risk
    public let maxDrawdownPct: Double
    public let maxDrawdownAbsolute: Double
    public let maxDrawdownBars: Int
    public let annualisedVolatilityPct: Double
    public let sharpe: Double
    public let sortino: Double
    public let calmar: Double

    // Trades
    public let tradeCount: Int
    public let winRate: Double
    public let profitFactor: Double
    public let expectancyPct: Double
    public let payoffRatio: Double
    public let averageHoldBars: Double
    public let maxConsecutiveLosses: Int
    public let largestWinPct: Double
    public let largestLossPct: Double

    // Costs & exposure
    public let feesPaid: Double
    public let fundingPaid: Double
    public let exposurePct: Double

    // Benchmark
    public let buyHoldReturnPct: Double

    /// Degrees of freedom, carried for the robustness grade.
    public let freeParameterCount: Int

    /// Geometric average daily return in percent — the number to compare
    /// against a "0.5% a day" target. Compounding matters: 0.5% daily is
    /// +16.1% over 30 days, not +15%.
    public var dailyReturnPct: Double {
        guard spanDays > 0, totalReturnPct > -100 else { return 0 }
        return (pow(1 + totalReturnPct / 100, 1 / spanDays) - 1) * 100
    }

    public var excessReturnPct: Double { totalReturnPct - buyHoldReturnPct }
    public var beatsBuyHold: Bool { totalReturnPct > buyHoldReturnPct }
    /// Annualising a handful of days produces absurd numbers; below a month
    /// the CAGR figure should not drive any decision.
    public var annualisationReliable: Bool { spanDays >= 30 }

    public static let empty = BacktestMetrics(
        trades: [], equityCurve: [], initialCapital: 0, bar: .h1, freeParameterCount: 1)

    // MARK: Construction

    /// Adopt the kernel's numbers. `profitFactor` and `payoffRatio` arrive as
    /// nil when they are infinite (no losing trades) — JSON cannot carry
    /// infinity, and substituting a large finite number would silently rank
    /// such a run against real ones.
    public init(kernel m: KernelMetrics) {
        totalReturnPct = m.totalReturnPct
        absolutePnL = m.absolutePnL
        cagr = m.cagr
        spanDays = m.spanDays
        maxDrawdownPct = m.maxDrawdownPct
        maxDrawdownAbsolute = m.maxDrawdownAbsolute
        maxDrawdownBars = m.maxDrawdownBars
        annualisedVolatilityPct = m.annualisedVolatilityPct
        sharpe = m.sharpe
        sortino = m.sortino
        calmar = m.calmar
        tradeCount = m.tradeCount
        winRate = m.winRate
        profitFactor = m.profitFactor ?? .infinity
        expectancyPct = m.expectancyPct
        payoffRatio = m.payoffRatio ?? .infinity
        averageHoldBars = m.averageHoldBars
        maxConsecutiveLosses = m.maxConsecutiveLosses
        largestWinPct = m.largestWinPct
        largestLossPct = m.largestLossPct
        feesPaid = m.feesPaid
        fundingPaid = m.fundingPaid
        exposurePct = m.exposurePct
        buyHoldReturnPct = m.buyHoldReturnPct
        freeParameterCount = m.freeParameterCount
    }

    /// Statistics over a curve the kernel did not itself produce — the
    /// portfolio backtester and the factor tools stitch several strategies'
    /// curves together and then need exactly these numbers.
    ///
    /// Computation happens in the kernel so there is one Sharpe, one drawdown
    /// and one expectancy in the codebase rather than two that drift.
    public init(
        trades: [BacktestTrade],
        equityCurve: [EquityPoint],
        initialCapital: Double,
        bar: BarInterval,
        freeParameterCount: Int
    ) {
        do {
            self.init(kernel: try TradingKernel.metrics(
                trades: trades, equityCurve: equityCurve,
                initialCapital: initialCapital, bar: bar,
                freeParameterCount: freeParameterCount))
        } catch {
            // The kernel only fails here on malformed input, which would mean a
            // programming error rather than bad market data. Reporting zeros is
            // better than trapping inside a research sweep, and a zeroed metric
            // set is visibly wrong rather than plausibly wrong.
            Log.warn("metrics: kernel rejected the curve (\(error)); reporting zeros")
            self.init(kernel: KernelMetrics.zeroed(freeParameterCount: freeParameterCount))
        }
    }
}
