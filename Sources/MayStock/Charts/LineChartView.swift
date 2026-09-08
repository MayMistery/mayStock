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
///
/// On a market with sessions the clock keeps running while the tape does not,
/// and a time-proportional axis would spend most of a five-day window on
/// nights and weekends. There, every gap longer than a few minutes is drawn
/// at a fixed small width and marked, so the line is trading time — which is
/// how every stock chart is drawn.
struct LineChartView: View {
    let points: [SparkPoint]
    let window: LineWindow
    let decimals: Int
    var venue: Venue = .okx

    @State private var hover: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            let domain = Domain(points: points, window: window, venue: venue, size: geo.size)
            ZStack {
                if let domain {
                    Canvas(rendersAsynchronously: false) { context, size in
                        draw(context: context, size: size, domain: domain)
                    }
                    .chartLegend(legend(domain))
                } else {
                    ChartPlaceholder(text: venue.tradesContinuously ? "正在收集实时价格…" : "本窗口还没有成交")
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
        /// A gap between samples longer than this is closed-market time on a
        /// venue with sessions, and is collapsed.
        static let gapThreshold: TimeInterval = 5 * 60
        /// What a collapsed gap is drawn as, in axis seconds.
        static let collapsedGap: TimeInterval = 90

        let geometry: PlotGeometry
        let series: [SparkPoint]
        /// Axis position of each `series` point, in axis seconds from `start`.
        let positions: [TimeInterval]
        let start: Date
        let end: Date
        /// Length of the axis in axis seconds — clock seconds on a continuous
        /// market, trading seconds plus collapsed gaps on one with sessions.
        let span: TimeInterval
        let collapsesGaps: Bool
        /// Where collapsed gaps sit on the axis, for the markers.
        let gaps: [TimeInterval]
        let minPrice: Double
        let maxPrice: Double
        let open: Double
        let last: Double
        let high: Double
        let low: Double
        /// Left edge of real data, when the window reaches further back than
        /// the history we hold.
        let coverageStart: Date
        let timeZone: TimeZone

        init?(points: [SparkPoint], window: LineWindow, venue: Venue, size: CGSize) {
            let geometry = PlotGeometry(size: size)
            let now = Date()
            let end = max(now, points.last?.ts ?? now)
            let collapsesGaps = !venue.tradesContinuously
            // A session window is as long as what it holds; a trailing window
            // is a fixed stretch of clock time ending now.
            let start: Date
            if let seconds = window.seconds, !collapsesGaps {
                start = end.addingTimeInterval(-seconds)
            } else if let seconds = window.seconds, let first = points.first?.ts {
                start = max(first, end.addingTimeInterval(-seconds))
            } else {
                start = points.first?.ts ?? end
            }

            let inWindow = points.filter { $0.ts >= start && $0.ts <= end }
            guard inWindow.count >= 2 else { return nil }

            // One or two points per horizontal pixel is plenty; extremes survive.
            let series = ChartMath.downsample(inWindow, buckets: Int(geometry.plotWidth))
            self.series = series
            self.geometry = geometry
            self.start = start
            self.end = end
            self.collapsesGaps = collapsesGaps
            self.coverageStart = inWindow[0].ts
            self.timeZone = collapsesGaps ? venue.timeZone : .current

            if collapsesGaps {
                // Trading time: each step is the real interval, except across
                // a gap, which is drawn at a fixed small width.
                var positions: [TimeInterval] = []
                var gaps: [TimeInterval] = []
                var cursor: TimeInterval = 0
                positions.reserveCapacity(series.count)
                for (index, point) in series.enumerated() {
                    if index > 0 {
                        let dt = point.ts.timeIntervalSince(series[index - 1].ts)
                        if dt > Self.gapThreshold {
                            gaps.append(cursor + Self.collapsedGap / 2)
                            cursor += Self.collapsedGap
                        } else {
                            cursor += dt
                        }
                    }
                    positions.append(cursor)
                }
                self.positions = positions
                self.gaps = gaps
                self.span = max(cursor, 1)
            } else {
                self.positions = series.map { $0.ts.timeIntervalSince(start) }
                self.gaps = []
                self.span = max(end.timeIntervalSince(start), 1)
            }

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

        /// Axis position → pixel.
        func x(position: TimeInterval) -> CGFloat {
            geometry.plotWidth * CGFloat(min(max(position / span, 0), 1))
        }

        func x(index: Int) -> CGFloat { x(position: positions[index]) }

        /// A clock instant → pixel, on a continuous axis only.
        func x(_ ts: Date) -> CGFloat {
            x(position: ts.timeIntervalSince(start))
        }

        func y(_ price: Double) -> CGFloat {
            let range = max(maxPrice - minPrice, .leastNonzeroMagnitude)
            return geometry.top + (1 - CGFloat((price - minPrice) / range)) * geometry.height
        }

        /// Index of the sample nearest a cursor position, for the crosshair.
        func index(nearX x: CGFloat) -> Int? {
            guard !series.isEmpty else { return nil }
            let target = TimeInterval(min(max(x / geometry.plotWidth, 0), 1)) * span
            var best = 0
            var bestDelta = abs(positions[0] - target)
            for index in positions.indices.dropFirst() {
                let delta = abs(positions[index] - target)
                if delta < bestDelta { best = index; bestDelta = delta }
            }
            return best
        }

        func sample(nearX x: CGFloat) -> SparkPoint? {
            index(nearX: x).map { series[$0] }
        }

        /// The axis ticks: clock instants on a continuous axis, or the first
        /// sample on or after each candidate instant when gaps are collapsed —
        /// a tick that lands inside a collapsed gap is dropped rather than
        /// drawn where nothing traded.
        var timeTicks: [(x: CGFloat, date: Date, major: Bool)] {
            if !collapsesGaps {
                return ChartMath.timeTicks(from: start, to: end, maxLabels: 5)
                    .map { (x($0), $0, false) }
            }
            var ticks: [(x: CGFloat, date: Date, major: Bool)] = []
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let multiDay = !calendar.isDate(series[0].ts, inSameDayAs: series[series.count - 1].ts)
            if multiDay {
                // One tick per session, at its first sample.
                var lastDay: Date?
                for (index, point) in series.enumerated() {
                    let day = calendar.startOfDay(for: point.ts)
                    guard day != lastDay else { continue }
                    lastDay = day
                    ticks.append((x(index: index), point.ts, true))
                }
                return ticks
            }
            let tradingSpan = span - Double(gaps.count) * Self.collapsedGap
            let step = ChartMath.niceTimeStep(span: tradingSpan, maxLabels: 5)
            var next = ceil(series[0].ts.timeIntervalSince1970 / step) * step
            for (index, point) in series.enumerated() where point.ts.timeIntervalSince1970 >= next {
                // Skip ticks that fell inside a gap: the sample is far past them.
                if point.ts.timeIntervalSince1970 - next < Self.gapThreshold {
                    ticks.append((x(index: index), Date(timeIntervalSince1970: next), false))
                }
                next = ceil((point.ts.timeIntervalSince1970 + 1) / step) * step
            }
            return ticks
        }
    }

    // MARK: Legend

    private func legend(_ domain: Domain) -> [ChartLegendItem] {
        let probe = hover.flatMap { $0.x < domain.geometry.plotWidth ? domain.sample(nearX: $0.x) : nil }
        if let probe {
            let delta = domain.open > 0 ? (probe.price - domain.open) / domain.open * 100 : 0
            return [
                ChartLegendItem(key: "t", value: ChartFormatters.string(probe.ts, hoverFormat(domain), timeZone: domain.timeZone),
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

    private func hoverFormat(_ domain: Domain) -> String {
        let clockSpan = domain.end.timeIntervalSince(domain.start)
        if clockSpan > 86_400 { return "MM-dd HH:mm" }
        return clockSpan <= 3_600 ? "HH:mm:ss" : "HH:mm"
    }

    // MARK: Drawing

    private func draw(context: GraphicsContext, size: CGSize, domain: Domain) {
        let geometry = domain.geometry
        let color = ChartStyle.trend(domain.isUp)

        drawGrid(context: context, domain: domain)
        drawUncovered(context: context, domain: domain)
        drawGaps(context: context, domain: domain)

        // Price path.
        var line = Path()
        for index in domain.series.indices {
            let position = CGPoint(x: domain.x(index: index), y: domain.y(domain.series[index].price))
            if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
        }

        // Gradient area under the line.
        if let firstIndex = domain.series.indices.first, let lastIndex = domain.series.indices.last {
            var area = line
            area.addLine(to: CGPoint(x: domain.x(index: lastIndex), y: geometry.bottom))
            area.addLine(to: CGPoint(x: domain.x(index: firstIndex), y: geometry.bottom))
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

        let format = ChartMath.timeAxisFormat(span: domain.end.timeIntervalSince(domain.start))
        for tick in domain.timeTicks {
            let x = tick.x
            guard x > 12, x < geometry.plotWidth - 12 else { continue }
            context.strokeLine(from: CGPoint(x: x, y: geometry.top),
                               to: CGPoint(x: x, y: geometry.bottom),
                               color: ChartStyle.grid)
            context.drawText(ChartFormatters.string(tick.date, tick.major ? "MM-dd" : format, timeZone: domain.timeZone),
                             font: ChartStyle.axisFont,
                             color: tick.major ? .secondary : ChartStyle.axisLabel,
                             at: CGPoint(x: x, y: geometry.axisBaseline), anchor: .bottom)
        }
    }

    /// Shade the stretch of the window we simply do not have data for, instead
    /// of stretching what we do have across it and lying about the time base.
    private func drawUncovered(context: GraphicsContext, domain: Domain) {
        guard !domain.collapsesGaps else { return }
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

    /// A closed-market gap, drawn as a faint band so a five-day line is
    /// visibly five sessions rather than one unbroken tape.
    private func drawGaps(context: GraphicsContext, domain: Domain) {
        guard domain.collapsesGaps else { return }
        let width = domain.x(position: Domain.collapsedGap) - domain.x(position: 0)
        for gap in domain.gaps {
            let centre = domain.x(position: gap)
            let rect = CGRect(x: centre - width / 2, y: domain.geometry.top,
                              width: width, height: domain.geometry.height)
            context.fill(Path(rect), with: .color(Color.primary.opacity(0.05)))
        }
    }

    /// Faint line at the window's opening price — the reference the trend
    /// colour and the percentage in the legend are measured against.
    private func drawOpenBaseline(context: GraphicsContext, domain: Domain) {
        let y = domain.y(domain.open)
        let from = domain.collapsesGaps ? 0 : domain.x(domain.coverageStart)
        context.stroke(
            Path.dashedHorizontal(y: y, from: from, to: domain.geometry.plotWidth),
            with: .color(Color.secondary.opacity(0.35)), lineWidth: 1)
    }

    private func drawLast(context: GraphicsContext, domain: Domain, color: Color) {
        guard let lastIndex = domain.series.indices.last else { return }
        let position = CGPoint(x: domain.x(index: lastIndex), y: domain.y(domain.series[lastIndex].price))
        context.stroke(
            Path.dashedHorizontal(y: position.y, from: 0, to: domain.geometry.plotWidth),
            with: .color(color.opacity(0.55)), lineWidth: 1)
        context.fill(Path(ellipseIn: CGRect(x: position.x - 4.5, y: position.y - 4.5, width: 9, height: 9)),
                     with: .color(color.opacity(0.22)))
        context.fill(Path(ellipseIn: CGRect(x: position.x - 2.5, y: position.y - 2.5, width: 5, height: 5)),
                     with: .color(color))
        context.drawPriceTag(PriceFormatter.price(domain.series[lastIndex].price, decimals: decimals),
                             y: position.y, geometry: domain.geometry, fill: color)
    }

    private func drawCrosshair(context: GraphicsContext, domain: Domain, at point: CGPoint, color: Color) {
        guard let index = domain.index(nearX: point.x) else { return }
        let sample = domain.series[index]
        let geometry = domain.geometry
        let x = domain.x(index: index)
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
        context.drawTimeTag(ChartFormatters.string(sample.ts, hoverFormat(domain), timeZone: domain.timeZone),
                            x: x, geometry: geometry, fill: ChartStyle.tagFill,
                            text: ChartStyle.tagText)
    }
}
