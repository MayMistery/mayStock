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

    // The venue's account as every screen and the trading loop read it. The
    // one copy: OKX's is the live account document, valued at the mark as it
    // streams; a venue with no stream is read on a clock. Each part keeps its
    // own stamp, because they are not always read together — one stamp for
    // all of them let a five-minute-old position table borrow the age of a
    // twenty-second-old equity sample (2026-10-08).

    /// The whole reading, not just its balance lines: the aggregate view needs
    /// the venue's own `totalEquity` — the one figure that is already in USD
    /// and already counts what no balance line carries (a derivative's
    /// unrealised P&L) — and deriving the lines from here keeps the two from
    /// describing different moments.
    var accountSnapshot: AccountSnapshot?
    var accountBalances: [AccountBalance] { accountSnapshot?.balances ?? [] }
    /// How much of each currency and share the account holds, whatever it is
    /// worth: what a transfer or a trade changes and a price never does.
    var heldCounts: [String: Double] {
        Dictionary(accountBalances.map { ($0.ccy, $0.total) }, uniquingKeysWith: +)
    }
    /// When `accountSnapshot`'s equity was true.
    var equityAt: Date?
    /// Past this age `equityAt` reads stale: set with each reading, from the
    /// clock that renews it — a few of its intervals, by the kernel's rule.
    var equityStaleAfter: TimeInterval?
    /// Every holding the venue lists — contracts, then shares — as every
    /// screen shows them.
    var exchangePositions: [ExchangePosition] { contractPositions + shareHoldings }
    /// Contract positions: what the account's contract risk is measured from.
    var contractPositions: [ExchangePosition] = []
    /// Shares, valued through the balances.
    var shareHoldings: [ExchangePosition] = []
    /// When the list of positions was last confirmed; each position carries
    /// the time of its own mark.
    var positionsAt: Date?
    /// Where equity and positions came from.
    var accountSource: AccountReading.Source?
    /// The live account document last adopted, for what it says about
    /// itself — its feeds, transfers, why a figure is as pushed.
    var liveAccount: LiveAccount?
    var accountError: String?
    /// Everything the venue is holding open on the active account, whoever
    /// placed it. Kept apart from `accountError`: a refused order book must
    /// not blank the equity and positions that were read fine.
    var openOrders: [ExchangeOpenOrder] = []
    /// Books the listing could not read, in words; nil when it read them all.
    var openOrdersNote: String?
    var openOrdersError: String?
    var ordersAt: Date?
    /// Everything the venue has filled on this account lately, whoever placed
    /// it — newest first.
    ///
    /// Kept beside the local ledger's fills rather than derived from them: the
    /// ledger only knows the orders MayStock itself sent, and it can only
    /// attribute those it tagged. Everything else on the account — placed by
    /// hand, by the exchange's own CLI, or by another program — is real
    /// trading the account did, and a 「最近成交」 panel fed only by the
    /// ledger reads "nothing traded" on an account that traded all week. That
    /// is the same class of mistake as showing an external position as if it
    /// did not exist, and it is the mistake this field exists to stop.
    ///
    /// No count appears here on purpose. The window rolls — three readings of
    /// the same account on three days gave 58, 63 and 59 fills — so any number
    /// written into this comment is wrong within a day.
    var exchangeFills: [ExchangeFill] = []
    /// Fill books that could not be read, in words; nil when all were read.
    var exchangeFillsNote: String?
    var exchangeFillsError: String?
    var fillsAt: Date?
    /// The venue's own ledger of the active account, as last read, where the
    /// venue keeps one (`Venue.publishesBills`) — the realised breakdown of a
    /// window's result.
    var exchangeBills: ExchangeBillListing?
    var billsError: String?
    /// Money moved into or out of the account over the last week, as last
    /// read: what a window's result leaves out. Nil until read — which is not
    /// the same as none moved.
    var transfers: AccountTransferListing?
    var transfersError: String?
    var isRefreshingAccount = false
    /// One connection verdict per environment.
    var connections: [TradingMode: VenueConnectionStatus] = [:]

    /// Told whenever the account's figures are forgotten, and why.
    @ObservationIgnored var onCleared: ((String?) -> Void)?
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

    func didSampleEquity(_ equity: Double, rate: Double?, mode: TradingMode, at ts: Date) {
        equityCurve(for: mode).record(equity: equity, at: ts, quoteUsd: rate)
    }

    // MARK: The account reading

    /// Forget everything read from the account: on a switch to the other
    /// account, and when the account may no longer be read at all — a figure
    /// from the previous account must never stay on screen looking current.
    func clearAccount(reason: String? = nil) {
        accountSnapshot = nil
        equityAt = nil
        equityStaleAfter = nil
        contractPositions = []
        shareHoldings = []
        positionsAt = nil
        accountSource = nil
        liveAccount = nil
        openOrders = []
        openOrdersNote = nil
        openOrdersError = nil
        ordersAt = nil
        exchangeFills = []
        exchangeFillsNote = nil
        exchangeFillsError = nil
        fillsAt = nil
        exchangeBills = nil
        billsError = nil
        transfers = nil
        transfersError = nil
        accountError = reason
        onCleared?(reason)
    }

    /// The current reading, as the trading loop takes it.
    var reading: AccountReading? {
        guard let accountSnapshot, let equityAt, let accountSource else { return nil }
        return AccountReading(
            snapshot: accountSnapshot, equityAt: equityAt,
            positions: positionsAt == nil ? nil : contractPositions, shareHoldings: shareHoldings,
            positionsError: positionsAt == nil ? accountError : nil,
            positionsAt: positionsAt, source: accountSource)
    }

    /// Take a REST reading as the account's current one.
    func adopt(_ reading: AccountReading) {
        accountSnapshot = reading.snapshot
        equityAt = reading.equityAt
        equityStaleAfter = reading.pollInterval(quoteCurrency: venue.quoteCurrency) * LiveKernel.staleAfterIntervals
        if let positions = reading.positions {
            contractPositions = positions
            shareHoldings = reading.shareHoldings
            positionsAt = reading.positionsAt
        }
        accountSource = reading.source
        accountError = reading.positionsError
    }

    /// Take the live account document as the account's current reading — if
    /// it is this account's. A document for the other environment (the layer
    /// has not caught up with a switch yet) is not this account's figures.
    func adopt(_ account: LiveAccount, mode: TradingMode) {
        guard account.mode == (mode.isDemo ? "demo" : "live") else { return }
        liveAccount = account
        guard account.source != "none" else { return }
        let source: AccountReading.Source = account.source == "rest" ? .fallback : .stream
        if account.wasRead, let positionsMs = account.positionsMs {
            contractPositions = account.exchangePositions
            shareHoldings = []
            positionsAt = account.date(ms: positionsMs)
        }
        if let snapshot = account.snapshot, let asOf = account.equityAsOf() {
            accountSnapshot = snapshot
            equityAt = account.date(ms: asOf.ms)
            equityStaleAfter = asOf.staleAfterMs / 1000
        }
        // Every working order, read whole and again the moment a push says
        // one changed. A failed read keeps the last good list, labelled.
        if let listing = account.orders.listing, let readMs = account.orders.readMs {
            openOrders = listing.orders
            openOrdersNote = listing.unavailable.isEmpty
                ? nil : "未能读取：" + listing.unavailable.joined(separator: "、") + "。这些簿上若有挂单，这里不会显示。"
            openOrdersError = account.orders.error.map { "最近一次读取失败（显示的是上一次读到的）：\($0)" }
            ordersAt = account.date(ms: readMs)
        }
        if let listing = account.transferListing {
            transfers = listing
            transfersError = account.transfers.error
        }
        accountSource = source
        accountError = nil
    }

    /// Whether the live document's order listing is current — read within a
    /// few of its own intervals — so the account refresh need not read it.
    var ordersStreamed: Bool {
        guard let orders = liveAccount?.orders, orders.wasRead, let readMs = orders.readMs,
              let account = liveAccount else { return false }
        return Date().timeIntervalSince(account.date(ms: readMs)) * 1000 <= orders.staleAfterMs
    }

    /// Whether the live document is what the account is read from right now:
    /// it is this account's, it has read the positions, and the list is no
    /// older than the stream's own stale age. Otherwise the account is read
    /// over REST in its place.
    var isStreamed: Bool {
        guard let account = liveAccount, account.wasRead, account.source != "none",
              let positionsAt else { return false }
        return Date().timeIntervalSince(positionsAt) * 1000 <= account.positionsStaleAfterMs
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
        // Each point keeps the venue's own rate into its quote currency at
        // that instant, so the curve can be stated in the quote exactly.
        let rate = books.accountSnapshot?.usdRate(for: books.venue.quoteCurrency)
        books.didSampleEquity(equity, rate: rate, mode: app.tradingMode, at: ts)
    }

    /// The books' reading — the one every screen shows — when it is fresh
    /// enough; otherwise the account is read again and the books take that.
    func accountReading(maxAge: TimeInterval) async throws -> AccountReading {
        if let reading = books.reading, Date().timeIntervalSince(reading.equityAt) <= maxAge {
            return reading
        }
        await app.readAccount(books.venue)
        guard let reading = books.reading else {
            throw AccountReading.Unavailable(books.accountError ?? "账户读数不可用")
        }
        return reading
    }

    func runnerDidSampleStrategyEquity(_ strategyId: String, equity: Double, basis: Double, at ts: Date) {
        books.didSampleStrategyEquity(strategyId, equity: equity, basis: basis, mode: app.tradingMode, at: ts)
    }
}
