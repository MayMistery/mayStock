import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MayStockKit

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

/// The studio: the portfolio's budget at the top, the library on the left,
/// one strategy's everything on the right.
struct StrategiesPage: View {
    let appState: AppState
    @Bindable var selection: TerminalSelection

    var body: some View {
        VStack(spacing: 0) {
            PortfolioBar(appState: appState)
            Divider()
            HStack(spacing: 0) {
                StrategyList(appState: appState, selection: selection)
                    .frame(width: 290)
                Divider()
                Group {
                    if let id = selection.strategyId, let strategy = appState.strategy(id: id) {
                        StrategyDetailView(appState: appState, strategy: strategy, selection: selection)
                    } else {
                        EmptyState(icon: "function", title: "还没有可用的策略",
                                   message: "导入一份策略清单（JSON），或恢复内置示例。",
                                   actionTitle: "恢复内置示例",
                                   action: {
                                       appState.strategyStore.installPresetsIfEmpty()
                                       appState.reloadStrategies()
                                   })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selection.strategyId == nil { selection.strategyId = appState.strategies.first?.id }
        }
    }
}

// MARK: - Portfolio bar

private struct PortfolioBar: View {
    let appState: AppState

    private var portfolio: StrategyPortfolioPrefs { appState.store.config.strategy }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("策略组合").font(Theme.Text.title)
                    Text("运行中 \(portfolio.runningCount)/\(appState.strategies.count) · "
                         + "已分配 \(PriceFormatter.money(portfolio.allocatedCapital, decimals: 0)) · "
                         + "未分配 \(PriceFormatter.money(portfolio.unallocatedCapital, decimals: 0)) \(portfolio.quoteCurrency)")
                        .font(Theme.Text.secondary).numeric()
                        .foregroundStyle(portfolio.isOverAllocated ? Theme.down : .secondary)
                    diversificationLine
                }
                Spacer()
                figure("本金 · \(portfolio.quoteCurrency)") {
                    CommitTextField(placeholder: "0", value: PriceFormatter.plain(portfolio.totalCapital), width: 96) { text in
                        if let value = Double(text) { appState.setTotalCapital(value) }
                    }
                }
                figure("合计盈亏") {
                    let pnl = appState.portfolioNetPnL
                    HStack(spacing: 5) {
                        Text(PriceFormatter.signedMoney(pnl)).font(Theme.Text.number).numeric()
                        if let pct = appState.portfolioReturnPct {
                            Text("(\(PriceFormatter.signedPercent(pct)))").font(Theme.Text.captionMedium).numeric()
                        }
                    }
                    .foregroundStyle(Theme.signed(pnl))
                }
                Button {
                    appState.runAllBacktests()
                } label: {
                    Label("全部回测", systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)
                .help("重新回测全部策略（只用公开行情）")
            }
            if portfolio.isOverAllocated {
                let excess = portfolio.allocatedCapital - portfolio.totalCapital
                let multiple = portfolio.allocatedCapital / max(portfolio.totalCapital, 1)
                InlineNotice(kind: .danger, title: "预算超配",
                             message: "策略预算合计超出本金 \(PriceFormatter.money(excess, decimals: 0)) \(portfolio.quoteCurrency)——下单按各自预算定量，不看账户余额，全部满仓会下到本金的 \(PriceFormatter.decimals(multiple, 1)) 倍。改上面的本金即可按比例缩回。")
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 14)
    }

    private func figure<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(label).font(Theme.Text.caption).foregroundStyle(.secondary)
            content()
        }
    }

    /// How many independent bets this book actually holds. Two trend
    /// followers on BTC and ETH move together in a crash — exactly when the
    /// diversification was supposed to help.
    @ViewBuilder
    private var diversificationLine: some View {
        if let report = appState.portfolioDiversification,
           let effective = report.effectiveBets, !report.pairs.isEmpty {
            HStack(spacing: 6) {
                Text("有效独立注数 \(PriceFormatter.decimals(effective, 2)) / \(report.pairs.count + 1)")
                    .font(report.isConcentrated ? Theme.Text.captionMedium : Theme.Text.caption)
                    .foregroundStyle(report.isConcentrated ? Theme.warning : .secondary).numeric()
                if let names = report.highestPair {
                    Text("最高相关 \(names.a) ↔ \(names.b) \(PriceFormatter.decimals(names.correlation, 2))")
                        .font(Theme.Text.caption).foregroundStyle(.tertiary).numeric()
                }
            }
        }
    }
}

// MARK: - Strategy list

private struct StrategyList: View {
    let appState: AppState
    @Bindable var selection: TerminalSelection
    @State private var importError: String?
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            PageScroll {
                LazyVStack(spacing: 4) {
                    ForEach(appState.strategies, id: \.id) { strategy in
                        StrategyRow(appState: appState, strategy: strategy,
                                    isSelected: selection.strategyId == strategy.id)
                            .onTapGesture { selection.strategyId = strategy.id }
                            .contextMenu {
                                Button("重新回测") { appState.runBacktest(strategyId: strategy.id) }
                                Button("导出清单…") { export(strategy.manifest) }
                                Divider()
                                Button("移除策略", role: .destructive) {
                                    // Flattens first and only then removes; a
                                    // strategy whose position would not close
                                    // stays listed, with the reason posted.
                                    Task { @MainActor in
                                        guard await appState.deleteStrategy(id: strategy.id) else { return }
                                        if selection.strategyId == strategy.id {
                                            selection.strategyId = appState.strategies.first?.id
                                        }
                                    }
                                }
                            }
                    }
                    if !appState.brokenStrategies.isEmpty { brokenSection }
                }
                .padding(10)
            }
            Divider()
            footer
        }
        .background(isDropTarget ? Theme.accent.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var brokenSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("无法加载").font(Theme.Text.captionMedium).foregroundStyle(.secondary).padding(.top, 8)
            ForEach(appState.brokenStrategies) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Label(entry.name, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Text.bodyMedium).foregroundStyle(Theme.warning)
                    Text(entry.file).font(Theme.Text.monoSmall).foregroundStyle(.tertiary)
                    Text(entry.reason).font(Theme.Text.caption).foregroundStyle(.secondary)
                    if let allocation = appState.store.config.strategy.allocation(for: entry.id),
                       allocation.capital > 0 {
                        Text("预算 \(PriceFormatter.money(allocation.capital, decimals: 0)) 仍保留，未被动用")
                            .font(Theme.Text.caption).foregroundStyle(Theme.warning)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.rowRadius))
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let importError {
                Text(importError).font(Theme.Text.caption).foregroundStyle(Theme.down)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                presentImportPanel()
            } label: {
                Label("导入策略清单", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            Text("也可直接把 .json 清单拖到列表里").font(Theme.Text.caption).foregroundStyle(.tertiary)
        }
        .padding(10)
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
                lastImported = try appState.importStrategy(from: url).id
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

private struct StrategyRow: View {
    let appState: AppState
    let strategy: CompiledStrategy
    let isSelected: Bool

    private var allocation: StrategyAllocation? { appState.store.config.strategy.allocation(for: strategy.id) }
    private var state: StrategyRuntimeState { appState.runner.state(for: strategy.id) }
    private var position: StrategyPositionState? { appState.ledger.position(for: strategy.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            StatusDot(color: dotColor).padding(.top, 5)
                .help(state.status.displayName + (state.message.map { " · \($0)" } ?? ""))
            VStack(alignment: .leading, spacing: 3) {
                Text(strategy.name).font(Theme.Text.bodyMedium).lineLimit(1)
                Text("\(strategy.market.instId) · \(strategy.market.instType.displayName) · \(strategy.market.bar.rawValue)")
                    .font(Theme.Text.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(allocation.map { "预算 \(PriceFormatter.money($0.capital, decimals: 0))" } ?? "未分配")
                        .font(Theme.Text.caption).numeric()
                        .foregroundStyle((allocation?.capital ?? 0) > 0 ? .secondary : .tertiary)
                    if let pct = appState.returnPct(for: strategy.id) {
                        Text(PriceFormatter.signedPercent(pct))
                            .font(Theme.Text.captionMedium).numeric().foregroundStyle(Theme.signed(pct))
                    }
                    if let direction = position?.direction {
                        Badge(text: direction.displayName, tint: Theme.trend(direction == .long), size: .small)
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
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
            .fill(isSelected ? Theme.selectedFill : Theme.rowFill))
        .contentShape(Rectangle())
    }

    private var dotColor: Color {
        switch state.status {
        case .running: return Theme.up
        case .warmingUp: return Theme.accent
        case .halted: return Theme.warning
        case .failed: return Theme.down
        case .stopped: return (allocation?.running ?? false) ? Theme.accent : Color.secondary.opacity(0.4)
        }
    }
}
