import SwiftUI
import MayStockKit

/// Account equity and its trailing returns — the top of the panel's strip.
///
/// Takes plain values rather than `AppState` so it can be rendered in isolation:
/// this is the block whose layout is easiest to get wrong (four numbers, a
/// badge and a button on 356 points) and the hardest to inspect once it is
/// living inside a menu-bar accessory.
struct AccountSummaryRow: View {
    let mode: TradingMode
    /// Nil while the first balance read is in flight, or when it failed.
    let equity: Double?
    /// Share of equity held in anything that is not a stablecoin. Nil until the
    /// first account read lands.
    var nonStablePct: Double? = nil
    /// Profit on the book right now. Independent of the trailing windows —
    /// it needs no recorded history, only a position and a price.
    var openPnL: Double? = nil
    var openPnLPct: Double? = nil
    /// Shown in place of the equity when there is none.
    let placeholder: String
    let change: (EquityWindow) -> EquityChange?
    var onOpenStudio: () -> Void = {}

    var body: some View {
        VStack(spacing: 5) {
            equityRow
            if openPnL != nil { currentPnLRow }
            returnsRow
        }
    }

    /// Always-available P&L, so the panel never reports nothing merely because
    /// the equity curve is young.
    private var currentPnLRow: some View {
        let pnl = openPnL ?? 0
        return HStack(spacing: 5) {
            Text("当前盈亏")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Text(PriceFormatter.signedMoney(pnl, decimals: 2))
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(ChartStyle.trend(pnl >= 0))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: pnl)
            if let pct = openPnLPct {
                Text("(\(PriceFormatter.signedPercent(pct)))")
                    .font(.system(size: 9, weight: .medium)).monospacedDigit()
                    .foregroundStyle(ChartStyle.trend(pnl >= 0).opacity(0.75))
            }
            Spacer(minLength: 0)
            Text("持仓盈亏 · 不依赖历史")
                .font(.system(size: 8)).foregroundStyle(.tertiary)
        }
    }

    // MARK: Equity

    private var equityRow: some View {
        HStack(spacing: 6) {
            modeBadge
            if let equity {
                Text(PriceFormatter.money(equity))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: equity)
                Text(StrategyRunner.quoteCurrency)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .baselineOffset(-1)
                if let nonStablePct {
                    // How much of the account is actually at market risk. A
                    // book that is 100% stablecoin is flat however many
                    // strategies are armed.
                    Text("非稳定币 \(PriceFormatter.decimals(nonStablePct, 1))%")
                        .font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(riskTint.opacity(0.16), in: Capsule())
                        .foregroundStyle(riskTint)
                        .help("现货币种持仓 + 永续名义额，占账户权益的比例。做空同样计入敞口。")
                }
            } else {
                Text(placeholder)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button(action: onOpenStudio) {
                HStack(spacing: 3) {
                    Text("策略工作台").font(.system(size: 10, weight: .medium))
                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(ChartStyle.accent)
            .fixedSize()
        }
    }

    /// Green while most of the book is in cash, amber as exposure builds.
    private var riskTint: Color {
        switch nonStablePct ?? 0 {
        case ..<25: return ChartStyle.up
        case ..<75: return .orange
        default: return ChartStyle.down
        }
    }

    private var modeBadge: some View {
        Text(mode.badge)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background((mode.isDemo ? Color.orange : ChartStyle.down).opacity(0.18), in: Capsule())
            .foregroundStyle(mode.isDemo ? .orange : ChartStyle.down)
            .help(mode.isDemo ? "当前为 OKX 模拟盘" : "当前为实盘，订单会真实成交")
    }

    // MARK: Trailing returns

    private var returnsRow: some View {
        HStack(spacing: 0) {
            ForEach(EquityWindow.allCases) { window in
                cell(window)
            }
        }
    }

    /// One trailing window.
    ///
    /// A window the recorded history does not yet cover shows a dash and how
    /// long it has actually been recording — never a number. Falling back to
    /// the oldest sample would print the same figure under all three labels,
    /// which reads as three independent measurements agreeing when it is really
    /// one short measurement repeated. The partial value stays in the tooltip.
    private func cell(_ window: EquityWindow) -> some View {
        let change = change(window)
        let pct = change?.changePct
        let ready = change?.isComplete == true && pct != nil

        return VStack(spacing: 1) {
            Text(window.label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
            // Amount first: "+33 USDT" answers "how much did I make" directly,
            // where a percentage of an unstated base does not.
            Text(ready ? PriceFormatter.signedMoney(change?.changeQuote ?? 0, decimals: 1) : "—")
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(ready ? ChartStyle.trend((pct ?? 0) >= 0) : Color.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Group {
                if ready {
                    Text(PriceFormatter.signedPercent(pct ?? 0))
                        .foregroundStyle(ChartStyle.trend((pct ?? 0) >= 0).opacity(0.75))
                } else if let change, change.coveredSeconds > 0 {
                    Text("记录 \(AccountEquityCurve.describe(change.coveredSeconds))")
                        .foregroundStyle(.tertiary)
                } else {
                    Text("等待记录").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 8, weight: .medium)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .help(tooltip(window, change))
    }

    private func tooltip(_ window: EquityWindow, _ change: EquityChange?) -> String {
        guard let change, change.coveredSeconds > 0 else {
            return "尚无 \(window.label) 的权益记录 —— 应用需先运行一段时间才能给出这个窗口的收益率"
        }
        let range = "\(PriceFormatter.money(change.startEquity)) → "
            + "\(PriceFormatter.money(change.endEquity)) \(StrategyRunner.quoteCurrency)"
        return change.isComplete ? "\(window.label)：\(range)" : "\(range)（\(change.coverageNote)）"
    }
}
