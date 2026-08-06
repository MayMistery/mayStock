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
    func runnerDidHalt(strategyId: String, reason: String)
    /// A fresh reading of total account equity, for the equity curve.
    func runnerDidSampleEquity(_ equity: Double, at ts: Date)
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
    public static let tickStallTimeout: TimeInterval = 300
    /// How long an unconfirmed order may stay unresolved before the strategy is
    /// halted for a human to look at. Long enough to ride out an outage, short
    /// enough that nobody discovers it a day later.
    public static let inFlightTimeout: TimeInterval = 600

    private weak var host: StrategyRunnerHost?
    private let rest: OKXRESTClient
    private var loop: Task<Void, Never>?

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

    /// How often the loop wakes. Bar-close detection does the real pacing.
    public static let tickInterval: TimeInterval = 20

    public init(host: StrategyRunnerHost, rest: OKXRESTClient = OKXRESTClient()) {
        self.host = host
        self.rest = rest
    }

    // MARK: Lifecycle

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                // Drop the strong reference before sleeping, so a deallocated
                // runner ends the loop instead of keeping it alive for a tick.
                guard let runner = self else { return }
                await runner.tick()
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        for id in states.keys { states[id]?.status = .stopped }
    }

    public func state(for strategyId: String) -> StrategyRuntimeState {
        states[strategyId] ?? StrategyRuntimeState()
    }

    public func mark(for instId: String) -> Double? { marks[instId] }

    /// Flatten one strategy immediately at market. Used by the stop button and
    /// by the emergency stop.
    public func flatten(strategyId: String) async {
        guard let host,
              let strategy = host.runnableStrategies.first(where: { $0.id == strategyId }),
              let position = host.ledger.position(for: strategyId), !position.isFlat else { return }
        // baseQuantity, not quantity: a swap position is counted in contracts, and
        // submit() converts base units back into contracts itself. Passing
        // contracts here would have tried to sell 11.65 BTC instead of 0.1165.
        await submit(baseDelta: -position.baseQuantity, strategy: strategy, host: host,
                     reason: "手动平仓")
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
            // Defence in depth: if a previous tick wedged despite the
            // per-command timeouts, recover rather than stall forever.
            guard let started = tickStartedAt,
                  Date().timeIntervalSince(started) > Self.tickStallTimeout else { return }
            Log.warn("strategy runner: tick stalled for "
                     + "\(Int(Date().timeIntervalSince(started)))s, recovering")
        }
        isTicking = true
        tickStartedAt = Date()
        defer { isTicking = false; tickStartedAt = nil; lastTickAt = Date() }

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

        // Equity is sampled unconditionally — before the "is anything running"
        // guard below — because "how much money is in this account" is a
        // question the panel must answer even with every strategy stopped.
        await sampleEquity(for: host)

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

    /// Refresh the mark price of every instrument the ledger has exposure to,
    /// and make sure the ledger knows each one's contract size.
    ///
    /// The contract size matters as much as the price: a swap position is
    /// counted in contracts, so without it every P&L figure is out by the
    /// multiplier (100× on BTC, 10× on ETH).
    private func refreshMarks(for host: StrategyRunnerHost) async {
        let instruments = Set(host.ledger.positions.values.filter { !$0.isFlat }.map(\.instId))
        for instId in instruments {
            if let price = try? await host.venue.lastPrice(instId: instId), price > 0 {
                marks[instId] = price
            }
            host.ledger.setContractSize(
                await contractSize(for: instId, venue: host.venue), forInstId: instId)
        }
    }

    /// Base units per contract, cached. Spot is one-for-one.
    private func contractSize(for instId: String, venue: any ExchangeVenue) async -> Double {
        if let cached = metaCache[instId] { return cached.contractValue ?? 1 }
        guard let meta = (try? await venue.instrumentMeta(instId: instId)) ?? nil else { return 1 }
        metaCache[instId] = meta
        return meta.contractValue ?? 1
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
            if let quoted = try? await host.venue.lastPrice(instId: instId), quoted > 0 {
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
            if price == nil { price = try? await host.venue.lastPrice(instId: instId) }
            guard let price, price > 0 else { continue }
            marks[instId] = price
            exposure += balance.total * price
        }

        // Derivative positions, at their own mark and contract size.
        for state in host.ledger.positions.values where !state.isFlat {
            guard state.instId.hasSuffix("-SWAP") else { continue }
            let price = marks[state.instId] ?? state.averagePrice
            exposure += abs(state.baseQuantity) * price
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
                candles = try await rest.historyCandles(
                    instId: market.instId, bar: market.bar, target: wanted)
            } else {
                let recent = try await rest.candles(instId: market.instId, bar: market.bar, target: 100)
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
            let loaded = await AlternativeDataProvider(rest: rest).load(
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
                $0.status = .running
                $0.message = nil
            }
            return
        }

        let position = host.ledger.position(for: strategy.id)
        let current = position?.direction

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
                    heldBase: position?.baseQuantity ?? 0,
                    dayStartEquity: anchor.equity,
                    leverageCap: allocation.leverageCap,
                    barsSinceExit: barsSince(lastExitBar[strategy.id],
                                             latestBar: latestBar, market: market),
                    haltedToday: anchor.halted))
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

        lastActedBar[strategy.id] = latestBar.ts
        update(strategy.id) {
            $0.status = decision.haltDailyLoss ? .halted : .running
            $0.message = decision.reason
            $0.lastEvaluatedAt = Date()
            $0.targetDirection = decision.direction
        }

        if decision.shouldTrade {
            await submit(baseDelta: decision.baseDelta, strategy: strategy, host: host,
                         reason: decision.reason,
                         stopPrice: decision.stopPrice,
                         takeProfitPrice: decision.takeProfitPrice)
            if decision.target == 0 { lastExitBar[strategy.id] = latestBar.ts }
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
        guard let since, market.bar.seconds > 0 else { return nil }
        return Swift.max(Int(latestBar.ts.timeIntervalSince(since) / market.bar.seconds), 0)
    }

    /// Bars the current position has been held for, from its first fill.
    private func barsHeldCount(
        position: StrategyPositionState?, latestBar: Candle, market: StrategyMarket
    ) -> Int {
        guard let first = position?.firstFillAt, market.bar.seconds > 0 else { return 0 }
        return Swift.max(Int(latestBar.ts.timeIntervalSince(first) / market.bar.seconds), 0)
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

    // MARK: Sizing

    /// Capital this strategy may deploy: its budget compounded by its own P&L,
    /// never spilling into another strategy's allocation.
    private func workingCapital(
        strategy: CompiledStrategy, allocation: StrategyAllocation, host: StrategyRunnerHost
    ) -> Double {
        let state = host.ledger.position(for: strategy.id)
        let mark = marks[strategy.market.instId]
        let pnl = state?.netPnL(mark: mark) ?? 0
        return Swift.max(allocation.capital + pnl, 0)
    }

    // MARK: Order submission

    private func submit(
        baseDelta: Double, strategy: CompiledStrategy, host: StrategyRunnerHost, reason: String,
        stopPrice: Double? = nil, takeProfitPrice: Double? = nil
    ) async {
        guard abs(baseDelta) > 0 else { return }
        let market = strategy.market
        // A flatten can be requested for a strategy that never ran this
        // session, so there may be no cached mark — fetch one rather than
        // silently doing nothing with the user's open position.
        if marks[market.instId] == nil {
            marks[market.instId] = try? await host.venue.lastPrice(instId: market.instId)
        }
        guard let price = marks[market.instId], price > 0 else {
            update(strategy.id) { $0.message = "取不到行情价，未能下单" }
            return
        }

        let meta: InstrumentMeta?
        if let cached = metaCache[market.instId] {
            meta = cached
        } else {
            meta = try? await rest.instrumentMeta(instId: market.instId)
            if let meta { metaCache[market.instId] = meta }
        }

        let size = meta?.exchangeSize(forBaseQuantity: abs(baseDelta)) ?? abs(baseDelta)
        guard size > 0 else {
            update(strategy.id) { $0.message = "调整量低于交易所最小下单量，本次跳过" }
            return
        }

        // In OKX's long/short (hedge) account mode every swap order must name
        // the position leg it acts on, and `side` alone does not identify it:
        // "sell" opens a short but also closes a long. The leg is whichever
        // position we currently hold, or — from flat — whichever the delta is
        // opening. Spot has no such concept and must not send the field.
        var posSide: PositionSide?
        if market.instType == .swap {
            let held = host.ledger.position(for: strategy.id)?.quantity ?? 0
            let leg = abs(held) > 1e-12 ? held : baseDelta
            posSide = leg > 0 ? .long : .short
        }

        let order = OrderRequest(
            instId: market.instId,
            instType: market.instType,
            side: baseDelta > 0 ? .buy : .sell,
            kind: .market,
            size: size,
            sizeUnit: .base,
            posSide: posSide,
            stopTriggerPrice: stopPrice,
            takeProfitTriggerPrice: takeProfitPrice,
            clOrdId: OrderTag.make(strategyId: strategy.id))

        let clOrdId = order.clOrdId ?? ""
        do {
            let mode = host.portfolio.mode
            _ = try await host.venue.place(
                order, mode: mode, liveUnlocked: host.liveTradingUnlocked)
            inFlight[clOrdId] = nil
            update(strategy.id) {
                $0.lastOrderAt = Date()
                $0.message = "\(reason)：\(order.side.displayName) \(PriceFormatter.plain(size))"
            }
            // Give the exchange a moment, then book the fill.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await ingestFills(for: [strategy], host: host)
        } catch {
            // A failed *call* is not a failed *order*. The request may have
            // reached the exchange and filled; halting here would strand a real
            // position outside the ledger. Record it and ask the exchange what
            // happened on the next tick.
            inFlight[clOrdId] = InFlightOrder(
                strategyId: strategy.id, instId: market.instId, instType: market.instType,
                clOrdId: clOrdId, submittedAt: Date(), attempts: 0)
            update(strategy.id) {
                $0.status = .running
                $0.message = "下单结果未确认，等待交易所确认：\(error)"
            }
        }
    }

    // MARK: Fill attribution

    private func ingestFills(for strategies: [CompiledStrategy], host: StrategyRunnerHost) async {
        let instruments = Set(strategies.map { ($0.market.instId, $0.market.instType) }
            .map { InstrumentKey(instId: $0.0, instType: $0.1) })
        guard !instruments.isEmpty else { return }
        let knownIds = host.runnableStrategies.map(\.id)
        let mode = host.portfolio.mode

        for instrument in instruments {
            guard let fills = try? await host.venue.fills(
                instId: instrument.instId, instType: instrument.instType, mode: mode) else { continue }
            host.ledger.ingest(fills, knownStrategyIds: knownIds)
        }
    }

    private struct InstrumentKey: Hashable {
        let instId: String
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
