import MayStockKit
import SwiftUI

/// How live trading is doing against the backtest that justified it, and what
/// the account is really paying to trade.
///
/// Two numbers a backtest cannot produce on its own. A strategy that tested at
/// +67% and is running at −3% has something wrong with it, and the earlier that
/// is a figure on screen rather than a feeling, the better. Both are computed
/// by the kernel, from the same data the backtester uses.
struct LiveVsBacktestPanel: View {
    /// Handed in rather than read from the environment, like every other view
    /// here. Nothing in this app ever calls `.environment(_:)` — it is an
    /// AppKit shell that constructs its hosting views by hand — so an
    /// `@Environment(AppState.self)` here found no value and trapped on sight,
    /// taking the whole app down the moment the 持仓与成交 tab was opened. A
    /// stored property cannot be forgotten: leaving it out is a build error.
    let appState: AppState
    let strategy: CompiledStrategy

    var body: some View {
        if slippage != nil || comparison != nil {
            VStack(alignment: .leading, spacing: 7) {
                Label("实盘对照", systemImage: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let comparison { equityRows(comparison) }
                if let slippage { slippageRows(slippage) }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Equity

    @ViewBuilder
    private func equityRows(_ result: KernelEquityComparison) -> some View {
        if let live = result.liveReturnPct, let sim = result.backtestReturnPct,
           let gap = result.differencePct {
            row("净值（重合 \(coverage(result.covered))）",
                "实盘 \(signed(live)) · 回测 \(signed(sim))")
            row("差距", signed(gap), tint: gap < -1 ? .orange : .secondary)
            if let tracking = result.trackingErrorBps {
                row("跟踪误差", String(format: "%.1f bps", tracking))
            }
            if let correlation = result.correlation {
                // The distinction that matters: same shape at a lower level is
                // a cost problem, a different shape is a different strategy.
                row("形态相关性", String(format: "%.2f", correlation),
                    tint: correlation < 0.8 ? .orange : .secondary)
                if correlation < 0.8 {
                    note("形态已经不一致，实盘做的不是回测里那件事，先查信号与成交，再谈成本。")
                } else if gap < -1 {
                    note("形态跟得上但净值落后，通常是成本：看下面的滑点。")
                }
            } else {
                note("净值变化太平缓，相关性无法计算——不是「不相关」，是还没有形态可比。")
            }
        } else {
            row("净值", "重合样本不足 \(result.samples) 个，暂不比较")
        }
    }

    // MARK: Slippage

    @ViewBuilder
    private func slippageRows(_ report: KernelSlippageReport) -> some View {
        if let median = report.medianBps {
            row("实测滑点（\(report.samples) 笔）",
                String(format: "中位 %.1f bps · 假设 %.1f bps", median, report.assumedBps),
                tint: report.understatesCost ? .orange : .secondary)
            if let p90 = report.p90Bps {
                row("尾部 P90", String(format: "%.1f bps", p90))
            }
            if report.understatesCost, let recommended = report.recommendedBps {
                note("实际成本高于清单假设，回测收益被高估了。"
                     + "建议把 costs.slippageBps 改成 \(String(format: "%.0f", recommended))。")
            } else if report.samples < 10 {
                note("成交样本还太少，这个数字先看看就好，不要拿去改回测。")
            }
        }
    }

    // MARK: Rows

    private func row(_ label: String, _ value: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint).monospacedDigit()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func signed(_ value: Double) -> String {
        String(format: "%@%.2f%%", value >= 0 ? "+" : "", value)
    }

    private func coverage(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400 { return "\(Int(seconds / 86_400)) 天" }
        if seconds >= 3_600 { return "\(Int(seconds / 3_600)) 小时" }
        return "\(Int(seconds / 60)) 分钟"
    }

    // MARK: Data

    /// The backtest window whose curve overlaps live trading.
    ///
    /// The longest available, because the shorter windows are subsets of it and
    /// the comparison is bounded by the live curve at one end and by the
    /// backtest's own end at the other.
    private var backtestCurve: [EquityPoint]? {
        guard let report = appState.reports[strategy.id] else { return nil }
        return BacktestWindow.allCases
            .sorted { $0.days > $1.days }
            .compactMap { report.results[$0]?.equityCurve }
            .first { $0.count > 1 }
    }

    private var comparison: KernelEquityComparison? {
        guard let curve = backtestCurve,
              let live = appState.strategyEquity(strategy.id)?.points, live.count > 1
        else { return nil }
        return try? TradingKernel.compareEquity(
            live: live.map { (ts: $0.ts, equity: $0.equity) },
            backtest: curve.map { (ts: $0.ts, equity: $0.equity) })
    }

    private var slippage: KernelSlippageReport? {
        let fills = appState.ledger.fills(for: strategy.id, limit: 500)
        guard !fills.isEmpty else { return nil }
        // The candles the runner already holds for this strategy — the same
        // bars the decision was made on.
        let candles = appState.runner.cachedCandles(
            instId: strategy.market.instId, bar: strategy.market.bar)
        guard candles.count > 1 else { return nil }
        return try? TradingKernel.calibrateSlippage(
            fills: fills, candles: candles,
            assumedBps: strategy.manifest.costs?.slippageBps ?? 5)
    }
}
