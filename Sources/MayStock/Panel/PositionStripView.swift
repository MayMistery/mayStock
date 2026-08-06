import SwiftUI
import MayStockKit

/// Account equity, trailing returns, and this instrument's strategy positions —
/// all read-only.
///
/// The panel deliberately has no order entry. Trading happens through
/// strategies in the studio, where a position is always attached to a rule and
/// a budget; a hover panel is the wrong place to put money at risk on impulse.
struct PositionStripView: View {
    let appState: AppState
    let instId: String

    /// Strategies holding this *underlying*, with their live P&L.
    ///
    /// Matching is by underlying rather than by exact `instId`: a short on
    /// `BTC-USDT-SWAP` is a BTC position and belongs on the BTC panel, even
    /// though the watchlist tracks spot `BTC-USDT`. Requiring an exact match is
    /// what made the hybrid portfolio's perpetual legs invisible here.
    private var holdings: [(state: StrategyPositionState, name: String)] {
        appState.ledger.positions.values
            .filter { Self.underlying($0.instId) == Self.underlying(instId) && !$0.isFlat }
            .sorted { abs($0.quantity) > abs($1.quantity) }
            .map { ($0, appState.strategy(id: $0.strategyId)?.name ?? $0.strategyId) }
    }

    /// "BTC-USDT-SWAP" and "BTC-USDT" are both BTC against USDT.
    private static func underlying(_ instId: String) -> String {
        let (base, quote) = StrategyLedger.currencies(of: instId)
        return "\(base)-\(quote)"
    }

    /// Positions the portfolio holds on some *other* underlying, so nothing is
    /// ever silently invisible just because the panel is scoped to one symbol.
    private var elsewhere: [StrategyPositionState] {
        appState.ledger.positions.values
            .filter { Self.underlying($0.instId) != Self.underlying(instId) && !$0.isFlat }
            .sorted { $0.instId < $1.instId }
    }

    private var runningHere: Int {
        appState.strategies
            .filter { Self.underlying($0.market.instId) == Self.underlying(instId) }
            .filter { appState.store.config.strategy.allocation(for: $0.id)?.running == true }
            .count
    }

    /// Mark each holding against *its own* instrument — a perpetual and its
    /// spot pair do not trade at the same price.
    private func mark(for holding: StrategyPositionState) -> Double? {
        appState.mark(for: holding.instId) ?? appState.mark(for: instId)
    }
    private var mark: Double? { appState.mark(for: instId) }

    /// Summed in coins, not contracts: one BTC perpetual contract is 0.01 BTC,
    /// so adding raw sizes across a spot and a swap leg would be nonsense.
    private var totalQuantity: Double { holdings.reduce(0) { $0 + $1.state.baseQuantity } }
    private var totalNetPnL: Double {
        holdings.reduce(0) { $0 + $1.state.netPnL(mark: mark(for: $1.state)) }
    }
    private var totalCapital: Double {
        holdings.reduce(0) {
            $0 + (appState.store.config.strategy.allocation(for: $1.state.strategyId)?.capital ?? 0)
        }
    }
    private var totalReturnPct: Double? {
        totalCapital > 0 ? totalNetPnL / totalCapital * 100 : nil
    }

    var body: some View {
        VStack(spacing: 6) {
            AccountSummaryRow(
                mode: appState.tradingMode,
                equity: appState.accountEquity,
                nonStablePct: appState.nonStableExposurePct,
                placeholder: appState.accountError ?? "读取账户余额…",
                change: { appState.equityChange($0) },
                onOpenStudio: {
                    appState.openStrategyStudio(selecting: holdings.first?.state.strategyId)
                })
            Divider().opacity(0.35)
            positionsBlock
        }
        .padding(9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Positions on this instrument

    @ViewBuilder
    private var positionsBlock: some View {
        if holdings.isEmpty {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(runningHere > 0 ? "策略运行中 · 当前空仓" : "本标的无策略持仓")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Spacer()
                }
                elsewhereRow
            }
        } else {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Text(totalQuantity >= 0 ? "多" : "空")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ChartStyle.trend(totalQuantity >= 0))
                    Text(PriceFormatter.plain(abs(totalQuantity)))
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    Text(PriceFormatter.signedMoney(totalNetPnL))
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(ChartStyle.trend(totalNetPnL >= 0))
                    if let pct = totalReturnPct {
                        Text("(\(PriceFormatter.signedPercent(pct)))")
                            .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(ChartStyle.trend(pct >= 0))
                    }
                    Spacer(minLength: 2)
                }
                ForEach(holdings.prefix(2), id: \.state.id) { holding in
                    row(holding.state, name: holding.name)
                }
                if holdings.count > 2 {
                    Text("另有 \(holdings.count - 2) 个策略持仓")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
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
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 7)).foregroundStyle(.tertiary)
                Text(others.map { state in
                    let (base, _) = StrategyLedger.currencies(of: state.instId)
                    return "\(base) \(state.quantity > 0 ? "多" : "空")"
                }.joined(separator: " · "))
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ state: StrategyPositionState, name: String) -> some View {
        let capital = appState.store.config.strategy.allocation(for: state.strategyId)?.capital ?? 0
        let markHere = mark(for: state)
        let pct = state.returnPct(mark: markHere, capital: capital)
        let isSwap = state.instId.hasSuffix("-SWAP")
        return HStack(spacing: 6) {
            Circle()
                .fill(ChartStyle.trend(state.quantity > 0))
                .frame(width: 4, height: 4)
            Text(name)
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .lineLimit(1)
            // The panel is scoped to an underlying, so the leg has to say
            // which market it is actually on.
            Text(isSwap ? "永续" : "现货")
                .font(.system(size: 7, weight: .medium))
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 2)
            Text(PriceFormatter.plain(abs(state.baseQuantity)))
                .font(.system(size: 9)).monospacedDigit().foregroundStyle(.tertiary)
            Text("@ \(PriceFormatter.auto(state.averagePrice))")
                .font(.system(size: 9)).monospacedDigit().foregroundStyle(.tertiary)
            Text(pct.map(PriceFormatter.signedPercent) ?? "—")
                .font(.system(size: 9, weight: .medium)).monospacedDigit()
                .foregroundStyle(ChartStyle.trend((pct ?? 0) >= 0))
                .frame(width: 46, alignment: .trailing)
        }
    }
}
