import Foundation
import Observation
import MayStockKit

/// Everything the app keeps per venue: the two ledgers, the equity curves,
/// the heartbeat, the latest account reading, and the runner that trades it.
///
/// One of these per venue rather than one runner switching between them,
/// because the runner is a single-account engine — its equity, exposure and
/// currency are one account's — and OKX and Schwab are two accounts in two
/// currencies. Every file this writes carries the venue in its name, except
/// OKX's, which keep the names the app has always used.
@Observable
@MainActor
final class VenueBooks {
    let venue: Venue
    let demoLedger: StrategyLedger
    let liveLedger: StrategyLedger
    let demoEquity: AccountEquityCurve
    let liveEquity: AccountEquityCurve
    /// One curve per strategy, so a single-strategy backtest has something
    /// like-for-like to be compared against.
    var demoStrategyEquity: [String: AccountEquityCurve] = [:]
    var liveStrategyEquity: [String: AccountEquityCurve] = [:]
    let heartbeatStore: HeartbeatStore
    /// When this venue's engine last finished a full tick. Nil until the first.
    private(set) var lastCompletedTickAt: Date?

    // The latest reading of the venue's account, as the UI shows it.
    var accountBalances: [AccountBalance] = []
    var exchangePositions: [ExchangePosition] = []
    var accountError: String?
    var accountRefreshedAt: Date?
    var isRefreshingAccount = false
    /// One connection verdict per environment.
    var connections: [TradingMode: VenueConnectionStatus] = [:]

    @ObservationIgnored private(set) var runner: StrategyRunner!
    @ObservationIgnored private(set) var host: VenueRunnerHost!
    @ObservationIgnored private let dataDirectory: URL

    init(venue: Venue, dataDirectory: URL, app: AppState) {
        self.venue = venue
        self.dataDirectory = dataDirectory
        demoLedger = StrategyLedger(mode: .demo, venue: venue)
        liveLedger = StrategyLedger(mode: .live, venue: venue)
        demoEquity = AccountEquityCurve(mode: .demo, venue: venue)
        liveEquity = AccountEquityCurve(mode: .live, venue: venue)
        heartbeatStore = HeartbeatStore(directory: dataDirectory, venue: venue)
        host = VenueRunnerHost(app: app, books: self)
        runner = StrategyRunner(host: host)

        load()
        demoLedger.onChanged = { [weak self] in self?.saveLedger(.demo) }
        liveLedger.onChanged = { [weak self] in self?.saveLedger(.live) }
        demoEquity.onChanged = { [weak self] in self?.saveEquity(.demo) }
        liveEquity.onChanged = { [weak self] in self?.saveEquity(.live) }
    }

    // MARK: Lookups

    func ledger(for mode: TradingMode) -> StrategyLedger { mode == .demo ? demoLedger : liveLedger }
    func equityCurve(for mode: TradingMode) -> AccountEquityCurve { mode == .demo ? demoEquity : liveEquity }
    func strategyEquityCurves(for mode: TradingMode) -> [String: AccountEquityCurve] {
        mode == .demo ? demoStrategyEquity : liveStrategyEquity
    }

    /// How long this venue's loop has been silent, or nil when it never ran.
    /// Read from disk at launch, so a restart reports the gap it was away for.
    var heartbeatSilence: TimeInterval? {
        guard let last = lastCompletedTickAt ?? heartbeatStore.load() else { return nil }
        return Date().timeIntervalSince(last)
    }

    // MARK: Runner callbacks

    func didCompleteTick(at ts: Date) {
        lastCompletedTickAt = ts
        // Written to disk, not just held in memory: the question this answers
        // is "was this app trading while I was not watching", and an in-memory
        // value cannot answer it after a crash or a restart.
        heartbeatStore.record(ts)
    }

    func didSampleEquity(_ equity: Double, mode: TradingMode, at ts: Date) {
        equityCurve(for: mode).record(equity: equity, at: ts)
        accountBalances = runner.accountBalances
        accountRefreshedAt = ts
    }

    func didSampleStrategyEquity(_ strategyId: String, equity: Double, basis: Double, mode: TradingMode, at ts: Date) {
        let curve: AccountEquityCurve
        if let existing = strategyEquityCurves(for: mode)[strategyId] {
            curve = existing
        } else {
            curve = AccountEquityCurve(mode: mode, venue: venue)
            curve.onChanged = { [weak self] in self?.saveStrategyEquity(mode) }
            if mode == .demo { demoStrategyEquity[strategyId] = curve } else { liveStrategyEquity[strategyId] = curve }
        }
        curve.record(equity: equity, at: ts, basis: basis)
    }

    // MARK: Persistence

    private func ledgerStore(_ mode: TradingMode) -> StrategyLedgerStore {
        StrategyLedgerStore(directory: dataDirectory, mode: mode, venue: venue)
    }

    private func equityStore(_ mode: TradingMode, perStrategy: Bool = false) -> AccountEquityStore {
        AccountEquityStore(directory: dataDirectory, mode: mode, venue: venue, perStrategy: perStrategy)
    }

    private func load() {
        for mode in TradingMode.allCases {
            let payload = ledgerStore(mode).load()
            ledger(for: mode).replace(
                fills: payload.fills, positions: payload.positions, fundingIds: payload.fundingIds)
            equityCurve(for: mode).replace(points: equityStore(mode).load())
            var curves: [String: AccountEquityCurve] = [:]
            for (strategyId, points) in equityStore(mode, perStrategy: true).loadByStrategy() {
                let curve = AccountEquityCurve(mode: mode, venue: venue)
                curve.replace(points: points)
                curve.onChanged = { [weak self] in self?.saveStrategyEquity(mode) }
                curves[strategyId] = curve
            }
            if mode == .demo { demoStrategyEquity = curves } else { liveStrategyEquity = curves }
        }
    }

    func saveLedger(_ mode: TradingMode) {
        let ledger = ledger(for: mode)
        try? ledgerStore(mode).save(
            fills: ledger.fills, positions: ledger.positions, fundingIds: ledger.recordedFundingIds)
    }

    private func saveEquity(_ mode: TradingMode) {
        try? equityStore(mode).save(equityCurve(for: mode).points)
    }

    private func saveStrategyEquity(_ mode: TradingMode) {
        try? equityStore(mode, perStrategy: true).save(
            byStrategy: strategyEquityCurves(for: mode).mapValues(\.points))
    }
}

/// What one venue's runner is allowed to reach: the portfolio scoped to the
/// venue, the strategies that trade on it, its own ledger, and its exchange
/// adapter — built fresh on every access so a setting edited on the account
/// page is what the very next call runs under.
@MainActor
final class VenueRunnerHost: StrategyRunnerHost {
    private unowned let app: AppState
    private unowned let books: VenueBooks

    init(app: AppState, books: VenueBooks) {
        self.app = app
        self.books = books
    }

    var portfolio: StrategyPortfolioPrefs { app.store.config.strategy.scoped(to: books.venue) }
    var liveTradingUnlocked: Bool { app.liveTradingUnlocked }
    var runnableStrategies: [CompiledStrategy] { app.strategies.filter { $0.market.venue == books.venue } }
    var ledger: StrategyLedger { books.ledger(for: app.tradingMode) }
    var venue: any ExchangeVenue { app.exchangeVenue(for: books.venue) }

    func runnerDidChange() {
        // The runner mutates observable state directly; this hook exists for
        // side effects that must not run inside the tick loop.
        books.saveLedger(app.tradingMode)
    }

    func runnerDidCompleteTick(at ts: Date) {
        books.didCompleteTick(at: ts)
    }

    func runnerDidHalt(strategyId: String, reason: String) {
        app.strategyDidHalt(strategyId: strategyId, reason: reason)
    }

    func runnerDidSampleEquity(_ equity: Double, at ts: Date) {
        // The curve is per mode; the runner only ever samples the active one.
        books.didSampleEquity(equity, mode: app.tradingMode, at: ts)
    }

    func runnerDidSampleStrategyEquity(_ strategyId: String, equity: Double, basis: Double, at ts: Date) {
        books.didSampleStrategyEquity(strategyId, equity: equity, basis: basis, mode: app.tradingMode, at: ts)
    }
}
