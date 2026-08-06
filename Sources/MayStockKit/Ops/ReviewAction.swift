import Foundation

/// A change the unattended review is allowed to make on its own.
///
/// The list is short by design, and every member of it *reduces* what the book
/// can lose. Nothing here can arm a strategy, raise a budget, lift the pot,
/// unlock live trading or add leverage — not because those are hard, but
/// because an unattended process that can increase exposure is a different and
/// much worse kind of program than one that can only shrink it. The asymmetry
/// is enforced in `apply`, not merely intended: an action that would grow the
/// book is rejected even if some future check emits it by mistake.
public enum ReviewAction: Codable, Sendable, Equatable {
    /// Disarm a strategy. Open positions are left alone — closing one is a
    /// trade, and a trade is a decision a person makes.
    case halt(strategyId: String, reason: String)
    /// Lower a strategy's budget. Raising it is rejected.
    case reduceCapital(strategyId: String, to: Double, reason: String)
    /// Portfolio kill switch.
    case emergencyStop(reason: String)

    public var strategyId: String? {
        switch self {
        case .halt(let id, _), .reduceCapital(let id, _, _): return id
        case .emergencyStop: return nil
        }
    }

    public var reason: String {
        switch self {
        case .halt(_, let reason), .reduceCapital(_, _, let reason), .emergencyStop(let reason):
            return reason
        }
    }

    public var summary: String {
        switch self {
        case .halt(let id, _):
            return "停用 \(id)"
        case .reduceCapital(let id, let amount, _):
            return "\(id) 预算降到 \(String(format: "%.2f", amount))"
        case .emergencyStop:
            return "触发总闸"
        }
    }
}

// MARK: - Applying

public struct ReviewActionOutcome: Sendable {
    public var config: AppConfig
    public var applied: [ReviewAction]
    /// Actions the de-risking invariant refused, with the reason. A non-empty
    /// list is a bug in whichever check emitted the action, and is reported
    /// rather than swallowed.
    public var rejected: [(action: ReviewAction, why: String)]

    public var didChange: Bool { !applied.isEmpty }
}

public enum ReviewActuator {
    /// Apply actions one at a time, checking the invariant after each, so a
    /// single bad action cannot ride in on the back of a good one.
    public static func apply(_ actions: [ReviewAction], to config: AppConfig) -> ReviewActionOutcome {
        var current = config
        var applied: [ReviewAction] = []
        var rejected: [(ReviewAction, String)] = []

        for action in actions {
            var candidate = current
            switch action {
            case .halt(let id, let reason):
                guard let index = candidate.strategy.allocations.firstIndex(where: { $0.strategyId == id })
                else {
                    rejected.append((action, "组合里没有 \(id)"))
                    continue
                }
                candidate.strategy.allocations[index].running = false
                candidate.strategy.allocations[index].haltReason = reason
            case .reduceCapital(let id, let amount, let reason):
                guard let index = candidate.strategy.allocations.firstIndex(where: { $0.strategyId == id })
                else {
                    rejected.append((action, "组合里没有 \(id)"))
                    continue
                }
                candidate.strategy.allocations[index].capital = Swift.max(amount, 0)
                if candidate.strategy.allocations[index].haltReason == nil {
                    candidate.strategy.allocations[index].haltReason = reason
                }
            case .emergencyStop(let reason):
                candidate.strategy.emergencyStop = true
                _ = reason
            }

            if let violation = derisksViolation(from: current, to: candidate) {
                rejected.append((action, violation))
                continue
            }
            current = candidate
            applied.append(action)
        }

        return ReviewActionOutcome(config: current, applied: applied, rejected: rejected)
    }

    /// Total budget the armed strategies may commit. The single number the
    /// invariant is really about.
    public static func armedCapital(_ config: AppConfig) -> Double {
        guard !config.strategy.emergencyStop else { return 0 }
        return config.strategy.allocations.filter(\.running).reduce(0) { $0 + $1.capital }
    }

    /// `nil` when `to` is no riskier than `from`; otherwise why it is riskier.
    ///
    /// Deliberately checked field by field rather than by comparing one summary
    /// number: a change that leaves armed capital identical while flipping the
    /// account to live, or while arming a strategy that was halted for cause,
    /// is not a wash.
    public static func derisksViolation(from: AppConfig, to: AppConfig) -> String? {
        if to.strategy.mode != from.strategy.mode {
            return "改变了交易模式（\(from.strategy.mode.rawValue) → \(to.strategy.mode.rawValue)）"
        }
        if to.trading.liveTradingUnlocked && !from.trading.liveTradingUnlocked {
            return "解锁了实盘"
        }
        if !to.strategy.emergencyStop && from.strategy.emergencyStop {
            return "解除了总闸"
        }
        if to.strategy.totalCapital > from.strategy.totalCapital + 1e-9 {
            return "提高了本金"
        }
        if let before = from.strategy.maxDrawdownPct {
            if let after = to.strategy.maxDrawdownPct {
                if after > before + 1e-9 { return "放宽了回撤熔断" }
            } else {
                return "关掉了回撤熔断"
            }
        }
        for allocation in to.strategy.allocations {
            guard let before = from.strategy.allocation(for: allocation.strategyId) else {
                return "新增了策略 \(allocation.strategyId)"
            }
            if allocation.capital > before.capital + 1e-9 {
                return "提高了 \(allocation.strategyId) 的预算"
            }
            if allocation.running && !before.running {
                return "启动了 \(allocation.strategyId)"
            }
            let beforeCap = before.leverageCap ?? .infinity
            let afterCap = allocation.leverageCap ?? .infinity
            if afterCap > beforeCap + 1e-9 {
                return "放宽了 \(allocation.strategyId) 的杠杆上限"
            }
        }
        return nil
    }
}
