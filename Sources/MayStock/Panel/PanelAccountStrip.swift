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

    /// Strategies holding this *underlying*, with their live P&L.
    ///
    /// Matching is by underlying rather than by exact `instId`: a short on
    /// `BTC-USDT-SWAP` is a BTC position and belongs on the BTC panel, even
    /// though the watchlist tracks spot `BTC-USDT`.
    private var holdings: [StrategyPositionState] {
        appState.ledger.positions.values
            .filter { AppState.underlying($0.instId) == AppState.underlying(instId) && !$0.isFlat }
            .sorted { abs($0.quantity) > abs($1.quantity) }
    }

    /// Positions the portfolio holds on some *other* underlying, so nothing is
    /// ever silently invisible just because the panel is scoped to one symbol.
    private var elsewhere: [StrategyPositionState] {
        appState.ledger.positions.values
            .filter { AppState.underlying($0.instId) != AppState.underlying(instId) && !$0.isFlat }
            .sorted { $0.instId < $1.instId }
    }

    private var runningHere: Int {
        appState.strategies
            .filter { AppState.underlying($0.market.instId) == AppState.underlying(instId) }
            .filter { appState.store.config.strategy.allocation(for: $0.id)?.running == true }
            .count
    }

    var body: some View {
        VStack(spacing: 8) {
            equityRow
            if appState.openPnL != nil { currentPnLRow }
            returnsRow
            notice
            Divider().opacity(0.35)
            positionsBlock
        }
        .padding(10)
        .background(Theme.rowFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.mode(mode).opacity(0.25), lineWidth: 1))
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
                Text(StrategyRunner.quoteCurrency).font(Theme.Text.caption).foregroundStyle(.secondary).baselineOffset(-1)
                if let nonStablePct = appState.nonStableExposurePct {
                    Badge(text: "敞口 \(PriceFormatter.decimals(nonStablePct, 0))%", tint: riskTint(nonStablePct), size: .small)
                        .help("现货币种持仓 + 永续名义额，占账户权益的比例。做空同样计入敞口。")
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

    /// The number is always shown once a single sample exists; the caveats
    /// ride alongside it as a marker and spell themselves out on hover.
    private func cell(_ window: EquityWindow) -> some View {
        let change = appState.equityChange(window)
        let pct = change?.changePct
        let tint = Theme.trend((change?.changeQuote ?? 0) >= 0)

        return VStack(spacing: 2) {
            Text(window.label).font(Theme.Text.caption).foregroundStyle(.secondary)
            Text(change.map { PriceFormatter.signedMoney($0.changeQuote, decimals: 0) } ?? "—")
                .font(.system(size: 12, weight: .semibold)).numeric()
                .foregroundStyle(change == nil ? Color.secondary : tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Group {
                if let change, let pct {
                    HStack(spacing: 1) {
                        Text(PriceFormatter.signedPercent(pct)).foregroundStyle(tint.opacity(0.75))
                        if change.hasGaps {
                            Text("!").foregroundStyle(Theme.down)
                        } else if !change.isAnchored {
                            Text("*").foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("等待记录").foregroundStyle(.tertiary)
                }
            }
            .font(Theme.Text.captionMedium).numeric()
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .help(tooltip(window, change))
    }

    private func tooltip(_ window: EquityWindow, _ change: EquityChange?) -> String {
        guard let change else { return "\(window.longLabel)：还没有任何权益采样" }
        let range = "\(PriceFormatter.money(change.startEquity)) → \(PriceFormatter.money(change.endEquity)) \(StrategyRunner.quoteCurrency)"
        let head = "\(window.longLabel)\n\(range)"
        return change.coverageNote.isEmpty ? head : "\(head)\n\(change.coverageNote)"
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
                elsewhereRow
            }
        } else {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Badge(text: totalQuantity >= 0 ? "多" : "空", tint: Theme.trend(totalQuantity >= 0), size: .small)
                    Text(PriceFormatter.plain(abs(totalQuantity)) + " " + StrategyLedger.currencies(of: instId).base)
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
                elsewhereRow
            }
        }
    }

    /// One line naming every other underlying the book is exposed to.
    @ViewBuilder
    private var elsewhereRow: some View {
        let others = elsewhere
        if !others.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 8)).foregroundStyle(.tertiary)
                Text(others.map { "\(StrategyLedger.currencies(of: $0.instId).base) \($0.quantity > 0 ? "多" : "空")" }
                    .joined(separator: " · "))
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
        let family = InstrumentType.of(instId: state.instId).displayName
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
