import AppKit
import SwiftUI
import Observation
import MayStockKit

/// Persisted configuration with debounced saves.
@Observable
@MainActor
final class ConfigStore {
    var config: AppConfig
    private let io: ConfigIO
    private var saveScheduled = false

    init(directory: URL) {
        self.io = ConfigIO(directory: directory)
        self.config = io.load()
        // The app owns this directory, so it is the one process allowed to
        // keep a readable log there. Nothing else — tests included — writes
        // anywhere but stderr.
        Log.useFile(in: directory)
    }

    /// Mutate + persist + let AppState react.
    func update(_ mutate: (inout AppConfig) -> Void) {
        mutate(&config)
        scheduleSave()
        onChanged?()
    }

    var onChanged: (() -> Void)?

    func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            try? self.io.save(self.config)
        }
    }
}

/// How the process was started.
///
/// The one non-default way to run is the snapshot renderer: it draws every
/// surface to PNG and exits, against a *copy* of the state directory so the
/// running app's files are never touched, and without the trading loop so a
/// render can never place an order.
struct LaunchOptions: Sendable {
    var dataDirectory: URL = ConfigIO.defaultDirectory()
    var snapshotDirectory: URL? = nil
    var openIntelligence = false

    var isSnapshot: Bool { snapshotDirectory != nil }

    /// `MayStock [--data-dir <dir>] [--snapshot <out-dir>]`
    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--data-dir":
                if let value = iterator.next() { options.dataDirectory = URL(fileURLWithPath: value) }
            case "--snapshot":
                if let value = iterator.next() { options.snapshotDirectory = URL(fileURLWithPath: value) }
            case "--intelligence":
                options.openIntelligence = true
            default:
                break
            }
        }
        return options
    }
}

/// Composition root: config ⇄ market hub ⇄ alerts ⇄ strategies ⇄ status items ⇄ panel ⇄ terminal.
///
/// Trading state is kept per venue in `VenueBooks`: OKX and Schwab are two
/// accounts in two currencies, each with its own ledger, curve, heartbeat
/// and runner. What is shared is the config, the strategy library and the
/// trading mode — demo or live applies to every venue at once, and on
/// Schwab "demo" is the local shadow book.
@Observable
@MainActor
final class AppState {
    let options: LaunchOptions
    /// Where config, ledgers, equity curves and the heartbeat live.
    let dataDirectory: URL
    let store: ConfigStore
    let hub: MarketHub
    let alerts: AlertEngine
    let notifications: NotificationService
    let intelligence: IntelligenceCenter
    /// Chart mode / window selections for the hover panel.
    let charts = ChartPreferences()
    /// The terminal's markets page keeps its own, so flipping the big chart to
    /// depth does not also flip the panel the next time it opens.
    let terminalCharts = ChartPreferences()

    // MARK: Strategy layer

    let strategyStore: StrategyStore
    private(set) var strategies: [CompiledStrategy] = []
    /// Files that no longer compile — or no longer decode — with the reason.
    /// Surfaced rather than dropped, and their budgets left untouched.
    private(set) var brokenStrategies: [BrokenStrategy] = []
    private(set) var reports: [String: StrategyBacktestReport] = [:]
    private(set) var backtestPhase: [String: BacktestPhase] = [:]
    var cliInfo: CLIInfo?
    var isDetectingCLI = false
    /// `schwabctl`, and what it says about the login. Read at launch and on
    /// every account-page refresh; never holds a secret.
    var schwabCLI: CLIInfo?
    var schwabStatus: SchwabCredentialStatus?
    var isDetectingSchwabCLI = false

    // MARK: Environments

    /// The CLI's profiles, re-read whenever the account page asks.
    var profileCatalog: OKXProfileCatalog

    /// The one-off data sources, shared by the hub, the backtester and the
    /// Schwab venue so a token minted for one is a token minted for all.
    @ObservationIgnored let marketSources: MarketDataSources
    /// Thirty-minute Schwab tokens, from `schwabctl`.
    @ObservationIgnored let schwabTokens: SchwabCLITokenSource
    /// Schwab's demo account: there is none, so this is it.
    @ObservationIgnored let shadowBook: ShadowBook
    /// The strategy tags Schwab orders cannot carry, kept on our side.
    @ObservationIgnored let schwabTags: SchwabOrderTags

    @ObservationIgnored private var venueBooks: [Venue: VenueBooks] = [:]
    /// Every venue's account is re-read on a clock, not only on a button:
    /// positions opened by hand, stops firing and bills settling all happen
    /// on the exchange with no word to this app.
    static let accountRefreshInterval: TimeInterval = 300
    @ObservationIgnored private var accountRefreshLoop: Task<Void, Never>?
    @ObservationIgnored private var lastLoggedAccountError: [Venue: String] = [:]
    @ObservationIgnored private(set) var panel: HoverPanelController!
    @ObservationIgnored private var statusItems: StatusItemManager?
    @ObservationIgnored private var terminalController: TerminalWindowController?
    @ObservationIgnored private var backtestTasks: [String: Task<Void, Never>] = [:]
    /// Set by a deep link, read once by the checkup page. See
    /// `AppState.requestedCheckupInstId`.
    @ObservationIgnored var pendingCheckupInstId: String?

    init(options: LaunchOptions = LaunchOptions()) {
        self.options = options
        dataDirectory = options.dataDirectory
        store = ConfigStore(directory: options.dataDirectory)
        let trading = store.config.trading
        schwabTokens = SchwabCLITokenSource(bridge: SchwabBridge(prefs: trading))
        let yahoo = YahooFinanceClient()
        marketSources = MarketDataSources(
            yahoo: yahoo,
            schwab: SchwabMarketDataSource(schwab: SchwabRESTClient(tokens: schwabTokens), yahoo: yahoo),
            trading: trading)
        hub = MarketHub.standard(sources: marketSources)
        alerts = AlertEngine()
        notifications = NotificationService()
        intelligence = IntelligenceCenter(directory: options.dataDirectory, snapshotMode: options.isSnapshot)
        strategyStore = StrategyStore(directory: options.dataDirectory.appendingPathComponent("Strategies"))
        profileCatalog = OKXProfileCatalog.load()
        shadowBook = ShadowBook(
            venue: .schwab,
            fileURL: options.dataDirectory.appendingPathComponent("shadow-schwab.json"),
            startingCash: store.config.strategy.totalCapital(for: .schwab))
        schwabTags = SchwabOrderTags(fileURL: options.dataDirectory.appendingPathComponent("schwab-order-tags.json"))

        panel = HoverPanelController(appState: self)
        // A render pass must not put a second set of items in the menu bar.
        statusItems = options.isSnapshot ? nil : StatusItemManager(appState: self)
        for venue in Venue.allCases {
            venueBooks[venue] = VenueBooks(venue: venue, dataDirectory: options.dataDirectory, app: self)
        }

        wire()
        reloadStrategies()
        applyConfig()
        Task {
            await detectTradeCLI()
            await detectSchwabCLI()
            // Every venue's active account is checked at launch so the
            // overview can say whether each engine will be able to read its
            // book — and then read, so what it holds is on screen before
            // anyone asks.
            for venue in Venue.allCases { _ = await verifyConnection(tradingMode, venue: venue) }
            await refreshAccount()
        }
        if !options.isSnapshot {
            runners.forEach { $0.start() }
            startAccountRefreshLoop()
        }
        intelligence.start(watchlist: { [weak self] in
            self?.store.config.watchlist.map(\.instId) ?? []
        }, quote: { [weak self] instId in
            self?.hub.session(for: instId)?.ticker
        }, fetchQuote: { [weak self] instId in
            guard let self, let item = self.store.config.watchlist.first(where: { $0.instId == instId }),
                  let source = self.hub.source(for: item.venue) else { return nil }
            return try? await source.ticker(instId: instId)
        }, venues: { [weak self] in
            Dictionary((self?.store.config.watchlist ?? []).map { ($0.instId, $0.venue.rawValue) },
                       uniquingKeysWith: { first, _ in first })
        }, onFlash: { [weak self] body in
            self?.notifications.post(title: "MayStock · 局势快报", body: body, sound: false)
        })
    }

    private func wire() {
        // Config edits flow into the runtime.
        store.onChanged = { [weak self] in self?.applyConfig() }

        // Every tick feeds the alert engine.
        hub.onTick = { [weak self] session, ticker in
            guard let self else { return }
            self.alerts.evaluate(instId: ticker.instId, ticker: ticker, spark: session.spark)
        }

        // Fired alerts: notification + optional sound + optional shell hook.
        alerts.onAlert = { [weak self] event in
            guard let self else { return }
            self.notifications.post(title: event.title, body: event.body, sound: event.rule.playSound)
            if let hook = event.rule.shellHook, !hook.isEmpty {
                Self.runShellHook(hook, event: event)
            }
        }

        // Rule state (fired / auto-disabled) persists without re-entering the engine.
        alerts.onRulesChanged = { [weak self] rules in
            guard let self else { return }
            if self.store.config.alerts != rules {
                self.store.config.alerts = rules
                self.store.scheduleSave()
            }
        }
    }

    /// The venue an instrument belongs to: its live session's, else its
    /// watchlist entry's. Only a watch item can be asked about, and one that
    /// is not there is the OKX default the app grew up with.
    func venue(of instId: String) -> Venue {
        hub.session(for: instId)?.venue
            ?? store.config.watchlist.first { $0.instId == instId }?.venue
            ?? .okx
    }

    /// How a day's change is measured for an instrument, for alert summaries.
    func changeBasis(for instId: String) -> ChangeBasis {
        venue(of: instId).changeBasis
    }

    /// Push the current config into hub / status bar / alert engine.
    func applyConfig() {
        hub.setWatchlist(store.config.watchlist)
        statusItems?.sync(watchlist: store.config.watchlist)
        if alerts.rules != store.config.alerts {
            alerts.setRules(store.config.alerts)
        }
        LaunchAtLogin.set(enabled: store.config.general.launchAtLogin)
    }

    // MARK: Trading plumbing

    /// Built from the settings every time, so a profile edited on the account
    /// page is what the very next CLI call runs under.
    var tradeBridge: TradeBridge { TradeBridge(prefs: store.config.trading) }
    var schwabBridge: SchwabBridge { SchwabBridge(prefs: store.config.trading) }

    /// The exchange a venue's runner trades through, built from the current
    /// settings on every access. Everything downstream names `ExchangeVenue`;
    /// this switch is the one place a venue is bound to its adapter.
    func exchangeVenue(for venue: Venue) -> any ExchangeVenue {
        switch venue {
        case .okx:
            return OKXVenue(bridge: tradeBridge)
        case .schwab:
            return SchwabVenue(
                data: marketSources.schwab, bridge: schwabBridge, shadow: shadowBook, tags: schwabTags,
                economics: ShadowBook.Economics(schedule: store.config.strategy.feeSchedules.schwab))
        }
    }

    var tradingMode: TradingMode { store.config.strategy.mode }
    var liveTradingUnlocked: Bool { store.config.trading.liveTradingUnlocked }

    // MARK: Per-venue lookups

    func books(for venue: Venue) -> VenueBooks {
        // Built for every declared venue in `init`; a venue without books
        // would be an enum case the initialiser does not know, which the
        // loop over `allCases` rules out.
        venueBooks[venue]!
    }

    var runners: [StrategyRunner] { Venue.allCases.map { books(for: $0).runner } }
    func runner(for venue: Venue) -> StrategyRunner { books(for: venue).runner }
    func runner(forStrategy id: String) -> StrategyRunner? {
        venue(ofStrategy: id).map(runner(for:))
    }
    /// The runtime state of a strategy, from whichever engine trades it.
    func runtimeState(for strategyId: String) -> StrategyRuntimeState {
        runner(forStrategy: strategyId)?.state(for: strategyId) ?? StrategyRuntimeState()
    }

    func venue(ofStrategy id: String) -> Venue? {
        strategy(id: id)?.market.venue
            ?? store.config.strategy.allocation(for: id)?.venue
    }

    func ledger(for venue: Venue, mode: TradingMode) -> StrategyLedger { books(for: venue).ledger(for: mode) }
    func ledger(for venue: Venue) -> StrategyLedger { ledger(for: venue, mode: tradingMode) }
    func ledger(forStrategy id: String) -> StrategyLedger? { venue(ofStrategy: id).map(ledger(for:)) }
    /// Every venue's active-mode ledger, in declaration order.
    var ledgers: [StrategyLedger] { Venue.allCases.map(ledger(for:)) }

    func equityCurve(for venue: Venue) -> AccountEquityCurve { books(for: venue).equityCurve(for: tradingMode) }
    func strategyEquity(_ strategyId: String) -> AccountEquityCurve? {
        guard let venue = venue(ofStrategy: strategyId) else { return nil }
        return books(for: venue).strategyEquityCurves(for: tradingMode)[strategyId]
    }

    /// How many independent bets the allocated book actually holds.
    ///
    /// Computed from the live per-strategy equity curves, sampled onto a
    /// common grid — correlating series of different lengths would compare
    /// different periods and report whatever the misalignment happened to
    /// produce. Nil until at least two strategies have enough history.
    /// Returns are dimensionless, so curves in different currencies compare.
    var portfolioDiversification: KernelDiversification? {
        let curves = store.config.strategy.allocations
            .compactMap { allocation -> (name: String, points: [AccountEquityPoint])? in
                guard let curve = strategyEquity(allocation.strategyId),
                      curve.points.count >= 9 else { return nil }
                return (allocation.strategyId, curve.points)
            }
        guard curves.count >= 2 else { return nil }
        let length = curves.map(\.points.count).min() ?? 0
        guard length >= 9 else { return nil }

        let series = curves.map { entry -> (name: String, returns: [Double]) in
            // The most recent `length` points of each, so every series covers
            // the same window.
            let tail = entry.points.suffix(length)
            let returns = zip(tail, tail.dropFirst()).compactMap { previous, next -> Double? in
                guard previous.equity > 0 else { return nil }
                return next.equity / previous.equity - 1
            }
            return (entry.name, returns)
        }
        return try? TradingKernel.diversification(series)
    }

    // MARK: Account figures, per venue

    /// Live account equity on a venue, in its quote currency, sampled by
    /// that venue's runner.
    func accountEquity(for venue: Venue) -> Double? { runner(for: venue).accountEquity }

    /// Every account added up, in dollars, from the same readings the
    /// per-venue pages show. Accounts that could not be read are named in the
    /// result rather than dropped, so the total is never quietly a subtotal.
    var combinedPortfolio: CombinedPortfolio {
        CombinedPortfolio.combine(Venue.allCases.map { venue in
            let books = books(for: venue)
            return CombinedPortfolio.Reading(
                venue: venue, snapshot: books.accountSnapshot,
                error: books.accountError, readAt: books.accountRefreshedAt)
        })
    }

    /// Ledger profit across every account, in dollars.
    ///
    /// Per-venue P&L is booked in whatever the position settles in — USDT on
    /// OKX's USDT swaps — so it is converted at the rate the venue published
    /// in the same reading before being added to Schwab's dollars. Measured on
    /// both live accounts, USDT settled at 0.99962, so this is a real
    /// difference rather than a rounding.
    ///
    /// Nil only when no account has a book at all. A venue whose rate is
    /// unknown is left out rather than added at par, and `combinedPnLIsComplete`
    /// says so next to the number.
    var combinedOpenPnL: Double? { combinedInUsd { self.openPnLUsd(for: $0) } }

    /// Exchange-marked unrealised profit across every account, in dollars.
    var combinedExchangeUnrealisedPnL: Double? {
        combinedInUsd { self.exchangeUnrealisedPnLUsd(for: $0) }
    }

    /// False when any venue held a figure that could not be stated in dollars,
    /// so the totals above are a subtotal. Shown, not swallowed: a P&L missing
    /// one venue's positions looks exactly like a smaller P&L otherwise.
    var combinedPnLIsComplete: Bool {
        Venue.allCases.allSatisfy { venue in
            books(for: venue).exchangePositions.allSatisfy { $0.unrealisedPnLUsd != nil }
                && (openPnL(for: venue) == nil || openPnLUsd(for: venue) != nil)
        }
    }

    /// Add a per-venue figure that is already in dollars. Nil in, skipped; all
    /// nil, nil out — one venue having nothing to report must not blank the
    /// other's figure, but nor may it read as a zero contribution.
    private func combinedInUsd(_ figure: (Venue) -> Double?) -> Double? {
        let figures = Venue.allCases.compactMap(figure)
        return figures.isEmpty ? nil : figures.reduce(0, +)
    }

    /// Price risk across every account, in dollars, and as a share of the
    /// combined equity.
    ///
    /// `isComplete` is false as soon as any venue could not value everything
    /// it holds, any account is missing from the total, or any venue reports
    /// its exposure in something other than dollars — in each case the
    /// percentage is a floor, and the caller marks it as one. A venue that
    /// cannot state dollars is left out of the sum rather than added into it:
    /// the whole point of `exposureCurrency` is that this addition is only
    /// valid between figures that agree on the unit.
    var combinedExposure: (usd: Double, pct: Double?, isComplete: Bool) {
        let portfolio = combinedPortfolio
        var exposure = 0.0
        var complete = portfolio.isComplete
        for venue in Venue.allCases {
            let runner = runner(for: venue)
            guard runner.exposureCurrency == AccountSnapshot.usdCode else {
                complete = false
                continue
            }
            exposure += runner.nonStableExposure
            if !runner.exposureIsComplete { complete = false }
        }
        let pct = portfolio.totalUsd.flatMap { $0 > 0 ? exposure / $0 * 100 : nil }
        return (exposure, pct, complete)
    }

    /// Share of a venue's equity exposed to non-stablecoin price risk.
    func nonStableExposurePct(for venue: Venue) -> Double? { runner(for: venue).nonStableExposurePct }

    /// What the exchange's bills say a venue's account realised over a
    /// window. Nil until the ledger has been read, and on a venue that
    /// publishes no bill ledger — see `Venue.periodFigure`.
    func billedPnL(_ window: EquityWindow, venue: Venue) -> BilledPnL? {
        books(for: venue).exchangeBills.map { BilledPnL.over(window, listing: $0) }
    }

    /// Unrealised profit on every position a venue holds — whoever opened
    /// it — at the venue's own mark, in the venue's own settlement currency.
    /// Nil until the account has been read.
    ///
    /// This is the per-venue page's figure, shown beside that venue's other
    /// numbers and therefore correct in its own terms. Cross-venue callers
    /// want `exchangeUnrealisedPnLUsd`.
    func exchangeUnrealisedPnL(for venue: Venue) -> Double? {
        let books = books(for: venue)
        guard books.accountRefreshedAt != nil else { return nil }
        return books.exchangePositions.reduce(0) { $0 + $1.unrealisedPnL }
    }

    /// The same figure in dollars, or nil when some position could not be
    /// stated in dollars at all.
    ///
    /// All-or-nothing on purpose: a partial sum is a number that looks like an
    /// answer while being a floor, and the one thing worse than a missing P&L
    /// is a confidently wrong one.
    func exchangeUnrealisedPnLUsd(for venue: Venue) -> Double? {
        let books = books(for: venue)
        guard books.accountRefreshedAt != nil else { return nil }
        var total = 0.0
        for position in books.exchangePositions {
            guard let usd = position.unrealisedPnLUsd else { return nil }
            total += usd
        }
        return total
    }

    /// Live profit on everything a venue's book currently holds, plus
    /// whatever has already been realised, net of fees and funding — each
    /// position in its own settlement currency, summed as the per-venue page
    /// shows it.
    ///
    /// This needs no equity history at all — position, average price and mark
    /// are all available the moment a position exists.
    func openPnL(for venue: Venue) -> Double? {
        sumOpenPnL(for: venue) { figure, _ in figure }
    }

    /// The same profit in dollars, converting each position at the venue's own
    /// published rate for what that position settles in. Nil when any of them
    /// could not be converted.
    ///
    /// An OKX book can hold a USDT swap and a BTC-settled option at once, so
    /// the conversion is per position rather than per venue: one rate for the
    /// whole account would be right for the first and wrong for the second.
    func openPnLUsd(for venue: Venue) -> Double? {
        let snapshot = books(for: venue).accountSnapshot
        return sumOpenPnL(for: venue) { figure, instId in
            let currency = venue.settlementCurrency(of: instId)
            if currency == AccountSnapshot.usdCode { return figure }
            guard let rate = snapshot?.usdRate(for: currency) else { return nil }
            return figure * rate
        }
    }

    /// Walk a venue's non-flat ledger positions, mark each, and let `convert`
    /// decide what unit the result is in. Nil when the book is empty, or when
    /// `convert` refuses any position — the two totals above differ only in
    /// that closure, so they cannot drift apart in which positions they count.
    private func sumOpenPnL(
        for venue: Venue, convert: (Double, String) -> Double?
    ) -> Double? {
        let runner = runner(for: venue)
        let positions = ledger(for: venue).positions.values.filter { !$0.isFlat || $0.realisedPnL != 0 }
        guard !positions.isEmpty else { return nil }
        var total = 0.0
        for position in positions {
            let marked = position.netPnL(
                mark: runner.mark(for: position.instId) ?? mark(for: position.instId))
            guard let value = convert(marked, position.instId) else { return nil }
            total += value
        }
        return total
    }

    /// The same profit as a share of the capital actually committed to it.
    func openPnLPct(for venue: Venue) -> Double? {
        guard let pnl = openPnL(for: venue) else { return nil }
        let ledger = ledger(for: venue)
        let committed = store.config.strategy.allocations(on: venue)
            .filter { ledger.position(for: $0.strategyId)?.isFlat == false }
            .reduce(0) { $0 + $1.capital }
        guard committed > 0 else { return nil }
        return pnl / committed * 100
    }

    /// Trailing return for the panel, endpoint pinned to the live equity rather
    /// than the last stored sample.
    func equityChange(_ window: EquityWindow, venue: Venue) -> EquityChange? {
        equityCurve(for: venue).change(over: window, latest: accountEquity(for: venue))
    }

    // MARK: Readiness

    func detectTradeCLI() async {
        isDetectingCLI = true
        defer { isDetectingCLI = false }
        cliInfo = await tradeBridge.detectCLI()
    }

    func detectSchwabCLI() async {
        isDetectingSchwabCLI = true
        defer { isDetectingSchwabCLI = false }
        let bridge = schwabBridge
        schwabCLI = await bridge.detectCLI()
        schwabStatus = schwabCLI == nil ? nil : (try? await bridge.status())
    }

    /// True once a venue's tool exists *and* the active environment can be
    /// reached through it. On OKX that is the CLI plus a profile; on Schwab
    /// it is `schwabctl`, and for the live account a login that has not
    /// expired — the shadow book needs neither.
    func tradingReady(for venue: Venue) -> Bool { tradingBlocker(for: venue) == nil }

    /// Why trading on a venue is not ready, in words. Nil when it is.
    func tradingBlocker(for venue: Venue) -> String? {
        switch venue {
        case .okx:
            if cliInfo == nil { return "未检测到 okx CLI" }
            if !profileCatalog.fileExists { return "okx CLI 尚未配置 API Key（运行 okx config）" }
            if !credentialsConfigured(for: tradingMode) {
                return "\(tradingMode.displayName)没有可用的 profile（账户与连接页配置）"
            }
            return nil
        case .schwab:
            if schwabCLI == nil { return SchwabBridgeError.cliNotFound.description }
            guard tradingMode == .live else { return nil }
            guard let status = schwabStatus else { return "还没有读到 schwabctl 的状态，先在账户页重新检测" }
            return status.blocker
        }
    }

    /// Every venue that has a strategy, and is not ready. Nil when all are.
    var tradingBlockers: [(venue: Venue, reason: String)] {
        Venue.allCases.compactMap { venue in
            guard strategies.contains(where: { $0.market.venue == venue }),
                  let reason = tradingBlocker(for: venue) else { return nil }
            return (venue, reason)
        }
    }

    func refreshAccount() async {
        for venue in Venue.allCases { await refreshAccount(venue) }
    }

    func refreshAccount(_ venue: Venue) async {
        let books = books(for: venue)
        guard !books.isRefreshingAccount else { return }
        books.isRefreshingAccount = true
        defer { books.isRefreshingAccount = false }
        // A refresh asked for before launch-time detection has finished must
        // not report "no CLI" for a CLI that is there.
        switch venue {
        case .okx:
            if cliInfo == nil { await detectTradeCLI() }
            reloadProfilesIfChanged()
        case .schwab:
            // The login can change under a running app — `schwabctl login`
            // in a terminal — so the status is re-read on every refresh. It
            // is a local read, no network.
            if schwabCLI == nil { await detectSchwabCLI() } else { schwabStatus = try? await schwabBridge.status() }
        }
        guard tradingReady(for: venue) else {
            books.accountSnapshot = nil
            books.exchangePositions = []
            books.accountError = tradingBlocker(for: venue)
            return
        }
        let exchange = exchangeVenue(for: venue)
        let mode = tradingMode
        do {
            books.accountSnapshot = try await exchange.accountSnapshot(mode: mode)
            // Every position the venue holds, whatever family: the unfiltered
            // derivative listing, plus each family that is held as a
            // position rather than as a balance but is not a contract — a
            // share count. A failed listing is an error on screen, not an
            // empty list that reads as "nothing held".
            var positions = try await exchange.allPositions(mode: mode)
            for instType in venue.instrumentTypes where !instType.isDerivative && instType != .spot {
                positions += try await exchange.positions(mode: mode, instType: instType)
            }
            books.exchangePositions = positions
            books.accountError = nil
            books.accountRefreshedAt = Date()
        } catch {
            books.accountError = String(describing: error)
            return
        }
        // What the venue is holding open, and its own ledger where it keeps
        // one. Kept apart from `accountError`: a refused order book must not
        // blank the equity and positions that were read fine.
        do {
            switch venue {
            case .okx:
                let listing = try await tradeBridge.openOrders(mode: mode)
                books.openOrders = listing.orders
                books.openOrdersNote = listing.unavailable.isEmpty
                    ? nil : "未能读取：" + listing.unavailable.joined(separator: "、") + "。这些簿上若有挂单，这里不会显示。"
            case .schwab:
                books.openOrders = try await (exchange as? SchwabVenue)?.openOrders(mode: mode) ?? []
                books.openOrdersNote = nil
            }
            books.openOrdersError = nil
        } catch {
            books.openOrders = []
            books.openOrdersNote = nil
            books.openOrdersError = String(describing: error)
        }
        // What the venue has filled lately, whoever placed it. Its own block,
        // for the same reason the order book has one: a refused fill read must
        // not blank the equity and positions that were read fine — and, read
        // the other way, a blank fill list must not be allowed to read as
        // "nothing traded" when the book could not be reached at all.
        do {
            switch venue {
            case .okx:
                let listing = try await tradeBridge.fillListing(mode: mode)
                books.exchangeFills = listing.fills
                books.exchangeFillsNote = listing.unavailable.isEmpty
                    ? nil : "未能读取：" + listing.unavailable.joined(separator: "、") + "的成交。这些簿上的成交，这里不会显示。"
            case .schwab:
                let listing = try await (exchange as? SchwabVenue)?.fillListing(mode: mode)
                    ?? ExchangeFillListing()
                books.exchangeFills = listing.fills
                books.exchangeFillsNote = listing.unavailable.isEmpty
                    ? nil : "未能读取：" + listing.unavailable.joined(separator: "、") + "的成交。"
            }
            books.exchangeFillsError = nil
        } catch {
            books.exchangeFills = []
            books.exchangeFillsNote = nil
            books.exchangeFillsError = String(describing: error)
        }
        switch venue.periodFigure {
        case .exchangeBills:
            do {
                books.exchangeBills = try await tradeBridge.bills(mode: mode)
                books.billsError = nil
            } catch {
                books.exchangeBills = nil
                books.billsError = String(describing: error)
            }
        case .equityCurve:
            books.exchangeBills = nil
            books.billsError = nil
        }
        // Equity is the runner's figure — marked with the same prices the
        // engine trades on — so a refresh asks it to sample, rather than
        // computing a second, slightly different number here.
        await books.runner.sampleEquityNow()
    }

    /// Pull the OKX account's real fee rates into the schedule the backtester
    /// uses. Returns the failure, if any, in words. Only OKX has a CLI to
    /// ask; every other venue's schedule is a published table.
    func syncFeeRates() async -> String? {
        guard tradingReady(for: .okx) else { return tradingBlocker(for: .okx) }
        let bridge = tradeBridge
        let mode = tradingMode
        var schedule = store.config.strategy.feeSchedules.okx
        var failures: [String] = []
        let families = Venue.okx.instrumentTypes
        for instType in families {
            do {
                schedule.apply(try await bridge.feeRates(instType: instType, mode: mode))
            } catch {
                failures.append("\(instType.displayName)：\(error)")
            }
        }
        guard failures.count < families.count else {
            return failures.joined(separator: "\n")
        }
        store.update { $0.strategy.feeSchedules.okx = schedule }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// Start the shadow account over with the venue's configured capital.
    func resetShadowBook() async {
        let cash = store.config.strategy.totalCapital(for: .schwab)
        await shadowBook.reset(cash: cash)
        await refreshAccount(.schwab)
    }

    // MARK: Strategy library

    func reloadStrategies() {
        strategyStore.seedPresetsOnFirstRun()
        let loaded = strategyStore.loadCompiled()
        strategies = loaded.ready
        brokenStrategies = loaded.broken
        runners.forEach { $0.reloadKernel() }

        // Drop allocations whose strategy file is *gone*, so budget isn't held
        // hostage by something that can no longer trade. A file that is still
        // there but will not load keeps its budget: that is a file this build
        // cannot read, not a strategy the user removed, and taking its money
        // away would turn a version mismatch into a silent reallocation.
        let known = Set(strategies.map(\.id)).union(brokenStrategies.map(\.id))
        let stale = store.config.strategy.allocations.filter { !known.contains($0.strategyId) }
        if !stale.isEmpty {
            Log.warn("strategies: dropping budgets for missing files \(stale.map(\.strategyId))")
            store.update { config in
                config.strategy.allocations.removeAll { !known.contains($0.strategyId) }
            }
        }
        // A budget stamped with a venue the manifest no longer names would be
        // counted against the wrong pot. Re-stamped, and said.
        let moved = store.config.strategy.allocations.filter { allocation in
            guard let strategy = strategies.first(where: { $0.id == allocation.strategyId }) else { return false }
            return strategy.market.venue != allocation.venue
        }
        if !moved.isEmpty {
            Log.warn("strategies: re-stamping venue on budgets \(moved.map(\.strategyId))")
            store.update { config in
                for allocation in moved {
                    guard let strategy = strategies.first(where: { $0.id == allocation.strategyId }) else { continue }
                    config.strategy.setCapital(allocation.capital, for: allocation.strategyId, on: strategy.market.venue)
                }
            }
        }
    }

    func strategy(id: String) -> CompiledStrategy? {
        strategies.first { $0.id == id }
    }

    @discardableResult
    func importStrategy(from url: URL) throws -> StrategyManifest {
        let existing = strategies.map(\.manifest) + brokenStrategies.compactMap(\.manifest)
        let manifest = try strategyStore.importManifest(from: url, existing: existing)
        reloadStrategies()
        return manifest
    }

    /// Remove a strategy from the library, flattening what it holds first.
    ///
    /// Sequenced, not fired off: this used to start the flatten in a task and
    /// delete the strategy at once, so by the time the task ran the strategy
    /// was no longer runnable, `flatten` found nothing to do, and the ledger
    /// entry had already been cleared — leaving the exchange position with no
    /// record anywhere. A strategy whose position cannot be closed stays in
    /// the library, and the reason is shown.
    @discardableResult
    func deleteStrategy(id: String) async -> Bool {
        await runner(forStrategy: id)?.flatten(strategyId: id)
        if let ledger = ledger(forStrategy: id), let position = ledger.position(for: id), !position.isFlat {
            let name = strategy(id: id)?.name ?? id
            notifications.post(
                title: "未能移除 · \(name)",
                body: "仍持有 \(PriceFormatter.plain(abs(position.quantity))) 张 \(position.instId)，"
                    + "平仓未成交：" + (runtimeState(for: id).message ?? "见运行状态"),
                sound: true)
            return false
        }
        let ledger = ledger(forStrategy: id)
        try? strategyStore.delete(id: id)
        store.update { $0.strategy.remove(strategyId: id) }
        reports[id] = nil
        ledger?.clearPosition(strategyId: id)
        reloadStrategies()
        return true
    }

    func saveStrategy(_ manifest: StrategyManifest) {
        _ = try? strategyStore.save(manifest)
        reloadStrategies()
    }

    // MARK: Backtesting

    func isBacktesting(_ strategyId: String) -> Bool {
        backtestTasks[strategyId] != nil
    }

    func runBacktest(strategyId: String) {
        guard backtestTasks[strategyId] == nil, let strategy = strategy(id: strategyId) else { return }
        let capital = store.config.strategy.backtestCapital
        // The fee schedule the user configured, not the library default: a
        // setting the backtester never read was a promise the app did not keep.
        let feeSchedules = store.config.strategy.feeSchedules
        let sources = marketSources
        backtestPhase[strategyId] = .fetchingCandles(loaded: 0, target: 0)

        // Strong self is intentional: the task is finite, and AppState is the
        // app-lifetime composition root.
        backtestTasks[strategyId] = Task { @MainActor in
            defer {
                self.backtestTasks[strategyId] = nil
                self.backtestPhase[strategyId] = nil
            }
            do {
                let report = try await BacktestRunner(sources: sources, feeSchedules: feeSchedules).run(
                    strategy: strategy, capital: capital,
                    onPhase: { phase in
                        Task { @MainActor in self.backtestPhase[strategyId] = phase }
                    })
                self.reports[strategyId] = report
            } catch {
                self.notifications.post(
                    title: "回测失败 · \(strategy.name)",
                    body: String(describing: error), sound: false)
            }
        }
    }

    func runAllBacktests() {
        for strategy in strategies { runBacktest(strategyId: strategy.id) }
    }

    // MARK: Portfolio control

    /// Set a strategy's budget on the venue its manifest names.
    func setCapital(_ amount: Double, for strategyId: String) {
        guard let venue = venue(ofStrategy: strategyId) else { return }
        store.update { $0.strategy.setCapital(amount, for: strategyId, on: venue) }
    }

    func setTotalCapital(_ amount: Double, for venue: Venue) {
        // Not a plain assignment: the budgets are sized against this number and
        // must come down with it. See `StrategyPortfolio.setTotalCapital`.
        store.update { $0.strategy.setTotalCapital(amount, for: venue) }
    }

    /// Arm a strategy. The live-account confirmation lives in
    /// `requestStartStrategy`; this is the state change itself.
    func startStrategy(id: String) {
        guard let allocation = store.config.strategy.allocation(for: id), allocation.capital > 0 else { return }
        store.update {
            $0.strategy.emergencyStop = false
            $0.strategy.setRunning(true, for: id)
        }
        if let runner = runner(forStrategy: id) { Task { await runner.tick() } }
    }

    func stopStrategy(id: String) {
        store.update { $0.strategy.setRunning(false, for: id) }
    }

    /// Stop every strategy on every venue and flatten open positions.
    ///
    /// The notification reports what actually happened, after it happened. It
    /// used to announce "持仓已市价平掉" before a single order had been sent,
    /// which on the one occasion a flatten fails is the exact moment a person
    /// most needs to be told the opposite.
    func emergencyStop() {
        store.update { config in
            config.strategy.emergencyStop = true
            for index in config.strategy.allocations.indices {
                config.strategy.allocations[index].running = false
            }
        }
        Task {
            for runner in runners { await runner.emergencyStop() }
            let remaining = ledgers.flatMap(\.activePositions)
            if remaining.isEmpty {
                notifications.post(title: "已急停", body: "所有策略已停止，持仓已市价平掉。", sound: true)
            } else {
                let held = remaining.map {
                    "\($0.venue.displayName) \($0.instId) \(PriceFormatter.plain(abs($0.quantity)))"
                }.joined(separator: "，")
                notifications.post(
                    title: "已急停，但仍有持仓未平",
                    body: "所有策略已停止；未能平掉：\(held)。请到交易所核对。", sound: true)
            }
        }
    }

    func clearEmergencyStop() {
        store.update { $0.strategy.emergencyStop = false }
    }

    /// A venue's runner halted a strategy: disarm it, keep the reason, tell
    /// the user.
    func strategyDidHalt(strategyId: String, reason: String) {
        store.update { config in
            if let index = config.strategy.allocations.firstIndex(where: { $0.strategyId == strategyId }) {
                config.strategy.allocations[index].running = false
                config.strategy.allocations[index].haltReason = reason
            }
        }
        let name = strategy(id: strategyId)?.name ?? strategyId
        notifications.post(title: "策略已停止 · \(name)", body: reason, sound: true)
    }

    // MARK: Shell hooks

    private static func runShellHook(_ command: String, event: AlertEvent) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var env = ProcessInfo.processInfo.environment
        env["MAYSTOCK_INSTID"] = event.rule.instId
        env["MAYSTOCK_PRICE"] = PriceFormatter.plain(event.price)
        env["MAYSTOCK_RULE"] = event.summary
        process.environment = env
        try? process.run()
    }

    // MARK: Windows

    /// The one window. Every entry point — menu, panel, alert — lands on a page
    /// of it, optionally with a strategy selected.
    func openTerminal(_ page: TerminalPage = .overview, strategyId: String? = nil, instId: String? = nil) {
        if terminalController == nil {
            terminalController = TerminalWindowController(appState: self)
        }
        terminalController?.show(page: page, strategyId: strategyId, instId: instId)
        if page == .overview || page == .strategies || page == .account {
            refreshAccountIfStale(maxAge: 60)
        }
    }

    // MARK: Account freshness

    /// Re-read every venue whose reading is older than `maxAge`.
    ///
    /// Every surface that shows account figures asks here on appearing, so
    /// which door the user came through — the intelligence page at launch,
    /// the sidebar, the hover panel — never decides whether the figures are
    /// there.
    func refreshAccountIfStale(maxAge: TimeInterval) {
        for venue in Venue.allCases {
            let books = books(for: venue)
            if books.isRefreshingAccount { continue }
            if let at = books.accountRefreshedAt, Date().timeIntervalSince(at) < maxAge { continue }
            Task { await refreshAccount(venue) }
        }
    }

    func startAccountRefreshLoop() {
        accountRefreshLoop?.cancel()
        accountRefreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.accountRefreshInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.refreshAccount()
                // A refresh that keeps failing is on screen as a notice; the
                // log gets it once per distinct failure per venue, not once
                // per tick.
                for venue in Venue.allCases {
                    let error = self.books(for: venue).accountError
                    if let error, error != self.lastLoggedAccountError[venue] {
                        self.lastLoggedAccountError[venue] = error
                        Log.warn("account: \(venue.displayName)定时刷新失败：\(error)")
                    } else if error == nil {
                        self.lastLoggedAccountError[venue] = nil
                    }
                }
            }
        }
    }

    var terminalWindow: NSWindow? { terminalController?.window }

    func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MayStock",
            .applicationVersion: AppInfo.version,
            .credits: NSAttributedString(
                string: "菜单栏行情终端 · 低频量化工作台 · 行情 " + Venue.allCases.map { hub.sourceName(for: $0) }.joined(separator: " / "),
                attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
    }
}

enum AppInfo {
    static let version: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "2.2"
    }()
}

/// SMAppService needs a real bundle; guard so `swift run` (no bundle) works.
@MainActor
enum LaunchAtLogin {
    static func set(enabled: Bool) {
        #if canImport(ServiceManagement)
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try await SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                Log.warn("launch-at-login: \(error)")
            }
        }
        #endif
    }
}

#if canImport(ServiceManagement)
import ServiceManagement
#endif
