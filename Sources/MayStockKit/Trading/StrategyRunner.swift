import Foundation
import Observation

// MARK: - Runtime state

public struct StrategyRuntimeState: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case stopped, warmingUp, running, halted, failed

        public var displayName: String {
            switch self {
            case .stopped: return "已停止"
            case .warmingUp: return "预热中"
            case .running: return "运行中"
            case .halted: return "已熔断"
            case .failed: return "出错"
            }
        }

        public var isActive: Bool { self == .running || self == .warmingUp }
    }

    public var status: Status = .stopped
    public var message: String?
    public var barsLoaded: Int = 0
    public var lastBarTime: Date?
    public var lastEvaluatedAt: Date?
    public var lastOrderAt: Date?
    public var targetDirection: TradeDirection?

    public init() {}
}

/// What the runner is allowed to reach. Keeping this a protocol lets the engine
/// stay in MayStockKit (and stay testable) while the app owns the state.
@MainActor
public protocol StrategyRunnerHost: AnyObject {
    var portfolio: StrategyPortfolioPrefs { get }
    var liveTradingUnlocked: Bool { get }
    var runnableStrategies: [CompiledStrategy] { get }
    var ledger: StrategyLedger { get }
    /// The exchange this portfolio trades on. A protocol, not a concrete
    /// client, so a second venue is one conformance rather than an edit here.
    var venue: any ExchangeVenue { get }

    func runnerDidChange()
    /// A tick completed. Persisted as a heartbeat, so an app that was killed,
    /// slept, or whose loop died can be told apart from one that simply had
    /// nothing to do.
    func runnerDidCompleteTick(at ts: Date)
    func runnerDidHalt(strategyId: String, reason: String)
    /// A fresh reading of total account equity, for the equity curve.
    func runnerDidSampleEquity(_ equity: Double, at ts: Date)
    /// One strategy's own equity — its allocated capital compounded by its own
    /// P&L. Kept separate from the account total because that is the series a
    /// single-strategy backtest can actually be compared against; the account
    /// curve mixes every strategy together.
    ///
    /// `basis` is the budget that equity was measured against, so a later
    /// re-sizing of the strategy can be told apart from a loss. Without it the
    /// series has an unmarked cliff at every rebalance.
    func runnerDidSampleStrategyEquity(
        _ strategyId: String, equity: Double, basis: Double, at ts: Date)
}

// MARK: - Runner

/// Drives live strategies: one evaluation per closed bar, orders sized against
/// each strategy's own budget, every fill tagged and booked.
///
/// This is deliberately a *low-frequency* engine. It polls REST on a slow tick
/// rather than reacting to every websocket message, because a 1H strategy that
/// reacts within a second of the bar close is indistinguishable from one that
/// reacts within a minute — and the slow path is far easier to reason about
/// when real money is on the other end.
@Observable
@MainActor
public final class StrategyRunner {
    public private(set) var states: [String: StrategyRuntimeState] = [:]
    /// Latest traded price per instrument, for marking positions.
    public private(set) var marks: [String: Double] = [:]
    public private(set) var isTicking = false
    public private(set) var lastTickAt: Date?
    /// When the in-flight tick began, for the stall watchdog below.
    private var tickStartedAt: Date?

    /// Latest total account equity in the quote currency, and the balances it
    /// was computed from. Sampled on the tick so the menu bar always has a
    /// figure, whether or not any strategy is armed.
    public private(set) var accountEquity: Double?
    public private(set) var accountBalances: [AccountBalance] = []
    public private(set) var lastEquitySampleAt: Date?
    /// Absolute market value of everything that is not a stablecoin: spot coin
    /// holdings plus the notional of every open derivative position.
    ///
    /// Shorts count as exposure, not as a credit — being short 4 ETH is 4 ETH
    /// of price risk. Netting the two would report a hedged book as flat.
    public private(set) var nonStableExposure: Double = 0

    /// Fiat-pegged currencies, which carry no price risk worth reporting.
    public static let stableCurrencies: Set<String> = [
        "USDT", "USDC", "USD", "DAI", "TUSD", "FDUSD", "PYUSD", "BUSD", "USDD",
    ]

    /// Non-stable exposure as a share of account equity, or nil until both are
    /// known.
    public var nonStableExposurePct: Double? {
        guard let equity = accountEquity, equity > 0 else { return nil }
        return nonStableExposure / equity * 100
    }

    /// Everything the workbench trades settles in USDT, and per-strategy P&L is
    /// denominated in it, so equity is reported in it too.
    public static let quoteCurrency = "USDT"
    /// Equity is polled far less often than the tick: a curve read at 1-minute
    /// resolution is plenty, and each sample costs an authenticated CLI call.
    public static let equitySampleInterval: TimeInterval = 60

    /// A tick that has run this long is wedged. Nothing in a low-frequency
    /// engine legitimately takes minutes, and an unattended trading loop that
    /// stops silently is worse than one that errors loudly.
    ///
    /// Settable so a test can wedge a tick and watch the loop walk away from
    /// it without waiting five minutes to see it happen.
    public var tickStallTimeout: TimeInterval = StrategyRunner.defaultTickStallTimeout
    public static let defaultTickStallTimeout: TimeInterval = 300
    /// How long an unconfirmed order may stay unresolved before the strategy is
    /// halted for a human to look at. Long enough to ride out an outage, short
    /// enough that nobody discovers it a day later.
    public static let inFlightTimeout: TimeInterval = 600

    private weak var host: StrategyRunnerHost?
    private var loop: Task<Void, Never>?
    /// The tick the loop most recently started, so an overrunning one can be
    /// cancelled instead of silently waited on.
    private var tickTask: Task<Void, Never>?
    /// Bumped once per started tick. Only the newest holds the shared
    /// bookkeeping, so an abandoned tick unwinding late cannot clear the state
    /// of the one that replaced it.
    private var tickGeneration = 0

    /// Kernel strategies, compiled once and reused across ticks.
    private var kernelCache: [String: KernelStrategy] = [:]
    private var candleCache: [CacheKey: [Candle]] = [:]
    /// Deepest history any strategy on this (instId, bar) needs. Without it two
    /// strategies with different warm-ups would take turns truncating and
    /// refetching each other's candles on every tick.
    private var cacheDepth: [CacheKey: Int] = [:]
    private var metaCache: [String: InstrumentMeta] = [:]
    private var dayAnchors: [String: DayAnchor] = [:]
    /// Confirmed bar timestamp each strategy has already acted on.
    private var lastActedBar: [String: Date] = [:]

    private struct CacheKey: Hashable { let instId: String; let bar: BarInterval }
    private struct DayAnchor { var day: Date; var equity: Double; var halted: Bool }
    /// Confirmed bar on which each strategy last went flat, for the cooldown.
    private var lastExitBar: [String: Date] = [:]
    /// Orders whose submission outcome the exchange never confirmed.
    ///
    /// A timeout is not a rejection: the request may well have reached the
    /// venue and filled. Treating it as a failure would leave a real position
    /// on the exchange that the ledger knows nothing about, so these are
    /// resolved by asking, on the next tick, what actually happened.
    private var inFlight: [String: InFlightOrder] = [:]

    private struct InFlightOrder {
        let strategyId: String
        let instId: String
        let instType: InstrumentType
        let clOrdId: String
        let submittedAt: Date
        var attempts: Int
    }

    /// A position difference seen once and awaiting a second, agreeing reading.
    private var pendingExternal: [String: PendingExternal] = [:]
    private struct PendingExternal { let delta: Double; let seenAt: Date }

    /// How long a position difference must persist before it is believed.
    /// Longer than two ticks: an order that filled seconds ago is not visible
    /// on the fills and positions endpoints at the same instant, and booking a
    /// correction that never happened is as damaging as missing a real one.
    ///
    /// Settable so tests can exercise what happens *after* the window without
    /// waiting it out; two agreeing readings are still required either way.
    public var externalConfirmDelay: TimeInterval = 45
    /// Relative size below which a position difference is rounding, not an event.
    public static let externalTolerance = 0.005

    /// How often the loop wakes. Bar-close detection does the real pacing.
    /// Settable for the same reason as `tickStallTimeout`.
    public var tickInterval: TimeInterval = StrategyRunner.defaultTickInterval
    public static let defaultTickInterval: TimeInterval = 20

    /// Past this without a completed tick, the engine is presumed not to be
    /// trading. Generous against the 20-second interval, because a laptop
    /// waking from sleep legitimately misses a few.
    public static let heartbeatTimeout: TimeInterval = 300

    public init(host: StrategyRunnerHost) {
        self.host = host
    }

    // MARK: Lifecycle

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                // Drop the strong reference before sleeping, so a deallocated
                // runner ends the loop instead of keeping it alive for a tick.
                guard let runner = self else { return }
                runner.beginTick()
                try? await Task.sleep(nanoseconds: UInt64(runner.tickInterval * 1_000_000_000))
            }
        }
    }

    /// Start a tick, unless one is in flight and still inside its deadline.
    ///
    /// Deliberately **not** awaited. The loop's own liveness must not depend on
    /// any single tick coming back, and it used to: a subprocess whose
    /// continuation was never resumed took the whole engine down with it — no
    /// error, no exit, just an app that had quietly stopped managing open
    /// positions while the panel went on showing the last numbers it had.
    ///
    /// So the loop keeps its own clock. A tick that overruns
    /// `tickStallTimeout` is cancelled and replaced; whether the abandoned one
    /// ever returns is its own business.
    private func beginTick() {
        if let started = tickStartedAt {
            guard Date().timeIntervalSince(started) > tickStallTimeout else { return }
            // Cancelled, not merely forgotten: if its await does eventually
            // return, it must stand down rather than act on a price, a
            // position and a bar that are all minutes out of date.
            tickTask?.cancel()
        }
        tickTask = Task { [weak self] in await self?.tick() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        tickTask?.cancel()
        tickTask = nil
        for id in states.keys { states[id]?.status = .stopped }
    }

    public func state(for strategyId: String) -> StrategyRuntimeState {
        states[strategyId] ?? StrategyRuntimeState()
    }

    public func mark(for instId: String) -> Double? { marks[instId] }

    /// Candles the runner already holds for an instrument and interval.
    ///
    /// Exposed so a report can score fills against the *same* bars the decision
    /// was made on, rather than refetching a window that may not line up.
    public func cachedCandles(instId: String, bar: BarInterval) -> [Candle] {
        candleCache[CacheKey(instId: instId, bar: bar)] ?? []
    }

    /// Flatten one strategy immediately at market. Used by the stop button,
    /// the emergency stop and the locally enforced protective levels; `reason`
    /// is what the fill is recorded against, so a stop-out does not read as a
    /// manual close afterwards.
    public func flatten(strategyId: String, reason: String = "手动平仓") async {
        guard let host,
              let strategy = host.runnableStrategies.first(where: { $0.id == strategyId }),
              let position = host.ledger.position(for: strategyId), !position.isFlat else { return }
        // An option is sold back into its own book, not sized in coins.
        if InstrumentType.of(instId: position.instId) == .option {
            await closeOption(strategy: strategy, host: host, reason: reason)
            return
        }
        // baseQuantity, not quantity: a swap position is counted in contracts, and
        // submit() converts base units back into contracts itself. Passing
        // contracts here would have tried to sell 11.65 BTC instead of 0.1165.
        await submit(baseDelta: -position.baseQuantity, strategy: strategy, host: host,
                     reason: reason)
    }

    /// Snap a price to the instrument's tick, with a hair of tolerance so
    /// `0.02 × 0.98 / 0.0001` — which floating point makes 195.99999999999997 —
    /// still lands on 196 rather than one tick too far.
    nonisolated static func snapToTick(_ price: Double, tick: Double, roundingUp: Bool) -> Double {
        guard tick > 0 else { return price }
        let steps = price / tick
        let snapped = roundingUp ? (steps - 1e-9).rounded(.up) : (steps + 1e-9).rounded(.down)
        return (snapped * tick * 1e10).rounded() / 1e10
    }

    /// Stop everything and flatten every open strategy position.
    public func emergencyStop() async {
        guard let host else { return }
        for allocation in host.portfolio.allocations {
            states[allocation.strategyId]?.status = .stopped
            await flatten(strategyId: allocation.strategyId)
        }
        host.runnerDidChange()
    }

    // MARK: Tick

    public func tick() async {
        guard let host else { return }
        if isTicking {
            // Overlapping ticks would size a second order against a position
            // the first has not booked yet — so a tick in flight wins, right
            // up until it has plainly overrun and been abandoned.
            guard let started = tickStartedAt,
                  Date().timeIntervalSince(started) > tickStallTimeout else { return }
            Log.warn("strategy runner: tick stalled for "
                     + "\(Int(Date().timeIntervalSince(started)))s, starting a fresh one")
        }
        tickGeneration += 1
        let generation = tickGeneration
        isTicking = true
        tickStartedAt = Date()
        fillsThisTick.removeAll()
        indexThisTick.removeAll()
        defer {
            if generation == tickGeneration {
                isTicking = false
                tickStartedAt = nil
            }
            // A cancelled tick did not do the work, and an abandoned one
            // unwinding minutes later is not evidence that the engine is
            // alive. Reporting either as a heartbeat would paper over exactly
            // the failure the heartbeat exists to catch.
            if !Task.isCancelled {
                let finished = Date()
                lastTickAt = finished
                host.runnerDidCompleteTick(at: finished)
            }
        }

        let portfolio = host.portfolio
        let strategies = host.runnableStrategies
        let byId = Dictionary(strategies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Anything no longer armed drops to stopped without touching positions —
        // "stop trading" means stop deciding, not liquidate behind the user's back.
        for id in states.keys where portfolio.allocation(for: id)?.running != true {
            states[id]?.status = .stopped
        }

        // Anything whose outcome the exchange never confirmed is settled first:
        // a decision made while a fill is unaccounted for would size against a
        // position the ledger does not yet know about.
        await resolveInFlight(for: host)

        // Keep every open position marked to market, running or not: a stopped
        // strategy still holds coins, and its P&L must not freeze on screen.
        await refreshMarks(for: host)

        // What the exchange did on its own — a stop firing, a liquidation —
        // is checked for every held position, armed or not. A stopped
        // strategy's position can still be closed out from under it, and the
        // ledger has to learn that from somewhere.
        await reconcileExternal(for: host)
        await bookFunding(for: host)

        // Then any level the exchange refused to hold for us. After
        // reconciliation, so a position already closed on the exchange is not
        // "stopped out" a second time.
        await enforceLocalStops(for: host)

        // Equity is sampled unconditionally — before the "is anything running"
        // guard below — because "how much money is in this account" is a
        // question the panel must answer even with every strategy stopped.
        await sampleEquity(for: host)
        sampleStrategyEquity(for: host)
        evaluateProtection(for: host)
        evaluateCommitment(for: host)

        let active = portfolio.allocations.filter { $0.running && !portfolio.emergencyStop }
        guard !active.isEmpty else { return }

        if portfolio.mode == .live && !host.liveTradingUnlocked {
            for allocation in active {
                update(allocation.strategyId) {
                    $0.status = .failed
                    $0.message = TradeError.liveTradingLocked.description
                }
            }
            return
        }

        // Refresh attribution first: fills from the previous tick's orders land
        // here, so sizing decisions below see the real position.
        await ingestFills(for: active.compactMap { byId[$0.strategyId] }, host: host)

        for allocation in active {
            guard !Task.isCancelled else { return }
            guard let strategy = byId[allocation.strategyId] else {
                update(allocation.strategyId) {
                    $0.status = .failed
                    $0.message = "策略文件已丢失或无法编译"
                }
                continue
            }
            await evaluate(strategy: strategy, allocation: allocation, host: host)
        }
        host.runnerDidChange()
    }

    /// Ask the exchange what became of every order we lost track of.
    ///
    /// Absent from the venue's order listing is the only answer that makes a
    /// retry safe; anything else means the exchange acted on it and the ledger
    /// must catch up. An order that stays unresolved past `inFlightTimeout` is
    /// escalated to the user rather than quietly forgotten.
    private func resolveInFlight(for host: StrategyRunnerHost) async {
        guard !inFlight.isEmpty else { return }
        for (key, var pending) in inFlight {
            let status = try? await host.venue.orderStatus(
                instId: pending.instId, instType: pending.instType,
                clOrdId: pending.clOrdId, mode: host.portfolio.mode)

            switch status {
            case .some(.unknown):
                // The exchange never saw it. Safe to drop; the next bar will
                // decide again from a position the ledger correctly believes.
                inFlight[key] = nil
                update(pending.strategyId) { $0.message = "未确认订单确认未送达，已丢弃" }

            case .some(let resolved) where resolved.didExecute:
                inFlight[key] = nil
                // The fill is real; pull it into the ledger by its tag.
                if let strategy = host.runnableStrategies.first(where: { $0.id == pending.strategyId }) {
                    await ingestFills(for: [strategy], host: host)
                }
                update(pending.strategyId) { $0.message = "未确认订单实际已成交，已入账" }
                Log.warn("runner: recovered an unconfirmed fill for \(pending.clOrdId)")

            case .some(let resolved) where resolved.isTerminal:
                inFlight[key] = nil
                update(pending.strategyId) { $0.message = "未确认订单已终止（未成交）" }

            default:
                // Still working, or the query itself failed. Keep asking, but
                // do not ask forever in silence.
                pending.attempts += 1
                inFlight[key] = pending
                if Date().timeIntervalSince(pending.submittedAt) > Self.inFlightTimeout {
                    inFlight[key] = nil
                    host.runnerDidHalt(
                        strategyId: pending.strategyId,
                        reason: "订单 \(pending.clOrdId) 状态 \(pending.attempts) 次查询仍未确认，"
                            + "请到交易所核对后再启动")
                }
            }
        }
        host.runnerDidChange()
    }

    // MARK: Funding

    /// Book the funding charged on perpetual positions.
    ///
    /// The backtester models funding from real rate history. Live ignored it
    /// completely, which for a short held across several days is not a rounding
    /// error — it is the position's whole edge, settled eight-hourly.
    ///
    /// Polled on the same slow cadence as equity: settlements happen three
    /// times a day, and each read costs an authenticated call.
    private func bookFunding(for host: StrategyRunnerHost) async {
        let now = Date()
        if let last = lastFundingPollAt,
           now.timeIntervalSince(last) < Self.fundingPollInterval { return }

        let held = host.ledger.positions.values.filter {
            !$0.isFlat && InstrumentType.of(instId: $0.instId).settlesFunding
        }
        guard !held.isEmpty else { return }
        guard let payments = try? await host.venue.fundingPayments(
            instId: nil, mode: host.portfolio.mode) else { return }
        lastFundingPollAt = now

        for payment in payments {
            // Same attribution rule as an external fill: one owner or none.
            // Splitting a settlement between two strategies sharing a leg would
            // be a guess, and funding is small enough per settlement that
            // skipping is the cheaper error.
            let claimants = held.filter { $0.instId == payment.instId }
            guard claimants.count == 1, let owner = claimants.first else { continue }
            if host.ledger.recordFunding(payment, strategyId: owner.strategyId) {
                Log.warn("runner: booked funding \(payment.amount) on \(payment.instId)")
            }
        }
    }

    private var lastFundingPollAt: Date?
    /// Funding settles three times a day; polling faster buys nothing.
    public static let fundingPollInterval: TimeInterval = 900

    // MARK: External position changes

    /// Reconcile the ledger against what the exchange actually holds, and book
    /// whatever moved the position without us.
    ///
    /// The exchange changes positions on its own more often than the phrase
    /// "external fill" suggests. The commonest case is not exotic at all: we
    /// attach the stop to the entry order precisely so the exchange enforces it
    /// while this app is closed, and when it fires the resulting fill carries
    /// the exchange's own order id, not our `clOrdId`. `ingestFills` therefore
    /// skips it and the ledger goes on believing it holds a position that no
    /// longer exists. Liquidation, ADL and a manual close look the same.
    ///
    /// A phantom position is worse than a merely inaccurate one: the next
    /// decision sizes against coins that are not there, and a flatten would try
    /// to sell them.
    ///
    /// Derivatives only. A spot balance mixes this book with coins the user
    /// already held, so a difference there is not evidence of anything —
    /// whereas a derivative position is reported per instrument and is exactly
    /// the thing that gets stopped out, liquidated, auto-deleveraged or, for
    /// an option, settled at expiry.
    private func reconcileExternal(for host: StrategyRunnerHost) async {
        func heldDerivatives() -> [StrategyPositionState] {
            host.ledger.positions.values.filter {
                !$0.isFlat && InstrumentType.of(instId: $0.instId).isDerivative
            }
        }
        var held = heldDerivatives()
        guard !held.isEmpty else {
            pendingExternal.removeAll()
            return
        }

        // Book our *own* fills first. Without this, an order that filled but
        // whose ingest failed — a dropped response, a CLI hiccup — looks
        // exactly like an external reduction, and would be booked a second
        // time at the mark when the real fill arrived on a later tick.
        await ingestFills(
            for: Set(held.map {
                InstrumentKey(instId: $0.instId, instType: InstrumentType.of(instId: $0.instId))
            }),
            host: host)
        held = heldDerivatives()
        guard !held.isEmpty else {
            pendingExternal.removeAll()
            return
        }

        // A failed query must never read as "the exchange holds nothing";
        // that would book a liquidation on every network hiccup. Each family
        // is asked separately, and only a family that answered is judged.
        var exchangeByInst: [String: Double] = [:]
        var answered: Set<InstrumentType> = []
        for instType in Set(held.map { InstrumentType.of(instId: $0.instId) }) {
            guard let exchange = try? await host.venue.positions(
                mode: host.portfolio.mode, instType: instType) else { continue }
            answered.insert(instType)
            for position in exchange {
                exchangeByInst[position.instId, default: 0] += position.quantity
            }
        }
        var ledgerByInst: [String: Double] = [:]
        for state in held where answered.contains(InstrumentType.of(instId: state.instId)) {
            ledgerByInst[state.instId, default: 0] += state.quantity
        }

        for (instId, ledgerQuantity) in ledgerByInst {
            let exchangeQuantity = exchangeByInst[instId] ?? 0
            let delta = exchangeQuantity - ledgerQuantity
            let scale = Swift.max(abs(ledgerQuantity), abs(exchangeQuantity))
            guard scale > 0, abs(delta) / scale > Self.externalTolerance else {
                pendingExternal[instId] = nil
                continue
            }
            // An order we have not heard back from could explain the whole
            // difference. Settling that comes first.
            if inFlight.values.contains(where: { $0.instId == instId }) { continue }

            if let seen = pendingExternal[instId],
               abs(seen.delta - delta) / scale <= Self.externalTolerance {
                guard Date().timeIntervalSince(seen.seenAt) >= externalConfirmDelay
                else { continue }
            } else {
                pendingExternal[instId] = PendingExternal(delta: delta, seenAt: Date())
                continue
            }

            await absorb(delta: delta, ledgerQuantity: ledgerQuantity,
                         instId: instId, held: held, host: host)
        }
    }

    /// Book one confirmed position difference against the strategy that owns it.
    private func absorb(
        delta: Double, ledgerQuantity: Double, instId: String,
        held: [StrategyPositionState], host: StrategyRunnerHost
    ) async {
        let claimants = held.filter { $0.instId == instId }
        guard claimants.count == 1, let owner = claimants.first else {
            // Two strategies netted into one exchange position cannot be
            // decomposed. A liquidation hits the net leg, and splitting it
            // pro-rata would be a guess about whose money was lost — so stop
            // both rather than write a plausible fiction into the book.
            for state in claimants {
                host.runnerDidHalt(
                    strategyId: state.strategyId,
                    reason: "\(instId) 交易所仓位与台账相差 \(PriceFormatter.plain(delta)) 张，"
                        + "该合约由多个策略共用，无法归因，请人工核对")
            }
            pendingExternal[instId] = nil
            return
        }

        // Only reductions are absorbed. An increase is somebody else's order —
        // a manual trade, another bot — and folding it into this strategy would
        // have it trade away a position the user opened deliberately. It stays
        // visible as unattributed exposure in reconciliation instead.
        let booked: Double = ledgerQuantity > 0
            ? Swift.max(Swift.min(delta, 0), -ledgerQuantity)
            : Swift.min(Swift.max(delta, 0), -ledgerQuantity)
        guard abs(booked) > 0 else {
            update(owner.strategyId) {
                $0.message = "交易所 \(instId) 仓位多出 \(PriceFormatter.plain(delta)) 张"
                    + "（非本策略下单），未并入台账"
            }
            pendingExternal[instId] = nil
            return
        }

        var remaining = abs(booked)
        remaining -= await adoptUntaggedFills(
            instId: instId, owner: owner, reducing: booked, limit: remaining, host: host)

        if remaining > abs(booked) * 0.01 {
            // No fill record explains the rest. Book it at the mark so the
            // *size* is right, which is what every later decision depends on,
            // and be clear that the price and fee behind the realised P&L are
            // an estimate rather than a record.
            let price = marks[instId] ?? owner.averagePrice
            host.ledger.record(StrategyFill(
                id: "external-\(instId)-\(Int(Date().timeIntervalSince1970 * 1000))",
                strategyId: owner.strategyId, instId: instId,
                side: booked > 0 ? .buy : .sell, price: price, quantity: remaining,
                feeQuote: 0, ts: Date(), clOrdId: nil, mode: host.portfolio.mode))
        }

        pendingExternal[instId] = nil
        recordStopOut()
        // A position closed by the exchange is an exit like any other, so the
        // cooldown applies to it. Without this the strategy could re-enter on
        // the very next bar — something the backtest never does after a stop.
        if host.ledger.position(for: owner.strategyId)?.isFlat ?? true {
            lastExitBar[owner.strategyId] =
                lastConfirmedBarTime(forStrategy: owner.strategyId, host: host) ?? Date()
        }
        let causes = InstrumentType.of(instId: instId) == .option
            ? "止损/止盈/到期结算/手动" : "止损/止盈/强平/手动"
        update(owner.strategyId) {
            $0.message = "交易所已减仓 \(PriceFormatter.plain(abs(booked))) 张"
                + "（\(causes)），已补记入账"
        }
        Log.warn("runner: absorbed an external \(booked) on \(instId) for \(owner.strategyId)")
        host.runnerDidChange()
    }

    /// Adopt the exchange's own fills for this reduction, newest work first.
    ///
    /// Preferred over synthesising one, because a real fill carries the real
    /// price and the real fee — a stop fills at the stop, not at whatever the
    /// mark happens to be a minute later. Returns the size adopted.
    private func adoptUntaggedFills(
        instId: String, owner: StrategyPositionState, reducing booked: Double,
        limit: Double, host: StrategyRunnerHost
    ) async -> Double {
        guard let fills = await fills(
            for: InstrumentKey(instId: instId, instType: InstrumentType.of(instId: instId)),
            host: host) else { return 0 }

        let recorded = host.ledger.recordedFillIds
        let known = host.runnableStrategies.map(\.id)
        // Nothing older than our last recorded fill: that is history already
        // accounted for, and adopting it would double-count.
        let since = owner.lastFillAt ?? .distantPast
        let wanted = booked > 0 ? 1.0 : -1.0
        // An option fill the exchange did not stamp with an index converts at
        // this tick's reading; one that can be converted by neither is left
        // for the mark-priced correction below rather than booked at a guess.
        let indexPrices = await indexPrices(for: fills, host: host)

        var adopted = 0.0
        for fill in fills.sorted(by: { $0.ts < $1.ts })
        where fill.ts > since
            && !recorded.contains(fill.id)
            && OrderTag.resolveStrategy(fill.clOrdId, among: known) == nil
            && fill.side.sign * wanted > 0 {
            guard adopted < limit else { break }
            let index = InstrumentType.optionUnderlying(of: fill.instId).flatMap { indexPrices[$0] }
            guard let adoptedFill = StrategyFill(
                exchange: fill, strategyId: owner.strategyId, mode: host.portfolio.mode,
                indexPrice: index) else { continue }
            host.ledger.record(adoptedFill)
            adopted += abs(fill.size)
        }
        return adopted
    }

    /// Latest confirmed bar this strategy has cached, for dating an exit.
    private func lastConfirmedBarTime(
        forStrategy id: String, host: StrategyRunnerHost
    ) -> Date? {
        guard let strategy = host.runnableStrategies.first(where: { $0.id == id }) else {
            return nil
        }
        let key = CacheKey(instId: strategy.market.instId, bar: strategy.market.bar)
        return candleCache[key]?.last(where: { $0.confirmed })?.ts
    }

    /// Refresh the mark price of every instrument the ledger has exposure to,
    /// and make sure the ledger knows each one's contract size.
    ///
    /// The contract size matters as much as the price: a swap position is
    /// counted in contracts, so without it every P&L figure is out by the
    /// multiplier (100× on BTC, 10× on ETH).
    private func refreshMarks(for host: StrategyRunnerHost) async {
        let instruments = Set(host.ledger.positions.values.filter { !$0.isFlat }.map(\.instId))
        for instId in instruments {
            // The valuation price, not the last trade: for an option that is
            // the exchange's mark converted at the index, in the currency the
            // book keeps.
            if let price = try? await host.venue.valuationPrice(instId: instId, mode: host.portfolio.mode), price > 0 {
                marks[instId] = price
            }
            guard let size = await contractSize(for: instId, host: host) else {
                Log.warn("runner: 合约面值未知，本轮不改写 \(instId) 的面值（沿用账上已有值）")
                continue
            }
            host.ledger.setContractSize(size, forInstId: instId)
        }
    }

    /// Base units per contract, cached — or nil when nobody has told us yet.
    ///
    /// **A failed lookup must not answer `1`.** It used to, and 1 is a
    /// perfectly ordinary multiplier: indistinguishable from spot, and from a
    /// swap whose contract really is one coin. So a single unreachable-exchange
    /// tick — the machine waking from sleep before the network is up is enough
    /// — overwrote ETH's correct 0.1 with a fabricated 1 and every figure
    /// derived from it came out 10× off: the realised P&L booked on the very
    /// next fill (+921 where the truth was +92), and the exposure the leverage
    /// breaker reads (76,860 against a real 7,686). Realised P&L is cumulative,
    /// so learning the right multiplier a tick later does not undo it — the
    /// wrong number is already on the books.
    ///
    /// Only two answers are honest here: what the exchange said, and "unknown".
    private func contractSize(for instId: String, host: StrategyRunnerHost) async -> Double? {
        let implied = InstrumentType.of(instId: instId).impliedContractSize
        if let implied { return implied }
        if let cached = metaCache[instId] { return cached.contractValue }
        guard let meta = (try? await host.venue.instrumentMeta(instId: instId, mode: host.portfolio.mode)) ?? nil else {
            return nil
        }
        metaCache[instId] = meta
        return meta.contractValue
    }

    /// Read total account equity and hand it to the host for the curve.
    ///
    /// **The exchange's own figure wins.** An earlier version summed the spot
    /// balances itself, reasoning that every other number here is denominated
    /// in the quote currency and mixing in a USD valuation would show a "loss"
    /// whenever USDT drifted off peg. That reasoning only held while the book
    /// was spot-only: a balance sum cannot see a derivative position's
    /// unrealised P&L at all, so once perpetual legs opened, equity stopped
    /// moving and the panel reported no return on a profitable account.
    ///
    /// Summing balances ourselves is now only the fallback for a CLI that
    /// reports no total.
    private func sampleEquity(for host: StrategyRunnerHost) async {
        let now = Date()
        if let last = lastEquitySampleAt,
           now.timeIntervalSince(last) < Self.equitySampleInterval { return }

        guard let snapshot = try? await host.venue.accountSnapshot(mode: host.portfolio.mode)
        else { return }
        lastEquitySampleAt = now
        accountBalances = snapshot.balances

        var total = 0.0
        var pricedEverything = true
        for balance in snapshot.balances where balance.total > 0 {
            if balance.ccy == Self.quoteCurrency {
                total += balance.total
                continue
            }
            let instId = "\(balance.ccy)-\(Self.quoteCurrency)"
            // Always re-read: a mark cached from an earlier tick would freeze
            // this holding's contribution and flatten the curve.
            if let quoted = try? await host.venue.lastPrice(instId: instId, mode: host.portfolio.mode), quoted > 0 {
                marks[instId] = quoted
                total += balance.total * quoted
            } else {
                // Skipping the holding would understate equity and read as a
                // loss that never happened. Fall back to the exchange's own
                // valuation for the whole snapshot, or record nothing at all.
                pricedEverything = false
                break
            }
        }

        guard let equity = snapshot.totalEquity ?? (pricedEverything ? total : nil),
              equity > 0 else { return }
        accountEquity = equity
        nonStableExposure = await measureNonStableExposure(snapshot: snapshot, host: host)
        host.runnerDidSampleEquity(equity, at: now)
    }

    /// Record each allocated strategy's own equity.
    ///
    /// Sampled for every allocation, running or not: a stopped strategy still
    /// holds a position whose value moves, and a curve with a hole in it would
    /// misreport the return across that gap.
    private func sampleStrategyEquity(for host: StrategyRunnerHost) {
        let now = Date()
        if let last = lastStrategyEquitySampleAt,
           now.timeIntervalSince(last) < Self.equitySampleInterval { return }
        let byId = Dictionary(
            host.runnableStrategies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sampled = false
        for allocation in host.portfolio.allocations {
            guard let strategy = byId[allocation.strategyId] else { continue }
            let equity = workingCapital(strategy: strategy, allocation: allocation, host: host)
            guard equity > 0 else { continue }
            host.runnerDidSampleStrategyEquity(
                strategy.id, equity: equity, basis: allocation.capital, at: now)
            sampled = true
        }
        if sampled { lastStrategyEquitySampleAt = now }
    }

    private var lastStrategyEquitySampleAt: Date?

    /// Market value of every non-stablecoin holding and derivative position.
    private func measureNonStableExposure(
        snapshot: AccountSnapshot, host: StrategyRunnerHost
    ) async -> Double {
        var exposure = 0.0

        // Spot coin balances.
        for balance in snapshot.balances where balance.total > 0 {
            guard !Self.stableCurrencies.contains(balance.ccy.uppercased()) else { continue }
            let instId = "\(balance.ccy)-\(Self.quoteCurrency)"
            var price = marks[instId]
            if price == nil { price = try? await host.venue.lastPrice(instId: instId, mode: host.portfolio.mode) }
            guard let price, price > 0 else { continue }
            marks[instId] = price
            exposure += balance.total * price
        }

        // Derivative positions, at their own mark and contract size. For an
        // option that is the premium's current value — what would be lost if
        // it went to zero — not the notional it controls.
        for state in host.ledger.positions.values where !state.isFlat {
            guard InstrumentType.of(instId: state.instId).isDerivative else { continue }
            exposure += state.exposure(mark: marks[state.instId])
        }
        return exposure
    }

    // MARK: Per-strategy evaluation

    private func evaluate(
        strategy: CompiledStrategy, allocation: StrategyAllocation, host: StrategyRunnerHost
    ) async {
        let market = strategy.market
        let key = CacheKey(instId: market.instId, bar: market.bar)

        // --- Candles: keep a rolling window big enough for the longest indicator
        //     any strategy on this instrument and interval needs.
        let wanted = Swift.max(strategy.warmupBars + 120, cacheDepth[key] ?? 0)
        cacheDepth[key] = wanted
        var candles = candleCache[key] ?? []
        do {
            if candles.count < wanted {
                candles = try await host.venue.historyCandles(
                    instId: market.instId, bar: market.bar, target: wanted)
            } else {
                let recent = try await host.venue.candles(
                    instId: market.instId, bar: market.bar, target: 100)
                candles.mergeCandles(recent, cap: wanted + 200)
            }
        } catch {
            update(strategy.id) {
                $0.status = .failed
                $0.message = "行情获取失败：\(error)"
            }
            return
        }
        candleCache[key] = candles
        if let last = candles.last { marks[market.instId] = last.close }

        let confirmed = candles.filter(\.confirmed)
        guard let latestBar = confirmed.last else { return }
        update(strategy.id) {
            $0.barsLoaded = confirmed.count
            $0.lastBarTime = latestBar.ts
        }

        guard confirmed.count > strategy.warmupBars + 1 else {
            update(strategy.id) {
                $0.status = .warmingUp
                $0.message = "指标预热中（\(confirmed.count)/\(strategy.warmupBars + 2) 根）"
            }
            return
        }

        // --- Declared alternative data, aligned to the confirmed candles.
        var externalSeries: [String: [Double]] = [:]
        if strategy.usesAlternativeData {
            let days = Int(Double(confirmed.count) * market.bar.seconds / 86_400) + 2
            let loaded = await host.venue.alternativeSeries(
                specs: strategy.manifest.data, market: market,
                candles: confirmed, days: Swift.max(days, 2))
            externalSeries = loaded.series
            if let starved = loaded.coverage.first(where: { !$0.isUsable }) {
                update(strategy.id) { $0.message = "另类数据覆盖不足：\(starved.summary)" }
            }
        }

        // --- One decision per closed bar.
        guard lastActedBar[strategy.id] != latestBar.ts else {
            update(strategy.id) {
                // A failure that has since cleared no longer applies; a note
                // written while running — an exchange-side stop the book just
                // absorbed, a refused entry — is the last thing the reader
                // needs wiped by a quiet bar.
                if $0.status != .running { $0.message = nil }
                $0.status = .running
            }
            return
        }

        let position = host.ledger.position(for: strategy.id)
        // The view the position expresses, not its sign: a long put is short.
        let current = position?.signalDirection

        // --- Ask the kernel for a complete plan.
        //
        // Sizing, the rebalance threshold and the daily-loss breaker all live
        // in the kernel, next to the backtester that uses the same functions.
        // This runner used to re-implement all three in Swift, and they had
        // already drifted: the Swift sizing honoured only a percentage stop, so
        // an ATR-stopped `riskPerTrade` manifest risked 1% per trade in
        // simulation and committed the whole budget live.
        let equity = workingCapital(strategy: strategy, allocation: allocation, host: host)
        let today = Self.utcDay(of: Date())
        var anchor = dayAnchors[strategy.id]
            ?? DayAnchor(day: today, equity: equity, halted: false)
        // A new UTC day clears the breaker, exactly as the backtester does.
        // Leaving it latched would mean the backtest counted tomorrow's trades
        // and live never took them.
        if anchor.day != today {
            anchor = DayAnchor(day: today, equity: equity, halted: false)
        }
        dayAnchors[strategy.id] = anchor

        let decision: KernelDecision
        do {
            decision = try decide(
                strategy: strategy, candles: confirmed,
                externalSeries: externalSeries, current: current,
                barsHeld: barsHeldCount(position: position, latestBar: latestBar, market: market),
                account: KernelAccountState(
                    equity: equity,
                    heldBase: position?.kernelHeldBase ?? 0,
                    dayStartEquity: anchor.equity,
                    leverageCap: allocation.leverageCap,
                    barsSinceExit: barsSince(lastExitBar[strategy.id],
                                             latestBar: latestBar, market: market),
                    haltedToday: anchor.halted,
                    entryPrice: position?.averagePrice ?? 0,
                    // The kernel has no clock of its own, by design. Staleness
                    // is the one property it cannot judge without one.
                    now: Date(),
                    limits: orderLimits(for: host)))
        } catch {
            update(strategy.id) {
                $0.status = .failed
                $0.message = "信号求值失败：\(error)"
            }
            return
        }

        // The kernel refuses to answer while indicators are warming up. That is
        // a "hold", not a flat target — acting on it would liquidate a position
        // the moment the candle cache was trimmed.
        guard !decision.warmingUp else {
            update(strategy.id) {
                $0.status = .warmingUp
                $0.message = "内核指标预热中（\(decision.confirmedBars) 根）"
            }
            return
        }

        // Bad data is a refusal to decide, not a flat target. Acting on the
        // kernel's silence here would liquidate a position because the feed
        // hiccupped. `lastActedBar` is deliberately not set, so the moment the
        // series is clean again this bar gets decided properly.
        if let quality = decision.dataQuality, !quality.usable {
            update(strategy.id) {
                $0.status = .failed
                $0.message = decision.reason
            }
            Log.warn("runner: \(strategy.id) stood down — \(quality.reason)")
            return
        }

        lastActedBar[strategy.id] = latestBar.ts
        update(strategy.id) {
            $0.status = decision.haltDailyLoss ? .halted : .running
            $0.message = decision.reason
            $0.lastEvaluatedAt = Date()
            $0.targetDirection = decision.direction
        }

        if decision.shouldTrade {
            if let plan = decision.optionPlan {
                // The kernel picked the contract *rule* and the premium; the
                // exchange's chain and quotes turn that into an order.
                await executeOptionPlan(plan, strategy: strategy, host: host, reason: decision.reason)
            } else {
                await submit(baseDelta: decision.baseDelta, strategy: strategy, host: host,
                             reason: decision.reason,
                             stopPrice: decision.stopPrice,
                             takeProfitPrice: decision.takeProfitPrice)
            }
            if decision.target == 0 { lastExitBar[strategy.id] = latestBar.ts }
        } else if let level = decision.trailingStopPrice {
            // The position did not change but its stop did. Nothing is traded
            // here — the level on the exchange is simply moved up behind it.
            await syncTrailingStop(to: level, strategy: strategy, host: host)
        }
        if decision.haltDailyLoss {
            // Latched for the rest of the UTC day only — the anchor above
            // clears it at the day boundary.
            dayAnchors[strategy.id]?.halted = true
        }
    }

    /// Bars between `since` and the latest bar, or nil when there is no `since`.
    private func barsSince(
        _ since: Date?, latestBar: Candle, market: StrategyMarket
    ) -> Int? {
        guard let since else { return nil }
        return Self.barsBetween(since, and: latestBar.ts, bar: market.bar)
    }

    /// Bars the current position has been held for, counted from the bar its
    /// opening fill landed in.
    private func barsHeldCount(
        position: StrategyPositionState?, latestBar: Candle, market: StrategyMarket
    ) -> Int {
        guard let opened = position?.openedAt else { return 0 }
        return Self.barsBetween(opened, and: latestBar.ts, bar: market.bar) ?? 0
    }

    /// Bars between two instants, counting *bars* rather than elapsed time.
    ///
    /// Both ends are floored to their bar's opening time first. A fill lands
    /// part-way through a bar, and dividing the raw interval loses that
    /// fraction: an entry at 10:05 measured against the 15:00 bar gives 4.9 →
    /// 4, when the position has in fact been open across 5 bars. The
    /// backtester counts index arithmetic and has no such rounding, so
    /// without this every bar-counted rule — the minimum hold, the cooldown,
    /// and above all the time barrier and the trailing anchor's window — was
    /// one bar out from the simulation that justified it.
    nonisolated static func barsBetween(_ from: Date, and to: Date, bar: BarInterval) -> Int? {
        let seconds = bar.seconds
        guard seconds > 0 else { return nil }
        func barStart(_ date: Date) -> Double {
            (date.timeIntervalSince1970 / seconds).rounded(.down) * seconds
        }
        return Swift.max(Int(((barStart(to) - barStart(from)) / seconds).rounded()), 0)
    }

    /// Target direction for this bar, decided by the Rust kernel.
    ///
    /// This used to be a Swift reimplementation of `BacktestEngine`'s signal
    /// resolution, kept in step with it by a comment. It now calls the same
    /// compiled function the backtester calls, so "live trades what the
    /// backtest tested" is a property of the binary rather than a promise.
    private func decide(
        strategy: CompiledStrategy, candles: [Candle],
        externalSeries: [String: [Double]],
        current: TradeDirection?, barsHeld: Int, account: KernelAccountState
    ) throws -> KernelDecision {
        try kernel(for: strategy).decide(
            candles: candles, current: current,
            barsHeld: barsHeld, externalSeries: externalSeries, account: account)
    }

    /// Compiled kernel strategies, keyed by id.
    ///
    /// Compiling parses and validates every expression, which is wasted work on
    /// a 20-second tick; the cache is invalidated by `reloadKernel(for:)` when
    /// the library reloads a manifest from disk.
    private func kernel(for strategy: CompiledStrategy) throws -> KernelStrategy {
        if let cached = kernelCache[strategy.id] { return cached }
        let json = try JSONEncoder().encode(strategy.manifest)
        let compiled = try KernelStrategy(
            manifest: json,
            knownSeries: Array(strategy.manifest.data.keys))
        kernelCache[strategy.id] = compiled
        return compiled
    }

    /// Drop a cached kernel strategy, so an edited manifest takes effect.
    public func reloadKernel(for strategyId: String? = nil) {
        if let strategyId {
            kernelCache[strategyId] = nil
        } else {
            kernelCache.removeAll()
        }
    }

    // MARK: Portfolio-level protection

    /// Limits every order is checked against, whatever asked for it.
    ///
    /// Two of these are portfolio-wide rather than per strategy, which is the
    /// point: a per-strategy daily-loss breaker cannot see four strategies
    /// losing 4% each, and that is the day worth stopping.
    private func orderLimits(for host: StrategyRunnerHost) -> KernelOrderLimits {
        var limits = KernelOrderLimits()
        if let cap = host.portfolio.maxOrderNotional, cap > 0 {
            limits.maxOrderNotional = cap
        }
        // `reducing`, never `halted`: a halted engine cannot close the position
        // that tripped the breaker, which is the one order it most needs to
        // send. Closing stays available; opening does not.
        if protectionTripped != nil || overCommitted != nil { limits.state = .reducing }
        return limits
    }

    /// Set when the book already holds more than the account can back.
    ///
    /// Each strategy sizes against *its own* budget and never looks at the
    /// others, which is the right separation — one strategy's drawdown must not
    /// shrink another's position. But nothing was checking the sum. Four
    /// strategies each allocated half the account is a book that opens at twice
    /// the account, and every individual order looks perfectly reasonable on
    /// the way there.
    ///
    /// The studio window warns when the *budgets* over-commit, deliberately
    /// without resizing anyone's book. This is the other half: whatever the
    /// budgets say, the engine stops adding exposure once the account is fully
    /// committed. Reducing stays available — refusing to close an
    /// over-committed book is how a protective limit becomes the problem.
    public private(set) var overCommitted: String?

    /// Absolute notional the ledger currently holds, marked to market.
    public private(set) var committedNotional: Double = 0

    /// Compare what the book holds against what the account can back.
    private func evaluateCommitment(for host: StrategyRunnerHost) {
        committedNotional = host.ledger.positions.values
            .filter { !$0.isFlat }
            .reduce(0) { $0 + $1.exposure(mark: marks[$1.instId]) }

        guard let equity = accountEquity, equity > 0 else {
            overCommitted = nil
            return
        }
        // The most permissive leverage any armed strategy is allowed. A book
        // running one 3x strategy may legitimately hold three times the
        // account; judging it against 1x would refuse trades it was configured
        // for.
        let allowed = host.portfolio.allocations
            .filter(\.running)
            .compactMap { allocation in
                host.runnableStrategies.first { $0.id == allocation.strategyId }
                    .map { strategy in
                        Swift.min(allocation.leverageCap ?? .greatestFiniteMagnitude,
                                  Swift.max(strategy.manifest.risk.leverage, 1))
                    }
            }
            .max() ?? 1
        let ceiling = equity * allowed

        if committedNotional > ceiling * 1.02 {
            overCommitted = "已持仓名义 \(PriceFormatter.money(committedNotional, decimals: 0))"
                + " 超过账户可支撑的 \(PriceFormatter.money(ceiling, decimals: 0))"
                + "（权益 × \(PriceFormatter.decimals(allowed, 1)) 倍），只允许减仓"
        } else {
            overCommitted = nil
        }
    }

    /// Why the portfolio is currently refusing new exposure, if it is.
    public private(set) var protectionTripped: String?

    /// Account drawdown from its high-water mark, as a percentage.
    public private(set) var accountDrawdownPct: Double = 0

    /// Stop opening new positions when the *account* has drawn down past the
    /// configured limit, and when a strategy keeps getting stopped out.
    ///
    /// Freqtrade calls these MaxDrawdown and StoplossGuard. Both exist because
    /// a strategy can be behaving exactly as designed and still be wrong about
    /// the current market — the per-trade stop fires each time and the account
    /// bleeds out one correct stop-out at a time.
    private func evaluateProtection(for host: StrategyRunnerHost) {
        guard let equity = accountEquity, equity > 0 else { return }
        highWaterEquity = Swift.max(highWaterEquity ?? equity, equity)
        guard let peak = highWaterEquity, peak > 0 else { return }
        accountDrawdownPct = Swift.max((peak - equity) / peak * 100, 0)

        if let limit = host.portfolio.maxDrawdownPct, limit > 0,
           accountDrawdownPct >= limit {
            let reason = "账户自最高点回撤 \(PriceFormatter.percent(accountDrawdownPct))"
                + "，已达上限 \(PriceFormatter.percent(limit))，只允许减仓"
            if protectionTripped == nil {
                Log.warn("runner: portfolio drawdown breaker tripped at \(accountDrawdownPct)%")
            }
            protectionTripped = reason
            return
        }

        if let guardConfig = host.portfolio.stoplossGuard,
           guardConfig.trades > 0, guardConfig.lookbackMinutes > 0 {
            let since = Date().addingTimeInterval(-Double(guardConfig.lookbackMinutes) * 60)
            let recent = stopOuts.filter { $0 > since }
            stopOuts = recent
            if recent.count >= guardConfig.trades {
                protectionTripped = "\(guardConfig.lookbackMinutes) 分钟内触发了 "
                    + "\(recent.count) 次止损，暂停开新仓"
                return
            }
        }
        protectionTripped = nil
    }

    /// Account equity high-water mark, for the drawdown breaker.
    private var highWaterEquity: Double?
    /// When protective exits fired, for the stop-loss guard.
    private var stopOuts: [Date] = []

    /// Record that a position was closed by a protective level rather than by
    /// a signal. Called from the reconciliation path, which is the only place
    /// that learns about an exchange-side stop firing.
    private func recordStopOut() {
        stopOuts.append(Date())
        // Bounded: the guard only ever looks at a trailing window.
        if stopOuts.count > 200 { stopOuts.removeFirst(stopOuts.count - 200) }
    }

    // MARK: Sizing

    /// Capital this strategy may deploy: its budget compounded by its own P&L,
    /// never spilling into another strategy's allocation.
    private func workingCapital(
        strategy: CompiledStrategy, allocation: StrategyAllocation, host: StrategyRunnerHost
    ) -> Double {
        let state = host.ledger.position(for: strategy.id)
        // Marked at the position's *own* instrument. For spot and perpetuals
        // that is the market the strategy watches; for an option it is the
        // contract, whose premium is not the underlying's price.
        let mark = state.flatMap { marks[$0.instId] }
        let pnl = state?.netPnL(mark: mark) ?? 0
        return Swift.max(allocation.capital + pnl, 0)
    }

    // MARK: Order submission

    private func submit(
        baseDelta: Double, strategy: CompiledStrategy, host: StrategyRunnerHost, reason: String,
        stopPrice: Double? = nil, takeProfitPrice: Double? = nil
    ) async {
        guard abs(baseDelta) > 0 else { return }
        // An abandoned tick must not place an order when it finally resumes:
        // by then a fresh tick has already made the call, and this one would
        // be trading on a decision minutes stale.
        guard !Task.isCancelled else { return }
        let market = strategy.market
        // A flatten can be requested for a strategy that never ran this
        // session, so there may be no cached mark — fetch one rather than
        // silently doing nothing with the user's open position.
        if marks[market.instId] == nil {
            marks[market.instId] = try? await host.venue.lastPrice(instId: market.instId, mode: host.portfolio.mode)
        }
        guard let price = marks[market.instId], price > 0 else {
            update(strategy.id) { $0.message = "取不到行情价，未能下单" }
            return
        }

        let meta: InstrumentMeta?
        if let cached = metaCache[market.instId] {
            meta = cached
        } else {
            meta = (try? await host.venue.instrumentMeta(instId: market.instId, mode: host.portfolio.mode)) ?? nil
            if let meta { metaCache[market.instId] = meta }
        }

        // Same rule as the ledger's: an unknown multiplier is not 1. Falling
        // back to the coin quantity here would send 13.8 *contracts* where 13.8
        // ETH was meant — a 10× order, in real size, on a network hiccup. Spot
        // needs no lookup (`impliedContractSize` answers it), so this only ever
        // blocks a derivative order we genuinely cannot size.
        guard let contractSize = meta?.contractValue
                ?? InstrumentType.of(instId: market.instId).impliedContractSize else {
            update(strategy.id) { $0.message = "取不到合约面值，未能下单（不拿 1 兜底）" }
            Log.warn("runner: \(market.instId) 合约面值未知，跳过下单")
            return
        }
        // `exchangeSize` also rounds to the lot step, which needs the same meta.
        let size = meta?.exchangeSize(forBaseQuantity: abs(baseDelta))
            ?? abs(baseDelta) / contractSize
        guard size > 0 else {
            update(strategy.id) { $0.message = "调整量低于交易所最小下单量，本次跳过" }
            return
        }
        host.ledger.setContractSize(contractSize, forInstId: market.instId)

        // In OKX's long/short (hedge) account mode every swap order must name
        // the position leg it acts on, and `side` alone does not identify it:
        // "sell" opens a short but also closes a long. The leg is whichever
        // position we currently hold, or — from flat — whichever the delta is
        // opening. A net-mode account names no leg at all, and refuses one.
        // Spot has no such concept and must not send the field.
        let heldContracts = host.ledger.position(for: strategy.id)?.quantity ?? 0
        var posSide: PositionSide?
        if market.instType.usesPositionSide {
            let leg = abs(heldContracts) > 1e-12 ? heldContracts : baseDelta
            posSide = await positionSide(forLeg: leg, host: host)
        }
        // An order that shrinks a derivative position says so, and the
        // exchange then refuses to let it overshoot into the opposite side.
        let heldBase = host.ledger.position(for: strategy.id)?.baseQuantity ?? 0
        let reduces = market.instType.isDerivative && abs(heldBase) > 1e-12
            && (baseDelta > 0) != (heldBase > 0)
            && abs(baseDelta) <= abs(heldBase) + 1e-12

        func request(withProtection: Bool) -> OrderRequest {
            OrderRequest(
                instId: market.instId,
                instType: market.instType,
                side: baseDelta > 0 ? .buy : .sell,
                kind: .market,
                size: size,
                sizeUnit: .base,
                posSide: posSide,
                reduceOnly: reduces,
                stopTriggerPrice: withProtection ? stopPrice : nil,
                takeProfitTriggerPrice: withProtection ? takeProfitPrice : nil,
                clOrdId: OrderTag.make(strategyId: strategy.id))
        }

        let order = request(withProtection: true)
        // The inputs that decided the size, not just the outcome. Reconstructing
        // "why did it trade" from the fill alone is impossible: a wrong
        // multiplier produces an order that looks entirely reasonable on the
        // wire, and the number that made it wrong is never sent.
        Log.warn("""
            runner: 下单 \(strategy.id) \(market.instId) \
            \(baseDelta > 0 ? "buy" : "sell") \(size) 张（面值 \(contractSize)，\
            目标变动 \(baseDelta) 币，现持 \
            \(host.ledger.position(for: strategy.id)?.quantity ?? 0) 张）理由：\(reason)
            """)
        guard case .rejected(let rejection) = await placeOrTrack(
            order, strategy: strategy, host: host, reason: reason) else { return }

        // The exchange refused it outright, so nothing is in flight.
        //
        // The commonest reason for refusing an order that is otherwise fine
        // is the attachment: OKX rejects a trigger price it considers too
        // close to, or too far from, the mark. Abandoning the trade because
        // its *insurance* was unacceptable is the wrong trade-off — the
        // signal is still the signal. Send it bare and enforce the levels
        // from here instead.
        guard stopPrice != nil || takeProfitPrice != nil else {
            update(strategy.id) {
                $0.status = .failed
                $0.message = "交易所拒绝下单：\(rejection)"
            }
            return
        }
        switch await placeOrTrack(
            request(withProtection: false), strategy: strategy, host: host, reason: reason) {
        case .accepted:
            if let direction = TradeDirection(sign: baseDelta) {
                localStops[strategy.id] = LocalStop(
                    instId: market.instId, direction: direction,
                    stop: stopPrice, takeProfit: takeProfitPrice)
            }
            update(strategy.id) {
                $0.message = "交易所拒绝附加止损（\(rejection)），已改为裸单成交，"
                    + "止损改由本程序在 tick 上执行——App 关闭期间不受保护"
            }
            Log.warn("runner: \(strategy.id) fell back to a locally enforced stop")
        case .unconfirmed:
            // Tracked in flight like any other unanswered call; the levels are
            // armed once the fill is known.
            break
        case .rejected(let again):
            update(strategy.id) {
                $0.status = .failed
                $0.message = "交易所拒绝下单：\(rejection)；去掉止损重试仍失败：\(again)"
            }
        }
    }

    private enum PlacementOutcome {
        case accepted
        /// The call failed without a verdict from the exchange; the order is
        /// being tracked and will be resolved by asking.
        case unconfirmed
        /// The exchange saw the order and refused it — final, nothing in flight.
        case rejected(String)
    }

    /// Place an order and say what a failure means.
    ///
    /// A failed *call* is not a failed *order*. The request may have reached
    /// the exchange and filled; halting on it would strand a real position
    /// outside the ledger. Such an order is recorded in flight and resolved
    /// by asking the exchange on the next tick. Only a response carrying the
    /// exchange's own refusal is final.
    private func placeOrTrack(
        _ order: OrderRequest, strategy: CompiledStrategy,
        host: StrategyRunnerHost, reason: String
    ) async -> PlacementOutcome {
        do {
            try await place(order, strategy: strategy, host: host, reason: reason)
            return .accepted
        } catch {
            if let rejection = (error as? TradeError)?.exchangeRejection {
                return .rejected(rejection)
            }
            let clOrdId = order.clOrdId ?? ""
            inFlight[clOrdId] = InFlightOrder(
                strategyId: strategy.id, instId: order.instId, instType: order.instType,
                clOrdId: clOrdId, submittedAt: Date(), attempts: 0)
            update(strategy.id) {
                $0.status = .running
                $0.message = "下单结果未确认，等待交易所确认：\(error)"
            }
            return .unconfirmed
        }
    }

    // MARK: Account configuration

    /// The leg a perpetual order names. A long/short account names the side
    /// the position is on; a net-mode account names `net`, and sending `long`
    /// there is refused with an error that says nothing about why.
    private func positionSide(forLeg leg: Double, host: StrategyRunnerHost) async -> PositionSide {
        if await accountTradingConfig(host: host)?.positionMode == .net { return .net }
        return leg > 0 ? .long : .short
    }

    /// How often the account's derivative settings are re-read. They change
    /// only when the user changes them, and each read is an authenticated
    /// call.
    public static let accountConfigTTL: TimeInterval = 3_600
    private var accountConfigCache: (config: AccountTradingConfig, at: Date)?

    /// The account's position mode and margin level, cached. Nil when it has
    /// never been readable, in which case callers fall back to the long/short
    /// mode this app has always assumed — and the log says the read failed,
    /// so a rejected order can be traced to it.
    private func accountTradingConfig(host: StrategyRunnerHost) async -> AccountTradingConfig? {
        if let cached = accountConfigCache,
           Date().timeIntervalSince(cached.at) < Self.accountConfigTTL {
            return cached.config
        }
        do {
            let config = try await host.venue.accountTradingConfig(mode: host.portfolio.mode)
            accountConfigCache = (config, Date())
            return config
        } catch {
            Log.warn("runner: 读不到账户配置（\(error)），仓位模式沿用上次读数或按 long/short 处理")
            return accountConfigCache?.config
        }
    }

    // MARK: Option execution

    /// How far above the ask a buy may pay, and below the bid a sell may
    /// accept, so an IOC order clears a thin book without chasing it.
    public static let optionPriceBuffer = 0.02
    /// An ask this far above the exchange's mark is not a price; it is an
    /// empty book with a placeholder in it, and buying there hands the
    /// premium to whoever left it.
    public static let optionMaxAskOverMark = 0.25
    /// How long a fetched chain is reused. Listings change at settlement,
    /// three times a day at most.
    public static let optionChainTTL: TimeInterval = 600
    private var optionChains: [String: (contracts: [OptionContract], at: Date)] = [:]

    private func optionChain(
        underlying: String, host: StrategyRunnerHost
    ) async throws -> [OptionContract] {
        if let cached = optionChains[underlying],
           Date().timeIntervalSince(cached.at) < Self.optionChainTTL {
            return cached.contracts
        }
        let contracts = try await host.venue.optionChain(underlying: underlying, mode: host.portfolio.mode)
        optionChains[underlying] = (contracts, Date())
        return contracts
    }

    /// The contract's tick and lot, from the chain already fetched or the
    /// exchange's metadata.
    private func optionContractMeta(instId: String, host: StrategyRunnerHost) async -> InstrumentMeta? {
        if let listed = optionChains.values
            .flatMap(\.contracts)
            .first(where: { $0.instId == instId }) {
            return listed.meta
        }
        if let cached = metaCache[instId] { return cached }
        guard let meta = (try? await host.venue.instrumentMeta(instId: instId, mode: host.portfolio.mode)) ?? nil else {
            return nil
        }
        metaCache[instId] = meta
        return meta
    }

    /// Carry out the kernel's option plan.
    private func executeOptionPlan(
        _ plan: KernelOptionPlan, strategy: CompiledStrategy,
        host: StrategyRunnerHost, reason: String
    ) async {
        guard !Task.isCancelled else { return }
        switch plan.action {
        case .close:
            await closeOption(strategy: strategy, host: host, reason: reason)
        case .open:
            await openOption(plan, strategy: strategy, host: host, reason: reason)
        case .flip:
            await closeOption(strategy: strategy, host: host, reason: reason)
            // Only a book that is actually flat takes the new contract. A
            // close that did not fill leaves the old one, and the next bar
            // decides again from what is really held.
            guard host.ledger.position(for: strategy.id)?.isFlat ?? true else { return }
            await openOption(plan, strategy: strategy, host: host, reason: reason)
        }
    }

    /// Buy the contract the plan asks for: chain → selection rule → quote →
    /// whole contracts the budget affords → an IOC limit a little through the
    /// ask.
    private func openOption(
        _ plan: KernelOptionPlan, strategy: CompiledStrategy,
        host: StrategyRunnerHost, reason: String
    ) async {
        guard let kind = plan.kind else { return }
        guard host.ledger.position(for: strategy.id)?.isFlat ?? true else {
            update(strategy.id) { $0.message = "已持有期权仓位，未再开仓" }
            return
        }
        let underlying = strategy.optionsSpec.resolvedUnderlying(for: strategy.market)

        let chain: [OptionContract]
        do {
            chain = try await optionChain(underlying: underlying, host: host)
        } catch {
            update(strategy.id) { $0.message = "读不到 \(underlying) 期权链，未开仓：\(error)" }
            return
        }
        guard let index = try? await host.venue.indexPrice(underlying: underlying, mode: host.portfolio.mode), index > 0 else {
            update(strategy.id) { $0.message = "读不到 \(underlying) 指数价，未开仓" }
            return
        }

        let chosen: KernelOptionCandidate?
        do {
            chosen = try TradingKernel.selectOptionContract(
                kind: kind, spot: index, now: Date(),
                minDaysToExpiry: plan.minDaysToExpiry, moneynessPct: plan.moneynessPct,
                strikeStep: plan.strikeStep,
                candidates: chain.map(KernelOptionCandidate.init(contract:)))
        } catch {
            update(strategy.id) {
                $0.status = .failed
                $0.message = "期权合约筛选失败：\(error)"
            }
            return
        }
        guard let chosen, let contract = chain.first(where: { $0.instId == chosen.instId }) else {
            update(strategy.id) {
                $0.message = "\(underlying) 期权链里没有到期 ≥ "
                    + "\(PriceFormatter.plain(plan.minDaysToExpiry)) 天的\(kind.displayName)合约，未开仓"
            }
            return
        }

        guard let quote = try? await host.venue.optionQuote(instId: contract.instId, mode: host.portfolio.mode) else {
            update(strategy.id) { $0.message = "读不到 \(contract.instId) 报价，未开仓" }
            return
        }
        guard let ask = quote.ask, ask > 0, quote.indexPrice > 0 else {
            update(strategy.id) { $0.message = "\(contract.instId) 没有卖盘，未开仓" }
            return
        }
        if let mark = quote.mark, mark > 0, ask > mark * (1 + Self.optionMaxAskOverMark) {
            update(strategy.id) {
                $0.message = "\(contract.instId) 卖一 \(PriceFormatter.plain(ask)) 高出标记价 "
                    + "\(PriceFormatter.plain(mark)) 超过 \(Int(Self.optionMaxAskOverMark * 100))%，"
                    + "盘口太薄，未开仓"
            }
            return
        }

        // The exchange quotes in the settlement coin per unit of underlying;
        // the budget is in quote currency, so the ask converts at the same
        // index the fill will be booked at.
        let premiumQuotePerUnit = ask * quote.indexPrice
        let perContract = premiumQuotePerUnit * contract.contractValue
        let lot = contract.lotSize > 0 ? contract.lotSize : 1
        let contracts = perContract > 0
            ? (plan.premiumBudget / perContract / lot).rounded(.down) * lot : 0
        guard contracts >= Swift.max(contract.minSize, lot), contracts > 0 else {
            update(strategy.id) {
                $0.message = "权利金预算 \(PriceFormatter.money(plan.premiumBudget)) 买不起一张 "
                    + "\(contract.instId)（每张约 \(PriceFormatter.money(perContract))），未开仓"
            }
            return
        }
        let tick = contract.tickSize > 0 ? contract.tickSize : 0.0001
        let limit = Self.snapToTick(ask * (1 + Self.optionPriceBuffer), tick: tick, roundingUp: true)
        let config = await accountTradingConfig(host: host)
        let tradeMode = (config ?? AccountTradingConfig(positionMode: nil, accountLevel: nil))
            .optionTradeMode
        if let funding = await premiumFunding(
            contract: contract, contracts: contracts, limit: limit,
            strategy: strategy, config: config, host: host),
           !funding.isCovered {
            Log.warn("runner: \(strategy.id) 未下单：\(funding.explanation)")
            update(strategy.id) { $0.message = "未开仓：\(funding.explanation)" }
            return
        }
        host.ledger.setContractSize(contract.contractValue, forInstId: contract.instId)

        let order = OrderRequest(
            instId: contract.instId, instType: .option, side: .buy, kind: .ioc,
            size: contracts, sizeUnit: .base, limitPrice: limit,
            clOrdId: OrderTag.make(strategyId: strategy.id), tradeMode: tradeMode)
        Log.warn("""
            runner: 期权下单 \(strategy.id) 买入 \(contract.instId) \
            \(PriceFormatter.plain(contracts)) 张 @≤\(PriceFormatter.plain(limit)) \
            \(contract.settleCurrency)（卖一 \(PriceFormatter.plain(ask))，\
            指数 \(PriceFormatter.plain(quote.indexPrice))，每张 \(PriceFormatter.money(perContract))，\
            预算 \(PriceFormatter.money(plan.premiumBudget))，tdMode \(tradeMode)）理由：\(reason)
            """)
        if case .rejected(let rejection) = await placeOrTrack(
            order, strategy: strategy, host: host, reason: reason) {
            update(strategy.id) {
                $0.status = .failed
                $0.message = "交易所拒绝期权下单：\(rejection)"
            }
            return
        }

        // Protective levels on the premium itself, watched here. The
        // exchange's option stops trigger on a coin-denominated price that
        // would have to be re-converted on every tick, and a long option's loss
        // is bounded by the premium in any case.
        guard plan.stopLossPct != nil || plan.takeProfitPct != nil,
              let position = host.ledger.position(for: strategy.id), !position.isFlat,
              position.instId == contract.instId, position.averagePrice > 0 else { return }
        let entry = position.averagePrice
        localStops[strategy.id] = LocalStop(
            instId: contract.instId, direction: .long,
            stop: plan.stopLossPct.map { entry * (1 - $0 / 100) },
            takeProfit: plan.takeProfitPct.map { entry * (1 + $0 / 100) })
    }

    /// Whether the account can pay the premium for `contracts` of `contract`
    /// at `limit`, or nil when that cannot be known. The exchange then rules
    /// on the order itself, and the log says the check was skipped rather
    /// than passed.
    private func premiumFunding(
        contract: OptionContract, contracts: Double, limit: Double,
        strategy: CompiledStrategy, config: AccountTradingConfig?, host: StrategyRunnerHost
    ) async -> OptionPremiumFunding? {
        guard let config else {
            Log.warn("""
                runner: \(strategy.id) 读不到账户配置，跳过结算币 \(contract.settleCurrency) \
                余额检查，由交易所裁定
                """)
            return nil
        }
        let snapshot: AccountSnapshot
        do {
            snapshot = try await host.venue.accountSnapshot(mode: host.portfolio.mode)
        } catch {
            Log.warn("""
                runner: \(strategy.id) 读不到账户余额（\(error)），跳过结算币 \
                \(contract.settleCurrency) 检查，由交易所裁定
                """)
            return nil
        }
        return OptionPremiumFunding(
            settleCurrency: contract.settleCurrency, contracts: contracts,
            contractValue: contract.contractValue, limitPrice: limit,
            feeBps: strategy.manifest.effectiveCosts.feeBps,
            feeCapPctOfPremium: strategy.optionsSpec.feeCapPctOfPremium,
            available: snapshot.balance(of: contract.settleCurrency)?.available ?? 0,
            config: config)
    }

    /// Sell the held contract back into its book, whole, with an IOC limit a
    /// little through the bid.
    private func closeOption(
        strategy: CompiledStrategy, host: StrategyRunnerHost, reason: String
    ) async {
        guard !Task.isCancelled,
              let position = host.ledger.position(for: strategy.id), !position.isFlat,
              InstrumentType.of(instId: position.instId) == .option else { return }
        let contracts = abs(position.quantity)

        guard let quote = try? await host.venue.optionQuote(instId: position.instId, mode: host.portfolio.mode) else {
            update(strategy.id) { $0.message = "读不到 \(position.instId) 报价，未能平仓" }
            return
        }
        guard let bid = quote.bid, bid > 0 else {
            update(strategy.id) {
                $0.message = "\(position.instId) 没有买盘，未能平仓；到期时交易所按内在价值结算"
            }
            return
        }
        let tick = (await optionContractMeta(instId: position.instId, host: host))?.tickSize ?? 0.0001
        let step = tick > 0 ? tick : 0.0001
        let limit = Swift.max(
            Self.snapToTick(bid * (1 - Self.optionPriceBuffer), tick: step, roundingUp: false), step)
        let tradeMode = (await accountTradingConfig(host: host)
            ?? AccountTradingConfig(positionMode: nil, accountLevel: nil)).optionTradeMode

        let order = OrderRequest(
            instId: position.instId, instType: .option,
            side: position.quantity > 0 ? .sell : .buy, kind: .ioc,
            size: contracts, sizeUnit: .base, limitPrice: limit, reduceOnly: true,
            clOrdId: OrderTag.make(strategyId: strategy.id), tradeMode: tradeMode)
        Log.warn("""
            runner: 期权平仓 \(strategy.id) \(order.side.displayName) \(position.instId) \
            \(PriceFormatter.plain(contracts)) 张 @≥\(PriceFormatter.plain(limit))（买一 \
            \(PriceFormatter.plain(bid))，指数 \(PriceFormatter.plain(quote.indexPrice))）理由：\(reason)
            """)
        if case .rejected(let rejection) = await placeOrTrack(
            order, strategy: strategy, host: host, reason: reason) {
            update(strategy.id) {
                $0.status = .failed
                $0.message = "交易所拒绝期权平仓：\(rejection)"
            }
        }
        if host.ledger.position(for: strategy.id)?.isFlat ?? true {
            localStops[strategy.id] = nil
        }
    }

    /// Submit one order and book whatever it filled.
    private func place(
        _ order: OrderRequest, strategy: CompiledStrategy,
        host: StrategyRunnerHost, reason: String
    ) async throws {
        _ = try await host.venue.place(
            order, mode: host.portfolio.mode, liveUnlocked: host.liveTradingUnlocked)
        inFlight[order.clOrdId ?? ""] = nil
        update(strategy.id) {
            $0.lastOrderAt = Date()
            $0.message = "\(reason)：\(order.side.displayName) \(PriceFormatter.plain(order.size))"
        }
        // Give the exchange a moment, then book the fill. The cached listing
        // predates this order, so it is dropped first — reading it back would
        // report the position as unchanged and, on the next tick, look exactly
        // like an external reduction.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        fillsThisTick = fillsThisTick.filter { $0.key.instType != order.instType }
        await ingestFills(for: [strategy], host: host)
        if order.kind != .limit {
            await reportImmediateOutcome(of: order, strategy: strategy, host: host, reason: reason)
        }
    }

    /// What became of an order that resolves on arrival.
    ///
    /// A market or IOC order is filled, partly filled or cancelled before the
    /// placing call returns, so "买入 3" is not yet a fact when it is written:
    /// an IOC the book never touched leaves the ledger, correctly, holding
    /// nothing, and a message saying a buy happened next to a book saying it
    /// did not is the kind of disagreement that gets believed the wrong way
    /// round. The exchange is asked, and its answer becomes the message.
    private func reportImmediateOutcome(
        of order: OrderRequest, strategy: CompiledStrategy,
        host: StrategyRunnerHost, reason: String
    ) async {
        guard let clOrdId = order.clOrdId,
              let status = try? await host.venue.orderStatus(
                instId: order.instId, instType: order.instType,
                clOrdId: clOrdId, mode: host.portfolio.mode) else { return }
        let side = order.side.displayName
        let asked = PriceFormatter.plain(order.size)
        switch status {
        case .canceled:
            Log.warn("""
                runner: \(strategy.id) \(side) \(order.instId) \(asked) 未成交，交易所已撤单\
                （到达时盘口已不在限价内），台账未记仓位
                """)
            update(strategy.id) {
                $0.message = "\(reason)：\(side) \(asked) 未成交，交易所已撤单，台账未记仓位"
            }
        case .filled(let filled, let average)
            where order.sizeUnit == .base && filled < order.size - 1e-9:
            update(strategy.id) {
                $0.message = "\(reason)：\(side) \(asked)，成交 \(PriceFormatter.plain(filled)) "
                    + "@ \(PriceFormatter.plain(average))，其余已撤"
            }
        case .filled(_, let average):
            update(strategy.id) {
                $0.message = "\(reason)：\(side) \(asked) 已成交 @ \(PriceFormatter.plain(average))"
            }
        case .rejected(let verdict):
            // A refusal that only the listing reports: the placing call had
            // returned as if accepted.
            Log.warn("runner: \(strategy.id) \(side) \(order.instId) \(asked) 被交易所拒绝：\(verdict)")
            update(strategy.id) { $0.message = "\(reason)：\(side) \(asked) 被交易所拒绝：\(verdict)" }
        case .live, .unknown:
            break
        }
    }

    // MARK: Trailing stops

    /// Move the exchange's stop up behind the position, to the level the kernel
    /// computed from confirmed bars.
    ///
    /// **Why not OKX's own trailing-stop order.** The exchange has one, and it
    /// trails on every tick rather than once a bar — strictly tighter. It is
    /// not used, because the backtest trails on bar extremes: handing the job
    /// to a mechanism that behaves differently would mean the strategy that
    /// runs is not the strategy that was tested, and a stop measured against
    /// the wrong simulation is worth less than a slower one measured against
    /// the right it. Between bars the previous level stays live on the
    /// exchange, so the position is never unprotected — it simply tightens at
    /// the cadence it was tested at.
    private func syncTrailingStop(
        to level: Double, strategy: CompiledStrategy, host: StrategyRunnerHost
    ) async {
        guard level > 0,
              let position = host.ledger.position(for: strategy.id), !position.isFlat,
              let direction = position.direction else { return }

        // The exchange is asked what it is holding rather than trusting a
        // remembered value: a restart, or a stop that fired, would make any
        // cached level a fiction.
        let market = strategy.market
        guard let existing = try? await host.venue.protectiveOrders(
            instId: market.instId, instType: market.instType, mode: host.portfolio.mode)
        else {
            update(strategy.id) { $0.message = "移动止损：读不到交易所止损单，本次未调整" }
            return
        }

        guard let current = existing.first(where: { $0.stopTriggerPrice != nil }) else {
            // Nothing is protecting the position. That happens when the entry
            // order's attachment was refused, or after a manual entry.
            let size = abs(position.quantity)
            guard size > 0 else { return }
            do {
                try await host.venue.placeProtectiveOrder(
                    instId: market.instId, instType: market.instType,
                    posSide: market.instType == .swap
                        ? (direction == .long ? .long : .short) : nil,
                    size: size, stopPrice: level,
                    mode: host.portfolio.mode, liveUnlocked: host.liveTradingUnlocked)
                localStops[strategy.id] = nil
                update(strategy.id) {
                    $0.message = "已在交易所补挂移动止损 \(PriceFormatter.plain(level))"
                }
            } catch {
                // Falling back to local enforcement is worse but not nothing.
                localStops[strategy.id] = LocalStop(
                    instId: market.instId, direction: direction,
                    stop: level, takeProfit: nil)
                update(strategy.id) { $0.message = "交易所止损挂单失败（\(error)），已改为本地执行" }
            }
            return
        }

        // Ratchet: only ever tighten. A level that could loosen would give back
        // the protection it just gained.
        let onExchange = current.stopTriggerPrice ?? 0
        let tighter = direction == .long ? level > onExchange : level < onExchange
        // Below this the amendment is noise — every call costs a round trip and
        // OKX rate-limits the algo endpoints.
        let moved = onExchange > 0 ? abs(level - onExchange) / onExchange : 1
        guard tighter, moved >= Self.trailingStopMinMove else { return }

        do {
            try await host.venue.amendProtectiveOrder(
                instId: market.instId, instType: market.instType, algoId: current.algoId,
                stopPrice: level, mode: host.portfolio.mode,
                liveUnlocked: host.liveTradingUnlocked)
            update(strategy.id) {
                $0.message = "移动止损 \(PriceFormatter.plain(onExchange))"
                    + " → \(PriceFormatter.plain(level))"
            }
        } catch {
            // The old level is still live on the exchange, so the position kept
            // the protection it had; only the tightening was lost.
            update(strategy.id) {
                $0.message = "移动止损上移失败，交易所仍按 "
                    + "\(PriceFormatter.plain(onExchange)) 保护：\(error)"
            }
            Log.warn("runner: could not trail the stop for \(strategy.id): \(error)")
        }
    }

    /// Relative move below which the stop is left where it is.
    public static let trailingStopMinMove = 0.001

    // MARK: Locally enforced protective levels

    /// Levels this runner has to watch itself, because the exchange refused to
    /// attach them to the order.
    ///
    /// Strictly a fallback, and a weaker one: it only sees the mark at tick
    /// resolution and not at all while the app is closed, which is exactly why
    /// the levels ride on the order whenever OKX will accept them. Populated
    /// only after a refusal, so it can never race an exchange-side stop.
    private var localStops: [String: LocalStop] = [:]

    private struct LocalStop {
        let instId: String
        let direction: TradeDirection
        let stop: Double?
        let takeProfit: Double?

        func breach(at price: Double) -> String? {
            switch direction {
            case .long:
                if let stop, price <= stop { return "止损" }
                if let takeProfit, price >= takeProfit { return "止盈" }
            case .short:
                if let stop, price >= stop { return "止损" }
                if let takeProfit, price <= takeProfit { return "止盈" }
            }
            return nil
        }
    }

    private func enforceLocalStops(for host: StrategyRunnerHost) async {
        for (strategyId, level) in localStops {
            guard let position = host.ledger.position(for: strategyId), !position.isFlat,
                  position.direction == level.direction else {
                // The position is gone or reversed; the level no longer applies.
                localStops[strategyId] = nil
                continue
            }
            guard let price = marks[level.instId],
                  let kind = level.breach(at: price) else { continue }
            localStops[strategyId] = nil
            update(strategyId) { $0.message = "本地\(kind)触发（\(PriceFormatter.plain(price))），正在平仓" }
            await flatten(strategyId: strategyId,
                          reason: "本地\(kind)触发（\(PriceFormatter.plain(price))）")

            // Disarming before the order lands would leave the position
            // unprotected for good if that order failed. Only a position that
            // is actually gone releases the level.
            guard host.ledger.position(for: strategyId)?.isFlat ?? true else {
                localStops[strategyId] = level
                update(strategyId) { $0.message = "本地\(kind)平仓未成交，仍在盯价" }
                continue
            }
            lastExitBar[strategyId] =
                lastConfirmedBarTime(forStrategy: strategyId, host: host) ?? Date()
        }
    }

    // MARK: Fill attribution

    private func ingestFills(for strategies: [CompiledStrategy], host: StrategyRunnerHost) async {
        await ingestFills(for: Set(strategies.map(instrumentKey(for:))), host: host)
    }

    /// Where a strategy's fills are listed.
    ///
    /// An option strategy's fills land on whichever contract it holds, which
    /// changes at every roll — so its listing is the whole option book, and
    /// attribution by tag does the rest.
    private func instrumentKey(for strategy: CompiledStrategy) -> InstrumentKey {
        strategy.isOptionStrategy
            ? InstrumentKey(instId: nil, instType: .option)
            : InstrumentKey(instId: strategy.market.instId, instType: strategy.market.instType)
    }

    private func ingestFills(for instruments: Set<InstrumentKey>, host: StrategyRunnerHost) async {
        guard !instruments.isEmpty else { return }
        let knownIds = host.runnableStrategies.map(\.id)
        for instrument in instruments {
            guard let listing = await fills(for: instrument, host: host) else { continue }
            let indexPrices = await indexPrices(for: listing, host: host)
            host.ledger.ingest(listing, knownStrategyIds: knownIds, indexPrices: indexPrices)
        }
    }

    /// Index prices for the option fills in a listing that the exchange did
    /// not stamp with one, read once per underlying per tick.
    private func indexPrices(
        for listing: [ExchangeFill], host: StrategyRunnerHost
    ) async -> [String: Double] {
        var prices: [String: Double] = [:]
        for fill in listing where fill.indexPrice == nil && (fill.priceUsd ?? 0) <= 0 {
            guard let underlying = InstrumentType.optionUnderlying(of: fill.instId),
                  prices[underlying] == nil else { continue }
            if let cached = indexThisTick[underlying] {
                prices[underlying] = cached
            } else if let price = try? await host.venue.indexPrice(underlying: underlying, mode: host.portfolio.mode),
                      price > 0 {
                prices[underlying] = price
                indexThisTick[underlying] = price
            }
        }
        return prices
    }

    /// Cleared at the top of every tick, like `fillsThisTick`.
    private var indexThisTick: [String: Double] = [:]

    /// Fills for one instrument, fetched at most once per tick.
    ///
    /// Reconciliation and the per-strategy ingest both want the same listing,
    /// and every call spawns an `okx` process and spends an authenticated
    /// request against the exchange's rate limit. Nothing changes between two
    /// reads inside a single tick that the tick could act on, so the second
    /// read buys nothing.
    private func fills(
        for instrument: InstrumentKey, host: StrategyRunnerHost
    ) async -> [ExchangeFill]? {
        if let cached = fillsThisTick[instrument] { return cached }
        guard let fresh = try? await host.venue.fills(
            instId: instrument.instId, instType: instrument.instType,
            mode: host.portfolio.mode) else { return nil }
        fillsThisTick[instrument] = fresh
        return fresh
    }

    /// Cleared at the top of every tick; see `fills(for:host:)`.
    private var fillsThisTick: [InstrumentKey: [ExchangeFill]] = [:]

    private struct InstrumentKey: Hashable {
        /// Nil lists every instrument of the family.
        let instId: String?
        let instType: InstrumentType
    }

    // MARK: Helpers

    private func update(_ strategyId: String, _ mutate: (inout StrategyRuntimeState) -> Void) {
        var state = states[strategyId] ?? StrategyRuntimeState()
        mutate(&state)
        states[strategyId] = state
    }

    private static func utcDay(of date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400)
    }
}
