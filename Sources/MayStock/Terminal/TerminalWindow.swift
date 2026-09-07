import AppKit
import SwiftUI
import Observation
import MayStockKit

/// The pages of the terminal window, in sidebar order.
enum TerminalPage: String, CaseIterable, Identifiable {
    case overview, markets, strategies, alerts, account, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "总览"
        case .markets: return "行情"
        case .strategies: return "策略"
        case .alerts: return "告警"
        case .account: return "账户与连接"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .markets: return "chart.xyaxis.line"
        case .strategies: return "function"
        case .alerts: return "bell"
        case .account: return "person.crop.circle.badge.checkmark"
        case .settings: return "gearshape"
        }
    }
}

/// What the terminal is showing. Shared between the controller (which is told
/// where to open) and the SwiftUI tree (which renders it).
@Observable
@MainActor
final class TerminalSelection {
    var page: TerminalPage = .overview
    var strategyId: String?
    var instId: String?
    var backtestWindow: BacktestWindow = .d30
    var detailTab: StrategyDetailTab = .backtest
    /// Window of the account equity chart on the overview.
    var equityWindow: EquityWindow = .day1
}

/// Owns the terminal window — created lazily, reused, and never changing the
/// app's accessory activation policy: it is a window the menu bar app opens,
/// not a document the app is about.
@MainActor
final class TerminalWindowController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private(set) var window: NSWindow?
    let selection = TerminalSelection()

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func show(page: TerminalPage, strategyId: String?, instId: String?) {
        selection.page = page
        if let strategyId { selection.strategyId = strategyId }
        if selection.strategyId == nil { selection.strategyId = appState.strategies.first?.id }
        if let instId { selection.instId = instId }
        if selection.instId == nil { selection.instId = appState.store.config.watchlist.first?.instId }

        if window == nil {
            let root = TerminalView(appState: appState, selection: selection)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "MayStock"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unifiedCompact
            window.setContentSize(NSSize(width: 1_180, height: 780))
            window.minSize = NSSize(width: 980, height: 620)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("MayStockTerminal")
            if !window.setFrameUsingName("MayStockTerminal") { window.center() }
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Root

struct TerminalView: View {
    let appState: AppState
    @Bindable var selection: TerminalSelection

    var body: some View {
        NavigationSplitView {
            TerminalSidebar(appState: appState, selection: selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            TerminalDetail(appState: appState, selection: selection)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 620)
    }
}

/// The detail column: environment bar plus the selected page. Separate from
/// the split view so the snapshot renderer can draw it — `NavigationSplitView`
/// is AppKit-backed and renders as nothing offscreen.
struct TerminalDetail: View {
    let appState: AppState
    let selection: TerminalSelection

    var body: some View {
        // Laid out at exactly the space the column has. The split view sizes
        // its detail column from the content's *ideal* size when that is
        // larger than the column, and a page's ideal height is not a number
        // anyone controls — one wrapping label measured at an unspecified
        // width once came back two thousand points tall and pushed the whole
        // page out of the window. A geometry reader has no ideal size of its
        // own, so the column stays the column.
        GeometryReader { geometry in
            VStack(spacing: 0) {
                EnvironmentBar(appState: appState)
                Divider()
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch selection.page {
        case .overview: OverviewPage(appState: appState, selection: selection)
        case .markets: MarketsPage(appState: appState, selection: selection)
        case .strategies: StrategiesPage(appState: appState, selection: selection)
        case .alerts: AlertsPage(appState: appState)
        case .account: AccountPage(appState: appState)
        case .settings: SettingsPage(appState: appState)
        }
    }
}

// MARK: - Sidebar

private struct TerminalSidebar: View {
    let appState: AppState
    @Bindable var selection: TerminalSelection

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding<TerminalPage?>(
                get: { selection.page },
                set: { if let page = $0 { selection.page = page } })) {
                ForEach(TerminalPage.allCases) { page in
                    Label(page.label, systemImage: page.icon)
                        .badge(badge(for: page))
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
            Divider()
            footer
        }
    }

    private func badge(for page: TerminalPage) -> Int {
        switch page {
        case .strategies: return appState.store.config.strategy.runningCount
        case .alerts: return appState.alerts.rules.filter(\.enabled).count
        default: return 0
        }
    }

    /// Liveness at a glance: the two feeds, the CLI and the trading loop.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusLine(color: feedColor, text: "行情 " + feedText)
            statusLine(color: appState.cliInfo == nil ? Theme.down : Theme.up,
                       text: appState.cliInfo.map { "okx CLI \($0.version)" } ?? "okx CLI 未检测到")
            statusLine(color: heartbeatColor, text: heartbeatText)
        }
        .font(Theme.Text.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLine(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            StatusDot(color: color, size: 6)
            Text(text).lineLimit(1)
        }
    }

    private var feedColor: Color {
        switch (appState.hub.publicState, appState.hub.businessState) {
        case (.connected, .connected): return Theme.up
        case (.degraded, _), (_, .degraded): return Theme.warning
        default: return .secondary
        }
    }

    private var feedText: String {
        switch (appState.hub.publicState, appState.hub.businessState) {
        case (.connected, .connected): return "已连接"
        case (.degraded, _), (_, .degraded): return "重连中"
        case (.idle, .idle): return "空闲"
        default: return "连接中"
        }
    }

    private var heartbeatColor: Color {
        guard let silence = appState.heartbeatSilence else { return .secondary }
        return silence > StrategyRunner.heartbeatTimeout ? Theme.down : Theme.up
    }

    private var heartbeatText: String {
        guard let silence = appState.heartbeatSilence else { return "交易循环 未启动" }
        return "交易循环 " + (silence < 90 ? "\(Int(silence)) 秒前" : Format.duration(silence) + "前")
    }
}

// MARK: - Environment bar

/// The strip above every page: which account is in play, whether it can be
/// reached, what it is worth, and the one button that stops everything.
struct EnvironmentBar: View {
    let appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            TradingModeSwitch(appState: appState)
            ConnectionChip(appState: appState, mode: appState.tradingMode)
            equityChip
            Spacer(minLength: 8)
            if appState.store.config.strategy.emergencyStop {
                Button("解除急停") { appState.clearEmergencyStop() }
                    .controlSize(.small)
            } else {
                Button {
                    appState.requestEmergencyStop()
                } label: {
                    Label("急停", systemImage: "stop.circle.fill")
                }
                .controlSize(.small)
                .tint(Theme.down)
                .help("停止全部策略并市价平掉所有由策略建立的持仓")
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var equityChip: some View {
        HStack(spacing: 5) {
            Text("权益").font(Theme.Text.caption).foregroundStyle(.secondary)
            Text(Format.money(appState.accountEquity))
                .font(Theme.Text.secondaryMedium).numeric()
                .contentTransition(.numericText())
            Text(appState.runner.quoteCurrency).font(Theme.Text.caption).foregroundStyle(.tertiary)
            if let pct = appState.openPnLPct, let pnl = appState.openPnL {
                Text("\(PriceFormatter.signedMoney(pnl, decimals: 0)) (\(PriceFormatter.signedPercent(pct)))")
                    .font(Theme.Text.captionMedium).numeric()
                    .foregroundStyle(Theme.signed(pnl))
            }
        }
        .help("账户权益（\(appState.runner.quoteCurrency) 计）与当前持仓盈亏")
    }
}
