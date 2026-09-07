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
            default:
                break
            }
        }
        return options
    }
}

/// Composition root: config ⇄ market hub ⇄ alerts ⇄ strategies ⇄ status items ⇄ panel ⇄ terminal.
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
    var accountBalances: [AccountBalance] = []
    var exchangePositions: [ExchangePosition] = []
    var accountError: String?
    var accountRefreshedAt: Date?
    var isRefreshingAccount = false
    var cliInfo: CLIInfo?
    var isDetectingCLI = false

    // MARK: Environments

    /// The CLI's profiles, re-read whenever the account page asks.
    var profileCatalog: OKXProfileCatalog
    /// One connection verdict per environment.
    var connections: [TradingMode: VenueConnectionStatus] = [:]

    let demoLedger = StrategyLedger(mode: .demo)
    let liveLedger = StrategyLedger(mode: .live)
    let heartbeatStore: HeartbeatStore
    /// When the engine last finished a full tick. Nil until the first one.
    private(set) var lastCompletedTickAt: Date?
    let demoEquity = AccountEquityCurve(mode: .demo)
    let liveEquity = AccountEquityCurve(mode: .live)
    /// One curve per strategy, so a single-strategy backtest has something
    /// like-for-like to be compared against. The account curve mixes every
    /// strategy together and cannot answer "did *this* one track its test".
    var demoStrategyEquity: [String: AccountEquityCurve] = [:]
    var liveStrategyEquity: [String: AccountEquityCurve] = [:]

    @ObservationIgnored private(set) var runner: StrategyRunner!
    @ObservationIgnored private(set) var panel: HoverPanelController!
    @ObservationIgnored private var statusItems: StatusItemManager?
    @ObservationIgnored private var terminalController: TerminalWindowController?
    @ObservationIgnored private var backtestTasks: [String: Task<Void, Never>] = [:]

    init(options: LaunchOptions = LaunchOptions()) {
        self.options = options
        dataDirectory = options.dataDirectory
        store = ConfigStore(directory: options.dataDirectory)
        hub = MarketHub()
        alerts = AlertEngine()
        notifications = NotificationService()
        strategyStore = StrategyStore(directory: options.dataDirectory.appendingPathComponent("Strategies"))
        heartbeatStore = HeartbeatStore(directory: options.dataDirectory)
        profileCatalog = OKXProfileCatalog.load()

        panel = HoverPanelController(appState: self)
        // A render pass must not put a second set of items in the menu bar.
        statusItems = options.isSnapshot ? nil : StatusItemManager(appState: self)
        runner = StrategyRunner(host: self)

        wire()
        loadLedgers()
        reloadStrategies()
        applyConfig()
        Task {
            await detectTradeCLI()
            // The active account is checked at launch so the overview can say
            // whether the engine will even be able to read the book.
            _ = await verifyConnection(tradingMode)
        }
        if !options.isSnapshot { runner.start() }
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

        demoLedger.onChanged = { [weak self] in self?.saveLedger(.demo) }
        liveLedger.onChanged = { [weak self] in self?.saveLedger(.live) }
        demoEquity.onChanged = { [weak self] in self?.saveEquity(.demo) }
        liveEquity.onChanged = { [weak self] in self?.saveEquity(.live) }
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

    /// The exchange the runner trades through.
    ///
    /// Built here rather than injected from outside only because OKX is the one
    /// venue this app ships with. Everything downstream names `ExchangeVenue`,
    /// so a second exchange is a new conformance plus a choice made at this
    /// single line.
    var venue: any ExchangeVenue { OKXVenue(bridge: tradeBridge) }

    var tradingMode: TradingMode { store.config.strategy.mode }
    var liveTradingUnlocked: Bool { store.config.trading.liveTradingUnlocked }
    var ledger: StrategyLedger { ledger(for: tradingMode) }
    func ledger(for mode: TradingMode) -> StrategyLedger { mode == .demo ? demoLedger : liveLedger }
    var equityCurve: AccountEquityCurve { equityCurve(for: tradingMode) }
    func equityCurve(for mode: TradingMode) -> AccountEquityCurve { mode == .demo ? demoEquity : liveEquity }
    var strategyEquityCurves: [String: AccountEquityCurve] {
        tradingMode == .demo ? demoStrategyEquity : liveStrategyEquity
    }
    func strategyEquity(_ strategyId: String) -> AccountEquityCurve? {
        strategyEquityCurves[strategyId]
    }

    /// How many independent bets the allocated book actually holds.
    ///
    /// Computed from the live per-strategy equity curves, sampled onto a
    /// common grid — correlating series of different lengths would compare
    /// different periods and report whatever the misalignment happened to
    /// produce. Nil until at least two strategies have enough history.
    var portfolioDiversification: KernelDiversification? {
        let curves = store.config.strategy.allocations
            .compactMap { allocation -> (name: String, points: [AccountEquityPoint])? in
                guard let curve = strategyEquityCurves[allocation.strategyId],
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

    /// Live account equity in USDT, sampled by the runner.
    var accountEquity: Double? { runner.accountEquity }

    /// Share of equity exposed to non-stablecoin price risk.
    var nonStableExposurePct: Double? { runner.nonStableExposurePct }

    /// Live profit on everything the book currently holds, plus whatever has
    /// already been realised, net of fees and funding.
    ///
    /// This needs no equity history at all — position, average price and mark
    /// are all available the moment a position exists.
    var openPnL: Double? {
        let positions = ledger.positions.values.filter { !$0.isFlat || $0.realisedPnL != 0 }
        guard !positions.isEmpty else { return nil }
        return positions.reduce(0) { $0 + $1.netPnL(mark: runner.mark(for: $1.instId)) }
    }

    /// The same profit as a share of the capital actually committed to it.
    var openPnLPct: Double? {
        guard let pnl = openPnL else { return nil }
        let committed = store.config.strategy.allocations
            .filter { ledger.position(for: $0.strategyId)?.isFlat == false }
            .reduce(0) { $0 + $1.capital }
        guard committed > 0 else { return nil }
        return pnl / committed * 100
    }

    /// Trailing return for the panel, endpoint pinned to the live equity rather
    /// than the last stored sample.
    func equityChange(_ window: EquityWindow) -> EquityChange? {
        equityCurve.change(over: window, latest: accountEquity)
    }

    func detectTradeCLI() async {
        isDetectingCLI = true
        defer { isDetectingCLI = false }
        cliInfo = await tradeBridge.detectCLI()
    }

    /// True once the CLI exists *and* the active environment has a profile to
    /// run under — without both, nothing authenticated works, not even demo.
    var tradingReady: Bool { cliInfo != nil && credentialsConfigured(for: tradingMode) }

    /// Why trading is not ready, in words. Nil when it is.
    var tradingBlocker: String? {
        if cliInfo == nil { return "未检测到 okx CLI" }
        if !profileCatalog.fileExists { return "okx CLI 尚未配置 API Key（运行 okx config）" }
        if !credentialsConfigured(for: tradingMode) {
            return "\(tradingMode.displayName)没有可用的 profile（账户与连接页配置）"
        }
        return nil
    }

    func refreshAccount() async {
        guard !isRefreshingAccount else { return }
        isRefreshingAccount = true
        defer { isRefreshingAccount = false }
        // A refresh asked for before launch-time detection has finished must
        // not report "no CLI" for a CLI that is there.
        if cliInfo == nil { await detectTradeCLI() }
        if !profileCatalog.fileExists { reloadProfiles() }
        guard tradingReady else {
            accountBalances = []
            exchangePositions = []
            accountError = tradingBlocker
            return
        }
        let bridge = tradeBridge
        let mode = tradingMode
        do {
            accountBalances = try await bridge.balances(mode: mode)
            exchangePositions = (try? await bridge.positions(mode: mode, instType: .swap)) ?? []
            accountError = nil
            accountRefreshedAt = Date()
        } catch {
            accountError = String(describing: error)
            return
        }
        // Equity is the runner's figure — marked with the same prices the
        // engine trades on — so a refresh asks it to sample, rather than
        // computing a second, slightly different number here.
        await runner.sampleEquityNow()
    }

    /// Pull this account's real fee rates into the schedule the backtester uses.
    /// Returns the failure, if any, in words.
    func syncFeeRates() async -> String? {
        guard tradingReady else { return tradingBlocker }
        let bridge = tradeBridge
        let mode = tradingMode
        var schedule = store.config.strategy.feeSchedule
        var failures: [String] = []
        for instType in InstrumentType.allCases {
            do {
                schedule.apply(try await bridge.feeRates(instType: instType, mode: mode))
            } catch {
                failures.append("\(instType.displayName)：\(error)")
            }
        }
        guard failures.count < InstrumentType.allCases.count else {
            return failures.joined(separator: "\n")
        }
        store.update { $0.strategy.feeSchedule = schedule }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    // MARK: Strategy library

    func reloadStrategies() {
        strategyStore.installPresetsIfEmpty()
        let loaded = strategyStore.loadCompiled()
        strategies = loaded.ready
        brokenStrategies = loaded.broken
        runner.reloadKernel()

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

    func deleteStrategy(id: String) {
        Task { await runner.flatten(strategyId: id) }
        try? strategyStore.delete(id: id)
        store.update { $0.strategy.remove(strategyId: id) }
        reports[id] = nil
        ledger.clearPosition(strategyId: id)
        reloadStrategies()
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
        let feeSchedule = store.config.strategy.feeSchedule
        backtestPhase[strategyId] = .fetchingCandles(loaded: 0, target: 0)

        // Strong self is intentional: the task is finite, and AppState is the
        // app-lifetime composition root.
        backtestTasks[strategyId] = Task { @MainActor in
            defer {
                self.backtestTasks[strategyId] = nil
                self.backtestPhase[strategyId] = nil
            }
            do {
                let report = try await BacktestRunner(feeSchedule: feeSchedule).run(
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

    func setCapital(_ amount: Double, for strategyId: String) {
        store.update { $0.strategy.setCapital(amount, for: strategyId) }
    }

    func setTotalCapital(_ amount: Double) {
        // Not a plain assignment: the budgets are sized against this number and
        // must come down with it. See `StrategyPortfolio.setTotalCapital`.
        store.update { $0.strategy.setTotalCapital(amount) }
    }

    /// Arm a strategy. The live-account confirmation lives in
    /// `requestStartStrategy`; this is the state change itself.
    func startStrategy(id: String) {
        guard let allocation = store.config.strategy.allocation(for: id), allocation.capital > 0 else { return }
        store.update {
            $0.strategy.emergencyStop = false
            $0.strategy.setRunning(true, for: id)
        }
        Task { await runner.tick() }
    }

    func stopStrategy(id: String) {
        store.update { $0.strategy.setRunning(false, for: id) }
    }

    /// Stop every strategy and flatten open positions.
    func emergencyStop() {
        store.update { config in
            config.strategy.emergencyStop = true
            for index in config.strategy.allocations.indices {
                config.strategy.allocations[index].running = false
            }
        }
        Task { await runner.emergencyStop() }
        notifications.post(title: "已急停", body: "所有策略已停止，持仓已市价平掉。", sound: true)
    }

    func clearEmergencyStop() {
        store.update { $0.strategy.emergencyStop = false }
    }

    // MARK: Ledger persistence

    private func ledgerStore(_ mode: TradingMode) -> StrategyLedgerStore {
        StrategyLedgerStore(directory: dataDirectory, mode: mode)
    }

    private func loadLedgers() {
        for (mode, ledger) in [(TradingMode.demo, demoLedger), (.live, liveLedger)] {
            let payload = ledgerStore(mode).load()
            ledger.replace(
                fills: payload.fills, positions: payload.positions,
                fundingIds: payload.fundingIds)
        }
        for (mode, curve) in [(TradingMode.demo, demoEquity), (.live, liveEquity)] {
            curve.replace(points: equityStore(mode).load())
        }
        for mode in TradingMode.allCases {
            var curves: [String: AccountEquityCurve] = [:]
            for (strategyId, points) in strategyEquityStore(mode).loadByStrategy() {
                let curve = AccountEquityCurve(mode: mode)
                curve.replace(points: points)
                curve.onChanged = { [weak self] in self?.saveStrategyEquity(mode) }
                curves[strategyId] = curve
            }
            if mode == .demo { demoStrategyEquity = curves } else { liveStrategyEquity = curves }
        }
    }

    private func saveLedger(_ mode: TradingMode) {
        let ledger = ledger(for: mode)
        try? ledgerStore(mode).save(
            fills: ledger.fills, positions: ledger.positions,
            fundingIds: ledger.recordedFundingIds)
    }

    private func equityStore(_ mode: TradingMode) -> AccountEquityStore {
        AccountEquityStore(directory: dataDirectory, mode: mode)
    }

    private func saveEquity(_ mode: TradingMode) {
        try? equityStore(mode).save(equityCurve(for: mode).points)
    }

    private func strategyEquityStore(_ mode: TradingMode) -> AccountEquityStore {
        AccountEquityStore(directory: dataDirectory, mode: mode, perStrategy: true)
    }

    private func saveStrategyEquity(_ mode: TradingMode) {
        let curves = mode == .demo ? demoStrategyEquity : liveStrategyEquity
        try? strategyEquityStore(mode).save(byStrategy: curves.mapValues(\.points))
    }

    // MARK: Shell hooks

    private static func runShellHook(_ command: String, event: AlertEvent) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var env = ProcessInfo.processInfo.environment
        env["MAYSTOCK_INSTID"] = event.rule.instId
        env["MAYSTOCK_PRICE"] = PriceFormatter.plain(event.price)
        env["MAYSTOCK_RULE"] = event.rule.condition.summary
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
            Task { await refreshAccount() }
        }
    }

    var terminalWindow: NSWindow? { terminalController?.window }

    func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MayStock",
            .applicationVersion: AppInfo.version,
            .credits: NSAttributedString(
                string: "菜单栏行情终端 · 低频量化工作台 · 数据源 OKX",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
    }
}

enum AppInfo {
    static let version: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "2.2"
    }()
}

// MARK: - Strategy runner host

extension AppState: StrategyRunnerHost {
    var portfolio: StrategyPortfolioPrefs { store.config.strategy }
    var runnableStrategies: [CompiledStrategy] { strategies }

    func runnerDidChange() {
        // The runner mutates observable state directly; this hook exists for
        // side effects that must not run inside the tick loop.
        saveLedger(tradingMode)
    }

    func runnerDidCompleteTick(at ts: Date) {
        lastCompletedTickAt = ts
        // Written to disk, not just held in memory: the question this answers
        // is "was this app trading while I was not watching", and an in-memory
        // value cannot answer it after a crash or a restart.
        heartbeatStore.record(ts)
    }

    /// How long the trading loop has been silent, or nil when it has never run.
    ///
    /// Read from disk at launch, so a restart reports the gap it was away for
    /// rather than starting the clock fresh — the gap is the whole point.
    var heartbeatSilence: TimeInterval? {
        guard let last = lastCompletedTickAt ?? heartbeatStore.load() else { return nil }
        return Date().timeIntervalSince(last)
    }

    /// Set when the engine should be trading and demonstrably is not.
    ///
    /// A process that is alive but has stopped doing its job is the failure
    /// mode that goes unnoticed: nothing errors, the panel keeps showing the
    /// last numbers it had, and the account simply stops being managed.
    var heartbeatWarning: String? {
        guard store.config.strategy.allocations.contains(where: \.running),
              !store.config.strategy.emergencyStop,
              let silence = heartbeatSilence,
              silence > StrategyRunner.heartbeatTimeout else { return nil }
        let minutes = Int(silence / 60)
        return "交易循环已 \(minutes) 分钟没有完成一次轮询，仓位当前无人管理"
    }

    func runnerDidSampleEquity(_ equity: Double, at ts: Date) {
        // The curve is per mode; the runner only ever samples the active one.
        equityCurve.record(equity: equity, at: ts)
        accountBalances = runner.accountBalances
        accountRefreshedAt = ts
    }

    func runnerDidSampleStrategyEquity(
        _ strategyId: String, equity: Double, basis: Double, at ts: Date
    ) {
        let mode = tradingMode
        let curve: AccountEquityCurve
        if let existing = strategyEquityCurves[strategyId] {
            curve = existing
        } else {
            curve = AccountEquityCurve(mode: mode)
            curve.onChanged = { [weak self] in self?.saveStrategyEquity(mode) }
            if mode == .demo { demoStrategyEquity[strategyId] = curve }
            else { liveStrategyEquity[strategyId] = curve }
        }
        curve.record(equity: equity, at: ts, basis: basis)
    }

    func runnerDidHalt(strategyId: String, reason: String) {
        store.update { config in
            if let index = config.strategy.allocations.firstIndex(where: { $0.strategyId == strategyId }) {
                config.strategy.allocations[index].running = false
                config.strategy.allocations[index].haltReason = reason
            }
        }
        let name = strategy(id: strategyId)?.name ?? strategyId
        notifications.post(title: "策略已停止 · \(name)", body: reason, sound: true)
    }
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
