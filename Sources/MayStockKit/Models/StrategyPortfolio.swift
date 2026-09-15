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
    /// Where the strategy trades, stamped when the budget is first set so
    /// the portfolio can add budgets up per venue without opening every
    /// manifest. Budgets written before venues existed are OKX's.
    public var venue: Venue
    /// Budget in the venue's quote currency. The runner will not build a
    /// position whose notional exceeds this (times leverage).
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
        venue: Venue = .okx,
        capital: Double = 0,
        running: Bool = false,
        leverageCap: Double? = nil,
        addedAt: Date = Date(),
        haltReason: String? = nil
    ) {
        self.strategyId = strategyId
        self.venue = venue
        self.capital = capital
        self.running = running
        self.leverageCap = leverageCap
        self.addedAt = addedAt
        self.haltReason = haltReason
    }

    private enum CodingKeys: String, CodingKey {
        case strategyId, venue, capital, running, leverageCap, addedAt, haltReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strategyId = try c.decode(String.self, forKey: .strategyId)
        venue = try c.decodeIfPresent(Venue.self, forKey: .venue) ?? .okx
        capital = try c.decodeIfPresent(Double.self, forKey: .capital) ?? 0
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        leverageCap = try c.decodeIfPresent(Double.self, forKey: .leverageCap)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        haltReason = try c.decodeIfPresent(String.self, forKey: .haltReason)
    }
}

// MARK: - Portfolio preferences

/// Pause a strategy that keeps getting stopped out inside a short window.
///
/// The strategy may be doing exactly what it was designed to do and still be
/// wrong about the current market: the per-trade stop fires correctly each
/// time, and the account bleeds out one correct stop-out at a time.
public struct StoplossGuard: Codable, Sendable, Equatable {
    /// Stop-outs within the window that trip the guard.
    public var trades: Int
    public var lookbackMinutes: Int

    public init(trades: Int = 4, lookbackMinutes: Int = 360) {
        self.trades = trades
        self.lookbackMinutes = lookbackMinutes
    }
}

public struct StrategyPortfolioPrefs: Codable, Sendable, Equatable {
    /// Demo until the user unlocks live in Settings *and* confirms per strategy.
    public var mode: TradingMode
    /// Capital the portfolio may commit on each venue, in that venue's own
    /// quote currency. Two pots, never one: USDT on OKX and dollars at
    /// Schwab are different accounts, and a budget on one says nothing
    /// about what the other can afford.
    public var capital: [Venue: Double]
    public var allocations: [StrategyAllocation]
    /// Kill switch: stops every strategy regardless of its own state.
    public var emergencyStop: Bool
    /// External-script strategy engines stay off until explicitly allowed —
    /// running one executes code that arrived with an imported file.
    public var allowScriptEngines: Bool
    /// Capital used when backtesting, independent of what is actually allocated.
    public var backtestCapital: Double
    /// Fee models for backtests and cost estimates, one per venue. Each
    /// defaults to a fresh account on its venue.
    public var feeSchedules: FeeSchedules
    /// Stop opening new positions once the account has drawn down this far from
    /// its high-water mark. Portfolio-wide on purpose: a per-strategy daily
    /// breaker cannot see four strategies losing 4% each, which is exactly the
    /// day worth stopping. Nil disables it.
    public var maxDrawdownPct: Double?
    /// Hard ceiling on one order's notional, in the venue's quote currency.
    /// A backstop against a sizing bug rather than a strategy setting —
    /// nothing legitimate should ever reach it. Nil leaves only the
    /// equity-share cap.
    public var maxOrderNotional: Double?
    /// Pause a strategy that keeps getting stopped out. Freqtrade's
    /// StoplossGuard: the strategy may be behaving exactly as designed and
    /// still be wrong about the current market.
    public var stoplossGuard: StoplossGuard?

    /// Every venue's starting pot, for a portfolio that has never been set.
    public static var defaultCapital: [Venue: Double] {
        Dictionary(uniqueKeysWithValues: Venue.allCases.map { ($0, $0.defaultPortfolioCapital) })
    }

    public init(
        mode: TradingMode = .demo,
        capital: [Venue: Double] = StrategyPortfolioPrefs.defaultCapital,
        allocations: [StrategyAllocation] = [],
        emergencyStop: Bool = false,
        allowScriptEngines: Bool = false,
        backtestCapital: Double = 10_000,
        feeSchedules: FeeSchedules = FeeSchedules(),
        maxDrawdownPct: Double? = 25,
        maxOrderNotional: Double? = nil,
        stoplossGuard: StoplossGuard? = StoplossGuard()
    ) {
        self.mode = mode
        self.capital = capital
        self.allocations = allocations
        self.emergencyStop = emergencyStop
        self.allowScriptEngines = allowScriptEngines
        self.backtestCapital = backtestCapital
        self.feeSchedules = feeSchedules
        self.maxDrawdownPct = maxDrawdownPct
        self.maxOrderNotional = maxOrderNotional
        self.stoplossGuard = stoplossGuard
    }

    private enum CodingKeys: String, CodingKey {
        case mode, capital, allocations
        case emergencyStop, allowScriptEngines, backtestCapital, feeSchedules
        case maxDrawdownPct, maxOrderNotional, stoplossGuard
        /// Before v6 there was one pot, OKX's. Read, never written.
        case legacyTotalCapital = "totalCapital"
        /// The v3 name: one OKX schedule. Read, never written.
        case legacyFeeSchedule = "feeSchedule"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(TradingMode.self, forKey: .mode) ?? .demo
        var pots = Self.defaultCapital
        if let stored = try c.decodeIfPresent([String: Double].self, forKey: .capital) {
            for (key, value) in stored {
                if let venue = Venue(rawValue: key) { pots[venue] = value }
            }
        } else if let legacy = try c.decodeIfPresent(Double.self, forKey: .legacyTotalCapital) {
            pots[.okx] = legacy
        }
        capital = pots
        allocations = try c.decodeIfPresent([StrategyAllocation].self, forKey: .allocations) ?? []
        emergencyStop = try c.decodeIfPresent(Bool.self, forKey: .emergencyStop) ?? false
        allowScriptEngines = try c.decodeIfPresent(Bool.self, forKey: .allowScriptEngines) ?? false
        backtestCapital = try c.decodeIfPresent(Double.self, forKey: .backtestCapital) ?? 10_000
        if let schedules = try c.decodeIfPresent(FeeSchedules.self, forKey: .feeSchedules) {
            feeSchedules = schedules
        } else {
            // A v3 config carried one OKX schedule; it keeps its tier and
            // slippage, and the other venues start from their defaults.
            feeSchedules = FeeSchedules(
                okx: try c.decodeIfPresent(OKXFeeSchedule.self, forKey: .legacyFeeSchedule)
                    ?? OKXFeeSchedule())
        }
        // Absent means "never configured", which for a protective limit has to
        // mean the default rather than "off" — a config written before these
        // existed should gain the protection, not opt out of it.
        maxDrawdownPct = try c.decodeIfPresent(Double.self, forKey: .maxDrawdownPct) ?? 25
        maxOrderNotional = try c.decodeIfPresent(Double.self, forKey: .maxOrderNotional)
        stoplossGuard = try c.decodeIfPresent(StoplossGuard.self, forKey: .stoplossGuard)
            ?? StoplossGuard()
    }

    /// Written by hand because `CodingKeys` carries the legacy read-only keys,
    /// which have no property behind them for the compiler to synthesise from.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(
            Dictionary(uniqueKeysWithValues: capital.map { ($0.key.rawValue, $0.value) }),
            forKey: .capital)
        try c.encode(allocations, forKey: .allocations)
        try c.encode(emergencyStop, forKey: .emergencyStop)
        try c.encode(allowScriptEngines, forKey: .allowScriptEngines)
        try c.encode(backtestCapital, forKey: .backtestCapital)
        try c.encode(feeSchedules, forKey: .feeSchedules)
        try c.encodeIfPresent(maxDrawdownPct, forKey: .maxDrawdownPct)
        try c.encodeIfPresent(maxOrderNotional, forKey: .maxOrderNotional)
        try c.encodeIfPresent(stoplossGuard, forKey: .stoplossGuard)
    }

    // MARK: Per-venue arithmetic

    /// The pot on a venue. A venue the file never named starts from its
    /// default rather than from zero, so a fresh venue can be budgeted at all.
    public func totalCapital(for venue: Venue) -> Double {
        capital[venue] ?? venue.defaultPortfolioCapital
    }

    public func allocations(on venue: Venue) -> [StrategyAllocation] {
        allocations.filter { $0.venue == venue }
    }

    public func allocatedCapital(on venue: Venue) -> Double {
        allocations(on: venue).reduce(0) { $0 + $1.capital }
    }

    public func unallocatedCapital(on venue: Venue) -> Double {
        totalCapital(for: venue) - allocatedCapital(on: venue)
    }

    /// Venues with at least one budget, in declaration order — the venues
    /// a page has something to say about.
    public var budgetedVenues: [Venue] {
        Venue.allCases.filter { venue in allocations.contains { $0.venue == venue } }
    }

    public var runningCount: Int {
        allocations.filter(\.running).count
    }

    public func runningCount(on venue: Venue) -> Int {
        allocations(on: venue).filter(\.running).count
    }

    public func allocation(for strategyId: String) -> StrategyAllocation? {
        allocations.first { $0.strategyId == strategyId }
    }

    /// Largest budget `strategyId` could take on `venue` without
    /// over-allocating that venue's pot — its own capital stays available
    /// to itself.
    public func capitalHeadroom(for strategyId: String, on venue: Venue) -> Double {
        let others = allocations(on: venue)
            .filter { $0.strategyId != strategyId }
            .reduce(0) { $0 + $1.capital }
        return Swift.max(totalCapital(for: venue) - others, 0)
    }

    /// Budgets on a venue that add up to more than its pot.
    ///
    /// Not cosmetic: `StrategyRunner.workingCapital` sizes every order against
    /// the *budget*, never against the account, so four strategies each holding
    /// a budget of half the account will between them commit twice it.
    public func isOverAllocated(on venue: Venue) -> Bool {
        allocatedCapital(on: venue) > totalCapital(for: venue) + 1e-6
    }

    /// Every venue whose budgets exceed its pot.
    public var overAllocatedVenues: [Venue] {
        Venue.allCases.filter { isOverAllocated(on: $0) }
    }

    /// Set a venue's pot, bringing its budgets down with it.
    ///
    /// `setCapital` refuses to over-allocate on the way in, but nothing used to
    /// re-check on the way *down*. Lowering the pot left every budget exactly
    /// where it was, so a book split four ways against a larger account stayed
    /// split four ways against a smaller one — 已分配 at twice 本金, and a
    /// 未分配 that had gone negative.
    ///
    /// Scaled rather than truncated: how the pot is split between strategies is
    /// a decision the user made, and halving the pot should halve each share
    /// rather than starve whichever happens to sort last.
    public mutating func setTotalCapital(_ amount: Double, for venue: Venue) {
        let pot = Swift.max(amount, 0)
        capital[venue] = pot
        let allocated = allocatedCapital(on: venue)
        guard allocated > pot, allocated > 0 else { return }
        let scale = pot / allocated
        for index in allocations.indices where allocations[index].venue == venue {
            allocations[index].capital *= scale
        }
    }

    /// Set a budget, refusing to over-allocate: the value is clamped to what
    /// the venue's pot actually has left. The venue is stamped on the
    /// allocation the first time, and re-stamped if the strategy moved.
    public mutating func setCapital(_ amount: Double, for strategyId: String, on venue: Venue) {
        let clamped = Swift.min(Swift.max(amount, 0), capitalHeadroom(for: strategyId, on: venue))
        if let index = allocations.firstIndex(where: { $0.strategyId == strategyId }) {
            allocations[index].capital = clamped
            allocations[index].venue = venue
        } else {
            allocations.append(StrategyAllocation(strategyId: strategyId, venue: venue, capital: clamped))
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

    /// Split a venue's whole pot evenly across the given strategies.
    public mutating func distributeEvenly(across strategyIds: [String], on venue: Venue) {
        guard !strategyIds.isEmpty else { return }
        let share = totalCapital(for: venue) / Double(strategyIds.count)
        for id in strategyIds {
            if let index = allocations.firstIndex(where: { $0.strategyId == id }) {
                allocations[index].capital = share
                allocations[index].venue = venue
            } else {
                allocations.append(StrategyAllocation(strategyId: id, venue: venue, capital: share))
            }
        }
    }

    /// The portfolio as one venue's runner sees it: only that venue's pot
    /// and budgets, so a strategy on the other exchange is never counted
    /// against this book, nor evaluated by this engine.
    public func scoped(to venue: Venue) -> StrategyPortfolioPrefs {
        var copy = self
        copy.allocations = allocations(on: venue)
        copy.capital = [venue: totalCapital(for: venue)]
        return copy
    }
}
