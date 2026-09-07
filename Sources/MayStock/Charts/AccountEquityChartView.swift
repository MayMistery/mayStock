import SwiftUI
import MayStockKit

/// The account's own value over a window, drawn with its holes.
///
/// The line breaks wherever the sampler did: bridging an outage with a
/// straight segment is how a dead trading loop was once read as a quiet
/// market. The break is the information.
struct AccountEquityChartView: View {
    let points: [AccountEquityPoint]
    let window: EquityWindow
    /// The live figure, so the right edge is now rather than the last sample.
    var latest: Double? = nil
    var now = Date()

    @State private var hover: CGPoint? = nil

    var body: some View {
        VStack(spacing: 6) {
            ChartLegendRow(items: legend)
            GeometryReader { geo in
                let domain = Domain(points: points, window: window, latest: latest, now: now, size: geo.size)
                ZStack {
                    if let domain {
                        Canvas(rendersAsynchronously: false) { context, size in
                            draw(context: context, size: size, domain: domain)
                        }
                    } else {
                        VStack(spacing: 4) {
                            Text("这个窗口里还没有权益采样").font(Theme.Text.secondary).foregroundStyle(.secondary)
                            Text("引擎每 60 秒采一次账户权益；有两次采样后这里就会出现曲线。")
                                .font(Theme.Text.caption).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hover = point
                    case .ended: hover = nil
                    }
                }
            }
        }
    }

    // MARK: Domain

    private struct Domain {
        let geometry: PlotGeometry
        let runs: [[AccountEquityPoint]]
        let all: [AccountEquityPoint]
        let start: Date
        let end: Date
        let span: TimeInterval
        let low: Double
        let high: Double
        let reference: Double
        let last: AccountEquityPoint

        init?(points: [AccountEquityPoint], window: EquityWindow, latest: Double?, now: Date, size: CGSize) {
            let anchor = window.anchor(now: now)
            // One sample before the anchor keeps the left edge honest: the
            // curve starts where the window does, not at the first sample in it.
            var inWindow = points.filter { $0.ts >= anchor }
            if let before = points.last(where: { $0.ts < anchor }) { inWindow.insert(before, at: 0) }
            if let latest, latest > 0, let lastPoint = inWindow.last, now > lastPoint.ts {
                inWindow.append(AccountEquityPoint(ts: now, equity: latest, basis: nil))
            }
            guard inWindow.count >= 2 else { return nil }

            self.geometry = PlotGeometry(size: size, gutter: 64)
            self.all = inWindow
            self.runs = AccountEquityCurve.continuousRuns(inWindow, now: now)
            self.start = min(anchor, inWindow[0].ts)
            self.end = max(now, inWindow[inWindow.count - 1].ts)
            self.span = max(end.timeIntervalSince(start), 1)
            let values = inWindow.map(\.equity)
            let rawLow = values.min() ?? 0
            let rawHigh = values.max() ?? 1
            let pad = max((rawHigh - rawLow) * 0.12, max(abs(rawHigh), 1) * 0.0005)
            self.low = rawLow - pad
            self.high = rawHigh + pad
            self.reference = inWindow[0].equity
            self.last = inWindow[inWindow.count - 1]
        }

        var isUp: Bool { last.equity >= reference }

        func x(_ ts: Date) -> CGFloat {
            geometry.plotWidth * CGFloat(min(max(ts.timeIntervalSince(start) / span, 0), 1))
        }

        func y(_ equity: Double) -> CGFloat {
            let range = max(high - low, .leastNonzeroMagnitude)
            return geometry.top + (1 - CGFloat((equity - low) / range)) * geometry.height
        }

        func date(atX x: CGFloat) -> Date {
            start.addingTimeInterval(span * Double(min(max(x / geometry.plotWidth, 0), 1)))
        }

        func sample(nearX x: CGFloat) -> AccountEquityPoint? {
            let target = date(atX: x)
            return all.min { abs($0.ts.timeIntervalSince(target)) < abs($1.ts.timeIntervalSince(target)) }
        }
    }

    // MARK: Legend

    private var legend: [ChartLegendItem] {
        guard let domain = Domain(points: points, window: window, latest: latest, now: now,
                                  size: CGSize(width: 600, height: 200)) else { return [] }
        let probe = hover.flatMap { $0.x < domain.geometry.plotWidth ? domain.sample(nearX: $0.x) : nil }
        let point = probe ?? domain.last
        let change = point.equity - domain.reference
        let pct = domain.reference > 0 ? change / domain.reference * 100 : 0
        var items: [ChartLegendItem] = [
            ChartLegendItem(key: "t", value: ChartFormatters.string(point.ts, "MM-dd HH:mm"),
                            tint: .secondary, priority: 5),
            ChartLegendItem(key: "e", label: "权益", value: PriceFormatter.money(point.equity), priority: 10),
            .trend("d", label: window.label, value: PriceFormatter.signedMoney(change, decimals: 0),
                   isUp: change >= 0, priority: 9),
            .trend("p", value: PriceFormatter.signedPercent(pct), isUp: change >= 0, priority: 8),
        ]
        let holes = domain.runs.count - 1
        if holes > 0 {
            items.append(ChartLegendItem(key: "g", value: "\(holes) 段空洞", tint: .down, priority: 7))
        }
        return items
    }

    // MARK: Drawing

    private func draw(context: GraphicsContext, size: CGSize, domain: Domain) {
        let geometry = domain.geometry
        let color = Theme.trend(domain.isUp)

        for value in ChartMath.valueTicks(lo: domain.low, hi: domain.high, target: 4) {
            let y = domain.y(value)
            context.strokeLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: geometry.plotWidth, y: y),
                               color: ChartStyle.grid)
            context.drawText(PriceFormatter.money(value, decimals: 0), font: ChartStyle.axisFont,
                             color: ChartStyle.axisLabel,
                             at: CGPoint(x: geometry.plotWidth + 5, y: y), anchor: .leading)
        }
        let format = ChartMath.timeAxisFormat(span: domain.span)
        for tick in ChartMath.timeTicks(from: domain.start, to: domain.end, maxLabels: 6) {
            let x = domain.x(tick)
            guard x > 14, x < geometry.plotWidth - 14 else { continue }
            context.strokeLine(from: CGPoint(x: x, y: geometry.top), to: CGPoint(x: x, y: geometry.bottom),
                               color: ChartStyle.grid)
            context.drawText(ChartFormatters.string(tick, format), font: ChartStyle.axisFont,
                             color: ChartStyle.axisLabel,
                             at: CGPoint(x: x, y: geometry.axisBaseline), anchor: .bottom)
        }

        // Holes, shaded so the eye reads "no data" rather than "flat".
        for (index, run) in domain.runs.enumerated() where index > 0 {
            guard let previousEnd = domain.runs[index - 1].last, let resume = run.first else { continue }
            let rect = CGRect(x: domain.x(previousEnd.ts), y: geometry.top,
                              width: max(1, domain.x(resume.ts) - domain.x(previousEnd.ts)),
                              height: geometry.height)
            context.fill(Path(rect), with: .color(Theme.down.opacity(0.07)))
        }

        // Reference line at the window's opening equity.
        let referenceY = domain.y(domain.reference)
        context.stroke(Path.dashedHorizontal(y: referenceY, from: 0, to: geometry.plotWidth),
                       with: .color(Color.secondary.opacity(0.4)), lineWidth: 1)

        for run in domain.runs where run.count >= 1 {
            var line = Path()
            for (index, point) in run.enumerated() {
                let position = CGPoint(x: domain.x(point.ts), y: domain.y(point.equity))
                index == 0 ? line.move(to: position) : line.addLine(to: position)
            }
            if run.count == 1, let only = run.first {
                let position = CGPoint(x: domain.x(only.ts), y: domain.y(only.equity))
                context.fill(Path(ellipseIn: CGRect(x: position.x - 2, y: position.y - 2, width: 4, height: 4)),
                             with: .color(color))
                continue
            }
            var area = line
            area.addLine(to: CGPoint(x: domain.x(run[run.count - 1].ts), y: geometry.bottom))
            area.addLine(to: CGPoint(x: domain.x(run[0].ts), y: geometry.bottom))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.22), color.opacity(0.01)]),
                startPoint: CGPoint(x: 0, y: geometry.top), endPoint: CGPoint(x: 0, y: geometry.bottom)))
            context.stroke(line, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }

        let lastPoint = CGPoint(x: domain.x(domain.last.ts), y: domain.y(domain.last.equity))
        context.fill(Path(ellipseIn: CGRect(x: lastPoint.x - 2.5, y: lastPoint.y - 2.5, width: 5, height: 5)),
                     with: .color(color))
        context.drawPriceTag(PriceFormatter.money(domain.last.equity, decimals: 0), y: lastPoint.y,
                             geometry: geometry, fill: color)

        if let hover, hover.x < geometry.plotWidth, let sample = domain.sample(nearX: hover.x) {
            let x = domain.x(sample.ts)
            let y = domain.y(sample.equity)
            context.strokeLine(from: CGPoint(x: x, y: geometry.top), to: CGPoint(x: x, y: geometry.bottom),
                               color: ChartStyle.crosshair, dash: [2, 2])
            context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(color))
            context.drawPriceTag(PriceFormatter.money(sample.equity, decimals: 0), y: y, geometry: geometry,
                                 fill: ChartStyle.tagFill, text: ChartStyle.tagText)
            context.drawTimeTag(ChartFormatters.string(sample.ts, "MM-dd HH:mm"), x: x, geometry: geometry,
                                fill: ChartStyle.tagFill, text: ChartStyle.tagText)
        }
    }
}
