import Foundation

// MARK: - Trading mode

/// Which account orders reach. There is no third "paper" mode: simulated
/// trading is OKX's own demo account, so the execution path a strategy is
/// tested on is the execution path it will run on.
public enum TradingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case demo
    case live

    public var id: String { rawValue }
    public var isDemo: Bool { self == .demo }

    public var displayName: String {
        switch self {
        case .demo: return "模拟盘"
        case .live: return "实盘"
        }
    }

    public var badge: String {
        switch self {
        case .demo: return "DEMO"
        case .live: return "LIVE"
        }
    }
}

// MARK: - Allocation

/// One strategy's slice of the portfolio.
public struct StrategyAllocation: Codable, Sendable, Equatable, Identifiable {
    public var strategyId: String
    /// Budget in the quote currency. The runner will not build a position
    /// whose notional exceeds this (times leverage).
    public var capital: Double
    /// Armed: the runner may act on this strategy's signals.
    public var running: Bool
    /// Caps the manifest's own leverage; nil means the manifest decides.
    public var leverageCap: Double?
    public var addedAt: Date
    /// Set when the runner halts the strategy itself (daily loss, repeated errors).
    public var haltReason: String?

    public var id: String { strategyId }

    public init(
        strategyId: String,
        capital: Double = 0,
        running: Bool = false,
        leverageCap: Double? = nil,
        addedAt: Date = Date(),
        haltReason: String? = nil
    ) {
        self.strategyId = strategyId
        self.capital = capital
        self.running = running
        self.leverageCap = leverageCap
        self.addedAt = addedAt
        self.haltReason = haltReason
    }

    private enum CodingKeys: String, CodingKey {
        case strategyId, capital, running, leverageCap, addedAt, haltReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strategyId = try c.decode(String.self, forKey: .strategyId)
        capital = try c.decodeIfPresent(Double.self, forKey: .capital) ?? 0
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        leverageCap = try c.decodeIfPresent(Double.self, forKey: .leverageCap)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        haltReason = try c.decodeIfPresent(String.self, forKey: .haltReason)
    }
}

// MARK: - Portfolio preferences

public struct StrategyPortfolioPrefs: Codable, Sendable, Equatable {
    /// Demo until the user unlocks live in Settings *and* confirms per strategy.
    public var mode: TradingMode
    /// Total capital the portfolio may commit, in `quoteCurrency`.
    public var totalCapital: Double
    public var quoteCurrency: String
    public var allocations: [StrategyAllocation]
    /// Kill switch: stops every strategy regardless of its own state.
    public var emergencyStop: Bool
    /// External-script strategy engines stay off until explicitly allowed —
    /// running one executes code that arrived with an imported file.
    public var allowScriptEngines: Bool
    /// Capital used when backtesting, independent of what is actually allocated.
    public var backtestCapital: Double
    /// Fee model for backtests and cost estimates. Defaults to a fresh account.
    public var feeSchedule: OKXFeeSchedule

    public init(
        mode: TradingMode = .demo,
        totalCapital: Double = 1_000,
        quoteCurrency: String = "USDT",
        allocations: [StrategyAllocation] = [],
        emergencyStop: Bool = false,
        allowScriptEngines: Bool = false,
        backtestCapital: Double = 10_000,
        feeSchedule: OKXFeeSchedule = OKXFeeSchedule()
    ) {
        self.mode = mode
        self.totalCapital = totalCapital
        self.quoteCurrency = quoteCurrency
        self.allocations = allocations
        self.emergencyStop = emergencyStop
        self.allowScriptEngines = allowScriptEngines
        self.backtestCapital = backtestCapital
        self.feeSchedule = feeSchedule
    }

    private enum CodingKeys: String, CodingKey {
        case mode, totalCapital, quoteCurrency, allocations
        case emergencyStop, allowScriptEngines, backtestCapital, feeSchedule
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(TradingMode.self, forKey: .mode) ?? .demo
        totalCapital = try c.decodeIfPresent(Double.self, forKey: .totalCapital) ?? 1_000
        quoteCurrency = try c.decodeIfPresent(String.self, forKey: .quoteCurrency) ?? "USDT"
        allocations = try c.decodeIfPresent([StrategyAllocation].self, forKey: .allocations) ?? []
        emergencyStop = try c.decodeIfPresent(Bool.self, forKey: .emergencyStop) ?? false
        allowScriptEngines = try c.decodeIfPresent(Bool.self, forKey: .allowScriptEngines) ?? false
        backtestCapital = try c.decodeIfPresent(Double.self, forKey: .backtestCapital) ?? 10_000
        feeSchedule = try c.decodeIfPresent(OKXFeeSchedule.self, forKey: .feeSchedule) ?? OKXFeeSchedule()
    }

    public var allocatedCapital: Double {
        allocations.reduce(0) { $0 + $1.capital }
    }

    public var unallocatedCapital: Double {
        totalCapital - allocatedCapital
    }

    public var runningCount: Int {
        allocations.filter(\.running).count
    }

    public func allocation(for strategyId: String) -> StrategyAllocation? {
        allocations.first { $0.strategyId == strategyId }
    }

    /// Largest budget `strategyId` could take without over-allocating the
    /// portfolio — its own capital stays available to itself.
    public func capitalHeadroom(for strategyId: String) -> Double {
        let others = allocations.filter { $0.strategyId != strategyId }.reduce(0) { $0 + $1.capital }
        return Swift.max(totalCapital - others, 0)
    }

    /// Set a budget, refusing to over-allocate: the value is clamped to what
    /// the portfolio actually has left.
    public mutating func setCapital(_ amount: Double, for strategyId: String) {
        let clamped = Swift.min(Swift.max(amount, 0), capitalHeadroom(for: strategyId))
        if let index = allocations.firstIndex(where: { $0.strategyId == strategyId }) {
            allocations[index].capital = clamped
        } else {
            allocations.append(StrategyAllocation(strategyId: strategyId, capital: clamped))
        }
    }

    public mutating func setRunning(_ running: Bool, for strategyId: String) {
        guard let index = allocations.firstIndex(where: { $0.strategyId == strategyId }) else { return }
        allocations[index].running = running
        if running { allocations[index].haltReason = nil }
    }

    public mutating func remove(strategyId: String) {
        allocations.removeAll { $0.strategyId == strategyId }
    }

    /// Split the whole portfolio evenly across the given strategies.
    public mutating func distributeEvenly(across strategyIds: [String]) {
        guard !strategyIds.isEmpty else { return }
        let share = totalCapital / Double(strategyIds.count)
        for id in strategyIds {
            if let index = allocations.firstIndex(where: { $0.strategyId == id }) {
                allocations[index].capital = share
            } else {
                allocations.append(StrategyAllocation(strategyId: id, capital: share))
            }
        }
    }
}
