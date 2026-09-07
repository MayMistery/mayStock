import AppKit
import SwiftUI
import Observation
import MayStockKit

/// Owns one NSStatusItem for one watchlist instrument.
///
/// Rendering is driven by Observation (`withObservationTracking`) with a
/// 100ms coalescing throttle — ticks can arrive far faster than the menu bar
/// deserves to be redrawn.
@MainActor
final class StatusItemController: NSObject {
    let itemID: UUID
    private(set) var watchItem: WatchItem
    private let session: InstrumentSession
    private let statusItem: NSStatusItem
    private unowned let appState: AppState

    private var renderScheduled = false
    private var lastRenderAt = Date.distantPast
    private var hoverWorkItem: DispatchWorkItem?

    /// The drawn sparkline, and the sample it was drawn from.
    ///
    /// The buffer takes at most one sample per second, so redrawing faster than
    /// that cannot show anything new — and the redraw is far from free: a
    /// 60-minute window is 3 600 points to slice, map, downsample and
    /// rasterise into an NSImage. Doing all of it at the render rate, for every
    /// status item, is what had an idle menu bar app holding a fifth of a core.
    private var sparkImage: NSImage?
    private var sparkImageKey: SparkKey?

    private struct SparkKey: Equatable { let newest: Date?; let minutes: Int }

    init(watchItem: WatchItem, session: InstrumentSession, appState: AppState) {
        self.itemID = watchItem.id
        self.watchItem = watchItem
        self.session = session
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        observeAndRender()
    }

    deinit {
        // NSStatusBar removal must happen on main; deinit of a @MainActor
        // object is already main-bound in practice, but be explicit.
        let item = statusItem
        Task { @MainActor in NSStatusBar.system.removeStatusItem(item) }
    }

    func update(watchItem: WatchItem) {
        self.watchItem = watchItem
        scheduleRender(force: true)
    }

    func remove() {
        hoverWorkItem?.cancel()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: Button & interactions

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageTrailing
        button.title = watchItem.displayLabel + " …"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        button.addTrackingArea(tracking)
    }

    @objc func mouseEntered(with event: NSEvent) {
        hoverWorkItem?.cancel()
        let delay = Double(appState.store.config.general.hoverDelayMs) / 1000
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.appState.panel.show(instId: self.watchItem.instId, anchoredTo: self.statusItem, pinned: false)
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @objc func mouseExited(with event: NSEvent) {
        hoverWorkItem?.cancel()
        appState.panel.scheduleHide()
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            hoverWorkItem?.cancel()
            appState.panel.togglePinned(instId: watchItem.instId, anchoredTo: statusItem)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let mode = appState.tradingMode

        let terminal = NSMenuItem(title: "打开 MayStock 终端", action: #selector(openTerminal), keyEquivalent: "t")
        terminal.target = self
        menu.addItem(terminal)
        let markets = NSMenuItem(title: "\(watchItem.instId) 行情…", action: #selector(openMarkets), keyEquivalent: "")
        markets.target = self
        menu.addItem(markets)
        let strategies = NSMenuItem(title: "策略…", action: #selector(openStrategies), keyEquivalent: "s")
        strategies.target = self
        menu.addItem(strategies)
        menu.addItem(.separator())

        // The account in play, and the switch. Selecting the other account
        // runs the same verify-then-confirm flow as the terminal's switch.
        let header = NSMenuItem(title: "交易环境：\(mode.displayName)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for candidate in TradingMode.allCases {
            let item = NSMenuItem(title: candidate.displayName, action: #selector(switchMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.rawValue
            item.state = candidate == mode ? .on : .off
            if candidate == .live && !appState.liveTradingUnlocked {
                item.isEnabled = false
                item.title = "实盘（未解锁）"
            }
            menu.addItem(item)
        }
        let account = NSMenuItem(title: "账户与连接…", action: #selector(openAccount), keyEquivalent: ",")
        account.target = self
        menu.addItem(account)
        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于 MayStock", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MayStock", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // restore normal click handling
    }

    @objc private func openTerminal() { appState.openTerminal(.overview) }
    @objc private func openMarkets() { appState.openTerminal(.markets, instId: watchItem.instId) }
    @objc private func openStrategies() { appState.openTerminal(.strategies) }
    @objc private func openAccount() { appState.openTerminal(.account) }
    @objc private func openAbout() { appState.openAbout() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func switchMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = TradingMode(rawValue: raw) else { return }
        appState.requestModeSwitch(to: mode)
    }

    // MARK: Observation-driven rendering (throttled)

    private func observeAndRender() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRender(force: false)
            }
        }
    }

    private func scheduleRender(force: Bool) {
        if force {
            observeAndRender()
            return
        }
        guard !renderScheduled else { return }
        renderScheduled = true
        let sinceLast = Date().timeIntervalSince(lastRenderAt)
        let delay = max(0, 0.1 - sinceLast)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.observeAndRender()
        }
    }

    private func render() {
        lastRenderAt = Date()
        guard let button = statusItem.button else { return }

        let title = NSMutableAttributedString()
        let baseFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

        // Reading these registers observation dependencies. `spark` is read as
        // a whole — that is what registers it — but the window is only *taken*
        // when the drawing below actually needs one.
        let ticker = session.ticker
        let spark = session.spark
        let connection = session.connection
        let decimals = watchItem.decimals ?? session.priceDecimals

        // Leading glyph / label.
        if watchItem.style == .full, let glyph = watchItem.glyph {
            title.append(NSAttributedString(string: glyph + " ", attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        } else if watchItem.style == .full || watchItem.style == .priceAndChange {
            title.append(NSAttributedString(string: watchItem.displayLabel + " ", attributes: [
                .font: smallFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }

        // Price.
        if let ticker {
            let price = PriceFormatter.price(ticker.last, decimals: decimals)
            title.append(NSAttributedString(string: price, attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
            ]))

            // Change chip.
            if watchItem.style == .priceAndChange || watchItem.style == .full {
                let up = ticker.changePct24h >= 0
                let arrow = up ? " ▲" : " ▼"
                let pct = String(format: "%.2f%%", abs(ticker.changePct24h))
                title.append(NSAttributedString(string: arrow + pct, attributes: [
                    .font: smallFont,
                    .foregroundColor: up ? NSColor.systemGreen : NSColor.systemRed,
                ]))
            }
        } else {
            let text = connection == .degraded ? "\(watchItem.displayLabel) ⌁" : "…"
            title.append(NSAttributedString(string: text, attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }

        button.attributedTitle = title

        // Trailing sparkline, redrawn only when the series actually advanced.
        if watchItem.style == .sparkline || watchItem.style == .full {
            let key = SparkKey(newest: spark.last?.ts, minutes: watchItem.sparklineMinutes)
            if key != sparkImageKey || sparkImage == nil {
                sparkImageKey = key
                sparkImage = SparklineRenderer.image(
                    points: spark.window(minutes: watchItem.sparklineMinutes))
            }
            button.image = sparkImage
            button.imagePosition = .imageTrailing
        } else {
            button.image = nil
            sparkImage = nil
            sparkImageKey = nil
        }

        button.toolTip = toolTip(ticker: ticker, connection: connection)
    }

    private func toolTip(ticker: Ticker?, connection: OKXConnectionState) -> String {
        guard let ticker else { return "\(watchItem.instId) — 连接中 (\(connection.rawValue))" }
        return """
        \(watchItem.instId) · OKX
        最新 \(PriceFormatter.auto(ticker.last))   24h \(PriceFormatter.signedPercent(ticker.changePct24h))
        高 \(PriceFormatter.auto(ticker.high24h))   低 \(PriceFormatter.auto(ticker.low24h))
        """
    }
}
