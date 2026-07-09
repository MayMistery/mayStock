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

/// Composition root: config ⇄ market hub ⇄ alerts ⇄ status items ⇄ panel.
@Observable
@MainActor
final class AppState {
    let store: ConfigStore
    let hub: MarketHub
    let alerts: AlertEngine
    let notifications: NotificationService

    private(set) var cliInfo: CLIInfo?

    @ObservationIgnored private(set) var panel: HoverPanelController!
    @ObservationIgnored private var statusItems: StatusItemManager!
    @ObservationIgnored private var settingsController: SettingsWindowController?

    init() {
        store = ConfigStore()
        hub = MarketHub()
        alerts = AlertEngine()
        notifications = NotificationService()

        panel = HoverPanelController(appState: self)
        statusItems = StatusItemManager(appState: self)

        wire()
        applyConfig()
        Task { await detectTradeCLI() }
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

    // MARK: Trading

    var tradeBridge: TradeBridge {
        TradeBridge(
            explicitCLIPath: store.config.trading.cliPath,
            profile: store.config.trading.profile)
    }

    func detectTradeCLI() async {
        cliInfo = await tradeBridge.detectCLI()
    }

    func placeOrder(_ order: SpotOrderRequest) async throws -> OrderResult {
        let live = store.config.trading.liveTradingUnlocked
        return try await tradeBridge.placeSpotOrder(order, demo: !live, liveUnlocked: live)
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

    func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MayStock",
            .applicationVersion: "2.0",
            .credits: NSAttributedString(
                string: "优雅的菜单栏行情终端 · 数据源 OKX",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
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
