import Foundation

// MARK: - Findings

public enum ReviewSeverity: String, Codable, Sendable, Comparable, CaseIterable {
    /// Nothing to say.
    case ok
    /// Worth knowing, nothing to do.
    case info
    /// Something is wrong and a person should look.
    case warn
    /// The book is unmanaged, over-exposed, or losing beyond its mandate.
    case critical

    private var rank: Int {
        switch self {
        case .ok: return 0
        case .info: return 1
        case .warn: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: ReviewSeverity, rhs: ReviewSeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    public var label: String {
        switch self {
        case .ok: return "正常"
        case .info: return "提示"
        case .warn: return "告警"
        case .critical: return "严重"
        }
    }
}

public struct ReviewFinding: Codable, Sendable, Equatable {
    /// Stable identifier, so a log of these can be diffed across runs and a
    /// finding that has been present for six hours can be told from a new one.
    public var code: String
    public var severity: ReviewSeverity
    public var title: String
    public var detail: String
    /// What a person would do about it, when the review cannot.
    public var remedy: String?
    /// The de-risking changes the review will make on its own, if any. A list
    /// because one condition can need several: over-allocation is a single
    /// finding whose fix touches every budget.
    public var actions: [ReviewAction]

    public init(
        code: String, severity: ReviewSeverity, title: String, detail: String,
        remedy: String? = nil, actions: [ReviewAction] = []
    ) {
        self.code = code
        self.severity = severity
        self.title = title
        self.detail = detail
        self.remedy = remedy
        self.actions = actions
    }
}

// MARK: - Evidence budget

/// How much of a conclusion one reading actually contains.
///
/// Printed on every report, including the quiet ones, because the temptation
/// this whole design exists to resist is looking at an hour of P&L and feeling
/// informed. The account's hourly noise is roughly two orders of magnitude
/// larger than an hour's worth of any edge these strategies claim, so a single
/// reading carries a few thousandths of one answer. Stating the fraction turns
/// that from something you have to remember into something you have to read.
public struct EvidenceBudget: Codable, Sendable, Equatable {
    /// Standard deviation of hourly equity returns, in percent, measured.
    public var hourlyNoisePct: Double?
    /// Expected return per hour, in percent, from the pre-registered mandates.
    public var hourlyEdgePct: Double?
    /// Hours of observation for the edge to clear two standard errors.
    public var hoursForSignificance: Double?
    /// Hours of live history behind this reading.
    public var hoursObserved: Double
    /// Strategy-bars of genuinely new data since each mandate was validated.
    public var barsSinceValidation: [String: Int]

    public init(
        hourlyNoisePct: Double? = nil,
        hourlyEdgePct: Double? = nil,
        hoursForSignificance: Double? = nil,
        hoursObserved: Double = 0,
        barsSinceValidation: [String: Int] = [:]
    ) {
        self.hourlyNoisePct = hourlyNoisePct
        self.hourlyEdgePct = hourlyEdgePct
        self.hoursForSignificance = hoursForSignificance
        self.hoursObserved = hoursObserved
        self.barsSinceValidation = barsSinceValidation
    }

    /// One line, always printed.
    ///
    /// When it cannot be computed it says *which* input is missing. "Cannot
    /// estimate" with no reason is the same silence-reads-as-approval failure
    /// this whole report exists to avoid.
    public var headline: String {
        guard let noise = hourlyNoisePct else {
            return "本次读数的统计含量：算不出 —— 连续小时的采样点不足，测不出小时噪声"
        }
        guard let edge = hourlyEdgePct else {
            return String(
                format: "本次读数的统计含量：只有一半 —— 小时噪声 %.3f%%，"
                    + "但没有预注册的年化期望可以拿来除（review-policy.json 里额度为空）", noise)
        }
        guard let hours = hoursForSignificance, hours.isFinite, hours > 0 else {
            return String(format: "本次读数的统计含量：算不出 —— 小时噪声 %.3f%%，期望 %.4f%%", noise, edge)
        }
        let observedShare = hoursObserved / hours
        return String(
            format: "本次读数的统计含量：小时噪声 %.3f%%，小时期望 %.4f%%，"
                + "要把两者分开需要 %.0f 小时（%.0f 天）；已观察 %.0f 小时 = %.1f%%",
            noise, edge, hours, hours / 24, hoursObserved, observedShare * 100)
    }
}

// MARK: - Snapshot

/// Everything the review reads. Assembled by the caller from disk so the review
/// itself stays a pure function — same inputs, same findings, testable without
/// a running app or an exchange.
public struct ReviewSnapshot: Sendable {
    public var now: Date
    public var config: AppConfig
    public var lastTickAt: Date?
    public var accountEquity: [AccountEquityPoint]
    public var strategyEquity: [String: [AccountEquityPoint]]
    public var positions: [String: StrategyPositionState]
    public var fills: [StrategyFill]
    /// True when a MayStock process is running. Distinguishes "the engine
    /// stopped" from "the engine was never started".
    public var appRunning: Bool

    public init(
        now: Date = Date(),
        config: AppConfig,
        lastTickAt: Date? = nil,
        accountEquity: [AccountEquityPoint] = [],
        strategyEquity: [String: [AccountEquityPoint]] = [:],
        positions: [String: StrategyPositionState] = [:],
        fills: [StrategyFill] = [],
        appRunning: Bool = true
    ) {
        self.now = now
        self.config = config
        self.lastTickAt = lastTickAt
        self.accountEquity = accountEquity
        self.strategyEquity = strategyEquity
        self.positions = positions
        self.fills = fills
        self.appRunning = appRunning
    }
}

public struct ReviewResult: Sendable {
    public var now: Date
    public var findings: [ReviewFinding]
    public var evidence: EvidenceBudget

    public var verdict: ReviewSeverity {
        findings.map(\.severity).max() ?? .ok
    }

    /// The de-risking changes this review wants to make. Still subject to the
    /// actuator's invariant — this is a request, not a guarantee.
    public var actions: [ReviewAction] {
        findings.flatMap(\.actions)
    }
}

// MARK: - Review

/// The hourly unattended pass.
///
/// It runs *operations*, not research. The split is the whole idea: a strategy
/// on daily bars thinks once a day, so twenty-three of every twenty-four runs
/// see byte-identical inputs, and any position change they produced would be
/// driven by nothing. Re-deciding allocations on that cadence is 8,760 fresh
/// selections a year over the same evidence — precisely the multiple-testing
/// failure the Deflated Sharpe and PBO machinery exists to punish, applied to
/// live money instead of a backtest.
///
/// So the hourly job answers only questions that genuinely change hourly: is
/// the engine alive, is the book inside its mandate, is anything bleeding. Real
/// strategy work is *scheduled* by this pass — `evidence.stale` says when
/// enough new bars exist for a re-validation to mean anything — and never
/// performed by it.
public enum PortfolioReview {
    public static func run(_ snapshot: ReviewSnapshot, policy: ReviewPolicy) -> ReviewResult {
        var findings: [ReviewFinding] = []
        findings += liveness(snapshot, policy)
        findings += exposure(snapshot, policy)
        findings += risk(snapshot, policy)
        findings += carry(snapshot, policy)
        findings += activity(snapshot, policy)
        findings += evidence(snapshot, policy)
        findings += hygiene(snapshot, policy)
        findings.sort { ($0.severity, $0.code) > ($1.severity, $1.code) }
        return ReviewResult(
            now: snapshot.now, findings: findings,
            evidence: evidenceBudget(snapshot, policy))
    }

    // MARK: Liveness

    static func liveness(_ s: ReviewSnapshot, _ policy: ReviewPolicy) -> [ReviewFinding] {
        var findings: [ReviewFinding] = []
        let armed = s.config.strategy.allocations.contains(where: \.running)
            && !s.config.strategy.emergencyStop

        if armed {
            if let last = s.lastTickAt {
                let silence = s.now.timeIntervalSince(last)
                if silence > policy.heartbeatStaleAfter {
                    findings.append(ReviewFinding(
                        code: "heartbeat.stale",
                        severity: .critical,
                        title: "交易循环已停",
                        detail: "距上次完成轮询 \(AccountEquityCurve.describe(silence))，"
                            + "超过 \(AccountEquityCurve.describe(policy.heartbeatStaleAfter)) 的容忍；"
                            + "进程\(s.appRunning ? "还活着但循环没在转" : "已经不在了")。"
                            + "仓位当前无人管理。",
                        remedy: s.appRunning
                            ? "重启 MayStock；若重启后仍不跳动，看 Console 里的运行器日志"
                            : "启动 MayStock"))
                }
            } else {
                findings.append(ReviewFinding(
                    code: "heartbeat.missing",
                    severity: .critical,
                    title: "从未记录过心跳",
                    detail: "有策略处于运行状态，但引擎从未完成过一次轮询。",
                    remedy: "启动 MayStock 并确认策略工作台里显示「运行中」"))
            }
        }

        // A hole in the curve is not cosmetic: the chart interpolates across it,
        // so an outage renders as a flat, calm stretch of market.
        let recent = s.accountEquity.filter { s.now.timeIntervalSince($0.ts) <= 86_400 }
        if recent.count >= 2 {
            var worst: (start: Date, seconds: TimeInterval)?
            for index in 1..<recent.count {
                let gap = recent[index].ts.timeIntervalSince(recent[index - 1].ts)
                if gap > (worst?.seconds ?? 0) { worst = (recent[index - 1].ts, gap) }
            }
            if let worst, worst.seconds > policy.equityGapAlarm {
                findings.append(ReviewFinding(
                    code: "equity.gap",
                    severity: .warn,
                    title: "净值曲线有洞",
                    detail: "过去 24 小时里最长一段 \(AccountEquityCurve.describe(worst.seconds))"
                        + "没有采样（从 \(Self.clock(worst.start)) 起）。"
                        + "图上这段会画成一条直线，看起来像行情很平，实际是引擎没在跑。",
                    remedy: "多半是笔记本睡眠。要连续记录就让机器保持唤醒，或接受曲线上的洞并按此读图"))
            }
        }
        return findings
    }

    // MARK: Exposure

    static func exposure(_ s: ReviewSnapshot, _ policy: ReviewPolicy) -> [ReviewFinding] {
        var findings: [ReviewFinding] = []
        let portfolio = s.config.strategy
        let ceiling = portfolio.totalCapital * policy.maxAllocationRatio

        // Splitting 79,658 three ways and rounding to cents leaves a cent over.
        // A cent is not over-allocation, and an unattended fixer that reacts to
        // one would rewrite the config every hour forever without ever reaching
        // a state it is happy with. Anything that acts on its own has to have a
        // resting state; the tolerance is what gives this one one.
        let slack = Swift.max(1.0, portfolio.totalCapital * 0.0005)

        if portfolio.allocatedCapital > ceiling + slack, portfolio.totalCapital > 0 {
            let ratio = portfolio.allocatedCapital / portfolio.totalCapital
            // Scale every budget down by the same factor: the review has no
            // basis for preferring one strategy over another, and picking a
            // favourite here would be exactly the discretionary re-weighting
            // this design refuses to do on a clock. Aim slightly under the
            // ceiling so rounding on the way back cannot land above it again.
            let scale = (ceiling - slack / 2) / portfolio.allocatedCapital
            let actions = portfolio.allocations
                .filter { $0.capital > 0 }
                .map { allocation in
                    ReviewAction.reduceCapital(
                        strategyId: allocation.strategyId,
                        to: (allocation.capital * scale * 100).rounded(.down) / 100,
                        reason: String(format: "预算总额 %.2f× 本金，按比例缩回", ratio))
                }
            findings.append(ReviewFinding(
                code: "capital.overallocated",
                severity: .critical,
                title: "预算之和超过本金",
                detail: String(
                    format: "已分配 %.2f，本金 %.2f，%.2f×（容差 %.2f）"
                        + " —— 这些预算加起来是账户兑现不了的承诺。",
                    portfolio.allocatedCapital, portfolio.totalCapital, ratio, slack),
                remedy: "按同一比例缩回，不挑策略",
                actions: actions))
        }

        for allocation in portfolio.allocations
        where !allocation.running && allocation.capital > 1e-6 {
            findings.append(ReviewFinding(
                code: "capital.idleBudget",
                severity: .info,
                title: "停用的策略仍占着预算",
                detail: String(
                    format: "%@ 已停用，但仍占 %.2f 预算，这部分本金既不工作也不可分配。",
                    allocation.strategyId, allocation.capital),
                remedy: "把它的预算清零，或重新分配给在跑的策略"))
        }

        for (strategyId, position) in s.positions.sorted(by: { $0.key < $1.key })
        where !position.isFlat {
            let allocation = portfolio.allocation(for: strategyId)
            if allocation == nil || allocation?.running == false {
                findings.append(ReviewFinding(
                    code: "position.orphan",
                    severity: .warn,
                    title: "无人管理的持仓",
                    detail: String(
                        format: "%@ %@ 仍持有 %.4f 张，但该策略%@。"
                            + "没有任何信号会来平掉它 —— 止损止盈仍在交易所挂着，其余全靠行情。",
                        strategyId, position.instId, position.quantity,
                        allocation == nil ? "已不在组合里" : "已停用"),
                    remedy: "手动平掉，或重新启用该策略让它自己退出。复盘不会替你下单"))
            }
        }
        return findings
    }

    // MARK: Risk

    static func risk(_ s: ReviewSnapshot, _ policy: ReviewPolicy) -> [ReviewFinding] {
        var findings: [ReviewFinding] = []

        if let breaker = s.config.strategy.maxDrawdownPct,
           let drawdown = Self.drawdownPct(s.accountEquity) {
            if drawdown >= breaker {
                findings.append(ReviewFinding(
                    code: "drawdown.breached",
                    severity: .critical,
                    title: "账户回撤已触及熔断线",
                    detail: String(format: "距高水位 -%.2f%%，熔断线 %.2f%%。", drawdown, breaker),
                    remedy: "运行器应已停止开新仓；确认它确实停了，再决定是否降本金"))
            } else if drawdown >= breaker * policy.drawdownWarnFraction {
                findings.append(ReviewFinding(
                    code: "drawdown.approaching",
                    severity: .warn,
                    title: "账户回撤接近熔断线",
                    detail: String(
                        format: "距高水位 -%.2f%%，熔断线 %.2f%%，已走完 %.0f%%。",
                        drawdown, breaker, drawdown / breaker * 100),
                    remedy: "熔断触发前先想清楚：是策略失效，还是它本来就该经历这段"))
            }
        }

        for allocation in s.config.strategy.allocations where allocation.running {
            let id = allocation.strategyId
            guard let mandate = policy.mandate(for: id) else {
                findings.append(ReviewFinding(
                    code: "mandate.missing",
                    severity: .warn,
                    title: "策略没有预注册的风险预算",
                    detail: "\(id) 正在运行，但 review-policy.json 里没有它的授权额度。"
                        + "没有事先写下的回撤上限，就没有任何客观标准能判定它「跑坏了」——"
                        + "只剩下事后看着亏损临时编一个，那不是风控。",
                    remedy: "跑一次 walkforward + resample，把 p95 回撤写进 review-policy.json"))
                continue
            }

            // A failed re-validation is a standing condition, not a one-off
            // event. Reported on every pass, because the thing that quietly
            // becomes the status quo is whatever stopped being mentioned.
            // Not auto-halted: this is a research judgement, and the automatic
            // side of this system acts on mandate breaches, not on opinions.
            switch mandate.verdict {
            case .failed:
                findings.append(ReviewFinding(
                    code: "mandate.failed",
                    severity: .warn,
                    title: "在跑，但走向前验证没通过",
                    detail: "\(id)（\(Self.day(mandate.validatedAt)) 判定：\(mandate.verdict.label)）"
                        + "\(mandate.evidence)",
                    remedy: "这条不会自动停 —— 停不停是判断，不是规则。要么停用，"
                        + "要么把它降级成小仓位的观察仓，别让它靠「没人再提起」留在账上"))
            case .inconclusive:
                findings.append(ReviewFinding(
                    code: "mandate.inconclusive",
                    severity: .info,
                    title: "在跑，但没能被验证",
                    detail: "\(id)（\(Self.day(mandate.validatedAt))）：\(mandate.evidence)",
                    remedy: "「测不了」不等于「通过」。按未证实的仓位规模对待它"))
            case .validated:
                break
            }

            guard let curve = s.strategyEquity[id], curve.count >= 2 else { continue }

            let liveBars = Int(
                curve[curve.count - 1].ts.timeIntervalSince(curve[0].ts) / mandate.barSeconds)
            switch Self.timeWeightedDrawdownPct(curve) {
            case .unknown(let why):
                findings.append(ReviewFinding(
                    code: "drawdown.strategyUnknown",
                    severity: .info,
                    title: "策略回撤算不出来",
                    detail: "\(id)：\(why)。这里报「算不出」而不是报一个数 —— "
                        + "把调仓造成的台阶当成亏损，会让自动停用规则在每次再平衡后立刻开火。",
                    remedy: "等曲线积累到足够多带基准的采样点即可，无需干预"))
            case .value(let drawdown):
                guard drawdown >= mandate.resampleP95DrawdownPct else { break }
                if liveBars < policy.minimumLiveBarsBeforeHalt {
                    findings.append(ReviewFinding(
                        code: "drawdown.strategyEarly",
                        severity: .warn,
                        title: "策略回撤已超预算，但样本还不够停用",
                        detail: String(
                            format: "%@ 实盘回撤 -%.2f%%，超过预注册的 p95 %.2f%%；"
                                + "但只积累了 %d 根自有周期的数据，不足 %d 根。"
                                + "这条规则有下限，是因为一条能自动动仓的规则必须先防住自己被噪声触发。",
                            id, drawdown, mandate.resampleP95DrawdownPct,
                            liveBars, policy.minimumLiveBarsBeforeHalt),
                        remedy: "人来判断是否提前停；自动规则这时候不会动手"))
                } else {
                    findings.append(ReviewFinding(
                        code: "drawdown.strategyBreached",
                        severity: .critical,
                        title: "策略回撤超出授权额度",
                        detail: String(
                            format: "%@ 实盘回撤 -%.2f%%，超过预注册的 p95 %.2f%%"
                                + "（回测只画出 -%.2f%%）；已积累 %d 根自有周期。",
                            id, drawdown, mandate.resampleP95DrawdownPct,
                            mandate.backtestDrawdownPct, liveBars),
                        remedy: "已自动停用。持仓不动 —— 平仓是人的决定",
                        actions: [.halt(
                            strategyId: id,
                            reason: String(
                                format: "实盘回撤 -%.2f%% 超出 %@ 预注册的 p95 授权 %.2f%%（依据：%@）",
                                drawdown, Self.day(mandate.validatedAt),
                                mandate.resampleP95DrawdownPct, mandate.evidence))]))
                }
            }
        }
        return findings
    }

    // MARK: Carry

    static func carry(_ s: ReviewSnapshot, _ policy: ReviewPolicy) -> [ReviewFinding] {
        var findings: [ReviewFinding] = []
        for (strategyId, position) in s.positions.sorted(by: { $0.key < $1.key }) {
            // `openedAt` is scoped to the *current* position and is absent in
            // ledgers written before it existed, so fall back to the strategy's
            // first fill. Funding accrues from when exposure started, and a
            // missing field must not silently turn that into "no carry".
            let opened = position.openedAt
                ?? s.fills.filter { $0.strategyId == strategyId }.map(\.ts).min()
            guard !position.isFlat,
                  let funding = position.fundingPaid, funding < 0,
                  let opened else { continue }
            let held = s.now.timeIntervalSince(opened)
            let notional = abs(position.baseQuantity) * position.averagePrice
            guard held > 3_600, notional > 0 else { continue }
            let annualised = -funding / notional * (31_536_000 / held) * 100
            guard annualised >= policy.fundingBleedAnnualPct else { continue }
            findings.append(ReviewFinding(
                code: "funding.bleed",
                severity: .warn,
                title: "资金费在吃掉这笔仓位",
                detail: String(
                    format: "%@ %@ 持有 %@ 已付资金费 %.2f，名义 %.0f，年化 %.0f%%。"
                        + "这是持仓成本，不是行情 —— 边际再好也未必付得起。",
                    strategyId, position.instId, AccountEquityCurve.describe(held),
                    -funding, notional, annualised),
                remedy: "确认这个费率是持续的还是一次性尖峰；持续的话，这个方向的持仓期需要重新回测"))
        }
        return findings
    }

    // MARK: Activity

    static func activity(_ s: ReviewSnapshot, _ policy: ReviewPolicy) -> [ReviewFinding] {
        var findings: [ReviewFinding] = []
        for allocation in s.config.strategy.allocations where allocation.running {
            guard let mandate = policy.mandate(for: allocation.strategyId) else { continue }
            let last = s.fills
                .filter { $0.strategyId == allocation.strategyId }
                .map(\.ts).max()
            let since = last ?? allocation.addedAt
            let quietBars = Int(s.now.timeIntervalSince(since) / mandate.barSeconds)
            guard quietBars >= policy.silentTradeAlarmBars else { continue }
            findings.append(ReviewFinding(
                code: "trade.silent",
                severity: .warn,
                title: "策略已经很久没有动作",
                detail: String(
                    format: "%@ 已 %d 根自有周期没有成交（预期约每周 %.1f 次往返）。"
                        + "%@没有报错，所以没有任何东西会提醒你 —— 沉默本身才是信号。",
                    allocation.strategyId, quietBars, mandate.expectedTradesPerWeek,
                    last == nil ? "从加入组合起就没成交过；" : ""),
                remedy: "用 maystock-lab signals 看它最近几根 K 线到底出没出信号"))
        }
        return findings
    }

    // MARK: Evidence

    static func evidence(_ s: ReviewSnapshot, _ policy: ReviewPolicy) -> [ReviewFinding] {
        var findings: [ReviewFinding] = []
        for allocation in s.config.strategy.allocations where allocation.running {
            guard let mandate = policy.mandate(for: allocation.strategyId) else { continue }
            let bars = mandate.barsSinceValidation(now: s.now)
            guard bars >= policy.revalidateAfterBars else { continue }
            findings.append(ReviewFinding(
                code: "evidence.stale",
                severity: .info,
                title: "可以重新验证了",
                detail: String(
                    format: "%@ 自 %@ 验证以来已积累 %d 根新 K 线（阈值 %d）。"
                        + "到这里重跑走向前验证才第一次看得到没见过的窗口；"
                        + "在此之前重跑只是把同一段数据再判一遍。",
                    allocation.strategyId, Self.day(mandate.validatedAt),
                    bars, policy.revalidateAfterBars),
                remedy: "maystock-lab wf \(allocation.strategyId) --days 1000，"
                    + "然后把新的 p95 回撤写回 review-policy.json"))
        }
        return findings
    }

    // MARK: Hygiene

    static func hygiene(_ s: ReviewSnapshot, _ policy: ReviewPolicy) -> [ReviewFinding] {
        var findings: [ReviewFinding] = []

        // Reported, never auto-reverted. Which account the orders reach is the
        // user's decision, and a background job quietly undoing it would be a
        // worse failure than the one it was trying to prevent.
        if s.config.strategy.mode == .live || s.config.trading.liveTradingUnlocked {
            findings.append(ReviewFinding(
                code: "mode.live",
                severity: .critical,
                title: "账户不在模拟盘",
                detail: "mode=\(s.config.strategy.mode.rawValue)，"
                    + "liveTradingUnlocked=\(s.config.trading.liveTradingUnlocked)。"
                    + "自动复盘只汇报，绝不改这一项。",
                remedy: "如果这不是你本人刚刚改的，立刻在设置里改回模拟盘"))
        }

        if s.config.strategy.emergencyStop {
            findings.append(ReviewFinding(
                code: "emergency.on",
                severity: .warn,
                title: "总闸处于关闭状态",
                detail: "所有策略都不会动作，无论各自的开关是什么。",
                remedy: "确认这是有意为之"))
        }

        let configured = s.config.strategy.feeSchedule.slippageBps
        if abs(configured - policy.measuredSlippageBps) > policy.slippageDriftBps {
            findings.append(ReviewFinding(
                code: "config.slippage",
                severity: .info,
                title: "滑点假设与实测值不一致",
                detail: String(
                    format: "配置里 %.1f bps，实测 %.1f bps。回测和实盘会按不同的经济学被判定，"
                        + "同一个策略的两边结论就没法比。",
                    configured, policy.measuredSlippageBps),
                remedy: "改配置里的 feeSchedule.slippageBps，或重新校准后更新 review-policy.json"))
        }

        if policy.mandates.isEmpty {
            findings.append(ReviewFinding(
                code: "policy.empty",
                severity: .warn,
                title: "没有预注册的规则手册",
                detail: "review-policy.json 里一个授权额度都没有，自动停用规则因此永远不会触发。",
                remedy: "maystock-lab review --seed-policy 生成一份初始手册，再逐条核对数字"))
        }
        return findings
    }

    // MARK: Evidence budget

    static func evidenceBudget(_ s: ReviewSnapshot, _ policy: ReviewPolicy) -> EvidenceBudget {
        var budget = EvidenceBudget()
        if let first = s.accountEquity.first, let last = s.accountEquity.last {
            budget.hoursObserved = last.ts.timeIntervalSince(first.ts) / 3_600
        }
        budget.barsSinceValidation = Dictionary(
            uniqueKeysWithValues: policy.mandates.map {
                ($0.strategyId, $0.barsSinceValidation(now: s.now))
            })

        if let noise = Self.hourlyNoisePct(s.accountEquity) {
            budget.hourlyNoisePct = noise
            let armed = s.config.strategy.allocations.filter(\.running)
            let capital = armed.reduce(0) { $0 + $1.capital }
            if capital > 0 {
                // Capital-weighted expectation across the armed mandates,
                // converted from annual to hourly.
                let weighted = armed.reduce(0.0) { total, allocation in
                    guard let mandate = policy.mandate(for: allocation.strategyId) else { return total }
                    return total + mandate.expectedAnnualReturnPct * allocation.capital
                }
                let annual = weighted / capital
                let hourly = annual / 8_760
                if hourly > 0, noise > 0 {
                    budget.hourlyEdgePct = hourly
                    // n such that edge·√n / noise = 2.
                    budget.hoursForSignificance = pow(2 * noise / hourly, 2)
                }
            }
        }
        return budget
    }

    // MARK: Maths

    /// Peak-to-trough drawdown of a raw equity series, in percent.
    public static func drawdownPct(_ points: [AccountEquityPoint]) -> Double? {
        guard points.count >= 2 else { return nil }
        var peak = points[0].equity
        var worst = 0.0
        for point in points {
            peak = Swift.max(peak, point.equity)
            guard peak > 0 else { continue }
            worst = Swift.max(worst, (peak - point.equity) / peak)
        }
        return worst * 100
    }

    public enum DrawdownReading: Sendable, Equatable {
        case value(Double)
        case unknown(String)
    }

    /// Drawdown of a curve whose capital base moves, in percent.
    ///
    /// The trick is that P&L — `equity - basis` — stays continuous across a
    /// re-size while equity does not, so each interval's return can be taken as
    /// the change in P&L over the account value that earned it. Chaining those
    /// gives a curve with the rebalances removed. Without this, halving a
    /// strategy's budget from 39,829 to 19,914 reads as a 50% loss and an
    /// automatic halt rule fires every time somebody rebalances.
    ///
    /// The denominator is the *previous equity*, not the basis, so this returns
    /// the same quantity a backtest's compounding drawdown does — which is what
    /// the mandate's p95 is denominated in. Comparing a limit against a number
    /// computed a different way is a silent unit error wearing a threshold.
    ///
    /// Returns `.unknown` rather than a number when any interval lacks a basis.
    /// A missing basis is not a zero and not a carry-forward: it is a fact we do
    /// not have, and a risk limit must never be compared against a guess.
    public static func timeWeightedDrawdownPct(_ points: [AccountEquityPoint]) -> DrawdownReading {
        guard points.count >= 2 else { return .unknown("样本不足两点") }
        var value = 1.0
        var peak = 1.0
        var worst = 0.0
        for index in 1..<points.count {
            guard let previousBasis = points[index - 1].basis, previousBasis > 0,
                  let basis = points[index].basis, basis > 0 else {
                return .unknown("有采样点没有记录基准资金（早于该字段的旧数据）")
            }
            let previousEquity = points[index - 1].equity
            guard previousEquity > 0 else { return .unknown("有采样点的权益不为正") }
            let previousPnL = previousEquity - previousBasis
            let pnl = points[index].equity - basis
            let step = (pnl - previousPnL) / previousEquity
            guard step.isFinite else { return .unknown("区间收益不可用") }
            value *= (1 + step)
            peak = Swift.max(peak, value)
            guard peak > 0 else { continue }
            worst = Swift.max(worst, (peak - value) / peak)
        }
        return .value(worst * 100)
    }

    /// Standard deviation of hourly returns, in percent.
    ///
    /// Bucketed by clock hour and taken on the closing sample of each, so an
    /// uneven sampling rate does not weight busy hours more heavily.
    static func hourlyNoisePct(_ points: [AccountEquityPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        var closes: [(bucket: Int, equity: Double)] = []
        for point in points {
            let bucket = Int(point.ts.timeIntervalSince1970 / 3_600)
            if closes.last?.bucket == bucket {
                closes[closes.count - 1].equity = point.equity
            } else {
                closes.append((bucket, point.equity))
            }
        }
        guard closes.count >= 4 else { return nil }
        var returns: [Double] = []
        for index in 1..<closes.count {
            // Only consecutive hours: a return taken across a three-hour hole
            // is a three-hour return wearing an hourly label.
            guard closes[index].bucket == closes[index - 1].bucket + 1,
                  closes[index - 1].equity > 0 else { continue }
            returns.append(closes[index].equity / closes[index - 1].equity - 1)
        }
        guard returns.count >= 3 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count - 1)
        return sqrt(variance) * 100
    }

    // MARK: Formatting

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = EquityWindow.timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = EquityWindow.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private func > (lhs: (ReviewSeverity, String), rhs: (ReviewSeverity, String)) -> Bool {
    lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 > rhs.0
}
