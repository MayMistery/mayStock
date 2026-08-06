import Foundation

/// Swift mirrors of the JSON the kernel returns.
///
/// These are decode-only value types deliberately kept thin: the kernel owns
/// the definitions, and anything computed rather than reported (daily return,
/// excess over benchmark) is derived here so both sides cannot disagree about
/// a stored number.

// MARK: - Strategy description

public struct KernelStrategyInfo: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let instId: String
    public let instType: String
    public let bar: String
    public let warmupBars: Int
    public let freeParameterCount: Int
    public let isContinuous: Bool
    public let leverage: Double
    public let feeBps: Double
    public let slippageBps: Double
    public let params: [String: Double]

    /// Round-trip cost in percent — entry fee + exit fee + slippage both ways.
    public var roundTripCostPct: Double { (feeBps + slippageBps) * 2 / 100 }
}

// MARK: - Live decision

/// What the runner tells the kernel about the account before asking for a plan.
public struct KernelAccountState: Encodable, Sendable {
    /// Capital this strategy may deploy, compounded by its own P&L.
    public var equity: Double
    /// Coins currently held (signed).
    public var heldBase: Double
    /// Strategy equity at the start of the current UTC day.
    public var dayStartEquity: Double
    /// Portfolio-level cap, when tighter than the manifest's leverage.
    public var leverageCap: Double?
    /// Bars since the last exit, for the cooldown rule. Nil when the strategy
    /// has never held a position.
    public var barsSinceExit: Int?
    /// The daily-loss breaker already tripped today.
    public var haltedToday: Bool

    public init(
        equity: Double = 0, heldBase: Double = 0,
        dayStartEquity: Double = 0, leverageCap: Double? = nil,
        barsSinceExit: Int? = nil, haltedToday: Bool = false
    ) {
        self.equity = equity
        self.heldBase = heldBase
        self.dayStartEquity = dayStartEquity
        self.leverageCap = leverageCap
        self.barsSinceExit = barsSinceExit
        self.haltedToday = haltedToday
    }
}

public struct KernelDecision: Decodable, Sendable, Equatable {
    /// 1 long, −1 short, 0 flat.
    public let target: Int
    /// Position the strategy should hold, in coins (signed).
    public let targetBaseQuantity: Double
    /// Coins to buy (positive) or sell (negative) to reach it.
    public let baseDelta: Double
    /// False when the plan is to do nothing.
    public let shouldTrade: Bool
    /// The daily-loss breaker has tripped.
    public let haltDailyLoss: Bool
    /// Why, for the runtime status line.
    public let reason: String
    /// Protective levels to attach to the entry order so the exchange enforces
    /// them, rather than this app polling for a price it will miss.
    public let stopPrice: Double?
    public let takeProfitPrice: Double?
    /// Continuous exposure in −1…+1, or nil for a binary strategy.
    public let targetExposure: Double?
    public let confirmedBars: Int
    public let barTs: Int64
    /// True while indicators are still warming up. The caller must hold rather
    /// than read the flat target as an instruction to sell.
    public let warmingUp: Bool

    public var direction: TradeDirection? { TradeDirection.fromKernelCode(Int32(target)) }
    public var barTime: Date { Date(timeIntervalSince1970: Double(barTs) / 1000) }

    private enum CodingKeys: String, CodingKey {
        case target, targetExposure, confirmedBars, barTs, warmingUp
        case targetBaseQuantity, baseDelta, shouldTrade, haltDailyLoss, reason
        case stopPrice, takeProfitPrice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(Int.self, forKey: .target)
        targetBaseQuantity = try c.decode(Double.self, forKey: .targetBaseQuantity)
        baseDelta = try c.decode(Double.self, forKey: .baseDelta)
        shouldTrade = try c.decode(Bool.self, forKey: .shouldTrade)
        haltDailyLoss = try c.decode(Bool.self, forKey: .haltDailyLoss)
        reason = try c.decode(String.self, forKey: .reason)
        stopPrice = try c.decodeIfPresent(Double.self, forKey: .stopPrice)
        takeProfitPrice = try c.decodeIfPresent(Double.self, forKey: .takeProfitPrice)
        // Rust writes NaN for "not an exposure strategy"; JSON has no NaN, so
        // it arrives as null.
        targetExposure = try c.decodeIfPresent(Double.self, forKey: .targetExposure)
        confirmedBars = try c.decode(Int.self, forKey: .confirmedBars)
        barTs = try c.decode(Int64.self, forKey: .barTs)
        warmingUp = try c.decode(Bool.self, forKey: .warmingUp)
    }
}

// MARK: - Backtest

public struct KernelBacktestConfig: Encodable, Sendable {
    public var initialCapital: Double
    public var maintenanceMarginRate: Double
    public var fundingRates: [KernelFundingRate]
    /// Account-tier fallbacks, used only when the manifest states no costs.
    public var feeBps: Double?
    public var slippageBps: Double?
    public var externalSeries: [String: [Double]]
    /// Per-bar targets from a script engine: 1 long, −1 short, 0 flat.
    public var scriptTargets: [Int]?

    public init(
        initialCapital: Double = 10_000,
        maintenanceMarginRate: Double = 0.005,
        fundingRates: [KernelFundingRate] = [],
        feeBps: Double? = nil,
        slippageBps: Double? = nil,
        externalSeries: [String: [Double]] = [:],
        scriptTargets: [Int]? = nil
    ) {
        self.initialCapital = initialCapital
        self.maintenanceMarginRate = maintenanceMarginRate
        self.fundingRates = fundingRates
        self.feeBps = feeBps
        self.slippageBps = slippageBps
        self.externalSeries = externalSeries
        self.scriptTargets = scriptTargets
    }
}

public struct KernelFundingRate: Encodable, Sendable {
    public let ts_ms: Int64
    public let rate: Double

    public init(ts: Date, rate: Double) {
        self.ts_ms = Int64((ts.timeIntervalSince1970 * 1000).rounded())
        self.rate = rate
    }
}

public struct KernelTrade: Decodable, Sendable, Equatable {
    public let id: Int
    public let direction: TradeDirection
    public let entryTs: Int64
    public let exitTs: Int64
    public let entryPrice: Double
    public let exitPrice: Double
    public let quantity: Double
    public let notional: Double
    public let grossPnL: Double
    public let fees: Double
    public let funding: Double
    public let netPnL: Double
    public let returnPct: Double
    public let bars: Int
    public let exitReason: KernelExitReason

    public var isWin: Bool { netPnL > 0 }
    public var entryTime: Date { Date(timeIntervalSince1970: Double(entryTs) / 1000) }
    public var exitTime: Date { Date(timeIntervalSince1970: Double(exitTs) / 1000) }
}

public enum KernelExitReason: String, Decodable, Sendable, Equatable {
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

public struct KernelEquityPoint: Decodable, Sendable, Equatable {
    public let ts: Int64
    public let equity: Double
    public let price: Double

    public var time: Date { Date(timeIntervalSince1970: Double(ts) / 1000) }
}

public struct KernelMetrics: Decodable, Sendable, Equatable {
    public let totalReturnPct: Double
    public let absolutePnL: Double
    public let cagr: Double
    public let spanDays: Double

    public let maxDrawdownPct: Double
    public let maxDrawdownAbsolute: Double
    public let maxDrawdownBars: Int
    public let annualisedVolatilityPct: Double
    public let sharpe: Double
    public let sortino: Double
    public let calmar: Double

    public let tradeCount: Int
    public let winRate: Double
    /// Nil means infinite — no losing trades. JSON cannot carry infinity, and
    /// inventing a large finite number would silently rank such a run.
    public let profitFactor: Double?
    public let expectancyPct: Double
    public let payoffRatio: Double?
    public let averageHoldBars: Double
    public let maxConsecutiveLosses: Int
    public let largestWinPct: Double
    public let largestLossPct: Double

    public let feesPaid: Double
    public let fundingPaid: Double
    public let exposurePct: Double
    public let buyHoldReturnPct: Double
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
    /// Annualising a handful of days produces absurd numbers; below a month the
    /// CAGR figure should not drive any decision.
    public var annualisationReliable: Bool { spanDays >= 30 }
}

public struct KernelBacktestResult: Decodable, Sendable {
    public let strategyId: String
    public let instId: String
    public let bar: String
    public let start: Int64
    public let end: Int64
    public let barCount: Int
    public let initialCapital: Double
    public let finalEquity: Double
    public let trades: [KernelTrade]
    public let equityCurve: [KernelEquityPoint]
    public let liquidations: Int
    public let warmupBars: Int
    /// True when the strategy is a swap but no funding history was supplied —
    /// the result is optimistic by an unknown amount.
    public let fundingUnmodelled: Bool
    public let metrics: KernelMetrics

    public var startTime: Date { Date(timeIntervalSince1970: Double(start) / 1000) }
    public var endTime: Date { Date(timeIntervalSince1970: Double(end) / 1000) }
}
