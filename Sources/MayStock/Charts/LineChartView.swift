import SwiftUI
import MayStockKit

/// Tick-level price line with a gradient area fill.
///
/// The X axis is **time-proportional**, not index-proportional: samples arrive
/// once a second live but once a minute from the seeded history, so laying them
/// out by index (as this view used to) squeezed hours of history into a sliver
/// and stretched the last few minutes across most of the width. Positioning by
/// timestamp inside a window anchored to *now* is what makes the window filter
/// mean anything at all.
struct LineChartView: View {
    let points: [SparkPoint]
    let window: LineWindow
    let decimals: Int

    @State private var hover: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            let domain = Domain(points: points, window: window, size: geo.size)
            ZStack {
                if let domain {
                    Canvas(rendersAsynchronously: false) { context, size in
                        draw(context: context, size: size, domain: domain)
                    }
                    .chartLegend(legend(domain))
                } else {
                    ChartPlaceholder(text: "正在收集实时价格…")
                        .chartLegend([])
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

    // MARK: Domain

    /// Everything the draw pass needs, resolved once per render.
    private struct Domain {
        let geometry: PlotGeometry
        let series: [SparkPoint]
        let start: Date
        let end: Date
        let span: TimeInterval
        let minPrice: Double
        let maxPrice: Double
        let open: Double
        let last: Double
        let high: Double
        let low: Double
        /// Left edge of real data, when the window reaches further back than
        /// the history we hold.
        let coverageStart: Date

        init?(points: [SparkPoint], window: LineWindow, size: CGSize) {
            let geometry = PlotGeometry(size: size)
            let now = Date()
            let end = max(now, points.last?.ts ?? now)
            let start = end.addingTimeInterval(-window.seconds)

            let inWindow = points.filter { $0.ts >= start && $0.ts <= end }
            guard inWindow.count >= 2 else { return nil }

            // One or two points per horizontal pixel is plenty; extremes survive.
            self.series = ChartMath.downsample(inWindow, buckets: Int(geometry.plotWidth))
            self.geometry = geometry
            self.start = start
            self.end = end
            self.span = max(end.timeIntervalSince(start), 1)
            self.coverageStart = inWindow[0].ts

            let prices = inWindow.map(\.price)
            let rawMin = prices.min() ?? 0
            let rawMax = prices.max() ?? 1
            let pad = max((rawMax - rawMin) * 0.10, max(abs(rawMax), 1) * 0.00005)
            self.minPrice = rawMin - pad
            self.maxPrice = rawMax + pad
            self.open = inWindow[0].price
            self.last = inWindow[inWindow.count - 1].price
            self.high = rawMax
            self.low = rawMin
        }

        var isUp: Bool { last >= open }
        var changePct: Double { open > 0 ? (last - open) / open * 100 : 0 }

        func x(_ ts: Date) -> CGFloat {
            let fraction = ts.timeIntervalSince(start) / span
            return geometry.plotWidth * CGFloat(min(max(fraction, 0), 1))
        }

        func date(atX x: CGFloat) -> Date {
            let fraction = min(max(x / geometry.plotWidth, 0), 1)
            return start.addingTimeInterval(span * Double(fraction))
        }

        func y(_ price: Double) -> CGFloat {
            let range = max(maxPrice - minPrice, .leastNonzeroMagnitude)
            return geometry.top + (1 - CGFloat((price - minPrice) / range)) * geometry.height
        }

        /// Sample nearest a cursor position, for the crosshair.
        func sample(nearX x: CGFloat) -> SparkPoint? {
            guard !series.isEmpty else { return nil }
            let target = date(atX: x)
            var best = series[0]
            var bestDelta = abs(best.ts.timeIntervalSince(target))
            for point in series.dropFirst() {
                let delta = abs(point.ts.timeIntervalSince(target))
                if delta < bestDelta { best = point; bestDelta = delta }
            }
            return best
        }
    }

    // MARK: Legend

    private func legend(_ domain: Domain) -> [ChartLegendItem] {
        let probe = hover.flatMap { $0.x < domain.geometry.plotWidth ? domain.sample(nearX: $0.x) : nil }
        if let probe {
            let delta = domain.open > 0 ? (probe.price - domain.open) / domain.open * 100 : 0
            return [
                ChartLegendItem(key: "t", value: ChartFormatters.string(probe.ts, "HH:mm:ss"),
                                tint: .secondary, priority: 8),
                ChartLegendItem(key: "p", value: PriceFormatter.price(probe.price, decimals: decimals),
                                priority: 10),
                .trend("d", value: PriceFormatter.signedPercent(delta), isUp: delta >= 0, priority: 9),
            ]
        }
        return [
            ChartLegendItem(key: "p", label: "现价",
                            value: PriceFormatter.price(domain.last, decimals: decimals), priority: 10),
            .trend("d", label: window.title, value: PriceFormatter.signedPercent(domain.changePct),
                   isUp: domain.isUp, priority: 9),
            ChartLegendItem(key: "h", label: "高",
                            value: PriceFormatter.price(domain.high, decimals: decimals),
                            tint: .secondary, priority: 5),
            ChartLegendItem(key: "l", label: "低",
                            value: PriceFormatter.price(domain.low, decimals: decimals),
                            tint: .secondary, priority: 4),
        ]
    }

    // MARK: Drawing

    private func draw(context: GraphicsContext, size: CGSize, domain: Domain) {
        let geometry = domain.geometry
        let color = ChartStyle.trend(domain.isUp)

        drawGrid(context: context, domain: domain)
        drawUncovered(context: context, domain: domain)

        // Price path.
        var line = Path()
        for (index, point) in domain.series.enumerated() {
            let position = CGPoint(x: domain.x(point.ts), y: domain.y(point.price))
            if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
        }

        // Gradient area under the line.
        if let firstPoint = domain.series.first, let lastPoint = domain.series.last {
            var area = line
            area.addLine(to: CGPoint(x: domain.x(lastPoint.ts), y: geometry.bottom))
            area.addLine(to: CGPoint(x: domain.x(firstPoint.ts), y: geometry.bottom))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.26), color.opacity(0.015)]),
                startPoint: CGPoint(x: 0, y: geometry.top),
                endPoint: CGPoint(x: 0, y: geometry.bottom)))
        }

        context.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

        drawOpenBaseline(context: context, domain: domain)
        drawLast(context: context, domain: domain, color: color)
        if let hover, hover.x < geometry.plotWidth {
            drawCrosshair(context: context, domain: domain, at: hover, color: color)
        }
    }

    private func drawGrid(context: GraphicsContext, domain: Domain) {
        let geometry = domain.geometry

        for price in ChartMath.valueTicks(lo: domain.minPrice, hi: domain.maxPrice, target: 4) {
            let y = domain.y(price)
            context.strokeLine(from: CGPoint(x: 0, y: y),
                               to: CGPoint(x: geometry.plotWidth, y: y),
                               color: ChartStyle.grid)
            context.drawText(PriceFormatter.price(price, decimals: decimals),
                             font: ChartStyle.axisFont, color: ChartStyle.axisLabel,
                             at: CGPoint(x: geometry.plotWidth + 5, y: y), anchor: .leading)
        }

        let format = ChartMath.timeAxisFormat(span: domain.span)
        for tick in ChartMath.timeTicks(from: domain.start, to: domain.end, maxLabels: 5) {
            let x = domain.x(tick)
            guard x > 12, x < geometry.plotWidth - 12 else { continue }
            context.strokeLine(from: CGPoint(x: x, y: geometry.top),
                               to: CGPoint(x: x, y: geometry.bottom),
                               color: ChartStyle.grid)
            context.drawText(ChartFormatters.string(tick, format),
                             font: ChartStyle.axisFont, color: ChartStyle.axisLabel,
                             at: CGPoint(x: x, y: geometry.axisBaseline), anchor: .bottom)
        }
    }

    /// Shade the stretch of the window we simply do not have data for, instead
    /// of stretching what we do have across it and lying about the time base.
    private func drawUncovered(context: GraphicsContext, domain: Domain) {
        let edge = domain.x(domain.coverageStart)
        guard edge > domain.geometry.plotWidth * 0.02 else { return }
        let rect = CGRect(x: 0, y: domain.geometry.top,
                          width: edge, height: domain.geometry.height)
        context.fill(Path(rect), with: .color(Color.primary.opacity(0.035)))
        if edge > 68 {
            context.drawText("暂无更早数据", font: ChartStyle.axisFont, color: .secondary,
                             at: CGPoint(x: edge / 2, y: domain.geometry.top + domain.geometry.height / 2),
                             anchor: .center)
        }
    }

    /// Faint line at the window's opening price — the reference the trend
    /// colour and the percentage in the legend are measured against.
    private func drawOpenBaseline(context: GraphicsContext, domain: Domain) {
        let y = domain.y(domain.open)
        context.stroke(
            Path.dashedHorizontal(y: y, from: domain.x(domain.coverageStart), to: domain.geometry.plotWidth),
            with: .color(Color.secondary.opacity(0.35)), lineWidth: 1)
    }

    private func drawLast(context: GraphicsContext, domain: Domain, color: Color) {
        guard let lastPoint = domain.series.last else { return }
        let position = CGPoint(x: domain.x(lastPoint.ts), y: domain.y(lastPoint.price))
        context.stroke(
            Path.dashedHorizontal(y: position.y, from: 0, to: domain.geometry.plotWidth),
            with: .color(color.opacity(0.55)), lineWidth: 1)
        context.fill(Path(ellipseIn: CGRect(x: position.x - 4.5, y: position.y - 4.5, width: 9, height: 9)),
                     with: .color(color.opacity(0.22)))
        context.fill(Path(ellipseIn: CGRect(x: position.x - 2.5, y: position.y - 2.5, width: 5, height: 5)),
                     with: .color(color))
        context.drawPriceTag(PriceFormatter.price(lastPoint.price, decimals: decimals),
                             y: position.y, geometry: domain.geometry, fill: color)
    }

    private func drawCrosshair(context: GraphicsContext, domain: Domain, at point: CGPoint, color: Color) {
        guard let sample = domain.sample(nearX: point.x) else { return }
        let geometry = domain.geometry
        let x = domain.x(sample.ts)
        let y = domain.y(sample.price)

        context.strokeLine(from: CGPoint(x: x, y: geometry.top),
                           to: CGPoint(x: x, y: geometry.bottom),
                           color: ChartStyle.crosshair, dash: [2, 2])
        context.strokeLine(from: CGPoint(x: 0, y: y),
                           to: CGPoint(x: geometry.plotWidth, y: y),
                           color: ChartStyle.crosshair, dash: [2, 2])
        context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)),
                     with: .color(color))

        context.drawPriceTag(PriceFormatter.price(sample.price, decimals: decimals),
                             y: y, geometry: geometry, fill: ChartStyle.tagFill,
                             text: ChartStyle.tagText)
        let format = domain.span <= 3_600 ? "HH:mm:ss" : "HH:mm"
        context.drawTimeTag(ChartFormatters.string(sample.ts, format),
                            x: x, geometry: geometry, fill: ChartStyle.tagFill,
                            text: ChartStyle.tagText)
    }
}
