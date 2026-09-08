import SwiftUI
import MayStockKit

/// Account equity, trailing returns, and this instrument's strategy positions —
/// all read-only.
///
/// The panel deliberately has no order entry and no account switch. Trading
/// happens through strategies in the terminal, where a position is always
/// attached to a rule and a budget; a hover panel is the wrong place to put
/// money at risk on impulse.
struct PanelAccountStrip: View {
    let appState: AppState
    let instId: String

    private var mode: TradingMode { appState.tradingMode }
    /// The asset the panel is scoped to, on the instrument's own venue.
    private var panelUnderlying: String {
        AppState.underlying(instId, venue: appState.venue(of: instId))
    }

    /// Strategies holding this *underlying*, with their live P&L.
    ///
    /// Matching is by underlying rather than by exact `instId`: a short on
    /// `BTC-USDT-SWAP` is a BTC position and belongs on the BTC panel, even
    /// though the watchlist tracks spot `BTC-USDT`.
    private var holdings: [StrategyPositionState] {
        appState.ledger.positions.values
            .filter { AppState.underlying($0.instId, venue: $0.venue) == panelUnderlying && !$0.isFlat }
            .sorted { abs($0.quantity) > abs($1.quantity) }
    }

    /// Positions the portfolio holds on some *other* underlying, so nothing is
    /// ever silently invisible just because the panel is scoped to one symbol.
    private var elsewhere: [StrategyPositionState] {
        appState.ledger.positions.values
            .filter { AppState.underlying($0.instId, venue: $0.venue) != panelUnderlying && !$0.isFlat }
            .sorted { $0.instId < $1.instId }
    }

    /// Exchange positions on this underlying that no strategy's book holds —
    /// opened by hand or by another program. The panel is the account's
    /// window, so they belong on it as much as the strategies' own.
    private var externalHere: [ExchangePosition] {
        appState.externalPositions.filter {
            AppState.underlying($0.instId, venue: appState.venue(of: $0.instId)) == panelUnderlying
        }
    }

    private var externalElsewhere: [ExchangePosition] {
        appState.externalPositions
            .filter { AppState.underlying($0.instId, venue: appState.venue(of: $0.instId)) != panelUnderlying }
            .sorted { $0.instId < $1.instId }
    }

    /// Orders the exchange holds on this underlying, whoever placed them.
    private var ordersHere: [ExchangeOpenOrder] {
        appState.openOrders.filter {
            AppState.underlying($0.instId, venue: appState.venue(of: $0.instId)) == panelUnderlying
        }
    }

    /// One line: what is armed here, and how much is armed elsewhere.
    private var ordersSummary: String? {
        let here = ordersHere
        let elsewhere = appState.openOrders.count - here.count
        var parts: [String] = here.prefix(3).map { order in
            let level = (order.triggerPrice ?? order.price).map(PriceFormatter.auto) ?? "市价"
            return "\(order.kindLabel) \(order.side == .buy ? "买" : "卖") @ \(level)"
        }
        if here.count > 3 { parts.append("另 \(here.count - 3) 笔") }
        if elsewhere > 0 { parts.append("其它标的 \(elsewhere) 笔") }
        guard !parts.isEmpty else { return nil }
        return "挂单 · " + parts.joined(separator: " · ")
    }

    private var runningHere: Int {
        appState.strategies
            .filter { AppState.underlying($0.market.instId, venue: $0.market.venue) == panelUnderlying }
            .filter { appState.store.config.strategy.allocation(for: $0.id)?.running == true }
            .count
    }

    var body: some View {
        VStack(spacing: 8) {
            equityRow
            if appState.openPnL != nil { currentPnLRow }
            returnsRow
            exchangePnLRow
            notice
            Divider().opacity(0.35)
            positionsBlock
        }
        .padding(10)
        .background(Theme.rowFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.mode(mode).opacity(0.25), lineWidth: 1))
        // A hover is not a button press: the panel shows what it has and only
        // asks the exchange again when that is minutes old.
        .onAppear { appState.refreshAccountIfStale(maxAge: AppState.accountRefreshInterval) }
    }

    // MARK: Equity

    private var equityRow: some View {
        HStack(spacing: 6) {
            Button {
                appState.openTerminal(.account)
            } label: {
                ModeBadge(mode: mode, size: .small, filled: true)
            }
            .buttonStyle(.plain)
            .help("\(mode.displayName) · 点击打开账户与连接")
            if let equity = appState.accountEquity {
                Text(PriceFormatter.money(equity))
                    .font(.system(size: 16, weight: .medium, design: .rounded)).numeric()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: equity)
                Text(appState.runner.quoteCurrency).font(Theme.Text.caption).foregroundStyle(.secondary).baselineOffset(-1)
                if let nonStablePct = appState.nonStableExposurePct {
                    let complete = appState.runner.exposureIsComplete
                    Badge(text: "敞口 \(PriceFormatter.decimals(nonStablePct, 0))%" + (complete ? "" : "*"),
                          tint: complete ? riskTint(nonStablePct) : Theme.warning, size: .small)
                        .help(complete
                              ? "现货币种持仓 + 交易所上全部衍生品名义额（含非 MayStock 开的仓），占账户权益的比例。做空同样计入敞口。"
                              : "* 部分持仓未能从交易所读到或无法估值，实际敞口只会更高。现货币种持仓 + 衍生品名义额，占账户权益的比例。")
                }
            } else {
                Text(appState.accountError ?? appState.tradingBlocker ?? "读取账户权益…")
                    .font(Theme.Text.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button {
                appState.openTerminal(.overview)
            } label: {
                HStack(spacing: 3) {
                    Text("总览").font(Theme.Text.captionMedium)
                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .fixedSize()
        }
    }

    private func riskTint(_ pct: Double) -> Color {
        switch pct {
        case ..<25: return Theme.up
        case ..<75: return Theme.warning
        default: return Theme.down
        }
    }

    /// Always-available P&L, so the panel never reports nothing merely because
    /// the equity curve is young.
    private var currentPnLRow: some View {
        let pnl = appState.openPnL ?? 0
        return HStack(spacing: 5) {
            Text("账本盈亏").font(Theme.Text.caption).foregroundStyle(.secondary)
            Text(PriceFormatter.signedMoney(pnl, decimals: 2))
                .font(.system(size: 13, weight: .semibold)).numeric()
                .foregroundStyle(Theme.signed(pnl))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: pnl)
            if let pct = appState.openPnLPct {
                Text("(\(PriceFormatter.signedPercent(pct)))")
                    .font(Theme.Text.captionMedium).numeric()
                    .foregroundStyle(Theme.signed(pnl).opacity(0.75))
            }
            Spacer(minLength: 0)
            Text("已实现 + 浮动 · 扣费与资金费").font(Theme.Text.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: Trailing returns

    private var returnsRow: some View {
        HStack(spacing: 0) {
            ForEach(EquityWindow.allCases) { window in cell(window) }
        }
    }

    /// What the exchange's bills say the window realised. The exchange's
    /// figure, not this app's: its API publishes no period P&L and no equity
    /// history, so the bills it filed in the window are the one period number
    /// it can vouch for. A listing that ran out inside the window is marked.
    private func cell(_ window: EquityWindow) -> some View {
        let billed = appState.billedPnL(window)
        let tint = Theme.trend((billed?.total ?? 0) >= 0)

        return VStack(spacing: 2) {
            Text(window.label).font(Theme.Text.caption).foregroundStyle(.secondary)
            Text(billed.map { PriceFormatter.signedMoney($0.total, decimals: 0) } ?? "—")
                .font(.system(size: 12, weight: .semibold)).numeric()
                .foregroundStyle(billed == nil ? Color.secondary : tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Group {
                if let billed {
                    HStack(spacing: 1) {
                        Text("已实现").foregroundStyle(.tertiary)
                        if !billed.coversWindow { Text("*").foregroundStyle(Theme.warning) }
                    }
                } else {
                    Text(appState.billsError == nil ? "等待账单" : "账单读取失败").foregroundStyle(.tertiary)
                }
            }
            .font(Theme.Text.captionMedium).numeric()
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .help(tooltip(window, billed))
    }

    private func tooltip(_ window: EquityWindow, _ billed: BilledPnL?) -> String {
        let head = "\(window.longLabel) · OKX 账单口径"
        guard let billed else { return head + "\n" + (appState.billsError ?? "还没有读到账单") }
        var lines = [
            head,
            "平仓盈亏 \(PriceFormatter.signedMoney(billed.closedTradePnL)) · 资金费 \(PriceFormatter.signedMoney(billed.funding))"
                + " · 手续费 \(PriceFormatter.signedMoney(billed.fees))"
                + (billed.interest != 0 ? " · 利息 \(PriceFormatter.signedMoney(billed.interest))" : "")
                + " · \(billed.billCount) 条账单",
        ]
        if !billed.coversWindow, let oldest = appState.exchangeBills?.oldestBillAt {
            lines.append("* 账单只翻到 \(Format.stamp(oldest))，更早的没算进来")
        }
        lines.append("OKX 的 API 不提供分时段盈亏和权益历史；浮动盈亏在下一行，按交易所标记价")
        return lines.joined(separator: "\n")
    }

    /// Unrealised profit on what the exchange holds, at its own mark — the
    /// other half of the account's result, which no window can contain.
    private var exchangePnLRow: some View {
        let pnl = appState.exchangeUnrealisedPnL
        return HStack(spacing: 5) {
            Text("浮动盈亏").font(Theme.Text.caption).foregroundStyle(.secondary)
            Text(pnl.map { PriceFormatter.signedMoney($0, decimals: 2) } ?? "—")
                .font(.system(size: 13, weight: .semibold)).numeric()
                .foregroundStyle(pnl.map(Theme.signed) ?? .secondary)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
            Text(pnl == nil ? "等待账户读数" : "交易所标记 · \(appState.exchangePositions.count) 个持仓")
                .font(Theme.Text.caption).foregroundStyle(.tertiary)
        }
        .help("交易所对当前全部持仓（含非 MayStock 开的）按标记价算出的未实现盈亏之和。")
    }

    // MARK: Notices

    /// A protective breaker the user cannot see is worth nothing. A silent
    /// trading loop outranks it: a paused engine is a decision, a dead one is
    /// a position nobody is managing.
    @ViewBuilder
    private var notice: some View {
        if let first = appState.engineNotices.first {
            let danger = first.kind == .heartbeat
            HStack(spacing: 5) {
                Image(systemName: danger ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                    .font(.system(size: 10))
                Text(first.text)
                    .font(Theme.Text.captionMedium)
            }
            .foregroundStyle(danger ? Theme.down : Theme.warning)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((danger ? Theme.down : Theme.warning).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: Positions on this instrument

    private func mark(for holding: StrategyPositionState) -> Double? {
        appState.mark(for: holding.instId) ?? appState.mark(for: instId)
    }

    /// Summed in coins, not contracts: one BTC perpetual contract is 0.01 BTC.
    private var totalQuantity: Double { holdings.reduce(0) { $0 + $1.baseQuantity } }
    private var totalNetPnL: Double { holdings.reduce(0) { $0 + $1.netPnL(mark: mark(for: $1)) } }
    private var totalCapital: Double {
        holdings.reduce(0) { $0 + (appState.store.config.strategy.allocation(for: $1.strategyId)?.capital ?? 0) }
    }

    @ViewBuilder
    private var positionsBlock: some View {
        if holdings.isEmpty {
            VStack(spacing: 3) {
                HStack {
                    Text(runningHere > 0 ? "策略运行中 · 本标的当前空仓" : "本标的无策略持仓")
                        .font(Theme.Text.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                externalRows
                ordersRow
                elsewhereRow
            }
        } else {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Badge(text: totalQuantity >= 0 ? "多" : "空", tint: Theme.trend(totalQuantity >= 0), size: .small)
                    Text(PriceFormatter.plain(abs(totalQuantity)) + " " + appState.venue(of: instId).currencies(of: instId).base)
                        .font(Theme.Text.secondaryMedium).numeric()
                    Text(PriceFormatter.signedMoney(totalNetPnL))
                        .font(Theme.Text.secondaryMedium).numeric().foregroundStyle(Theme.signed(totalNetPnL))
                    if totalCapital > 0 {
                        Text("(\(PriceFormatter.signedPercent(totalNetPnL / totalCapital * 100)))")
                            .font(Theme.Text.captionMedium).numeric().foregroundStyle(Theme.signed(totalNetPnL))
                    }
                    Spacer(minLength: 2)
                }
                ForEach(holdings.prefix(3), id: \.id) { holding in row(holding) }
                if holdings.count > 3 {
                    Text("另有 \(holdings.count - 3) 个策略持仓").font(Theme.Text.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                externalRows
                ordersRow
                elsewhereRow
            }
        }
    }

    /// One line per position the exchange holds here that no strategy opened.
    @ViewBuilder
    private var externalRows: some View {
        ForEach(externalHere) { position in
            let family = appState.venue(of: position.instId).instrumentType(of: position.instId).displayName
            HStack(spacing: 6) {
                StatusDot(color: Theme.trend(position.quantity > 0), size: 5)
                Text("外部").font(Theme.Text.caption).foregroundStyle(.secondary)
                Badge(text: family, tint: .secondary, size: .small)
                Spacer(minLength: 2)
                Text("\(PriceFormatter.plain(abs(position.quantity))) 张").font(Theme.Text.caption).numeric().foregroundStyle(.tertiary)
                Text("@ \(PriceFormatter.auto(position.averagePrice))").font(Theme.Text.caption).numeric().foregroundStyle(.tertiary)
                Text(PriceFormatter.signedMoney(position.unrealisedPnL))
                    .font(Theme.Text.captionMedium).numeric()
                    .foregroundStyle(Theme.signed(position.unrealisedPnL))
                    .frame(width: 50, alignment: .trailing)
            }
            .help("非 MayStock 策略开的仓（手动、其它程序，或本机安装前就有）· 名义 "
                  + (position.notionalUsd.map { PriceFormatter.money($0, decimals: 0) } ?? "—")
                  + (position.leverage.map { " · \(PriceFormatter.decimals($0, 0))×" } ?? ""))
        }
    }

    @ViewBuilder
    private var ordersRow: some View {
        if let summary = ordersSummary {
            HStack(spacing: 4) {
                Image(systemName: "clock.badge").font(.system(size: 8)).foregroundStyle(.tertiary)
                Text(summary).font(Theme.Text.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .help("交易所当前挂着的委托，含非 MayStock 下的；完整列表在终端「总览」")
        }
    }

    /// One line naming every other underlying the book is exposed to.
    @ViewBuilder
    private var elsewhereRow: some View {
        let others = elsewhere.map { "\($0.venue.currencies(of: $0.instId).base) \($0.quantity > 0 ? "多" : "空")" }
            + externalElsewhere.map {
                "\(appState.venue(of: $0.instId).currencies(of: $0.instId).base) \($0.quantity > 0 ? "多" : "空")(外部)"
            }
        if !others.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 8)).foregroundStyle(.tertiary)
                Text(others.joined(separator: " · "))
                    .font(Theme.Text.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ state: StrategyPositionState) -> some View {
        let capital = appState.store.config.strategy.allocation(for: state.strategyId)?.capital ?? 0
        let pct = state.returnPct(mark: mark(for: state), capital: capital)
        // The panel is scoped to an underlying, so the leg has to say which
        // market it is actually on — spot, perpetual or an option contract.
        let family = state.venue.instrumentType(of: state.instId).displayName
        let name = appState.strategy(id: state.strategyId)?.name ?? state.strategyId
        return Button {
            appState.openTerminal(.strategies, strategyId: state.strategyId)
        } label: {
            HStack(spacing: 6) {
                StatusDot(color: Theme.trend(state.quantity > 0), size: 5)
                Text(name).font(Theme.Text.caption).foregroundStyle(.secondary).lineLimit(1)
                Badge(text: family, tint: .secondary, size: .small)
                Spacer(minLength: 2)
                Text(PriceFormatter.plain(abs(state.baseQuantity))).font(Theme.Text.caption).numeric().foregroundStyle(.tertiary)
                Text("@ \(PriceFormatter.auto(state.averagePrice))").font(Theme.Text.caption).numeric().foregroundStyle(.tertiary)
                Text(pct.map(PriceFormatter.signedPercent) ?? "—")
                    .font(Theme.Text.captionMedium).numeric()
                    .foregroundStyle(Theme.signed(pct ?? 0))
                    .frame(width: 50, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在终端里打开「\(name)」")
    }
}
