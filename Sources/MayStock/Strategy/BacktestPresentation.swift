import SwiftUI
import MayStockKit

// MARK: - Robustness badge

/// The grade, coloured by how much the numbers can be trusted. Deliberately
/// prominent: a 1-day return of +40% next to a "样本不足" badge is honest;
/// the same number alone is a lie by omission.
struct RobustnessBadge: View {
    let assessment: RobustnessAssessment
    var compact = false

    private var tint: Color {
        switch assessment.grade {
        case .robust: return ChartStyle.up
        case .indicative: return ChartStyle.accent
        case .insufficientData: return .secondary
        case .overfitSuspect: return .orange
        }
    }

    private var icon: String {
        switch assessment.grade {
        case .robust: return "checkmark.seal.fill"
        case .indicative: return "info.circle.fill"
        case .insufficientData: return "questionmark.circle.fill"
        case .overfitSuspect: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: compact ? 8 : 10))
            Text(assessment.grade.displayName)
                .font(.system(size: compact ? 9 : 11, weight: .semibold))
        }
        .padding(.horizontal, compact ? 5 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(tint.opacity(0.16), in: Capsule())
        .foregroundStyle(tint)
        .help(assessment.grade.explanation + "\n" + assessment.notes.joined(separator: "\n"))
    }
}

// MARK: - Window cards

/// One backtest window. The headline is the return; everything under it exists
/// so the headline can be argued with.
struct BacktestWindowCard: View {
    let window: BacktestWindow
    let result: BacktestResult?
    let isSelected: Bool
    var onTap: () -> Void

    private var metrics: BacktestMetrics? { result?.metrics }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(window.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let result, result.trades.isEmpty {
                        Text("无交易")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }

                if let metrics {
                    Text(PriceFormatter.signedPercent(metrics.totalReturnPct))
                        .font(.system(size: 19, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ChartStyle.trend(metrics.totalReturnPct >= 0))
                        .lineLimit(1).minimumScaleFactor(0.6)

                    VStack(alignment: .leading, spacing: 2) {
                        miniRow("回撤", PriceFormatter.percent(metrics.maxDrawdownPct, decimals: 1))
                        miniRow("交易", "\(metrics.tradeCount) 笔")
                        miniRow("夏普", PriceFormatter.ratio(metrics.sharpe))
                        miniRow("对标持有",
                                PriceFormatter.signedPercent(metrics.excessReturnPct),
                                tint: ChartStyle.trend(metrics.excessReturnPct >= 0))
                    }
                } else {
                    Text("—")
                        .font(.system(size: 19, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Text("数据不足")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(height: 44, alignment: .top)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.09 : 0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? ChartStyle.accent.opacity(0.7) : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private func miniRow(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            Spacer(minLength: 2)
            Text(value)
                .font(.system(size: 9, weight: .medium)).monospacedDigit()
                .foregroundStyle(tint ?? .secondary)
        }
    }
}

// MARK: - Equity curve

/// Strategy equity against buy-and-hold, both rebased to 100.
///
/// The benchmark is not decoration: a strategy that made 8% while the asset
/// made 30% lost money in the only sense that matters.
struct EquityCurveView: View {
    let result: BacktestResult
    var showBenchmark = true

    var body: some View {
        Canvas { context, size in
            let points = result.equityCurve
            guard points.count > 1, let base = points.first, base.equity > 0, base.price > 0 else {
                return
            }

            let strategy = points.map { $0.equity / base.equity * 100 }
            let benchmark = points.map { $0.price / base.price * 100 }
            var values = strategy
            if showBenchmark { values += benchmark }
            let low = values.min() ?? 100
            let high = values.max() ?? 100
            let span = max(high - low, 0.0001)

            let inset: CGFloat = 4
            func point(_ index: Int, _ value: Double) -> CGPoint {
                let x = inset + (size.width - inset * 2) * CGFloat(index) / CGFloat(points.count - 1)
                let y = size.height - inset
                    - (size.height - inset * 2) * CGFloat((value - low) / span)
                return CGPoint(x: x, y: y)
            }

            // Baseline at 100 — above it the strategy made money.
            if low < 100, high > 100 {
                let y = point(0, 100).y
                context.stroke(
                    Path.dashedHorizontal(y: y, from: inset, to: size.width - inset),
                    with: .color(ChartStyle.grid), lineWidth: 1)
            }

            if showBenchmark {
                var path = Path()
                for (index, value) in benchmark.enumerated() {
                    let p = point(index, value)
                    index == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                context.stroke(path, with: .color(.secondary.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }

            var path = Path()
            for (index, value) in strategy.enumerated() {
                let p = point(index, value)
                index == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            let up = (strategy.last ?? 100) >= 100
            let tint = ChartStyle.trend(up)

            var fill = path
            fill.addLine(to: CGPoint(x: size.width - inset, y: size.height))
            fill.addLine(to: CGPoint(x: inset, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.22), tint.opacity(0.01)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(path, with: .color(tint), lineWidth: 1.6)
        }
    }
}

// MARK: - Metric grid

/// The full statistics table for the selected window.
struct BacktestMetricGrid: View {
    let result: BacktestResult
    let quoteCurrency: String

    private var metrics: BacktestMetrics { result.metrics }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 108), spacing: 10)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            cell("年化收益", metrics.annualisationReliable
                 ? PriceFormatter.signedPercent(metrics.cagr) : "样本过短",
                 tint: metrics.annualisationReliable
                 ? ChartStyle.trend(metrics.cagr >= 0) : nil)
            cell("最大回撤", PriceFormatter.percent(metrics.maxDrawdownPct, decimals: 2), tint: ChartStyle.down)
            cell("夏普", PriceFormatter.ratio(metrics.sharpe))
            cell("索提诺", PriceFormatter.ratio(metrics.sortino))
            cell("卡玛", PriceFormatter.ratio(metrics.calmar))
            cell("年化波动", PriceFormatter.percent(metrics.annualisedVolatilityPct, decimals: 1))
            cell("胜率", PriceFormatter.percent(metrics.winRate, decimals: 1))
            cell("盈亏比", PriceFormatter.ratio(metrics.profitFactor))
            cell("赔率", PriceFormatter.ratio(metrics.payoffRatio))
            cell("单笔期望", PriceFormatter.signedPercent(metrics.expectancyPct),
                 tint: ChartStyle.trend(metrics.expectancyPct >= 0))
            cell("最长连亏", "\(metrics.maxConsecutiveLosses) 笔")
            cell("平均持仓", "\(PriceFormatter.decimals(metrics.averageHoldBars, 1)) 根")
            cell("持仓占比", PriceFormatter.percent(metrics.exposurePct, decimals: 0))
            cell("手续费", PriceFormatter.money(metrics.feesPaid) + " " + quoteCurrency)
            if metrics.fundingPaid != 0 {
                cell("资金费", PriceFormatter.signedMoney(metrics.fundingPaid) + " " + quoteCurrency)
            }
            if result.liquidations > 0 {
                cell("强平", "\(result.liquidations) 次", tint: ChartStyle.down)
            }
        }
    }

    private func cell(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
