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

    init(directory: URL = ConfigIO.defaultDirectory()) {
        self.io = ConfigIO(directory: directory)
        self.config = io.load()
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

/// Composition root: config ⇄ market hub ⇄ alerts ⇄ strategies ⇄ status items ⇄ panel.
@Observable
@MainActor
final class AppState {
    let store: ConfigStore
    let hub: MarketHub
    let alerts: AlertEngine
    let notifications: NotificationService
    /// Chart mode / window selections, shared by every panel presentation.
    let charts = ChartPreferences()

    // MARK: Strategy layer

    let strategyStore: StrategyStore
    private(set) var strategies: [CompiledStrategy] = []
    /// Manifests that no longer compile, with the reason — surfaced rather than dropped.
    private(set) var brokenStrategies: [(manifest: StrategyManifest, reason: String)] = []
    private(set) var reports: [String: StrategyBacktestReport] = [:]
    private(set) var backtestPhase: [String: BacktestPhase] = [:]
    private(set) var accountBalances: [AccountBalance] = []
    private(set) var exchangePositions: [ExchangePosition] = []
    private(set) var accountError: String?
    private(set) var cliInfo: CLIInfo?

    let demoLedger = StrategyLedger(mode: .demo)
    let liveLedger = StrategyLedger(mode: .live)
    let heartbeatStore = HeartbeatStore(directory: ConfigIO.defaultDirectory())
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
    @ObservationIgnored private var statusItems: StatusItemManager!
    @ObservationIgnored private var settingsController: SettingsWindowController?
    @ObservationIgnored private var studioController: StrategyStudioWindowController?
    @ObservationIgnored private var backtestTasks: [String: Task<Void, Never>] = [:]

    init() {
        store = ConfigStore()
        hub = MarketHub()
        alerts = AlertEngine()
        notifications = NotificationService()
        strategyStore = StrategyStore(directory: StrategyStore.defaultDirectory())

        panel = HoverPanelController(appState: self)
        statusItems = StatusItemManager(appState: self)
        runner = StrategyRunner(host: self)

        wire()
        loadLedgers()
        reloadStrategies()
        applyConfig()
        Task { await detectTradeCLI() }
        runner.start()
    }

    private func wire() {
        // Config edits (from Settings) flow into the runtime.
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
        statusItems.sync(watchlist: store.config.watchlist)
        if alerts.rules != store.config.alerts {
            alerts.setRules(store.config.alerts)
        }
        LaunchAtLogin.set(enabled: store.config.general.launchAtLogin)
    }

    // MARK: Trading plumbing

    var tradeBridge: TradeBridge {
        TradeBridge(
            explicitCLIPath: store.config.trading.cliPath,
            profile: store.config.trading.profile)
    }

    /// The exchange the runner trades through.
    ///
    /// Built here rather than injected from outside only because OKX is the one
    /// venue this app ships with. Everything downstream names `ExchangeVenue`,
    /// so a second exchange is a new conformance plus a choice made at this
    /// single line.
    var venue: any ExchangeVenue { OKXVenue(bridge: tradeBridge) }

    var tradingMode: TradingMode { store.config.strategy.mode }
    var liveTradingUnlocked: Bool { store.config.trading.liveTradingUnlocked }
    var ledger: StrategyLedger { tradingMode == .demo ? demoLedger : liveLedger }
    var equityCurve: AccountEquityCurve { tradingMode == .demo ? demoEquity : liveEquity }
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
    /// are all available the moment a position exists. Making it wait for the
    /// trailing windows to fill was a design mistake: it left a profitable
    /// account reporting nothing.
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
        cliInfo = await tradeBridge.detectCLI()
    }

    /// True once the CLI exists *and* has a profile — without both, nothing
    /// authenticated works, not even demo.
    var tradingReady: Bool { cliInfo != nil && tradeBridge.hasCredentials() }

    func refreshAccount() async {
        guard tradingReady else {
            accountBalances = []
            exchangePositions = []
            accountError = cliInfo == nil ? "未检测到 okx CLI" : "okx CLI 尚未配置 API Key"
            return
        }
        let bridge = tradeBridge
        let mode = tradingMode
        do {
            accountBalances = try await bridge.balances(mode: mode)
            exchangePositions = (try? await bridge.positions(mode: mode, instType: .swap)) ?? []
            accountError = nil
        } catch {
            accountError = String(describing: error)
        }
    }

    // MARK: Strategy library

    func reloadStrategies() {
        strategyStore.installPresetsIfEmpty()
        let loaded = strategyStore.loadCompiled()
        strategies = loaded.ready
        brokenStrategies = loaded.broken.map { (manifest: $0.0, reason: $0.1) }

        // Drop allocations whose strategy file is gone, so budget isn't held
        // hostage by something that can no longer trade.
        let known = Set(strategies.map(\.id))
        let stale = store.config.strategy.allocations.filter { !known.contains($0.strategyId) }
        if !stale.isEmpty {
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
        let existing = strategies.map(\.manifest) + brokenStrategies.map(\.manifest)
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
        backtestPhase[strategyId] = .fetchingCandles(loaded: 0, target: 0)

        // Strong self is intentional: the task is finite, and AppState is the
        // app-lifetime composition root.
        backtestTasks[strategyId] = Task { @MainActor in
            defer {
                self.backtestTasks[strategyId] = nil
                self.backtestPhase[strategyId] = nil
            }
            do {
                let report = try await BacktestRunner().run(
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

    func setMode(_ mode: TradingMode) {
        guard mode == .demo || liveTradingUnlocked else { return }
        store.update { config in
            config.strategy.mode = mode
            // Switching accounts must never leave strategies armed against a
            // book they were not sized for.
            for index in config.strategy.allocations.indices {
                config.strategy.allocations[index].running = false
            }
        }
        Task { await refreshAccount() }
    }

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
        StrategyLedgerStore(directory: ConfigIO.defaultDirectory(), mode: mode)
    }

    private func loadLedgers() {
        for (mode, ledger) in [(TradingMode.demo, demoLedger), (.live, liveLedger)] {
            let payload = ledgerStore(mode).load()
            ledger.replace(fills: payload.fills, positions: payload.positions)
        }
        for (mode, curve) in [(TradingMode.demo, demoEquity), (.live, liveEquity)] {
            curve.replace(points: equityStore(mode).load())
        }
        for mode in [TradingMode.demo, TradingMode.live] {
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
        let ledger = mode == .demo ? demoLedger : liveLedger
        try? ledgerStore(mode).save(fills: ledger.fills, positions: ledger.positions)
    }

    private func equityStore(_ mode: TradingMode) -> AccountEquityStore {
        AccountEquityStore(directory: ConfigIO.defaultDirectory(), mode: mode)
    }

    private func saveEquity(_ mode: TradingMode) {
        let curve = mode == .demo ? demoEquity : liveEquity
        try? equityStore(mode).save(curve.points)
    }

    private func strategyEquityStore(_ mode: TradingMode) -> AccountEquityStore {
        AccountEquityStore(
            directory: ConfigIO.defaultDirectory(), mode: mode, perStrategy: true)
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

    func openSettings(tab: SettingsTab = .watchlist) {
        if settingsController == nil {
            settingsController = SettingsWindowController(appState: self)
        }
        settingsController?.show(tab: tab)
    }

    func openStrategyStudio(selecting strategyId: String? = nil) {
        if studioController == nil {
            studioController = StrategyStudioWindowController(appState: self)
        }
        studioController?.show(selecting: strategyId)
        Task { await refreshAccount() }
    }

    func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MayStock",
            .applicationVersion: "2.1",
            .credits: NSAttributedString(
                string: "优雅的菜单栏行情终端 · 低频量化工作台 · 数据源 OKX",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
    }
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
    }

    func runnerDidSampleStrategyEquity(_ strategyId: String, equity: Double, at ts: Date) {
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
        curve.record(equity: equity, at: ts)
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
