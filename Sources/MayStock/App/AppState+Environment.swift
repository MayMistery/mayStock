import AppKit
import MayStockKit

/// Which account the engine acts on, and whether it can reach it.
///
/// The two environments are separate accounts with separate keys, so the
/// switch is a real operation with real failure modes — not a toggle. The
/// flow is: prove the target's credentials work, say what the switch will do,
/// then do it, and stop the loop across the boundary so nothing decided under
/// one account executes on the other.
extension AppState {

    // MARK: Profiles

    func reloadProfiles() {
        profileCatalog = OKXProfileCatalog.load()
    }

    /// True when the CLI has a profile this mode can run under.
    func credentialsConfigured(for mode: TradingMode) -> Bool {
        guard profileCatalog.fileExists else { return false }
        if let name = store.config.trading.profile(for: mode) {
            return profileCatalog.profile(named: name) != nil
        }
        return !profileCatalog.profiles.isEmpty
    }

    /// The profile a mode resolves to in the catalogue, default included.
    func resolvedProfile(for mode: TradingMode) -> OKXProfile? {
        profileCatalog.resolved(store.config.trading.profile(for: mode))
    }

    /// A profile the CLI has flagged for the *other* environment. Caught here
    /// rather than by the exchange, which would only say the key did not match.
    func profileMismatch(for mode: TradingMode) -> String? {
        guard let profile = resolvedProfile(for: mode), let isDemo = profile.isDemo,
              isDemo != mode.isDemo else { return nil }
        return isDemo
            ? "profile「\(profile.name)」在 CLI 里标记为模拟盘密钥（demo = true），用它连实盘会被拒绝。"
            : "profile「\(profile.name)」在 CLI 里标记为实盘密钥（demo = false），用它连模拟盘会被拒绝。"
    }

    func setProfile(_ name: String?, for mode: TradingMode) {
        store.update { $0.trading.setProfile(name, for: mode) }
        // A changed profile is an unchecked one.
        connections[mode] = .unknown
    }

    func setCLIPath(_ path: String?) {
        let cleaned = path?.trimmingCharacters(in: .whitespaces)
        store.update { $0.trading.cliPath = (cleaned?.isEmpty ?? true) ? nil : cleaned }
        cliInfo = nil
        Task { await detectTradeCLI() }
    }

    // MARK: Connections

    func connectionStatus(for mode: TradingMode) -> VenueConnectionStatus {
        connections[mode] ?? .unknown
    }

    /// Prove the mode's credentials reach its environment. Read-only.
    @discardableResult
    func verifyConnection(_ mode: TradingMode) async -> VenueConnectionStatus {
        if cliInfo == nil { await detectTradeCLI() }
        guard cliInfo != nil else {
            let status = VenueConnectionStatus.failed(
                message: TradeError.cliNotFound.description, hint: nil, at: Date())
            connections[mode] = status
            return status
        }
        guard credentialsConfigured(for: mode) else {
            let status = VenueConnectionStatus.failed(
                message: profileCatalog.fileExists
                    ? "\(mode.displayName)配置的 profile 在 ~/.okx/config.toml 里不存在"
                    : TradeError.notConfigured.description,
                hint: "在下方为\(mode.displayName)选择一个 profile。", at: Date())
            connections[mode] = status
            return status
        }
        connections[mode] = .checking
        let bridge = tradeBridge
        let status: VenueConnectionStatus
        do {
            let report = try await bridge.verifyConnection(mode: mode)
            status = .connected(report)
            Log.warn("connection: \(mode.rawValue) verified via profile \(report.profile ?? "<default>")")
        } catch {
            let message = String(describing: error)
            let hint = (error as? TradeError)?.hint ?? profileMismatch(for: mode)
            status = .failed(message: message, hint: hint, at: Date())
            Log.warn("connection: \(mode.rawValue) failed — \(message)")
        }
        connections[mode] = status
        return status
    }

    func verifyAllConnections() async {
        for mode in TradingMode.allCases { await verifyConnection(mode) }
    }

    // MARK: Live unlock

    func setLiveTradingUnlocked(_ unlocked: Bool) {
        store.update { config in
            config.trading.liveTradingUnlocked = unlocked
            // Locking live must not leave strategies armed against a real
            // account, nor leave the app *on* that account.
            if !unlocked, config.strategy.mode == .live {
                config.strategy.mode = .demo
                for index in config.strategy.allocations.indices {
                    config.strategy.allocations[index].running = false
                }
            }
        }
        if !unlocked { runner.restart() }
        Log.warn("trading: live \(unlocked ? "unlocked" : "locked")")
    }

    // MARK: Switching

    enum ModeSwitchBlock: Equatable {
        case alreadyActive
        case liveLocked
        case connectionFailed(String)

        var message: String {
            switch self {
            case .alreadyActive: return "已经在这个环境上。"
            case .liveLocked: return "实盘尚未解锁。先在「账户与连接」页解锁实盘，再切换。"
            case .connectionFailed(let reason): return reason
            }
        }
    }

    /// The state change itself. Every strategy is disarmed and the trading loop
    /// restarted across the boundary; positions are left alone, because
    /// "stop trading" means stop deciding, not liquidate.
    @discardableResult
    func switchMode(to mode: TradingMode) -> ModeSwitchBlock? {
        if mode == tradingMode { return .alreadyActive }
        if mode == .live && !liveTradingUnlocked { return .liveLocked }
        // Cancel first, then change: see `StrategyRunner.restart`.
        runner.stop()
        let armed = store.config.strategy.allocations.filter(\.running).map(\.strategyId)
        store.update { config in
            config.strategy.mode = mode
            for index in config.strategy.allocations.indices {
                config.strategy.allocations[index].running = false
            }
        }
        runner.start()
        Log.warn("mode: switched to \(mode.rawValue); disarmed \(armed.isEmpty ? "nothing" : armed.joined(separator: ", "))")
        accountBalances = []
        exchangePositions = []
        accountError = nil
        Task {
            await refreshAccount()
            await verifyConnection(mode)
        }
        return nil
    }

    /// The user-facing flow: verify the target, describe the consequences,
    /// switch on confirmation. Safe to call from a menu item or a button.
    func requestModeSwitch(to mode: TradingMode) {
        Task { await performModeSwitch(to: mode) }
    }

    private func performModeSwitch(to mode: TradingMode) async {
        guard mode != tradingMode else { return }
        if mode == .live && !liveTradingUnlocked {
            let choice = await presentAlert(
                title: "实盘尚未解锁",
                message: "切到实盘之前要先在「账户与连接」页解锁实盘。解锁本身不会下单，只是允许切换。",
                style: .warning, buttons: ["前往账户与连接", "取消"])
            if choice == .alertFirstButtonReturn { openTerminal(.account) }
            return
        }

        let status = await verifyConnection(mode)
        if case .failed(let message, let hint, _) = status {
            let choice = await presentAlert(
                title: "无法连接\(mode.displayName)",
                message: [message, hint].compactMap { $0 }.joined(separator: "\n\n"),
                style: .critical, buttons: ["前往账户与连接", "取消"])
            if choice == .alertFirstButtonReturn { openTerminal(.account) }
            return
        }

        let running = store.config.strategy.allocations.filter(\.running).count
        let held = ledger(for: mode).activePositions.count
        var lines: [String] = []
        if running > 0 {
            lines.append("当前有 \(running) 个策略在运行，切换会先把它们全部停止（持仓保留，不会平仓）。")
        }
        if held > 0 {
            lines.append("\(mode.displayName)账户台账上有 \(held) 个持仓，切换后由这边的策略接管。")
        }
        if let report = status.report, let equity = report.totalEquity {
            lines.append("\(mode.displayName)账户权益 \(PriceFormatter.money(equity)) USDT"
                + (report.profile.map { "，profile「\($0)」" } ?? "，CLI 默认 profile") + "。")
        }
        lines.append(mode.isDemo
                     ? "模拟盘的订单不会动用真实资金。"
                     : "实盘下策略发出的每一笔订单都会真实成交。")
        let choice = await presentAlert(
            title: "切换到\(mode.displayName)？",
            message: lines.joined(separator: "\n"),
            style: mode.isDemo ? .informational : .critical,
            buttons: ["切换到\(mode.displayName)", "取消"])
        guard choice == .alertFirstButtonReturn else { return }
        if let block = switchMode(to: mode) {
            _ = await presentAlert(title: "没有切换", message: block.message, style: .warning, buttons: ["好"])
        }
    }

    // MARK: Arming a strategy

    /// Start a strategy, with a confirmation when the account is real. The
    /// README has always promised "per-strategy confirmation" for live; this
    /// is where the promise is kept.
    func requestStartStrategy(id: String) {
        guard let strategy = strategy(id: id),
              let allocation = store.config.strategy.allocation(for: id) else { return }
        guard allocation.capital > 0 else {
            Task { _ = await presentAlert(title: "还没有分配仓位", message: "先给「\(strategy.name)」分配预算，再开始交易。", style: .warning, buttons: ["好"]) }
            return
        }
        guard tradingReady else {
            let reason = tradingBlocker ?? "交易尚未就绪"
            Task {
                let choice = await presentAlert(title: "交易尚未就绪", message: reason, style: .warning, buttons: ["前往账户与连接", "取消"])
                if choice == .alertFirstButtonReturn { openTerminal(.account) }
            }
            return
        }
        guard tradingMode == .live else {
            startStrategy(id: id)
            return
        }
        Task {
            let choice = await presentAlert(
                title: "在实盘启动「\(strategy.name)」？",
                message: "将以 \(PriceFormatter.money(allocation.capital, decimals: 0)) "
                    + "\(store.config.strategy.quoteCurrency) 的预算在 \(strategy.market.instId) "
                    + "（\(strategy.market.instType.displayName) · \(strategy.market.bar.rawValue)）上按信号自动下单，"
                    + "每一笔都会真实成交。",
                style: .critical, buttons: ["在实盘启动", "取消"])
            if choice == .alertFirstButtonReturn { startStrategy(id: id) }
        }
    }

    /// Flatten a strategy's position at market, after asking.
    func requestFlatten(strategyId: String) {
        guard let strategy = strategy(id: strategyId),
              let position = ledger.position(for: strategyId), !position.isFlat else { return }
        Task {
            let choice = await presentAlert(
                title: "市价平掉「\(strategy.name)」的持仓？",
                message: "\(position.direction?.displayName ?? "") \(PriceFormatter.plain(abs(position.baseQuantity))) "
                    + "\(StrategyLedger.currencies(of: position.instId).base) @ \(PriceFormatter.auto(position.averagePrice))，"
                    + "在\(tradingMode.displayName)上以市价单平仓。",
                style: tradingMode.isDemo ? .warning : .critical, buttons: ["平仓", "取消"])
            if choice == .alertFirstButtonReturn {
                await runner.flatten(strategyId: strategyId)
            }
        }
    }

    func requestEmergencyStop() {
        Task {
            let choice = await presentAlert(
                title: "急停？",
                message: "停止全部策略，并把每个由策略建立的持仓以市价单平掉（\(tradingMode.displayName)）。",
                style: .critical, buttons: ["急停", "取消"])
            if choice == .alertFirstButtonReturn { emergencyStop() }
        }
    }

    // MARK: Alerts

    /// Show a modal alert and wait for the answer. Sheeted onto the terminal
    /// when it is showing, otherwise app-modal.
    func presentAlert(
        title: String, message: String, style: NSAlert.Style, buttons: [String]
    ) async -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        for button in buttons { alert.addButton(withTitle: button) }
        if buttons.count > 1, let cancel = alert.buttons.last {
            cancel.keyEquivalent = "\u{1b}"
        }
        if let window = terminalWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            return await alert.beginSheetModal(for: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
