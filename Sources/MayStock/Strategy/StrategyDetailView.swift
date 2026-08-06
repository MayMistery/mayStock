import SwiftUI
import MayStockKit

/// Right-hand pane: everything known about one strategy, with the two actions
/// that matter — how much money it gets, and whether it is trading — pinned to
/// the bottom so they are never more than one glance away.
struct StrategyDetailView: View {
    let appState: AppState
    let strategy: CompiledStrategy
    @Bindable var selection: StudioSelection

    private var report: StrategyBacktestReport? { appState.reports[strategy.id] }
    private var allocation: StrategyAllocation? {
        appState.store.config.strategy.allocation(for: strategy.id)
    }
    private var runtime: StrategyRuntimeState { appState.runner.state(for: strategy.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $selection.detailTab) {
                ForEach(StrategyDetailTab.allCases) { tab in Text(tab.label).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 9)

            ScrollView {
                Group {
                    switch selection.detailTab {
                    case .backtest: backtestTab
                    case .position: positionTab
                    case .definition: definitionTab
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }

            Divider()
            actionBar
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(strategy.name).font(.system(size: 15, weight: .semibold))
                    if let report {
                        RobustnessBadge(assessment: report.robustness)
                    }
                }
                Text("\(strategy.market.instId) · \(strategy.market.instType.displayName) · "
                     + "\(strategy.market.bar.rawValue) · v\(strategy.manifest.version)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let notes = strategy.manifest.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            backtestControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var backtestControl: some View {
        if appState.isBacktesting(strategy.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(appState.backtestPhase[strategy.id]?.displayText ?? "回测中")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Button {
                    appState.runBacktest(strategyId: strategy.id)
                } label: {
                    Label(report == nil ? "开始回测" : "重新回测", systemImage: "play.rectangle")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                if let report {
                    Text("更新于 " + report.generatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Backtest tab

    @ViewBuilder
    private var backtestTab: some View {
        if let report {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(BacktestWindow.allCases) { window in
                        BacktestWindowCard(
                            window: window,
                            result: report.result(for: window),
                            isSelected: selection.window == window,
                            onTap: { selection.window = window })
                    }
                }

                robustnessPanel(report)

                if let result = report.result(for: selection.window) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("净值曲线 · \(selection.window.displayName)")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            HStack(spacing: 5) {
                                legendSwatch(ChartStyle.trend(result.metrics.totalReturnPct >= 0), "策略")
                                legendSwatch(.secondary.opacity(0.45), "买入持有", dashed: true)
                            }
                        }
                        EquityCurveView(result: result)
                            .frame(height: 150)
                            .background(Color.primary.opacity(0.03),
                                        in: RoundedRectangle(cornerRadius: 9))
                        Text("\(result.start.formatted(date: .numeric, time: .shortened)) → "
                             + "\(result.end.formatted(date: .numeric, time: .shortened)) · "
                             + "\(result.barCount) 根 \(result.bar.rawValue) K 线 · "
                             + "起始 \(PriceFormatter.money(result.initialCapital, decimals: 0)) "
                             + appState.store.config.strategy.quoteCurrency)
                            .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                    }

                    BacktestMetricGrid(
                        result: result,
                        quoteCurrency: appState.store.config.strategy.quoteCurrency)

                    if !result.trades.isEmpty {
                        tradeList(result)
                    }
                } else {
                    infoBox("该窗口内数据不足，未能生成回测。", tint: .secondary)
                }
            }
            .padding(.top, 2)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("尚未回测")
                    .font(.system(size: 13, weight: .medium))
                Text("回测只用公开行情，不需要 API Key，可以放心先跑一遍。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Button("开始回测") { appState.runBacktest(strategyId: strategy.id) }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
    }

    private func robustnessPanel(_ report: StrategyBacktestReport) -> some View {
        let assessment = report.robustness
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                RobustnessBadge(assessment: assessment)
                Text(assessment.grade.explanation)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                statChip("样本", "\(assessment.observedTrades)/\(assessment.requiredTrades) 笔")
                statChip("样本内夏普", PriceFormatter.ratio(assessment.inSampleSharpe))
                statChip("样本外夏普", PriceFormatter.ratio(assessment.outOfSampleSharpe))
                statChip("样本外效率", PriceFormatter.ratio(assessment.outOfSampleEfficiency))
                statChip("窗口一致性", PriceFormatter.percent(assessment.windowAgreement * 100))
            }
            ForEach(assessment.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let coverage = report.coverageNote {
                Label(coverage, systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: 9)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private func tradeList(_ result: BacktestResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("回测成交（最近 \(min(result.trades.count, 40)) 笔）")
                .font(.system(size: 11, weight: .semibold))
            VStack(spacing: 0) {
                tableHeader(["方向", "入场", "出场", "收益", "持仓", "离场原因"])
                ForEach(result.trades.suffix(40).reversed()) { trade in
                    HStack(spacing: 0) {
                        cell(trade.direction.displayName,
                             tint: ChartStyle.trend(trade.direction == .long))
                        cell(PriceFormatter.auto(trade.entryPrice))
                        cell(PriceFormatter.auto(trade.exitPrice))
                        cell(PriceFormatter.signedPercent(trade.returnPct),
                             tint: ChartStyle.trend(trade.netPnL >= 0))
                        cell("\(trade.bars) 根")
                        cell(trade.exitReason.displayName,
                             tint: trade.exitReason == .liquidation ? ChartStyle.down : nil)
                    }
                    .padding(.vertical, 3)
                    .background(trade.id % 2 == 0 ? Color.primary.opacity(0.025) : .clear)
                }
            }
            .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    // MARK: Position tab

    @ViewBuilder
    private var positionTab: some View {
        let position = appState.ledger.position(for: strategy.id)
        VStack(alignment: .leading, spacing: 14) {
            if !appState.tradingReady {
                infoBox(appState.accountError
                        ?? "okx CLI 未就绪：回测可用，实际下单需要先安装并配置 CLI。", tint: .orange)
            }
            if let reason = allocation?.haltReason {
                infoBox("上次因「\(reason)」自动停止，重新开始前请先确认原因已消除。", tint: .orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("当前持仓（\(appState.tradingMode.displayName)）")
                    .font(.system(size: 11, weight: .semibold))
                if let position, !position.isFlat {
                    let mark = appState.mark(for: position.instId)
                    HStack(spacing: 0) {
                        positionStat("方向", position.direction?.displayName ?? "—",
                                     tint: ChartStyle.trend(position.quantity > 0))
                        positionStat("数量", PriceFormatter.plain(abs(position.quantity)))
                        positionStat("均价", PriceFormatter.auto(position.averagePrice))
                        positionStat("现价", mark.map(PriceFormatter.auto) ?? "—")
                        positionStat("浮动盈亏",
                                     PriceFormatter.signedMoney(position.unrealisedPnL(mark: mark)),
                                     tint: ChartStyle.trend(position.unrealisedPnL(mark: mark) >= 0))
                    }
                } else {
                    Text("空仓").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 0) {
                    positionStat("已实现", PriceFormatter.signedMoney(position?.realisedPnL ?? 0),
                                 tint: ChartStyle.trend((position?.realisedPnL ?? 0) >= 0))
                    positionStat("累计手续费", PriceFormatter.money(position?.feesPaid ?? 0))
                    if let funding = position?.fundingPaid, funding != 0 {
                        // Shown apart from realised P&L on purpose: a perp
                        // losing money purely to funding is a different
                        // diagnosis from one losing it on entries.
                        positionStat("资金费", PriceFormatter.signedMoney(funding),
                                     tint: ChartStyle.trend(funding >= 0))
                    }
                    positionStat("净盈亏", PriceFormatter.signedMoney(appState.netPnL(for: strategy.id)),
                                 tint: ChartStyle.trend(appState.netPnL(for: strategy.id) >= 0))
                    positionStat("收益率",
                                 appState.returnPct(for: strategy.id).map(PriceFormatter.signedPercent) ?? "—",
                                 tint: ChartStyle.trend((appState.returnPct(for: strategy.id) ?? 0) >= 0))
                    positionStat("成交笔数", "\(position?.fillCount ?? 0)")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))

            reconciliationPanel
            LiveVsBacktestPanel(strategy: strategy)

            let fills = appState.ledger.fills(for: strategy.id, limit: 50)
            if fills.isEmpty {
                Text("还没有成交记录。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("成交明细").font(.system(size: 11, weight: .semibold))
                    VStack(spacing: 0) {
                        tableHeader(["时间", "方向", "价格", "数量", "手续费", "订单标签"])
                        ForEach(fills) { fill in
                            HStack(spacing: 0) {
                                cell(fill.ts.formatted(date: .numeric, time: .standard))
                                cell(fill.side.displayName,
                                     tint: ChartStyle.trend(fill.side == .buy))
                                cell(PriceFormatter.auto(fill.price))
                                cell(PriceFormatter.plain(fill.quantity))
                                cell(PriceFormatter.money(fill.feeQuote, decimals: 4))
                                cell(fill.clOrdId ?? "—")
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var reconciliationPanel: some View {
        let rows = appState.ledger
            .reconcile(spotBalances: appState.accountBalances,
                       swapPositions: appState.exchangePositions)
            .filter { $0.instId == strategy.market.instId && $0.isMaterial }
        if let row = rows.first {
            VStack(alignment: .leading, spacing: 3) {
                Label("交易所持仓与台账不一致", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                Text("台账 \(PriceFormatter.plain(row.ledgerQuantity)) · "
                     + "交易所 \(PriceFormatter.plain(row.exchangeQuantity)) · "
                     + "未归因 \(PriceFormatter.signedMoney(row.unattributed, decimals: 6))")
                    .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                Text("差额通常来自手动下单或其它程序；策略只会调整自己台账内的仓位。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Definition tab

    private var definitionTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !strategy.manifest.params.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("参数").font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Text("\(strategy.freeParameterCount) 个自由参数 → 稳健性阈值 \(strategy.freeParameterCount * 30) 笔交易")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    ForEach(strategy.manifest.params.items) { parameter in
                        ParameterRow(appState: appState, strategy: strategy, parameter: parameter)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("信号").font(.system(size: 11, weight: .semibold))
                signalRow("做多入场", strategy.manifest.signals.longEntry)
                signalRow("做多离场", strategy.manifest.signals.longExit)
                signalRow("做空入场", strategy.manifest.signals.shortEntry)
                signalRow("做空离场", strategy.manifest.signals.shortExit)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("仓位与风控").font(.system(size: 11, weight: .semibold))
                let risk = strategy.manifest.risk
                let costs = strategy.manifest.effectiveCosts
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)],
                          alignment: .leading, spacing: 6) {
                    definitionCell("仓位模式", "\(strategy.manifest.sizing.mode.displayName) "
                                   + PriceFormatter.plain(strategy.manifest.sizing.value)
                                   + (strategy.manifest.sizing.mode == .fixedQuote ? "" : "%"))
                    definitionCell("杠杆", "\(PriceFormatter.plain(risk.leverage))×")
                    definitionCell("止损", risk.stopLossPct.map { PriceFormatter.percent($0, decimals: 1) } ?? "—")
                    definitionCell("止盈", risk.takeProfitPct.map { PriceFormatter.percent($0, decimals: 1) } ?? "—")
                    definitionCell("移动止损", risk.trailingStopPct.map { PriceFormatter.percent($0, decimals: 1) } ?? "—")
                    definitionCell("ATR 止损", risk.atrStop.map { "\($0.period) × \(PriceFormatter.plain($0.mult))" } ?? "—")
                    definitionCell("冷却", "\(risk.cooldownBars) 根")
                    definitionCell("最短持仓", "\(risk.minHoldBars) 根")
                    definitionCell("日内熔断", risk.maxDailyLossPct.map { PriceFormatter.percent($0, decimals: 1) } ?? "—")
                    definitionCell("手续费假设", "\(PriceFormatter.plain(costs.feeBps)) bps")
                    definitionCell("滑点假设", "\(PriceFormatter.plain(costs.slippageBps)) bps")
                    definitionCell("指标预热", "\(strategy.warmupBars) 根")
                }
            }

            infoBox("回测按「本根收盘出信号、下根开盘成交」撮合，进出各收一次手续费并叠加滑点；"
                    + "同一根 K 线同时触及止损与止盈时按止损先成交计算。", tint: .secondary)
        }
        .padding(.top, 2)
    }

    private func signalRow(_ label: String, _ source: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(source ?? "—")
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(source == nil ? .tertiary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(7)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    private func definitionCell(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            Spacer(minLength: 2)
            Text(value).font(.system(size: 10, weight: .medium)).monospacedDigit()
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Action bar

    private var actionBar: some View {
        let portfolio = appState.store.config.strategy
        let capital = allocation?.capital ?? 0
        let headroom = portfolio.capitalHeadroom(for: strategy.id)
        let running = allocation?.running ?? false

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("分配仓位").font(.system(size: 11, weight: .semibold))
                    Text("\(PriceFormatter.money(capital, decimals: 0)) \(portfolio.quoteCurrency)")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(ChartStyle.accent)
                    Text("· 可用上限 \(PriceFormatter.money(headroom, decimals: 0))")
                        .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                }
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { min(capital, max(headroom, 0.0001)) },
                            set: { appState.setCapital($0, for: strategy.id) }),
                        in: 0...max(headroom, 0.0001))
                    .controlSize(.small)
                    .disabled(running || headroom <= 0)

                    ForEach([0.25, 0.5, 1.0], id: \.self) { fraction in
                        Button(fraction == 1.0 ? "全部" : "\(Int(fraction * 100))%") {
                            appState.setCapital(headroom * fraction, for: strategy.id)
                        }
                        .controlSize(.mini)
                        .disabled(running || headroom <= 0)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: 3) {
                startStopButton(running: running, capital: capital)
                Text(runtimeSummary)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func startStopButton(running: Bool, capital: Double) -> some View {
        if running {
            HStack(spacing: 6) {
                Button("结束交易") { appState.stopStrategy(id: strategy.id) }
                    .controlSize(.regular)
                Button {
                    Task { await appState.runner.flatten(strategyId: strategy.id) }
                } label: {
                    Text("平仓").font(.system(size: 11))
                }
                .controlSize(.regular)
                .disabled(appState.ledger.position(for: strategy.id)?.isFlat ?? true)
                .help("市价平掉本策略当前持仓")
            }
        } else {
            Button {
                appState.startStrategy(id: strategy.id)
            } label: {
                Label("开始交易", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .controlSize(.regular)
            .tint(ChartStyle.up)
            .disabled(capital <= 0 || !appState.tradingReady)
            .help(capital <= 0 ? "先分配仓位"
                  : (appState.tradingReady ? "按 \(strategy.market.bar.rawValue) 收盘评估信号并自动下单"
                     : "okx CLI 未就绪"))
        }
    }

    private var runtimeSummary: String {
        let state = runtime
        if let message = state.message { return "\(state.status.displayName) · \(message)" }
        if let bar = state.lastBarTime {
            return "\(state.status.displayName) · 最新 K 线 "
                + bar.formatted(date: .omitted, time: .shortened)
        }
        return state.status.displayName
    }

    // MARK: Small pieces

    private func legendSwatch(_ color: Color, _ label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: dashed ? 5 : 10, height: 2)
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private func statChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 10, weight: .medium)).monospacedDigit()
        }
    }

    private func positionStat(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableHeader(_ titles: [String]) -> some View {
        HStack(spacing: 0) {
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func cell(_ text: String, tint: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(tint ?? .secondary)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoBox(_ text: String, tint: Color) -> some View {
        Label(text, systemImage: tint == .orange ? "exclamationmark.triangle" : "info.circle")
            .font(.system(size: 10))
            .foregroundStyle(tint == .orange ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((tint == .orange ? Color.orange : Color.primary).opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Parameter editing

/// Editing a parameter rewrites the manifest on disk and invalidates the
/// backtest — the numbers on screen must never describe a different strategy
/// from the one that would run.
private struct ParameterRow: View {
    let appState: AppState
    let strategy: CompiledStrategy
    let parameter: StrategyParameter
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        HStack(spacing: 10) {
            Text(parameter.displayLabel)
                .font(.system(size: 10))
                .frame(width: 96, alignment: .leading)

            if let lower = parameter.minimum, let upper = parameter.maximum, upper > lower {
                Slider(
                    value: Binding(get: { parameter.value }, set: { commit($0) }),
                    in: lower...upper,
                    step: parameter.step ?? (upper - lower > 20 ? 1 : 0.1))
                .controlSize(.small)
            }

            TextField("", text: Binding(
                get: { editing ? text : PriceFormatter.plain(parameter.value) },
                set: { text = $0 }
            ), onEditingChanged: { began in
                editing = began
                if began {
                    text = PriceFormatter.plain(parameter.value)
                } else if let value = Double(text) {
                    commit(value)
                }
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10).monospacedDigit())
            .frame(width: 68)

            Text(parameter.name)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 76, alignment: .leading)
        }
    }

    private func commit(_ value: Double) {
        var manifest = strategy.manifest
        manifest.params.setValue(value, for: parameter.name)
        guard manifest != strategy.manifest else { return }
        appState.saveStrategy(manifest)
    }
}
