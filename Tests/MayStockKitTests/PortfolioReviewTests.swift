import Foundation
import Testing
@testable import MayStockKit

private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

private func at(_ hours: Double) -> Date {
    epoch.addingTimeInterval(hours * 3_600)
}

private func allocation(
    _ id: String, capital: Double, running: Bool = true, addedAt: Date = epoch
) -> StrategyAllocation {
    StrategyAllocation(strategyId: id, capital: capital, running: running, addedAt: addedAt)
}

private func config(
    _ allocations: [StrategyAllocation],
    totalCapital: Double = 100_000,
    mode: TradingMode = .demo,
    emergencyStop: Bool = false
) -> AppConfig {
    var config = AppConfig.default
    config.strategy.mode = mode
    config.strategy.totalCapital = totalCapital
    config.strategy.allocations = allocations
    config.strategy.emergencyStop = emergencyStop
    config.strategy.feeSchedule.slippageBps = 1
    return config
}

private func mandate(
    _ id: String, p95: Double = 30, backtest: Double = 20,
    barSeconds: TimeInterval = 86_400, validatedAt: Date = epoch,
    tradesPerWeek: Double = 0.35, annual: Double = 40
) -> StrategyMandate {
    StrategyMandate(
        strategyId: id, barSeconds: barSeconds, resampleP95DrawdownPct: p95,
        backtestDrawdownPct: backtest, expectedTradesPerWeek: tradesPerWeek,
        expectedAnnualReturnPct: annual, validatedAt: validatedAt, evidence: "测试用")
}

/// A curve whose capital base is recorded, so drawdown can be separated from
/// re-sizing.
private func curve(_ samples: [(hours: Double, equity: Double, basis: Double?)])
    -> [AccountEquityPoint]
{
    samples.map { AccountEquityPoint(ts: at($0.hours), equity: $0.equity, basis: $0.basis) }
}

// MARK: - The de-risking invariant

@Suite("复盘只能减仓")
struct ReviewActuatorTests {
    @Test func haltDisarmsAndRecordsWhy() {
        let before = config([allocation("a", capital: 50_000)])
        let outcome = ReviewActuator.apply(
            [.halt(strategyId: "a", reason: "超出授权额度")], to: before)
        #expect(outcome.applied.count == 1)
        #expect(outcome.rejected.isEmpty)
        #expect(outcome.config.strategy.allocation(for: "a")?.running == false)
        #expect(outcome.config.strategy.allocation(for: "a")?.haltReason == "超出授权额度")
        // The position budget is untouched: disarming is not closing.
        #expect(outcome.config.strategy.allocation(for: "a")?.capital == 50_000)
    }

    @Test func raisingABudgetIsRejected() {
        let before = config([allocation("a", capital: 10_000)])
        let outcome = ReviewActuator.apply(
            [.reduceCapital(strategyId: "a", to: 20_000, reason: "bug")], to: before)
        #expect(outcome.applied.isEmpty)
        #expect(outcome.rejected.count == 1)
        #expect(outcome.rejected[0].why.contains("提高"))
        #expect(outcome.config.strategy.allocation(for: "a")?.capital == 10_000)
    }

    @Test func oneBadActionCannotRideInOnAGoodOne() {
        let before = config([allocation("a", capital: 10_000), allocation("b", capital: 10_000)])
        let outcome = ReviewActuator.apply([
            .reduceCapital(strategyId: "a", to: 5_000, reason: "缩回"),
            .reduceCapital(strategyId: "b", to: 90_000, reason: "bug"),
        ], to: before)
        #expect(outcome.applied.count == 1)
        #expect(outcome.rejected.count == 1)
        #expect(outcome.config.strategy.allocation(for: "a")?.capital == 5_000)
        #expect(outcome.config.strategy.allocation(for: "b")?.capital == 10_000)
    }

    @Test func actionsAgainstAnUnknownStrategyAreRejectedNotInvented() {
        let before = config([allocation("a", capital: 10_000)])
        let outcome = ReviewActuator.apply(
            [.halt(strategyId: "ghost", reason: "x")], to: before)
        #expect(outcome.applied.isEmpty)
        #expect(outcome.rejected.count == 1)
        #expect(outcome.config.strategy.allocations.count == 1)
    }

    /// The invariant is checked field by field rather than on one summary
    /// number, so these all trip it even where armed capital is unchanged.
    @Test func everyWayToIncreaseRiskIsNamed() {
        let base = config([allocation("a", capital: 10_000)])

        var live = base
        live.strategy.mode = .live
        #expect(ReviewActuator.derisksViolation(from: base, to: live)?.contains("模式") == true)

        var unlocked = base
        unlocked.trading.liveTradingUnlocked = true
        #expect(ReviewActuator.derisksViolation(from: base, to: unlocked)?.contains("实盘") == true)

        var richer = base
        richer.strategy.totalCapital *= 2
        #expect(ReviewActuator.derisksViolation(from: base, to: richer)?.contains("本金") == true)

        var loosened = base
        loosened.strategy.maxDrawdownPct = 90
        #expect(ReviewActuator.derisksViolation(from: base, to: loosened)?.contains("熔断") == true)

        var disabled = base
        disabled.strategy.maxDrawdownPct = nil
        #expect(ReviewActuator.derisksViolation(from: base, to: disabled)?.contains("熔断") == true)

        var added = base
        added.strategy.allocations.append(allocation("b", capital: 0))
        #expect(ReviewActuator.derisksViolation(from: base, to: added)?.contains("新增") == true)

        var armed = config([allocation("a", capital: 10_000, running: false)])
        armed.strategy.allocations[0].running = true
        let stopped = config([allocation("a", capital: 10_000, running: false)])
        #expect(ReviewActuator.derisksViolation(from: stopped, to: armed)?.contains("启动") == true)

        var levered = base
        levered.strategy.allocations[0].leverageCap = 5
        var capped = base
        capped.strategy.allocations[0].leverageCap = 2
        #expect(ReviewActuator.derisksViolation(from: capped, to: levered)?.contains("杠杆") == true)

        // Releasing the kill switch is an increase in risk even though every
        // other field is identical.
        let halted = config([allocation("a", capital: 10_000)], emergencyStop: true)
        #expect(ReviewActuator.derisksViolation(from: halted, to: base)?.contains("总闸") == true)
    }

    @Test func genuineDeriskingPasses() {
        let before = config([allocation("a", capital: 10_000), allocation("b", capital: 10_000)])
        var after = before
        after.strategy.allocations[0].capital = 4_000
        after.strategy.allocations[1].running = false
        after.strategy.emergencyStop = true
        #expect(ReviewActuator.derisksViolation(from: before, to: after) == nil)
    }
}

// MARK: - Drawdown with a moving capital base

@Suite("回撤要能和调仓分开")
struct TimeWeightedDrawdownTests {
    /// The bug this exists to prevent: halving a strategy's budget puts a 50%
    /// cliff in its equity curve, and a naive reading calls that a catastrophe.
    @Test func resizingIsNotALoss() {
        let points = curve([
            (0, 40_000, 40_000),
            (1, 40_000, 40_000),
            (2, 20_000, 20_000),   // budget halved, P&L still zero
            (3, 20_000, 20_000),
        ])
        #expect(PortfolioReview.drawdownPct(points)! > 49)   // the naive reading
        guard case .value(let drawdown, _, _) = PortfolioReview.timeWeightedDrawdownPct(points)
        else {
            Issue.record("应当能算出来")
            return
        }
        #expect(abs(drawdown) < 1e-9)
    }

    /// Denominated the same way a backtest's drawdown is — peak equity, not
    /// capital at risk — because that is what the mandate's p95 is measured in.
    /// 44,000 → 38,000 is 13.64% of the peak, not 15% of the 40,000 budget.
    @Test func realLossesStillShow() {
        let points = curve([
            (0, 40_000, 40_000),
            (1, 44_000, 40_000),   // +10%
            (2, 38_000, 40_000),   // -6,000 off a 44,000 peak
            (3, 40_000, 40_000),
        ])
        guard case .value(let drawdown, _, _) = PortfolioReview.timeWeightedDrawdownPct(points)
        else {
            Issue.record("应当能算出来")
            return
        }
        #expect(abs(drawdown - 13.636) < 0.01)
        // And it agrees with the naive reading whenever the basis never moves —
        // the correction must be invisible when there is nothing to correct.
        #expect(abs(drawdown - PortfolioReview.drawdownPct(points)!) < 0.01)
    }

    /// A loss that happens across a re-size is still a loss, and is measured
    /// against the capital that was actually at risk for it.
    @Test func lossAcrossAResizeSurvives() {
        let points = curve([
            (0, 40_000, 40_000),
            (1, 36_000, 40_000),   // -10% on 40k
            (2, 18_000, 20_000),   // budget halved; P&L still -4,000... but now -2,000
            (3, 18_000, 20_000),
        ])
        guard case .value(let drawdown, _, _) = PortfolioReview.timeWeightedDrawdownPct(points)
        else {
            Issue.record("应当能算出来")
            return
        }
        // -10% then +5% recovery of the earlier loss on the same 40k base.
        #expect(drawdown > 9.9 && drawdown < 10.1)
    }

    /// Unknown must stay unknown. A missing basis is not zero, and not the
    /// previous value carried forward — a risk limit compared against a guess
    /// is worse than no limit at all, because it looks like one.
    @Test func tooLittleBasisReportsUnknownRatherThanANumber() {
        let points = curve([
            (0, 40_000, 40_000),
            (1, 20_000, nil),
            (2, 20_000, 20_000),      // only one usable point at the tail
        ])
        guard case .unknown(let why) = PortfolioReview.timeWeightedDrawdownPct(points) else {
            Issue.record("缺基准时不该给出一个数")
            return
        }
        #expect(why.contains("基准"))
    }

    /// Legacy points are skipped, not fatal: a curve holds thirty days, and
    /// refusing to look at anything until the last basis-less point ages out
    /// would leave the halt rule blind for a month.
    @Test func legacyPointsAreSkippedRatherThanPoisoningTheReading() {
        let points = curve([
            (0, 99_999, nil),         // written before `basis` existed
            (1, 99_999, nil),
            (2, 40_000, 40_000),
            (3, 44_000, 40_000),
            (4, 38_000, 40_000),
        ])
        guard case .value(let drawdown, let from, let samples) =
            PortfolioReview.timeWeightedDrawdownPct(points)
        else {
            Issue.record("尾部有三个带基准的点，应当能算")
            return
        }
        #expect(samples == 3)
        #expect(from == at(2))
        #expect(abs(drawdown - 13.636) < 0.01)
    }

    /// The span travels with the number. Two hours of drawdown and two months
    /// of it are different claims, and a caller that cannot tell them apart
    /// will eventually enforce a limit on the first as if it were the second.
    @Test func theReadingCarriesHowMuchHistoryItSaw() {
        let points = curve([(0, 40_000, 40_000), (1, 40_000, 40_000)])
        guard case .value(_, let from, let samples) =
            PortfolioReview.timeWeightedDrawdownPct(points)
        else {
            Issue.record("应当能算出来")
            return
        }
        #expect(from == at(0))
        #expect(samples == 2)
    }
}

// MARK: - Checks

@Suite("复盘检查项")
struct PortfolioReviewChecksTests {
    private func snapshot(
        _ config: AppConfig, now: Date = at(48), lastTick: Date? = at(48)
    ) -> ReviewSnapshot {
        ReviewSnapshot(now: now, config: config, lastTickAt: lastTick)
    }

    @Test func aStoppedHeartbeatIsCriticalWhileArmed() {
        let result = PortfolioReview.run(
            snapshot(config([allocation("a", capital: 10_000)]), lastTick: at(40)),
            policy: ReviewPolicy(mandates: [mandate("a")]))
        #expect(result.findings.contains { $0.code == "heartbeat.stale" })
        #expect(result.verdict == .critical)
    }

    @Test func aStoppedHeartbeatIsSilentWhenNothingIsArmed() {
        let result = PortfolioReview.run(
            snapshot(
                config([allocation("a", capital: 0, running: false)]), lastTick: at(10)),
            policy: ReviewPolicy(mandates: [mandate("a")]))
        #expect(!result.findings.contains { $0.code.hasPrefix("heartbeat") })
    }

    /// Splitting a pot three ways and rounding to cents leaves a cent over. An
    /// unattended fixer that reacts to a cent never reaches a resting state.
    @Test func aRoundingCentIsNotOverAllocation() {
        let pot = 79_658.0
        let each = (pot / 3 * 100).rounded() / 100     // 26,552.67 → sums to 79,658.01
        let result = PortfolioReview.run(
            snapshot(config(
                [allocation("a", capital: each), allocation("b", capital: each),
                 allocation("c", capital: each)],
                totalCapital: pot)),
            policy: ReviewPolicy(mandates: [mandate("a"), mandate("b"), mandate("c")]))
        #expect(!result.findings.contains { $0.code == "capital.overallocated" })
    }

    @Test func realOverAllocationScalesEveryBudgetAndConverges() {
        let start = config(
            [allocation("a", capital: 80_000), allocation("b", capital: 80_000)],
            totalCapital: 100_000)
        let policy = ReviewPolicy(mandates: [mandate("a"), mandate("b")])
        let first = PortfolioReview.run(snapshot(start), policy: policy)
        #expect(first.findings.contains { $0.code == "capital.overallocated" })
        #expect(first.actions.count == 2)

        let outcome = ReviewActuator.apply(first.actions, to: start)
        #expect(outcome.applied.count == 2)
        #expect(outcome.config.strategy.allocatedCapital <= 100_000)

        // The whole point: a second pass over the state we just wrote must be
        // quiet, or the hourly job rewrites the config forever.
        let second = PortfolioReview.run(snapshot(outcome.config), policy: policy)
        #expect(!second.findings.contains { $0.code == "capital.overallocated" })
        #expect(second.actions.isEmpty)
    }

    @Test func anArmedStrategyWithoutAMandateIsFlagged() {
        let result = PortfolioReview.run(
            snapshot(config([allocation("a", capital: 10_000)])),
            policy: ReviewPolicy(mandates: []))
        #expect(result.findings.contains { $0.code == "mandate.missing" })
        #expect(result.findings.contains { $0.code == "policy.empty" })
    }

    @Test func livemodeIsReportedAndNeverReverted() {
        let live = config([allocation("a", capital: 10_000)], mode: .live)
        let result = PortfolioReview.run(
            snapshot(live), policy: ReviewPolicy(mandates: [mandate("a")]))
        let finding = result.findings.first { $0.code == "mode.live" }
        #expect(finding?.severity == .critical)
        // Reported only: nothing in the action list touches the mode.
        #expect(finding?.actions.isEmpty == true)
        let outcome = ReviewActuator.apply(result.actions, to: live)
        #expect(outcome.config.strategy.mode == .live)
    }

    @Test func aHeldPositionOnAStoppedStrategyIsFlaggedButNotTraded() {
        var state = StrategyPositionState(strategyId: "a", instId: "BTC-USDT-SWAP")
        state.quantity = -10
        state.averagePrice = 64_000
        var snap = snapshot(config([allocation("a", capital: 0, running: false)]))
        snap.positions = ["a": state]
        let result = PortfolioReview.run(snap, policy: ReviewPolicy(mandates: [mandate("a")]))
        let finding = result.findings.first { $0.code == "position.orphan" }
        #expect(finding?.severity == .warn)
        #expect(finding?.actions.isEmpty == true)
    }

    /// A rule that can act on its own has to be protected from acting on noise
    /// first. One bad hour of a daily strategy is not a verdict.
    @Test func theHaltRuleWaitsForEnoughOfItsOwnBars() {
        var snap = snapshot(config([allocation("a", capital: 10_000)]), now: at(72))
        snap.strategyEquity = ["a": curve([
            (0, 10_000, 10_000),
            (24, 10_000, 10_000),
            (48, 5_000, 10_000),      // -50%, way past any mandate
        ])]
        let policy = ReviewPolicy(
            minimumLiveBarsBeforeHalt: 20, mandates: [mandate("a", p95: 30)])
        let result = PortfolioReview.run(snap, policy: policy)
        #expect(result.findings.contains { $0.code == "drawdown.strategyEarly" })
        #expect(result.actions.isEmpty)
    }

    @Test func theHaltRuleFiresOnceThereIsEnoughHistory() {
        var samples: [(Double, Double, Double?)] = []
        for day in 0..<40 { samples.append((Double(day) * 24, 10_000, 10_000)) }
        samples.append((40 * 24, 6_000, 10_000))      // -40% past a 30% mandate
        var snap = snapshot(
            config([allocation("a", capital: 10_000)]), now: at(41 * 24))
        snap.strategyEquity = ["a": curve(samples)]
        let policy = ReviewPolicy(
            minimumLiveBarsBeforeHalt: 20, mandates: [mandate("a", p95: 30)])
        let result = PortfolioReview.run(snap, policy: policy)
        #expect(result.findings.contains { $0.code == "drawdown.strategyBreached" })
        guard case .halt(let id, let reason) = result.actions.first else {
            Issue.record("应当产生一个停用动作")
            return
        }
        #expect(id == "a")
        // The notice quotes the pre-registered number and its date, so the halt
        // can be audited against a decision made before the loss.
        #expect(reason.contains("30.00%"))
    }

    /// Re-validation is scheduled by accumulated evidence, never by the clock.
    @Test func revalidationIsScheduledByBarsNotByHours() {
        let armed = config([allocation("a", capital: 10_000)])
        let fresh = ReviewPolicy(
            revalidateAfterBars: 63, mandates: [mandate("a", validatedAt: at(0))])
        // Ten days later: 3,600 hourly reviews have run, ten new bars exist.
        let early = PortfolioReview.run(
            snapshot(armed, now: at(10 * 24), lastTick: at(10 * 24)), policy: fresh)
        #expect(!early.findings.contains { $0.code == "evidence.stale" })

        let later = PortfolioReview.run(
            snapshot(armed, now: at(70 * 24), lastTick: at(70 * 24)), policy: fresh)
        #expect(later.findings.contains { $0.code == "evidence.stale" })
    }

    @Test func fundingBleedIsMeasuredAgainstNotionalAndAnnualised() {
        var state = StrategyPositionState(strategyId: "a", instId: "ETH-USDT-SWAP")
        state.quantity = -27.4
        state.contractSize = 0.1
        state.averagePrice = 1_919.58
        state.fundingPaid = -46.71
        state.openedAt = at(26)
        var snap = snapshot(config([allocation("a", capital: 10_000)]))
        snap.positions = ["a": state]
        let result = PortfolioReview.run(snap, policy: ReviewPolicy(mandates: [mandate("a")]))
        let finding = result.findings.first { $0.code == "funding.bleed" }
        #expect(finding != nil)
        #expect(finding?.detail.contains("年化") == true)
    }

    @Test func receivingFundingIsNotBleeding() {
        var state = StrategyPositionState(strategyId: "a", instId: "BTC-USDT-SWAP")
        state.quantity = -10.32
        state.contractSize = 0.01
        state.averagePrice = 64_650
        state.fundingPaid = 36.37          // positive: we were paid
        state.openedAt = at(26)
        var snap = snapshot(config([allocation("a", capital: 10_000)]))
        snap.positions = ["a": state]
        let result = PortfolioReview.run(snap, policy: ReviewPolicy(mandates: [mandate("a")]))
        #expect(!result.findings.contains { $0.code == "funding.bleed" })
    }

    @Test func aQuietStrategyIsFlaggedEvenThoughNothingErrored() {
        let snap = snapshot(
            config([allocation("a", capital: 10_000, addedAt: at(0))]), now: at(30 * 24))
        let policy = ReviewPolicy(
            silentTradeAlarmBars: 10, mandates: [mandate("a")])
        let result = PortfolioReview.run(snap, policy: policy)
        #expect(result.findings.contains { $0.code == "trade.silent" })
    }

    @Test func aHoleInTheCurveIsReportedBecauseTheChartHidesIt() {
        var snap = snapshot(config([allocation("a", capital: 10_000)]), now: at(48))
        snap.accountEquity = curve([
            (40, 100_000, nil), (41, 100_000, nil), (45, 100_000, nil), (46, 100_000, nil),
        ])
        let result = PortfolioReview.run(snap, policy: ReviewPolicy(mandates: [mandate("a")]))
        #expect(result.findings.contains { $0.code == "equity.gap" })
    }
}

// MARK: - Evidence budget

@Suite("一次读数含有多少结论")
struct EvidenceBudgetTests {
    /// The number that makes the case: hourly noise dwarfs an hour of edge, so
    /// one reading carries a vanishing share of an answer. Printed every run so
    /// it does not have to be remembered.
    @Test func hoursForSignificanceDwarfsAnHour() {
        var points: [AccountEquityPoint] = []
        var equity = 100_000.0
        // A deterministic saw with ~0.08% hourly amplitude — the scale actually
        // measured on the live curve.
        for hour in 0..<48 {
            equity *= hour % 2 == 0 ? 1.0008 : 0.9992
            points.append(AccountEquityPoint(ts: at(Double(hour)), equity: equity))
        }
        var snap = ReviewSnapshot(
            now: at(48), config: config([allocation("a", capital: 100_000)]))
        snap.accountEquity = points
        let policy = ReviewPolicy(mandates: [mandate("a", annual: 40)])
        let budget = PortfolioReview.evidenceBudget(snap, policy)

        #expect(budget.hourlyNoisePct! > 0.05)
        #expect(abs(budget.hourlyEdgePct! - 40.0 / 8_760) < 1e-9)
        // Thousands of hours, i.e. months — not one.
        #expect(budget.hoursForSignificance! > 1_000)
        #expect(budget.headline.contains("统计含量"))
    }

    /// A return taken across a three-hour hole is a three-hour return wearing
    /// an hourly label; including it would overstate the noise.
    @Test func gapsAreExcludedFromTheNoiseEstimate() {
        let dense = (0..<12).map {
            AccountEquityPoint(ts: at(Double($0)), equity: 100_000 + Double($0 % 2) * 50)
        }
        let holed = dense + [AccountEquityPoint(ts: at(40), equity: 130_000)]
        let a = PortfolioReview.hourlyNoisePct(dense)
        let b = PortfolioReview.hourlyNoisePct(holed)
        #expect(a != nil)
        #expect(abs(a! - b!) < 1e-9)
    }

    /// Every branch that cannot produce a number says which input is missing.
    /// "Cannot estimate", unqualified, is the same silence-reads-as-approval
    /// failure the rest of this report exists to avoid.
    @Test func everyUnknownNamesItsMissingInput() {
        #expect(EvidenceBudget().headline.contains("噪声"))
        #expect(EvidenceBudget(hourlyNoisePct: 0.07).headline.contains("年化期望"))
    }
}

// MARK: - Policy persistence

@Suite("规则手册")
struct ReviewPolicyStoreTests {
    @Test func absentThresholdsDecodeToTheDefaultNotToOff() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ReviewPolicyStore(directory: directory)
        try Data(#"{"version":1,"mandates":[]}"#.utf8).write(to: store.fileURL)
        let policy = store.load()
        #expect(policy.heartbeatStaleAfter == ReviewPolicy().heartbeatStaleAfter)
        #expect(policy.minimumLiveBarsBeforeHalt == ReviewPolicy().minimumLiveBarsBeforeHalt)
        #expect(policy.maxAllocationRatio == 1.0)
    }

    @Test func anAbsentFileMeansTheDefaultsNotNoRules() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = ReviewPolicyStore(directory: directory)
        #expect(!store.exists)
        #expect(store.load().heartbeatStaleAfter == ReviewPolicy().heartbeatStaleAfter)
    }

    @Test func aMandateCountsBarsNotWallClock() {
        let daily = mandate("a", barSeconds: 86_400, validatedAt: at(0))
        #expect(daily.barsSinceValidation(now: at(24 * 10)) == 10)
        #expect(daily.barsSinceValidation(now: at(1)) == 0)
    }
}

// MARK: - Book versus account

/// Every other check reads our own numbers. This is the only one that can
/// catch arithmetic, because a wrong figure agrees with everything derived
/// from it — which is exactly how a tenfold P&L survived a full review pass.
@Suite("账本与交易所对账")
struct BookDriftTests {

    private static let instId = "ETH-USDT-SWAP"

    private func position(
        realised: Double = 145.71, fees: Double = 11.33, funding: Double = -45.26,
        strategyId: String = "eth-short"
    ) -> StrategyPositionState {
        var state = StrategyPositionState(strategyId: strategyId, instId: Self.instId)
        state.contractSize = 0.1
        state.quantity = -39.46
        state.averagePrice = 1_886.08
        state.realisedPnL = realised
        state.feesPaid = fees
        state.fundingPaid = funding
        return state
    }

    private func totals(
        earliest: Date = at(-100), tradeIds: Set<String> = ["f1"]
    ) -> ExchangeBookTotals {
        ExchangeBookTotals(
            instId: Self.instId, realisedPnL: 145.71, fees: 11.33, funding: -45.26,
            earliestBillAt: earliest, tradeIds: tradeIds)
    }

    private func snapshot(
        positions: [String: StrategyPositionState],
        totals: [String: ExchangeBookTotals]?,
        firstFillAt: Date = at(-50)
    ) -> ReviewSnapshot {
        ReviewSnapshot(
            now: at(0),
            config: config([allocation("eth-short", capital: 26_552)]),
            positions: positions,
            fills: [StrategyFill(
                id: "f1", strategyId: "eth-short", instId: Self.instId, side: .sell,
                price: 1_919, quantity: 40, feeQuote: 3.8, ts: firstFillAt,
                clOrdId: nil, mode: .demo)],
            exchangeTotals: totals)
    }

    @Test("三个进钱的字段，任何一个对不上都要报严重")
    func everyMoneyFieldIsCompared() {
        // Walked as a table rather than asserted once on realisedPnL: these are
        // the only three ways money enters the book, and a check that only
        // guards the field that broke last time guards nothing.
        let drifts: [(String, StrategyPositionState)] = [
            ("已实现盈亏", position(realised: 975.03)),
            ("手续费", position(fees: 22.66)),
            ("资金费", position(funding: -90.52)),
        ]
        for (label, drifted) in drifts {
            let result = PortfolioReview.bookDrift(
                snapshot(positions: ["eth-short": drifted], totals: [Self.instId: totals()]),
                ReviewPolicy())
            #expect(result.count == 1, "\(label) 没被发现")
            #expect(result.first?.code == "ledger.drift")
            #expect(result.first?.severity == .critical)
            #expect(result.first?.detail.contains(label) == true)
        }
    }

    @Test("两边一致时不出声")
    func agreementIsQuiet() {
        let result = PortfolioReview.bookDrift(
            snapshot(positions: ["eth-short": position()], totals: [Self.instId: totals()]),
            ReviewPolicy())
        #expect(result.isEmpty)
    }

    @Test("取不到账单是「没核对」，不是「核对通过」")
    func unreachableIsNotAPass() {
        let result = PortfolioReview.bookDrift(
            snapshot(positions: ["eth-short": position()], totals: nil), ReviewPolicy())
        #expect(result.map(\.code) == ["ledger.uncheckable"])
    }

    /// OKX serves a bounded window of bills. A book older than the window
    /// differs for the window's reason, and crying drift there would train
    /// everyone to ignore the check.
    @Test("账单窗口盖不住历史时，报「比不了」而不是报差异")
    func aShortBillWindowIsNotDrift() {
        let result = PortfolioReview.bookDrift(
            snapshot(
                positions: ["eth-short": position(realised: 975.03)],
                // The window does not carry our fill: that, not a timestamp
                // comparison, is what "does not cover" means.
                totals: [Self.instId: totals(earliest: at(-10), tradeIds: ["someone-else"])],
                firstFillAt: at(-50)),
            ReviewPolicy())
        #expect(result.map(\.code) == ["ledger.uncheckable"])
    }

    /// The bill for a fill is stamped on or just after the fill. Deciding
    /// coverage on stamps therefore called a complete window incomplete, and
    /// the check reported a reason that had nothing to do with the truth.
    @Test("账单比成交晚几毫秒，不算窗口不够")
    func aBillStampedAfterItsFillStillCounts() {
        let result = PortfolioReview.bookDrift(
            snapshot(
                positions: ["eth-short": position()],
                totals: [Self.instId: totals(earliest: at(-50).addingTimeInterval(0.4))],
                firstFillAt: at(-50)),
            ReviewPolicy())
        #expect(result.isEmpty)
    }

    @Test("同一合约两个策略时不猜归属")
    func sharedInstrumentsAreNotGuessed() {
        let result = PortfolioReview.bookDrift(
            snapshot(
                positions: [
                    "eth-short": position(realised: 975.03),
                    "eth-other": position(realised: 0, strategyId: "eth-other"),
                ],
                totals: [Self.instId: totals()]),
            ReviewPolicy())
        #expect(result.isEmpty)
    }

    /// The real bill shape, so a CLI field rename cannot pass silently.
    @Test("按交易所真实账单字段解析")
    func parsesTheRealBillShape() {
        let json = """
        [{"billId":"1","instId":"ETH-USDT-SWAP","type":"2","subType":"6","pnl":"92.1462",
          "fee":"-2.58375","balChg":"89.56245","ts":"1786501007000"},
         {"billId":"2","instId":"ETH-USDT-SWAP","type":"8","subType":"173","pnl":"-32.237933",
          "fee":"0","balChg":"-32.237933","ts":"1786320000000"}]
        """
        let totals = TradeBridge.parseBookTotals(json: [json])["ETH-USDT-SWAP"]
        #expect(abs((totals?.realisedPnL ?? 0) - 92.1462) < 1e-9)
        // Fees are filed negative on the wire and held as a positive cost.
        #expect(abs((totals?.fees ?? 0) - 2.58375) < 1e-9)
        #expect(abs((totals?.funding ?? 0) + 32.237933) < 1e-9)
        #expect(totals?.earliestBillAt == Date(timeIntervalSince1970: 1_786_320_000))
    }

    /// The live listing and the archive overlap. Counting a settlement twice
    /// because it appeared in both would manufacture the very drift this check
    /// reports — and it would look exactly like a real bookkeeping defect.
    @Test("两个窗口重叠的账单只算一次")
    func overlappingWindowsAreMergedOnBillId() {
        let live = """
        [{"billId":"7","instId":"ETH-USDT-SWAP","type":"8","subType":"173","pnl":"-32.24",
          "fee":"0","balChg":"-32.24","ts":"1786320000000"}]
        """
        let archive = """
        [{"billId":"7","instId":"ETH-USDT-SWAP","type":"8","subType":"173","pnl":"-32.24",
          "fee":"0","balChg":"-32.24","ts":"1786320000000"},
         {"billId":"6","instId":"ETH-USDT-SWAP","type":"2","subType":"1","pnl":"0",
          "fee":"-3.843","balChg":"-3.843","ts":"1786040201000"}]
        """
        let totals = TradeBridge.parseBookTotals(json: [live, archive])["ETH-USDT-SWAP"]
        #expect(abs((totals?.funding ?? 0) + 32.24) < 1e-9)
        // And the archive extends the window back to the opening trade.
        #expect(abs((totals?.fees ?? 0) - 3.843) < 1e-9)
        #expect(totals?.earliestBillAt == Date(timeIntervalSince1970: 1_786_040_201))
    }
}
