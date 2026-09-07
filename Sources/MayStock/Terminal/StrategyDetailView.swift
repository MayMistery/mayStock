import SwiftUI
import MayStockKit

/// Everything known about one strategy, with the two actions that matter —
/// how much money it gets, and whether it is trading — pinned to the bottom.
struct StrategyDetailView: View {
    let appState: AppState
    let strategy: CompiledStrategy
    @Bindable var selection: TerminalSelection

    private var report: StrategyBacktestReport? { appState.reports[strategy.id] }
    private var allocation: StrategyAllocation? { appState.store.config.strategy.allocation(for: strategy.id) }
    private var runtime: StrategyRuntimeState { appState.runner.state(for: strategy.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack {
                PillSegments(
                    segments: StrategyDetailTab.allCases.map { PillSegments<StrategyDetailTab>.Segment(value: $0, title: $0.label) },
                    selection: selection.detailTab,
                    onSelect: { selection.detailTab = $0 })
                Spacer()
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 10)

            PageScroll {
                Group {
                    switch selection.detailTab {
                    case .backtest: backtestTab
                    case .position: positionTab
                    case .definition: definitionTab
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, Theme.pagePadding)
            }

            Divider()
            actionBar
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(strategy.name).font(Theme.Text.title)
                    if let report { RobustnessBadge(assessment: report.robustness) }
                    if strategy.isScriptEngine { Badge(text: "外部脚本", tint: Theme.warning, size: .small) }
                }
                Text("\(strategy.market.instId) · \(strategy.market.instType.displayName) · \(strategy.market.bar.rawValue) · v\(strategy.manifest.version)"
                     + (strategy.manifest.author.map { " · \($0)" } ?? ""))
                    .font(Theme.Text.secondary).foregroundStyle(.secondary)
                if let notes = strategy.manifest.notes, !notes.isEmpty {
                    Text(notes).font(Theme.Text.secondary).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            backtestControl
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var backtestControl: some View {
        if appState.isBacktesting(strategy.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(appState.backtestPhase[strategy.id]?.displayText ?? "回测中")
                    .font(Theme.Text.secondary).foregroundStyle(.secondary).numeric()
            }
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                Button {
                    appState.runBacktest(strategyId: strategy.id)
                } label: {
                    Label(report == nil ? "开始回测" : "重新回测", systemImage: "play.rectangle")
                }
                .controlSize(.small)
                if let report {
                    Text("更新于 " + Format.clock(report.generatedAt)).font(Theme.Text.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Backtest tab

    @ViewBuilder
    private var backtestTab: some View {
        if let report {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                HStack(spacing: 8) {
                    ForEach(BacktestWindow.allCases) { window in
                        BacktestWindowCard(window: window, result: report.result(for: window),
                                           isSelected: selection.backtestWindow == window,
                                           onTap: { selection.backtestWindow = window })
                    }
                }
                robustnessPanel(report)

                if let result = report.result(for: selection.backtestWindow) {
                    Card(title: "净值曲线 · \(selection.backtestWindow.displayName)",
                         subtitle: "\(result.start.formatted(date: .numeric, time: .shortened)) → \(result.end.formatted(date: .numeric, time: .shortened)) · \(result.barCount) 根 \(result.bar.rawValue) · 起始 \(PriceFormatter.money(result.initialCapital, decimals: 0)) \(appState.store.config.strategy.quoteCurrency)") {
                        HStack(spacing: 8) {
                            legendSwatch(Theme.trend(result.metrics.totalReturnPct >= 0), "策略")
                            legendSwatch(.secondary.opacity(0.45), "买入持有", dashed: true)
                        }
                    } content: {
                        EquityCurveView(result: result).frame(height: 180)
                        BacktestMetricGrid(result: result, quoteCurrency: appState.store.config.strategy.quoteCurrency)
                    }
                    if !result.trades.isEmpty { tradeList(result) }
                } else {
                    InlineNotice(kind: .info, message: "该窗口内数据不足，未能生成回测。")
                }
            }
        } else {
            EmptyState(icon: "chart.bar.doc.horizontal", title: "尚未回测",
                       message: "回测只用公开行情，不需要 API Key，可以放心先跑一遍。",
                       actionTitle: "开始回测", action: { appState.runBacktest(strategyId: strategy.id) })
                .padding(.vertical, 40)
        }
    }

    private func robustnessPanel(_ report: StrategyBacktestReport) -> some View {
        let assessment = report.robustness
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    RobustnessBadge(assessment: assessment)
                    Text(assessment.grade.explanation).font(Theme.Text.secondary).foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    statChip("样本", "\(assessment.observedTrades)/\(assessment.requiredTrades) 笔")
                    statChip("样本内夏普", PriceFormatter.ratio(assessment.inSampleSharpe))
                    statChip("样本外夏普", PriceFormatter.ratio(assessment.outOfSampleSharpe))
                    statChip("样本外效率", PriceFormatter.ratio(assessment.outOfSampleEfficiency))
                    statChip("窗口一致性", PriceFormatter.percent(assessment.windowAgreement * 100))
                }
                ForEach(assessment.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(Theme.Text.caption).foregroundStyle(.secondary)
                }
                if let coverage = report.coverageNote {
                    Label(coverage, systemImage: "clock.badge.exclamationmark")
                        .font(Theme.Text.caption).foregroundStyle(Theme.warning)
                }
            }
        }
    }

    private func tradeList(_ result: BacktestResult) -> some View {
        Card(title: "回测成交", subtitle: "最近 \(min(result.trades.count, 40)) 笔，共 \(result.trades.count) 笔") {
            DataGrid(columns: [
                GridColumn(title: "方向"), GridColumn(title: "入场", alignment: .trailing),
                GridColumn(title: "出场", alignment: .trailing), GridColumn(title: "收益", alignment: .trailing),
                GridColumn(title: "持仓"), GridColumn(title: "离场原因"),
            ], rows: Array(result.trades.suffix(40).reversed())) { trade in
                GridText(trade.direction.displayName, tint: Theme.trend(trade.direction == .long), weight: .semibold, fit: true)
                GridText(PriceFormatter.auto(trade.entryPrice), mono: true, alignment: .trailing)
                GridText(PriceFormatter.auto(trade.exitPrice), mono: true, alignment: .trailing)
                GridText(PriceFormatter.signedPercent(trade.returnPct), tint: Theme.signed(trade.netPnL), mono: true, alignment: .trailing)
                GridText("\(trade.bars) 根", tint: .secondary, fit: true)
                GridText(trade.exitReason.displayName, tint: trade.exitReason == .liquidation ? Theme.down : .secondary, fit: true)
            }
        }
    }

    // MARK: Position tab

    @ViewBuilder
    private var positionTab: some View {
        let position = appState.ledger.position(for: strategy.id)
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            if !appState.tradingReady {
                InlineNotice(kind: .warning, message: (appState.tradingBlocker ?? "交易尚未就绪") + "：回测可用，实际下单需要先配置 okx CLI。",
                             actionTitle: "账户与连接", action: { appState.openTerminal(.account) })
            }
            if let reason = allocation?.haltReason, !(allocation?.running ?? false) {
                InlineNotice(kind: .warning, title: "上次自动停止", message: reason + "\n重新开始前请先确认原因已消除。")
            }

            Card(title: "当前持仓", subtitle: "\(appState.tradingMode.displayName)台账 · \(strategy.market.instId)") {
                EmptyView()
            } content: {
                if let position, !position.isFlat {
                    let mark = appState.mark(for: position.instId)
                    let isOption = position.optionKind != nil
                    if isOption {
                        // The contract is not the market the strategy watches,
                        // so it has to be named; the premium is booked in quote
                        // currency per unit of underlying, which is what the
                        // 均价 / 现价 tiles show.
                        Text(position.instId).font(Theme.Text.mono).foregroundStyle(.secondary)
                    }
                    HStack(spacing: Theme.itemSpacing) {
                        StatTile(label: "方向", value: position.signalDirection?.displayName ?? "—",
                                 tint: Theme.trend(position.signalDirection == .long))
                        StatTile(label: "数量", value: PriceFormatter.plain(abs(position.baseQuantity)),
                                 caption: position.contractSizeIsKnown ? nil : "合约面值未知")
                        StatTile(label: isOption ? "权利金均价" : "均价", value: PriceFormatter.auto(position.averagePrice))
                        StatTile(label: isOption ? "权利金标记" : "现价", value: mark.map(PriceFormatter.auto) ?? "—")
                        StatTile(label: "浮动盈亏", value: PriceFormatter.signedMoney(position.unrealisedPnL(mark: mark)),
                                 tint: Theme.signed(position.unrealisedPnL(mark: mark)))
                    }
                } else {
                    Text("空仓").font(Theme.Text.secondary).foregroundStyle(.tertiary)
                }
                HStack(spacing: Theme.itemSpacing) {
                    StatTile(label: "已实现", value: PriceFormatter.signedMoney(position?.realisedPnL ?? 0), tint: Theme.signed(position?.realisedPnL ?? 0))
                    StatTile(label: "累计手续费", value: PriceFormatter.money(position?.feesPaid ?? 0))
                    if let funding = position?.fundingPaid, funding != 0 {
                        StatTile(label: "资金费", value: PriceFormatter.signedMoney(funding), tint: Theme.signed(funding),
                                 help: "与已实现盈亏分开列出：永续只因资金费亏钱，和因进出场亏钱是两种不同的诊断。")
                    }
                    StatTile(label: "净盈亏", value: PriceFormatter.signedMoney(appState.netPnL(for: strategy.id)), tint: Theme.signed(appState.netPnL(for: strategy.id)))
                    StatTile(label: "收益率", value: appState.returnPct(for: strategy.id).map(PriceFormatter.signedPercent) ?? "—",
                             tint: Theme.signed(appState.returnPct(for: strategy.id) ?? 0))
                    StatTile(label: "成交笔数", value: "\(position?.fillCount ?? 0)")
                }
            }

            reconciliationPanel
            LiveVsBacktestPanel(appState: appState, strategy: strategy)

            let fills = appState.ledger.fills(for: strategy.id, limit: 50)
            Card(title: "成交明细", subtitle: fills.isEmpty ? "还没有成交记录" : "最近 \(fills.count) 笔") {
                DataGrid(columns: [
                    GridColumn(title: "时间"), GridColumn(title: "操作"), GridColumn(title: "价格", alignment: .trailing),
                    GridColumn(title: "数量", alignment: .trailing), GridColumn(title: "手续费", alignment: .trailing),
                    GridColumn(title: "兑现净益", alignment: .trailing), GridColumn(title: "订单标签"),
                ], rows: fills, emptyText: "还没有成交记录") { fill in
                    GridText(Format.stamp(fill.ts), tint: .secondary, mono: true, fit: true)
                    // 开仓/平仓，不是买入/卖出：空头账本里「卖出」是建仓。
                    GridText(fill.actionLabel, tint: Theme.trend(fill.side == .buy), weight: .medium, fit: true)
                    GridText(PriceFormatter.auto(fill.price), mono: true, alignment: .trailing)
                    GridText(PriceFormatter.plain(fill.quantity), mono: true, alignment: .trailing)
                    GridText(PriceFormatter.money(fill.feeQuote, decimals: 4), mono: true, alignment: .trailing)
                    GridText(fill.netRealisedQuote.map { PriceFormatter.signedMoney($0, decimals: 4) } ?? "—",
                             tint: fill.netRealisedQuote.map(Theme.signed) ?? .secondary, mono: true, alignment: .trailing)
                    GridText(fill.clOrdId ?? "—", tint: .secondary, mono: true, fit: true)
                }
            }
        }
    }

    @ViewBuilder
    private var reconciliationPanel: some View {
        // The instrument the book actually holds — for an option strategy
        // that is the contract, not the market its signals read.
        let held = appState.ledger.position(for: strategy.id)?.instId ?? strategy.market.instId
        let rows = appState.reconciliationIssues.filter { $0.instId == held }
        if let row = rows.first {
            InlineNotice(kind: .warning, title: "交易所持仓与台账不一致",
                         message: "台账 \(PriceFormatter.plain(row.ledgerQuantity)) · 交易所 \(PriceFormatter.plain(row.exchangeQuantity)) · 未归因 \(PriceFormatter.signedMoney(row.unattributed, decimals: 6))\n差额通常来自手动下单或其它程序；策略只会调整自己台账内的仓位。")
        }
    }

    // MARK: Definition tab

    private var definitionTab: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            if !strategy.manifest.params.isEmpty {
                Card(title: "参数", subtitle: "\(strategy.freeParameterCount) 个自由参数 → 稳健性阈值 \(strategy.freeParameterCount * 30) 笔交易 · 修改会重写清单并使回测失效") {
                    VStack(spacing: 6) {
                        ForEach(strategy.manifest.params.items) { parameter in
                            ParameterRow(appState: appState, strategy: strategy, parameter: parameter)
                        }
                    }
                }
            }

            Card(title: "信号") {
                signalRow("做多入场", strategy.manifest.signals.longEntry)
                signalRow("做多离场", strategy.manifest.signals.longExit)
                signalRow("做空入场", strategy.manifest.signals.shortEntry)
                signalRow("做空离场", strategy.manifest.signals.shortExit)
                if let exposure = strategy.manifest.signals.exposure {
                    signalRow("目标敞口", exposure)
                }
            }

            Card(title: "仓位与风控") {
                let risk = strategy.manifest.risk
                let costs = strategy.manifest.effectiveCosts(
                    under: appState.store.config.strategy.feeSchedules)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 6) {
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
                    definitionCell("最长持仓", risk.maxHoldBars.map { "\($0) 根" } ?? "—")
                    definitionCell("日内熔断", risk.maxDailyLossPct.map { PriceFormatter.percent($0, decimals: 1) } ?? "—")
                    definitionCell("手续费假设", costs?.fees.summary ?? "无费率模型")
                    definitionCell("滑点假设",
                                   costs.map { "\(PriceFormatter.plain($0.slippageBps)) bps" } ?? "—")
                    definitionCell("指标预热", "\(strategy.warmupBars) 根")
                }
            }

            if strategy.isOptionStrategy {
                let spec = strategy.optionsSpec
                Card(title: "期权合约") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 6) {
                        definitionCell("标的指数", spec.resolvedUnderlying(for: strategy.market))
                        definitionCell("最短到期", "≥ \(PriceFormatter.plain(spec.minDaysToExpiry)) 天")
                        definitionCell("行权价偏移", "\(PriceFormatter.plain(spec.moneynessPct))%（正为价外）")
                        definitionCell("隐含波动 / 实现波动", "×\(PriceFormatter.plain(spec.impliedVolMultiplier))")
                        definitionCell("手续费上限", "权利金的 \(PriceFormatter.plain(spec.feeCapPctOfPremium))%")
                    }
                }
                InlineNotice(kind: .warning, message: "做多信号买入看涨、做空信号买入看跌，只买不卖，最大亏损即权利金。回测按 Black–Scholes 用标的实现波动率 × 上面的倍数定价 —— 是模型定价，不是历史成交价；止损止盈按权利金百分比、在收盘判定；到期按内在价值结算。实盘读交易所真实盘口，以 IOC 限价单成交；权利金以结算币支付，账户须持有或能借到。")
            } else {
                InlineNotice(kind: .info, message: "回测按「本根收盘出信号、下根开盘成交」撮合，进出各收一次手续费并叠加滑点；同一根 K 线同时触及止损与止盈时按止损先成交计算。")
            }
        }
    }

    private func signalRow(_ label: String, _ source: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(Theme.Text.secondary).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(source ?? "—")
                .font(Theme.Text.mono)
                .textSelection(.enabled)
                .foregroundStyle(source == nil ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .rowStyle()
    }

    private func definitionCell(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.Text.caption).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(value).font(Theme.Text.secondaryMedium).numeric()
        }
        .rowStyle(padding: 7)
    }

    // MARK: Action bar

    private var actionBar: some View {
        let portfolio = appState.store.config.strategy
        let capital = allocation?.capital ?? 0
        let headroom = portfolio.capitalHeadroom(for: strategy.id)
        let running = allocation?.running ?? false

        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("分配预算").font(Theme.Text.heading)
                    Text("\(PriceFormatter.money(capital, decimals: 0)) \(portfolio.quoteCurrency)")
                        .font(Theme.Text.bodyMedium).numeric().foregroundStyle(Theme.accent)
                    Text("· 可用上限 \(PriceFormatter.money(headroom, decimals: 0))")
                        .font(Theme.Text.caption).foregroundStyle(.tertiary).numeric()
                }
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { min(capital, max(headroom, 0.0001)) },
                            set: { appState.setCapital($0, for: strategy.id) }),
                        in: 0...max(headroom, 0.0001))
                    .controlSize(.small)
                    .disabled(running || headroom <= 0)
                    CommitTextField(placeholder: "0", value: PriceFormatter.plain(capital.rounded()), width: 80) { text in
                        if let value = Double(text) { appState.setCapital(value, for: strategy.id) }
                    }
                    .disabled(running)
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

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    ModeBadge(mode: appState.tradingMode, size: .small)
                    startStopButtons(running: running, capital: capital)
                }
                Text(runtimeSummary).font(Theme.Text.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private func startStopButtons(running: Bool, capital: Double) -> some View {
        if running {
            Button("结束交易") { appState.stopStrategy(id: strategy.id) }
            Button("平仓") { appState.requestFlatten(strategyId: strategy.id) }
                .disabled(appState.ledger.position(for: strategy.id)?.isFlat ?? true)
                .help("市价平掉本策略当前持仓")
        } else {
            Button {
                appState.requestStartStrategy(id: strategy.id)
            } label: {
                Label(appState.tradingMode.isDemo ? "开始交易" : "在实盘开始交易", systemImage: "play.fill")
            }
            .buttonStyle(ProminentButtonStyle(tint: appState.tradingMode.isDemo ? Theme.up : Theme.down))
            .disabled(capital <= 0 || !appState.tradingReady || appState.store.config.strategy.emergencyStop)
            .help(capital <= 0 ? "先分配预算"
                  : appState.store.config.strategy.emergencyStop ? "急停中，先解除急停"
                  : (appState.tradingReady ? "按 \(strategy.market.bar.rawValue) 收盘评估信号并自动下单" : (appState.tradingBlocker ?? "")))
            if !(appState.ledger.position(for: strategy.id)?.isFlat ?? true) {
                Button("平仓") { appState.requestFlatten(strategyId: strategy.id) }
                    .help("策略已停止但仍有持仓：市价平掉")
            }
        }
    }

    private var runtimeSummary: String {
        let state = runtime
        if let message = state.message { return "\(state.status.displayName) · \(message)" }
        if let bar = state.lastBarTime {
            return "\(state.status.displayName) · 最新 K 线 " + bar.formatted(date: .omitted, time: .shortened)
        }
        return state.status.displayName
    }

    // MARK: Small pieces

    private func legendSwatch(_ color: Color, _ label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: dashed ? 6 : 12, height: 2)
            Text(label).font(Theme.Text.caption).foregroundStyle(.secondary)
        }
    }

    private func statChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.Text.caption).foregroundStyle(.secondary)
            Text(value).font(Theme.Text.secondaryMedium).numeric()
        }
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

    var body: some View {
        HStack(spacing: 10) {
            Text(parameter.displayLabel).font(Theme.Text.body).frame(width: 110, alignment: .leading)
            if let lower = parameter.minimum, let upper = parameter.maximum, upper > lower {
                Slider(value: Binding(get: { parameter.value }, set: { commit($0) }),
                       in: lower...upper, step: parameter.step ?? (upper - lower > 20 ? 1 : 0.1))
                    .controlSize(.small)
            } else {
                Spacer()
            }
            CommitTextField(placeholder: "", value: PriceFormatter.plain(parameter.value), width: 72) { text in
                if let value = Double(text) { commit(value) }
            }
            Text(parameter.name).font(Theme.Text.mono).foregroundStyle(.tertiary).frame(width: 90, alignment: .leading)
        }
        .rowStyle(padding: 6)
    }

    private func commit(_ value: Double) {
        var manifest = strategy.manifest
        manifest.params.setValue(value, for: parameter.name)
        guard manifest != strategy.manifest else { return }
        appState.saveStrategy(manifest)
    }
}
