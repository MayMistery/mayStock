import SwiftUI
import MayStockKit

/// The first thing the window shows: what the account is worth, how it got
/// there, what it holds, and anything the engine wants a human to know.
struct OverviewPage: View {
    let appState: AppState
    @Bindable var selection: TerminalSelection

    private var mode: TradingMode { appState.tradingMode }

    var body: some View {
        pageBody
            // Whatever brought the page up, the book on it must be current.
            .onAppear { appState.refreshAccountIfStale(maxAge: 60) }
    }

    private var pageBody: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                PageHeader(title: "总览",
                           subtitle: "\(mode.displayName)账户 · 账户读数 " + Format.relative(appState.accountRefreshedAt)) {
                    Button {
                        Task { await appState.refreshAccount() }
                    } label: {
                        Label("刷新账户", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(appState.isRefreshingAccount)
                }

                notices
                statsRow
                equityCard

                HStack(alignment: .top, spacing: Theme.sectionSpacing) {
                    positionsCard.frame(maxWidth: .infinity)
                    strategiesCard.frame(width: 360)
                }

                ordersCard

                HStack(alignment: .top, spacing: Theme.sectionSpacing) {
                    balancesCard.frame(width: 400)
                    fillsCard.frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.pagePadding)
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        let engine = appState.engineNotices
        if !engine.isEmpty || connectionFailure != nil || appState.accountError != nil {
            VStack(spacing: 8) {
                ForEach(Array(engine.enumerated()), id: \.offset) { _, notice in
                    InlineNotice(kind: notice.kind == .heartbeat ? .danger : .warning,
                                 title: title(for: notice.kind), message: notice.text,
                                 actionTitle: notice.kind == .emergencyStop ? "解除急停" : nil,
                                 action: notice.kind == .emergencyStop ? { appState.clearEmergencyStop() } : nil)
                }
                if let failure = connectionFailure {
                    InlineNotice(kind: .danger, title: "\(mode.displayName)连接失败", message: failure,
                                 actionTitle: "账户与连接", action: { appState.openTerminal(.account) })
                } else if let error = appState.accountError {
                    InlineNotice(kind: .warning, title: "读取账户失败", message: error,
                                 actionTitle: "账户与连接", action: { appState.openTerminal(.account) })
                }
            }
        }
    }

    private var connectionFailure: String? {
        if case .failed(let message, let hint, _) = appState.connectionStatus(for: mode) {
            return [message, hint].compactMap { $0 }.joined(separator: "\n")
        }
        return nil
    }

    private func title(for kind: AppState.EngineNoticeKind) -> String {
        switch kind {
        case .heartbeat: return "交易循环失联"
        case .emergencyStop: return "急停中"
        case .overCommitted: return "持仓超出账户可支撑"
        case .protection: return "保护性熔断已触发"
        case .overAllocated: return "预算超配"
        }
    }

    // MARK: Stats

    private var statsRow: some View {
        HStack(spacing: Theme.itemSpacing) {
            StatTile(label: "账户权益 · \(appState.runner.quoteCurrency)",
                     value: Format.money(appState.accountEquity),
                     caption: appState.nonStableExposurePct.map {
                         "非稳定币敞口 \(PriceFormatter.decimals($0, 1))%"
                             + (appState.runner.exposureIsComplete ? "" : "*")
                     } ?? (appState.tradingBlocker ?? "等待引擎采样"),
                     captionTint: riskTint,
                     help: appState.runner.exposureIsComplete
                         ? "现货币种持仓 + 交易所上全部衍生品名义额（含非 MayStock 开的仓），占账户权益的比例。做空同样计入敞口。"
                         : "* 部分持仓未能从交易所读到或无法估值，实际敞口只会更高。现货币种持仓 + 衍生品名义额，占账户权益的比例。")
            StatTile(label: "账本盈亏 · 已实现 + 浮动",
                     value: Format.signedMoney(appState.openPnL),
                     tint: appState.openPnL.map(Theme.signed) ?? .secondary,
                     caption: appState.openPnLPct.map { "占已动用预算 " + PriceFormatter.signedPercent($0) }
                         ?? "扣手续费与资金费",
                     help: "本账户台账上每个策略的已实现盈亏加当前持仓的浮动盈亏，扣除手续费与资金费。不依赖权益历史。")
            StatTile(label: "浮动盈亏 · 交易所标记",
                     value: Format.signedMoney(appState.exchangeUnrealisedPnL),
                     tint: appState.exchangeUnrealisedPnL.map(Theme.signed) ?? .secondary,
                     caption: appState.exchangeUnrealisedPnL == nil ? "等待账户读数" : "\(appState.exchangePositions.count) 个持仓 · upl",
                     help: "交易所对当前全部持仓（含非 MayStock 开的）按标记价算出的未实现盈亏之和。")
            ForEach(EquityWindow.allCases) { window in
                windowTile(window)
            }
        }
    }

    private var riskTint: Color {
        switch appState.nonStableExposurePct ?? 0 {
        case ..<25: return .secondary
        case ..<75: return Theme.warning
        default: return Theme.down
        }
    }

    /// What the exchange's bills say the window realised — its figure, not
    /// this app's. See `BilledPnL` for why there is no other period figure.
    private func windowTile(_ window: EquityWindow) -> some View {
        let billed = appState.billedPnL(window)
        let tint: Color = billed.map { Theme.signed($0.total) } ?? .secondary
        var caption = billed.map { "已实现 · \($0.billCount) 条账单" }
            ?? (appState.billsError == nil ? "等待账单" : "账单读取失败")
        if let billed, !billed.coversWindow { caption += " · 账单未翻到起点" }
        return StatTile(label: (window.longLabel.components(separatedBy: "（").first ?? window.label) + " · 账单",
                        value: Format.signedMoney(billed?.total, decimals: 0),
                        tint: tint,
                        caption: caption,
                        captionTint: billed?.coversWindow == false ? Theme.warning : .secondary,
                        help: tooltip(window, billed))
    }

    private func tooltip(_ window: EquityWindow, _ billed: BilledPnL?) -> String {
        let head = "\(window.longLabel) · OKX 账单口径"
        guard let billed else { return head + "\n" + (appState.billsError ?? "还没有读到账单") }
        var lines = [
            head,
            "平仓盈亏 \(PriceFormatter.signedMoney(billed.closedTradePnL)) · 资金费 \(PriceFormatter.signedMoney(billed.funding))"
                + " · 手续费 \(PriceFormatter.signedMoney(billed.fees))"
                + (billed.interest != 0 ? " · 利息 \(PriceFormatter.signedMoney(billed.interest))" : ""),
        ]
        if !billed.coversWindow, let oldest = appState.exchangeBills?.oldestBillAt {
            lines.append("* 账单只翻到 \(Format.stamp(oldest))，更早的没算进来")
        }
        lines.append("OKX 的 API 不提供分时段盈亏和权益历史（App 里的今日收益是其服务端算的）；浮动盈亏见左侧，按交易所标记价。")
        return lines.joined(separator: "\n")
    }

    // MARK: Equity

    private var equityCard: some View {
        Card(title: "账户权益曲线", subtitle: coverageSubtitle) {
            PillSegments(
                segments: EquityWindow.allCases.map {
                    PillSegments<EquityWindow>.Segment(value: $0, title: $0.label, help: $0.longLabel)
                },
                selection: selection.equityWindow,
                onSelect: { selection.equityWindow = $0 })
        } content: {
            AccountEquityChartView(
                points: appState.equityCurve.points,
                window: selection.equityWindow,
                latest: appState.accountEquity)
            .frame(height: 220)
        }
    }

    private var coverageSubtitle: String {
        let curve = appState.equityCurve
        guard let oldest = curve.oldest else { return "\(mode.displayName) · 尚无采样" }
        var text = "\(mode.displayName) · 记录自 \(Format.shortDate(oldest.ts)) · \(curve.points.count) 个样本"
        if let change = appState.equityChange(selection.equityWindow), !change.coverageNote.isEmpty {
            text += " · " + change.coverageNote
        }
        return text
    }

    // MARK: Positions

    private var positionsCard: some View {
        Card(title: "持仓", subtitle: "\(mode.displayName)台账 · 按名义额排序") {
            Button("策略") { appState.openTerminal(.strategies) }.controlSize(.small)
        } content: {
            let positions = appState.openPositions
            ForEach(appState.reconciliationIssues) { issue in
                InlineNotice(kind: .warning, title: "\(issue.instId) 台账与交易所不一致",
                             message: "台账 \(PriceFormatter.plain(issue.ledgerQuantity)) · 交易所 \(PriceFormatter.plain(issue.exchangeQuantity)) · 未归因 \(PriceFormatter.signedMoney(issue.unattributed, decimals: 6))。差额通常来自手动下单或其它程序；策略只调整自己台账内的仓位。")
            }
            DataGrid(columns: [
                GridColumn(title: "策略"), GridColumn(title: "标的"), GridColumn(title: "方向"),
                GridColumn(title: "数量", alignment: .trailing), GridColumn(title: "均价", alignment: .trailing),
                GridColumn(title: "现价", alignment: .trailing), GridColumn(title: "盈亏", alignment: .trailing),
                GridColumn(title: "收益率", alignment: .trailing),
            ], rows: positions, emptyText: appState.strategies.isEmpty ? "还没有策略" : "空仓") { position in
                let mark = appState.mark(for: position.instId)
                let pnl = position.netPnL(mark: mark)
                let capital = appState.store.config.strategy.allocation(for: position.strategyId)?.capital ?? 0
                let pct = position.returnPct(mark: mark, capital: capital)
                GridText(appState.strategy(id: position.strategyId)?.name ?? position.strategyId, weight: .medium)
                GridText(position.instId, tint: .secondary, mono: true, fit: true)
                GridText(position.direction?.displayName ?? "—", tint: Theme.trend(position.quantity > 0), weight: .semibold, fit: true)
                GridText(PriceFormatter.plain(abs(position.baseQuantity)), mono: true, alignment: .trailing)
                GridText(PriceFormatter.auto(position.averagePrice), mono: true, alignment: .trailing)
                GridText(mark.map(PriceFormatter.auto) ?? "—", mono: true, alignment: .trailing)
                GridText(PriceFormatter.signedMoney(pnl), tint: Theme.signed(pnl), mono: true, alignment: .trailing)
                GridText(pct.map(PriceFormatter.signedPercent) ?? "—", tint: Theme.signed(pct ?? 0), mono: true, alignment: .trailing)
            }
            externalPositionsGrid
        }
    }

    /// What the exchange holds that no strategy's book does. Listed, not
    /// alarmed about: there is nothing for the book to be wrong about, but a
    /// 10× long opened by hand is the account's risk all the same.
    @ViewBuilder
    private var externalPositionsGrid: some View {
        let external = appState.externalPositions
        if !external.isEmpty {
            Text("交易所持仓 · 非 MayStock 策略开仓（手动、其它程序，或本机安装前就有）")
                .font(Theme.Text.caption).foregroundStyle(.secondary).padding(.top, 6)
            DataGrid(columns: [
                GridColumn(title: "标的"), GridColumn(title: "族"), GridColumn(title: "方向"),
                GridColumn(title: "张数", alignment: .trailing), GridColumn(title: "均价", alignment: .trailing),
                GridColumn(title: "标记价", alignment: .trailing), GridColumn(title: "名义额", alignment: .trailing),
                GridColumn(title: "未实现", alignment: .trailing), GridColumn(title: "杠杆", alignment: .trailing),
            ], rows: external) { position in
                GridText(position.instId, mono: true, weight: .medium, fit: true)
                GridText(position.familyLabel, tint: .secondary, fit: true)
                GridText(position.quantity > 0 ? "多" : "空", tint: Theme.trend(position.quantity > 0), weight: .semibold, fit: true)
                GridText(PriceFormatter.plain(abs(position.quantity)), mono: true, alignment: .trailing)
                GridText(PriceFormatter.auto(position.averagePrice), mono: true, alignment: .trailing)
                GridText(position.markPrice.map(PriceFormatter.auto) ?? "—", mono: true, alignment: .trailing)
                GridText(position.notionalUsd.map { PriceFormatter.money($0, decimals: 0) } ?? "—", mono: true, alignment: .trailing)
                GridText(PriceFormatter.signedMoney(position.unrealisedPnL), tint: Theme.signed(position.unrealisedPnL), mono: true, alignment: .trailing)
                GridText(position.leverage.map { "\(PriceFormatter.decimals($0, 0))×" } ?? "—", mono: true, alignment: .trailing)
            }
        }
    }

    // MARK: Open orders

    /// Everything the exchange is holding open on this account — resting
    /// limits and armed stops alike — and who placed each: a strategy of ours
    /// by its tag, otherwise "外部".
    private var ordersCard: some View {
        Card(title: "挂单", subtitle: "交易所当前挂着的 · 普通委托 + 策略委托（止盈止损、计划、移动止损）· 最新在前") {
            EmptyView()
        } content: {
            if let error = appState.openOrdersError {
                InlineNotice(kind: .danger, title: "挂单读取失败", message: error)
            } else if let note = appState.openOrdersNote {
                InlineNotice(kind: .warning, title: "挂单列表不完整", message: note)
            }
            DataGrid(columns: [
                GridColumn(title: "时间"), GridColumn(title: "标的"), GridColumn(title: "类型"), GridColumn(title: "方向"),
                GridColumn(title: "价格", alignment: .trailing), GridColumn(title: "触发价", alignment: .trailing),
                GridColumn(title: "数量", alignment: .trailing), GridColumn(title: "已成交", alignment: .trailing),
                GridColumn(title: "来源"),
            ], rows: appState.openOrders,
               emptyText: appState.openOrdersError == nil ? "交易所上没有挂单" : "—") { order in
                GridText(order.createdAt.map(Format.stamp) ?? "—", tint: .secondary, mono: true, fit: true)
                GridText(order.instId, mono: true, fit: true)
                GridText(order.kindLabel, weight: .medium, fit: true)
                GridText(Self.directionLabel(order), tint: Theme.trend(order.side == .buy), weight: .semibold, fit: true)
                GridText(order.price.map(PriceFormatter.auto) ?? "市价", mono: true, alignment: .trailing)
                GridText(order.triggerPrice.map(PriceFormatter.auto) ?? "—", mono: true, alignment: .trailing)
                GridText(Self.sizeLabel(order), mono: true, alignment: .trailing)
                GridText(order.filledSize > 0 ? PriceFormatter.plain(order.filledSize) : "—", mono: true, alignment: .trailing)
                GridText(appState.orderSource(order), tint: .secondary, fit: true)
            }
        }
    }

    /// "卖出平多", "买入开空", or plain "买入" on a market without legs.
    static func directionLabel(_ order: ExchangeOpenOrder) -> String {
        let action = order.side == .buy ? "买入" : "卖出"
        guard let posSide = order.posSide, posSide != .net else {
            return order.reduceOnly ? action + "·只减仓" : action
        }
        return action + (order.reduceOnly ? "平" : "开") + (posSide == .long ? "多" : "空")
    }

    static func sizeLabel(_ order: ExchangeOpenOrder) -> String {
        if let size = order.size { return PriceFormatter.plain(size) }
        if let fraction = order.closeFraction {
            return fraction >= 1 ? "全平" : "平 \(PriceFormatter.decimals(fraction * 100, 0))%"
        }
        return "—"
    }

    // MARK: Strategies

    private var strategiesCard: some View {
        let portfolio = appState.store.config.strategy
        return Card(title: "策略",
                    subtitle: "运行中 \(portfolio.runningCount)/\(appState.strategies.count) · 已分配 \(PriceFormatter.money(portfolio.allocatedCapital, decimals: 0)) / \(PriceFormatter.money(portfolio.totalCapital, decimals: 0)) \(portfolio.quoteCurrency)") {
            EmptyView()
        } content: {
            if appState.strategies.isEmpty {
                Text("还没有策略。到「策略」页导入一份清单。").font(Theme.Text.secondary).foregroundStyle(.tertiary)
            }
            VStack(spacing: 4) {
                ForEach(appState.strategies, id: \.id) { strategy in
                    strategyRow(strategy)
                }
            }
        }
    }

    private func strategyRow(_ strategy: CompiledStrategy) -> some View {
        let allocation = appState.store.config.strategy.allocation(for: strategy.id)
        let state = appState.runner.state(for: strategy.id)
        let running = allocation?.running ?? false
        return HStack(spacing: 8) {
            StatusDot(color: statusColor(state.status, running: running))
            VStack(alignment: .leading, spacing: 1) {
                Text(strategy.name).font(Theme.Text.bodyMedium).lineLimit(1)
                Text(runtimeLine(state, allocation: allocation))
                    .font(Theme.Text.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let pct = appState.returnPct(for: strategy.id) {
                Text(PriceFormatter.signedPercent(pct))
                    .font(Theme.Text.captionMedium).numeric().foregroundStyle(Theme.signed(pct))
            }
            Button(running ? "停止" : "开始") {
                running ? appState.stopStrategy(id: strategy.id) : appState.requestStartStrategy(id: strategy.id)
            }
            .controlSize(.mini)
            .disabled(!running && (allocation?.capital ?? 0) <= 0)
        }
        .rowStyle(padding: 8)
        .contentShape(Rectangle())
        .onTapGesture { appState.openTerminal(.strategies, strategyId: strategy.id) }
    }

    private func runtimeLine(_ state: StrategyRuntimeState, allocation: StrategyAllocation?) -> String {
        var parts: [String] = []
        if let allocation, allocation.capital > 0 {
            parts.append("预算 " + PriceFormatter.money(allocation.capital, decimals: 0))
        } else {
            parts.append("未分配")
        }
        if let reason = allocation?.haltReason, !(allocation?.running ?? false) {
            parts.append("停止：" + reason)
        } else {
            parts.append(state.status.displayName + (state.message.map { " · \($0)" } ?? ""))
        }
        return parts.joined(separator: " · ")
    }

    private func statusColor(_ status: StrategyRuntimeState.Status, running: Bool) -> Color {
        switch status {
        case .running: return Theme.up
        case .warmingUp: return Theme.accent
        case .halted: return Theme.warning
        case .failed: return Theme.down
        case .stopped: return running ? Theme.accent : Color.secondary.opacity(0.4)
        }
    }

    // MARK: Balances & fills

    private var balancesCard: some View {
        Card(title: "交易所余额", subtitle: appState.accountBalances.isEmpty ? "尚未读取" : "okx account balance-all") {
            EmptyView()
        } content: {
            DataGrid(columns: [
                GridColumn(title: "币种"), GridColumn(title: "总额", alignment: .trailing),
                GridColumn(title: "可用", alignment: .trailing), GridColumn(title: "估值 USD", alignment: .trailing),
            ], rows: appState.accountBalances.sorted { ($0.valuationUsd ?? 0) > ($1.valuationUsd ?? 0) },
               emptyText: appState.accountError ?? "读取账户后显示") { balance in
                GridText(balance.ccy, weight: .medium, fit: true)
                GridText(PriceFormatter.plain(balance.total), mono: true, alignment: .trailing)
                GridText(PriceFormatter.plain(balance.available), mono: true, alignment: .trailing)
                GridText(balance.valuationUsd.map { PriceFormatter.money($0, decimals: 0) } ?? "—",
                         mono: true, alignment: .trailing)
            }
        }
    }

    private var fillsCard: some View {
        Card(title: "最近成交", subtitle: "\(mode.displayName) · 最近 12 笔") {
            EmptyView()
        } content: {
            DataGrid(columns: [
                GridColumn(title: "时间"), GridColumn(title: "策略"), GridColumn(title: "操作"),
                GridColumn(title: "价格", alignment: .trailing), GridColumn(title: "数量", alignment: .trailing),
                GridColumn(title: "净益", alignment: .trailing),
            ], rows: appState.recentFills(limit: 12), emptyText: "还没有成交记录") { fill in
                GridText(Format.stamp(fill.ts), tint: .secondary, mono: true, fit: true)
                GridText(appState.strategy(id: fill.strategyId)?.name ?? fill.strategyId)
                GridText(fill.actionLabel, tint: Theme.trend(fill.side == .buy), weight: .medium, fit: true)
                GridText(PriceFormatter.auto(fill.price), mono: true, alignment: .trailing)
                GridText(PriceFormatter.plain(fill.quantity), mono: true, alignment: .trailing)
                GridText(fill.netRealisedQuote.map { PriceFormatter.signedMoney($0) } ?? "—",
                         tint: fill.netRealisedQuote.map(Theme.signed) ?? .secondary, mono: true, alignment: .trailing)
            }
        }
    }
}
