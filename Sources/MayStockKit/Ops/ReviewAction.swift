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
        for venue in Venue.allCases
        where to.strategy.totalCapital(for: venue) > from.strategy.totalCapital(for: venue) + 1e-9 {
            return "提高了\(venue.displayName)本金"
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

// MARK: - Writing it down

/// What `review --apply` did to config.json, and whether it will hold.
public struct ReviewWrite: Sendable {
    /// Who takes a change to the file in, read off its follow lock
    /// (`ConfigIO.isFollowed`) rather than assumed from a process running.
    public enum Follower: Sendable, Equatable {
        /// A process follows the file and folds the change in as it lands.
        case following
        /// Nobody does. A MayStock process running then uses another data
        /// directory, or is a build from before the app followed the file —
        /// one whose next save writes its own copy back over the change.
        case nobody
        case unknown(String)

        public var label: String {
            switch self {
            case .following: return "following"
            case .nobody: return "nobody"
            case .unknown(let reason): return "unknown: \(reason)"
            }
        }
    }

    /// The write, when it went through — including one that found nothing
    /// left to change.
    public var update: ConfigUpdate<ReviewActionOutcome>?
    /// Why nothing was written, when nothing could be: no action applied.
    public var failure: String?
    /// What changed in the file between the checks reading it and the
    /// actions being applied — by the app, or by hand. The actions were
    /// applied to that, not to the copy the checks read.
    public var movedSinceChecked: [String]
    /// Who takes the change in; set when the file changed.
    public var follower: Follower?
    /// Whether a MayStock process was running when the change was written.
    public var appRunning: Bool

    public var outcome: ReviewActionOutcome? { update?.result }

    /// How the write itself went, as findings — so a write that failed, or
    /// one a running MayStock will save over, sets the verdict, the exit code
    /// and the hourly log's codes the way any other check does.
    public var findings: [ReviewFinding] {
        if let failure {
            return [ReviewFinding(
                code: "config.writeFailed", severity: .critical,
                title: "降敞口动作没有写进 config.json",
                detail: "\(failure)。一个动作都没有执行，账户仍是检查认为不该有的敞口。",
                remedy: "查明是谁占着 config.json 的锁、或文件为什么写不进；条件还在的话，下一次复盘会再提出这些动作")]
        }
        guard update?.changed == true else { return [] }
        switch follower {
        case .nobody? where appRunning:
            return [ReviewFinding(
                code: "config.unfollowed", severity: .critical,
                title: "写进了 config.json，但运行中的 MayStock 没有跟随它",
                detail: "有 MayStock 进程在运行，却没有进程持有 config.json.follow：它要么用的是别的数据目录，"
                    + "要么是还不跟随文件的旧版本——旧版本下一次保存会把这次写入撤销。",
                remedy: "装上新版本并重启 App；在那之前，这里写下的降风险动作随时可能被撤销")]
        case .unknown(let reason)?:
            return [ReviewFinding(
                code: "config.followUnknown", severity: .warn,
                title: "查不到有没有进程跟随 config.json",
                detail: "\(reason)。说不准运行中的 App 会不会并入这次写入。")]
        default:
            return []
        }
    }
}

extension ReviewActuator {
    /// Apply the actions to config.json as it is at this moment, under its
    /// write lock — never to the copy the checks read (`checked`). The checks
    /// take seconds (the exchange read alone), the app writes this file
    /// whenever an alert fires or a setting changes, and writing that copy
    /// back put every one of those changes back the way it was. The
    /// invariant is checked against what is actually there, so an action the
    /// file has meanwhile made moot — a budget already cut lower by hand — is
    /// refused rather than reversed.
    ///
    /// The file being replaced is kept beside it (`config.json.review-…`), so
    /// an unattended change can be undone by hand. Whether anyone will take
    /// the change in is read off the file's follow lock, not assumed.
    public static func write(
        _ actions: [ReviewAction], checked: AppConfig, to io: ConfigIO, appRunning: Bool,
        waitingUpTo timeout: TimeInterval = ConfigIO.lockTimeout
    ) -> ReviewWrite {
        let update: ConfigUpdate<ReviewActionOutcome>
        do {
            update = try io.update(keepingCopyAs: "review", waitingUpTo: timeout) { config in
                let outcome = apply(actions, to: config)
                config = outcome.config
                return outcome
            }
        } catch {
            return ReviewWrite(
                update: nil, failure: String(describing: error), movedSinceChecked: [], follower: nil,
                appRunning: appRunning)
        }
        let moved: [String]
        do {
            moved = try ConfigMerge.differences(from: checked, to: update.before.config).map(\.description)
        } catch {
            moved = ["（列不出来：\(error)）"]
        }
        var follower: ReviewWrite.Follower?
        if update.changed {
            do {
                follower = try io.isFollowed() ? .following : .nobody
            } catch {
                follower = .unknown(String(describing: error))
            }
        }
        return ReviewWrite(
            update: update, failure: nil, movedSinceChecked: moved, follower: follower, appRunning: appRunning)
    }
}
