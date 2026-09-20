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

    /// Re-read the CLI's config file if it has changed since it was last read.
    ///
    /// Called wherever the catalogue is about to be shown or acted on, so a
    /// profile added or renamed while the app is open is on screen the next
    /// time the account page opens — not after a restart.
    func reloadProfilesIfChanged() {
        guard profileCatalog.isStale() else { return }
        reloadProfiles()
        Log.warn("profiles: ~/.okx/config.toml 有变化，已重新读取（\(profileCatalog.profiles.count) 个 profile"
                 + (profileCatalog.defaultProfile.map { "，默认 \($0)" } ?? "") + "）")
        for mode in TradingMode.allCases { books(for: .okx).connections[mode] = .unknown }
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
        books(for: .okx).connections[mode] = .unknown
    }

    func setCLIPath(_ path: String?) {
        let cleaned = path?.trimmingCharacters(in: .whitespaces)
        store.update { $0.trading.cliPath = (cleaned?.isEmpty ?? true) ? nil : cleaned }
        cliInfo = nil
        Task { await detectTradeCLI() }
    }

    func setSchwabCLIPath(_ path: String?) {
        let cleaned = path?.trimmingCharacters(in: .whitespaces)
        store.update { $0.trading.schwabCLIPath = (cleaned?.isEmpty ?? true) ? nil : cleaned }
        schwabCLI = nil
        schwabStatus = nil
        let bridge = schwabBridge
        Task {
            await schwabTokens.update(bridge: bridge)
            await detectSchwabCLI()
        }
    }

    // MARK: Connections

    func connectionStatus(for mode: TradingMode, venue: Venue = .okx) -> VenueConnectionStatus {
        books(for: venue).connections[mode] ?? .unknown
    }

    /// Prove the mode's credentials reach its environment on a venue.
    /// Read-only: a balance read on OKX, a status read plus — for the live
    /// account — an account read through `schwabctl`.
    @discardableResult
    func verifyConnection(_ mode: TradingMode, venue: Venue = .okx) async -> VenueConnectionStatus {
        let books = books(for: venue)
        switch venue {
        case .okx:
            if cliInfo == nil { await detectTradeCLI() }
            guard cliInfo != nil else {
                let status = VenueConnectionStatus.failed(
                    message: TradeError.cliNotFound.description, hint: nil, at: Date())
                books.connections[mode] = status
                return status
            }
            guard credentialsConfigured(for: mode) else {
                let status = VenueConnectionStatus.failed(
                    message: profileCatalog.fileExists
                        ? "\(mode.displayName)配置的 profile 在 ~/.okx/config.toml 里不存在"
                        : TradeError.notConfigured.description,
                    hint: "在下方为\(mode.displayName)选择一个 profile。", at: Date())
                books.connections[mode] = status
                return status
            }
            books.connections[mode] = .checking
            let bridge = tradeBridge
            let status: VenueConnectionStatus
            do {
                let report = try await bridge.verifyConnection(mode: mode)
                status = .connected(report)
                Log.warn("connection: okx \(mode.rawValue) verified via profile \(report.profile ?? "<default>")")
            } catch {
                let message = String(describing: error)
                let hint = (error as? TradeError)?.hint ?? profileMismatch(for: mode)
                status = .failed(message: message, hint: hint, at: Date())
                Log.warn("connection: okx \(mode.rawValue) failed — \(message)")
            }
            books.connections[mode] = status
            return status
        case .schwab:
            if schwabCLI == nil { await detectSchwabCLI() }
            guard schwabCLI != nil else {
                let status = VenueConnectionStatus.failed(
                    message: SchwabBridgeError.cliNotFound.description,
                    hint: "./Scripts/make.sh install 会把 schwabctl 装进 MayStock.app", at: Date())
                books.connections[mode] = status
                return status
            }
            books.connections[mode] = .checking
            let bridge = schwabBridge
            let status: VenueConnectionStatus
            do {
                let credential = try await bridge.status()
                schwabStatus = credential
                switch mode {
                case .live:
                    guard credential.loggedIn else {
                        throw SchwabAPIError.loggedOut(credential.blocker ?? "未登录")
                    }
                    let account = try await bridge.account()
                    status = .connected(VenueConnectionReport(
                        mode: mode, profile: credential.accountSuffix.map { "账户 …\($0)" },
                        checkedAt: Date(), totalEquity: account.equity,
                        balanceCount: account.positions.count, account: nil))
                    Log.warn("connection: schwab live verified, \(account.positions.count) positions")
                case .demo:
                    // The shadow book is always reachable; what is worth
                    // knowing is whether its prices are Schwab's own.
                    let snapshot = await shadowBook.snapshot()
                    status = .connected(VenueConnectionReport(
                        mode: mode, profile: credential.loggedIn ? "影子账户 · 嘉信行情" : "影子账户 · Yahoo 行情",
                        checkedAt: Date(), totalEquity: snapshot.totalEquity,
                        balanceCount: snapshot.balances.count, account: nil))
                }
            } catch {
                let message = String(describing: error)
                status = .failed(message: message, hint: "在终端运行 schwabctl login（每 7 天一次）", at: Date())
                Log.warn("connection: schwab \(mode.rawValue) failed — \(message)")
            }
            books.connections[mode] = status
            return status
        }
    }

    func verifyAllConnections() async {
        for venue in Venue.allCases {
            for mode in TradingMode.allCases { await verifyConnection(mode, venue: venue) }
        }
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
        if !unlocked { runners.forEach { $0.restart() } }
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
        runners.forEach { $0.stop() }
        let armed = store.config.strategy.allocations.filter(\.running).map(\.strategyId)
        store.update { config in
            config.strategy.mode = mode
            for index in config.strategy.allocations.indices {
                config.strategy.allocations[index].running = false
            }
        }
        runners.forEach { $0.start() }
        Log.warn("mode: switched to \(mode.rawValue); disarmed \(armed.isEmpty ? "nothing" : armed.joined(separator: ", "))")
        for venue in Venue.allCases {
            let books = books(for: venue)
            books.accountBalances = []
            books.exchangePositions = []
            books.openOrders = []
            books.openOrdersNote = nil
            books.openOrdersError = nil
            books.exchangeBills = nil
            books.billsError = nil
            books.accountError = nil
        }
        Task {
            await refreshAccount()
            for venue in Venue.allCases { await verifyConnection(mode, venue: venue) }
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

        // Every venue that has a strategy must reach the target account;
        // one that cannot would leave its strategies deciding against a
        // book the engine cannot see.
        let venues = Venue.allCases.filter { venue in strategies.contains { $0.market.venue == venue } }
        var reports: [(venue: Venue, report: VenueConnectionReport)] = []
        for venue in venues.isEmpty ? [.okx] : venues {
            let status = await verifyConnection(mode, venue: venue)
            if case .failed(let message, let hint, _) = status {
                let choice = await presentAlert(
                    title: "无法连接\(venue.displayName)\(mode.displayName)",
                    message: [message, hint].compactMap { $0 }.joined(separator: "\n\n"),
                    style: .critical, buttons: ["前往账户与连接", "取消"])
                if choice == .alertFirstButtonReturn { openTerminal(.account) }
                return
            }
            if let report = status.report { reports.append((venue, report)) }
        }

        let running = store.config.strategy.allocations.filter(\.running).count
        let held = Venue.allCases.reduce(0) { $0 + ledger(for: $1, mode: mode).activePositions.count }
        var lines: [String] = []
        if running > 0 {
            lines.append("当前有 \(running) 个策略在运行，切换会先把它们全部停止（持仓保留，不会平仓）。")
        }
        if held > 0 {
            lines.append("\(mode.displayName)账户台账上有 \(held) 个持仓，切换后由这边的策略接管。")
        }
        for (venue, report) in reports {
            guard let equity = report.totalEquity else { continue }
            lines.append("\(venue.displayName)\(mode.displayName)账户权益 \(PriceFormatter.money(equity)) \(venue.quoteCurrency)"
                + (report.profile.map { "，\($0)" } ?? "") + "。")
        }
        if mode == .demo, venues.contains(.schwab) {
            lines.append("嘉信没有模拟盘：模拟盘下的美股订单由 MayStock 本地影子账户按实时行情撮合。")
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
        let venue = strategy.market.venue
        guard tradingReady(for: venue) else {
            let reason = tradingBlocker(for: venue) ?? "交易尚未就绪"
            Task {
                let choice = await presentAlert(title: "\(venue.displayName)交易尚未就绪", message: reason, style: .warning, buttons: ["前往账户与连接", "取消"])
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
                title: "在\(venue.displayName)实盘启动「\(strategy.name)」？",
                message: "将以 \(PriceFormatter.money(allocation.capital, decimals: 0)) "
                    + "\(venue.quoteCurrency) 的预算在 \(strategy.market.instId) "
                    + "（\(strategy.market.instType.displayName) · \(strategy.market.bar.rawValue)）上按信号自动下单，"
                    + "每一笔都会真实成交。",
                style: .critical, buttons: ["在实盘启动", "取消"])
            if choice == .alertFirstButtonReturn { startStrategy(id: id) }
        }
    }

    /// Flatten a strategy's position at market, after asking.
    func requestFlatten(strategyId: String) {
        guard let strategy = strategy(id: strategyId),
              let runner = runner(forStrategy: strategyId),
              let position = ledger(forStrategy: strategyId)?.position(for: strategyId), !position.isFlat else { return }
        Task {
            let choice = await presentAlert(
                title: "市价平掉「\(strategy.name)」的持仓？",
                message: "\(position.direction?.displayName ?? "") \(PriceFormatter.plain(abs(position.baseQuantity))) "
                    + "\(position.venue.currencies(of: position.instId).base) @ \(PriceFormatter.auto(position.averagePrice))，"
                    + "在\(tradingMode.displayName)上以市价单平仓。",
                style: tradingMode.isDemo ? .warning : .critical, buttons: ["平仓", "取消"])
            if choice == .alertFirstButtonReturn {
                await runner.flatten(strategyId: strategyId)
            }
        }
    }

    /// Start the Schwab shadow account over, after asking.
    func requestResetShadowBook() {
        let cash = store.config.strategy.totalCapital(for: .schwab)
        Task {
            let choice = await presentAlert(
                title: "重置嘉信影子账户？",
                message: "清空影子账户的持仓与挂单，现金重置为嘉信本金 \(PriceFormatter.money(cash, decimals: 0)) USD。"
                    + "策略台账上的成交记录保留；正在运行的美股策略会按新账户重新决策。",
                style: .warning, buttons: ["重置", "取消"])
            if choice == .alertFirstButtonReturn { await resetShadowBook() }
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
        // Put the hover panel away first. It is a non-activating panel whose
        // SwiftUI content tracks mouse-moved events, and a modal run loop plus
        // that tracking crashes the process on the macOS 27 SDK: the hover
        // dispatch reaches `MainActor.assumeIsolated` off the main executor and
        // segfaults (`NSHostingView.mouseMoved` → `HoverResponder
        // .containsGlobalPoints` → `swift_task_isMainExecutorImpl`). It took
        // two confirmation dialogs with real money on them to find that, and
        // the panel has nothing to say while a modal is up anyway.
        panel?.hide()

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
