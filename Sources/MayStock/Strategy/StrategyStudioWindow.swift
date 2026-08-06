import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MayStockKit

// MARK: - Window

/// Owns the strategy studio window — created lazily, reused, and (like the
/// settings window) never changes the app's accessory activation policy.
@MainActor
final class StrategyStudioWindowController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private var window: NSWindow?
    private let selection = StudioSelection()

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func show(selecting strategyId: String?) {
        if let strategyId { selection.strategyId = strategyId }
        if selection.strategyId == nil { selection.strategyId = appState.strategies.first?.id }

        if window == nil {
            let root = StrategyStudioView(appState: appState, selection: selection)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "MayStock 策略工作台"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1_060, height: 700))
            window.minSize = NSSize(width: 900, height: 560)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@Observable
@MainActor
final class StudioSelection {
    var strategyId: String?
    var window: BacktestWindow = .d30
    var detailTab: StrategyDetailTab = .backtest
}

enum StrategyDetailTab: String, CaseIterable, Identifiable {
    case backtest, position, definition
    var id: String { rawValue }
    var label: String {
        switch self {
        case .backtest: return "回测"
        case .position: return "持仓与成交"
        case .definition: return "参数与风控"
        }
    }
}

// MARK: - Root

struct StrategyStudioView: View {
    let appState: AppState
    @Bindable var selection: StudioSelection

    var body: some View {
        VStack(spacing: 0) {
            PortfolioHeader(appState: appState)
            Divider()
            HSplit(appState: appState, selection: selection)
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            if selection.strategyId == nil { selection.strategyId = appState.strategies.first?.id }
        }
    }
}

private struct HSplit: View {
    let appState: AppState
    @Bindable var selection: StudioSelection

    var body: some View {
        HStack(spacing: 0) {
            StrategySidebar(appState: appState, selection: selection)
                .frame(width: 276)
            Divider()
            Group {
                if let id = selection.strategyId, let strategy = appState.strategy(id: id) {
                    StrategyDetailView(appState: appState, strategy: strategy, selection: selection)
                } else {
                    EmptyStudioState(appState: appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Header

private struct PortfolioHeader: View {
    let appState: AppState
    @State private var capitalText = ""
    @State private var editingCapital = false

    private var portfolio: StrategyPortfolioPrefs { appState.store.config.strategy }

    /// How many independent bets this book actually holds.
    ///
    /// Allocating separately to each strategy is not the same as diversifying
    /// between them. Two trend followers on BTC and ETH move together in a
    /// crash — exactly when the diversification was supposed to help — so the
    /// book is one position of double the size, and no per-strategy backtest
    /// can show that.
    @ViewBuilder
    private var diversificationLine: some View {
        if let report = appState.portfolioDiversification,
           let effective = report.effectiveBets, !report.pairs.isEmpty {
            let names = report.highestPair
            HStack(spacing: 5) {
                Text("有效独立注数 \(PriceFormatter.decimals(effective, 2)) / \(report.pairs.count + 1)")
                    .font(.system(size: 10, weight: report.isConcentrated ? .semibold : .regular))
                    .foregroundStyle(report.isConcentrated ? Color.orange : .secondary)
                    .monospacedDigit()
                if let names {
                    Text("最高相关 \(names.a) ↔ \(names.b) "
                         + PriceFormatter.decimals(names.correlation, 2))
                        .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("策略组合").font(.system(size: 15, weight: .semibold))
                    modeSwitch
                    if portfolio.emergencyStop {
                        Label("急停中", systemImage: "hand.raised.fill")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(ChartStyle.down.opacity(0.16), in: Capsule())
                            .foregroundStyle(ChartStyle.down)
                    }
                }
                Text("运行中 \(portfolio.runningCount)/\(appState.strategies.count) · "
                     + "已分配 \(PriceFormatter.money(portfolio.allocatedCapital, decimals: 0)) · "
                     + "未分配 \(PriceFormatter.money(portfolio.unallocatedCapital, decimals: 0)) \(portfolio.quoteCurrency)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                diversificationLine
            }

            Spacer()

            capitalField
            aggregatePnL

            HStack(spacing: 8) {
                Button {
                    Task { await appState.refreshAccount() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新账户余额与持仓")

                if portfolio.emergencyStop {
                    Button("解除急停") { appState.clearEmergencyStop() }
                        .controlSize(.small)
                } else {
                    Button(role: .destructive) {
                        appState.emergencyStop()
                    } label: {
                        Label("急停", systemImage: "stop.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .controlSize(.small)
                    .help("停止全部策略并市价平掉所有由策略建立的持仓")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var modeSwitch: some View {
        Picker("", selection: Binding(
            get: { appState.tradingMode },
            set: { appState.setMode($0) }
        )) {
            Text("模拟盘").tag(TradingMode.demo)
            Text("实盘").tag(TradingMode.live)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 132)
        .disabled(!appState.liveTradingUnlocked)
        .help(appState.liveTradingUnlocked
              ? "切换账户会先停止所有策略"
              : "实盘需先在 设置 → 交易 中解锁")
    }

    private var capitalField: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("总资金").font(.system(size: 9)).foregroundStyle(.tertiary)
            HStack(spacing: 3) {
                TextField("", text: Binding(
                    get: { editingCapital ? capitalText : PriceFormatter.plain(portfolio.totalCapital) },
                    set: { capitalText = $0 }
                ), onEditingChanged: { editing in
                    editingCapital = editing
                    if editing {
                        capitalText = PriceFormatter.plain(portfolio.totalCapital)
                    } else if let value = Double(capitalText) {
                        appState.setTotalCapital(value)
                    }
                })
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .frame(width: 76)
                Text(portfolio.quoteCurrency)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }

    private var aggregatePnL: some View {
        let pnl = appState.portfolioNetPnL
        let pct = appState.portfolioReturnPct
        return VStack(alignment: .trailing, spacing: 1) {
            Text("合计盈亏").font(.system(size: 9)).foregroundStyle(.tertiary)
            HStack(spacing: 5) {
                Text(PriceFormatter.signedMoney(pnl))
                    .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                if let pct {
                    Text("(\(PriceFormatter.signedPercent(pct)))")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                }
            }
            .foregroundStyle(ChartStyle.trend(pnl >= 0))
        }
    }
}

// MARK: - Sidebar

private struct StrategySidebar: View {
    let appState: AppState
    @Bindable var selection: StudioSelection
    @State private var importError: String?
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(appState.strategies, id: \.id) { strategy in
                        StrategyRow(
                            appState: appState,
                            strategy: strategy,
                            isSelected: selection.strategyId == strategy.id)
                        .onTapGesture { selection.strategyId = strategy.id }
                        .contextMenu {
                            Button("重新回测") { appState.runBacktest(strategyId: strategy.id) }
                            Button("导出清单…") { export(strategy.manifest) }
                            Divider()
                            Button("移除策略", role: .destructive) {
                                appState.deleteStrategy(id: strategy.id)
                                if selection.strategyId == strategy.id {
                                    selection.strategyId = appState.strategies.first?.id
                                }
                            }
                        }
                    }

                    if !appState.brokenStrategies.isEmpty {
                        brokenSection
                    }
                }
                .padding(8)
            }

            Divider()
            footer
        }
        .background(isDropTarget ? ChartStyle.accent.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var brokenSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("无法加载")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
            ForEach(appState.brokenStrategies, id: \.manifest.id) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Label(entry.manifest.name, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                    Text(entry.reason)
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let importError {
                Text(importError)
                    .font(.system(size: 9)).foregroundStyle(ChartStyle.down)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                Button {
                    presentImportPanel()
                } label: {
                    Label("导入策略", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)

                Button {
                    appState.runAllBacktests()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)
                .help("重新回测全部策略")
            }
            Text("也可直接把 .json 策略清单拖到这里")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(9)
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.message = "选择策略清单（JSON）"
        guard panel.runModal() == .OK else { return }
        adopt(panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "json" else { return }
                Task { @MainActor in adopt([url]) }
            }
        }
    }

    private func adopt(_ urls: [URL]) {
        var failures: [String] = []
        var lastImported: String?
        for url in urls {
            do {
                let manifest = try appState.importStrategy(from: url)
                lastImported = manifest.id
            } catch {
                failures.append("\(url.lastPathComponent)：\(error)")
            }
        }
        importError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        if let lastImported {
            selection.strategyId = lastImported
            appState.runBacktest(strategyId: lastImported)
        }
    }

    private func export(_ manifest: StrategyManifest) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = manifest.id + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? manifest.encoded().write(to: url, options: .atomic)
    }
}

// MARK: - Sidebar row

private struct StrategyRow: View {
    let appState: AppState
    let strategy: CompiledStrategy
    let isSelected: Bool

    private var allocation: StrategyAllocation? {
        appState.store.config.strategy.allocation(for: strategy.id)
    }
    private var state: StrategyRuntimeState { appState.runner.state(for: strategy.id) }
    private var position: StrategyPositionState? { appState.ledger.position(for: strategy.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(strategy.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(strategy.market.instId) · \(strategy.market.instType.displayName) · \(strategy.market.bar.rawValue)")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(allocation.map {
                        "仓位 \(PriceFormatter.money($0.capital, decimals: 0))"
                    } ?? "未分配")
                        .font(.system(size: 9)).monospacedDigit()
                        .foregroundStyle(allocation?.capital ?? 0 > 0 ? .secondary : .tertiary)
                    if let pct = appState.returnPct(for: strategy.id) {
                        Text(PriceFormatter.signedPercent(pct))
                            .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(ChartStyle.trend(pct >= 0))
                    }
                    if let direction = position?.direction {
                        Text(direction.displayName)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(ChartStyle.trend(direction == .long).opacity(0.16), in: Capsule())
                            .foregroundStyle(ChartStyle.trend(direction == .long))
                    }
                }
            }
            Spacer(minLength: 0)
            if let report = appState.reports[strategy.id] {
                RobustnessBadge(assessment: report.robustness, compact: true)
            } else if appState.isBacktesting(strategy.id) {
                ProgressView().controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.09 : 0.03)))
        .contentShape(Rectangle())
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
            .padding(.top, 4)
            .help(state.status.displayName + (state.message.map { " · \($0)" } ?? ""))
    }

    private var dotColor: Color {
        switch state.status {
        case .running: return ChartStyle.up
        case .warmingUp: return ChartStyle.accent
        case .halted: return .orange
        case .failed: return ChartStyle.down
        case .stopped: return .secondary.opacity(0.5)
        }
    }
}

// MARK: - Empty state

private struct EmptyStudioState: View {
    let appState: AppState

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("还没有可用的策略")
                .font(.system(size: 14, weight: .medium))
            Text("导入一份策略清单，或从内置示例开始。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("恢复内置示例") {
                appState.strategyStore.installPresetsIfEmpty()
                appState.reloadStrategies()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Portfolio math

extension AppState {
    /// Latest known price for an instrument: the runner's poll, else a live
    /// watchlist session.
    func mark(for instId: String) -> Double? {
        runner.mark(for: instId) ?? hub.session(for: instId)?.ticker?.last
    }

    func netPnL(for strategyId: String) -> Double {
        guard let position = ledger.position(for: strategyId) else { return 0 }
        return position.netPnL(mark: mark(for: position.instId))
    }

    func returnPct(for strategyId: String) -> Double? {
        guard let allocation = store.config.strategy.allocation(for: strategyId),
              allocation.capital > 0,
              let position = ledger.position(for: strategyId),
              position.fillCount > 0 else { return nil }
        return position.returnPct(mark: mark(for: position.instId), capital: allocation.capital)
    }

    var portfolioNetPnL: Double {
        store.config.strategy.allocations.reduce(0) { $0 + netPnL(for: $1.strategyId) }
    }

    var portfolioReturnPct: Double? {
        let allocated = store.config.strategy.allocatedCapital
        guard allocated > 0 else { return nil }
        return portfolioNetPnL / allocated * 100
    }
}
