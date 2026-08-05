import SwiftUI
import MayStockKit

/// Candlestick chart with an MA20 overlay, a volume pane, last-price marker and
/// a crosshair with axis tags.
///
/// Two things separate this from the previous version: the moving average is
/// computed over the **whole** series and then sliced (computing it over the
/// visible slice produced both wrong values and a 19-bar hole at the left
/// edge), and the time axis labels sit on wall-clock boundaries instead of on
/// whichever indices happened to divide evenly.
struct CandleChartView: View {
    let candles: [Candle]
    let bar: BarInterval
    let decimals: Int

    @State private var hover: CGPoint? = nil

    /// Target horizontal slot per candle; the visible count follows the width.
    private let slotTarget: CGFloat = 4.6
    private let visibleBounds = (min: 30, max: 180)
    private let maLength = 20

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(candles: candles, bar: bar, size: geo.size,
                                slotTarget: slotTarget, bounds: visibleBounds, maLength: maLength)
            ZStack {
                if let layout {
                    Canvas(rendersAsynchronously: false) { context, size in
                        draw(context: context, size: size, layout: layout)
                    }
                    .chartLegend(legend(layout))
                } else {
                    ChartPlaceholder(text: "正在加载 K 线…")
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

    // MARK: Layout

    private struct Layout {
        let geometry: PlotGeometry
        let bar: BarInterval
        let visible: [Candle]
        /// MA20 aligned to `visible`, computed over full history.
        let ma: [Double?]
        let priceTop: CGFloat
        let priceHeight: CGFloat
        let volumeTop: CGFloat
        let volumeHeight: CGFloat
        let minPrice: Double
        let maxPrice: Double
        let maxVolume: Double
        let slot: CGFloat

        init?(candles: [Candle], bar: BarInterval, size: CGSize,
              slotTarget: CGFloat, bounds: (min: Int, max: Int), maLength: Int) {
            let geometry = PlotGeometry(size: size)
            let capacity = min(max(Int(geometry.plotWidth / slotTarget), bounds.min), bounds.max)
            guard candles.count >= 2 else { return nil }

            let count = min(candles.count, capacity)
            let start = candles.count - count
            self.visible = Array(candles[start...])
            self.ma = Array(ChartMath.movingAverage(candles.map(\.close), period: maLength)[start...])
            self.geometry = geometry
            self.bar = bar

            // Price pane on top, volume pane below, with a hairline gap.
            let gap: CGFloat = 6
            let total = geometry.height
            self.volumeHeight = max(14, total * 0.17)
            self.priceTop = geometry.top
            self.priceHeight = max(20, total - volumeHeight - gap)
            self.volumeTop = priceTop + priceHeight + gap

            let rawMin = visible.map(\.low).min() ?? 0
            let rawMax = visible.map(\.high).max() ?? 1
            let pad = max((rawMax - rawMin) * 0.07, max(abs(rawMax), 1) * 0.00005)
            self.minPrice = rawMin - pad
            self.maxPrice = rawMax + pad
            self.maxVolume = max(visible.map(\.volume).max() ?? 1, .leastNonzeroMagnitude)
            self.slot = geometry.plotWidth / CGFloat(max(visible.count, 1))
        }

        var bodyWidth: CGFloat { max(1.5, min(slot * 0.68, 14)) }

        func x(_ index: Int) -> CGFloat { (CGFloat(index) + 0.5) * slot }

        func y(_ price: Double) -> CGFloat {
            let range = max(maxPrice - minPrice, .leastNonzeroMagnitude)
            return priceTop + (1 - CGFloat((price - minPrice) / range)) * priceHeight
        }

        func price(atY y: CGFloat) -> Double {
            let fraction = 1 - Double((y - priceTop) / max(priceHeight, 1))
            return minPrice + fraction * (maxPrice - minPrice)
        }

        func volumeY(_ volume: Double) -> CGFloat {
            volumeTop + volumeHeight * (1 - CGFloat(volume / maxVolume))
        }

        func index(atX x: CGFloat) -> Int? {
            guard x >= 0, x < geometry.plotWidth, !visible.isEmpty else { return nil }
            return min(visible.count - 1, max(0, Int(x / slot)))
        }
    }

    // MARK: Legend

    private func legend(_ layout: Layout) -> [ChartLegendItem] {
        let index = hover.flatMap { layout.index(atX: $0.x) } ?? layout.visible.count - 1
        let candle = layout.visible[index]
        let changePct = candle.open > 0 ? (candle.close - candle.open) / candle.open * 100 : 0
        let format = bar.seconds >= 86_400 ? "MM-dd" : "MM-dd HH:mm"

        // O/H/L/C rather than 开/高/低/收: single Latin letters are half the
        // width of CJK glyphs, which is what lets four prices share one row.
        var items: [ChartLegendItem] = [
            ChartLegendItem(key: "t", value: ChartFormatters.string(candle.ts, format),
                            tint: .secondary, priority: 4),
            ChartLegendItem(key: "o", label: "O",
                            value: PriceFormatter.price(candle.open, decimals: decimals), priority: 6),
            ChartLegendItem(key: "h", label: "H",
                            value: PriceFormatter.price(candle.high, decimals: decimals), priority: 5),
            ChartLegendItem(key: "l", label: "L",
                            value: PriceFormatter.price(candle.low, decimals: decimals), priority: 5),
            .trend("c", label: "C", value: PriceFormatter.price(candle.close, decimals: decimals),
                   isUp: candle.isBullish, priority: 10),
            .trend("p", value: PriceFormatter.signedPercent(changePct),
                   isUp: changePct >= 0, priority: 9),
        ]
        if let average = layout.ma[index] {
            items.append(ChartLegendItem(key: "ma", label: "MA20",
                                         value: PriceFormatter.price(average, decimals: decimals),
                                         tint: .ma, priority: 3))
        }
        items.append(ChartLegendItem(key: "v", label: "量",
                                     value: PriceFormatter.compact(candle.volume),
                                     tint: .secondary, priority: 2))
        return items
    }

    // MARK: Drawing

    private func draw(context: GraphicsContext, size: CGSize, layout: Layout) {
        drawGrid(context: context, layout: layout)
        drawVolume(context: context, layout: layout)
        drawCandles(context: context, layout: layout)
        drawMA(context: context, layout: layout)
        drawLastPrice(context: context, layout: layout)
        drawTimeAxis(context: context, layout: layout)
        if let hover { drawCrosshair(context: context, layout: layout, at: hover) }
    }

    private func drawGrid(context: GraphicsContext, layout: Layout) {
        let geometry = layout.geometry
        for price in ChartMath.valueTicks(lo: layout.minPrice, hi: layout.maxPrice, target: 4) {
            let y = layout.y(price)
            context.strokeLine(from: CGPoint(x: 0, y: y),
                               to: CGPoint(x: geometry.plotWidth, y: y),
                               color: ChartStyle.grid)
            context.drawText(PriceFormatter.price(price, decimals: decimals),
                             font: ChartStyle.axisFont, color: ChartStyle.axisLabel,
                             at: CGPoint(x: geometry.plotWidth + 5, y: y), anchor: .leading)
        }
        // Separator between the price and volume panes.
        context.strokeLine(from: CGPoint(x: 0, y: layout.volumeTop - 3),
                           to: CGPoint(x: geometry.plotWidth, y: layout.volumeTop - 3),
                           color: ChartStyle.gridStrong)
        context.drawText(PriceFormatter.compact(layout.maxVolume),
                         font: ChartStyle.axisFont, color: ChartStyle.axisLabel,
                         at: CGPoint(x: geometry.plotWidth + 5, y: layout.volumeTop + 4), anchor: .leading)
    }

    private func drawCandles(context: GraphicsContext, layout: Layout) {
        let width = layout.bodyWidth
        for (index, candle) in layout.visible.enumerated() {
            let x = layout.x(index)
            let color = ChartStyle.trend(candle.isBullish)

            context.strokeLine(from: CGPoint(x: x, y: layout.y(candle.high)),
                               to: CGPoint(x: x, y: layout.y(candle.low)),
                               color: color.opacity(0.9))

            let top = layout.y(max(candle.open, candle.close))
            let bottom = layout.y(min(candle.open, candle.close))
            let rect = CGRect(x: x - width / 2, y: top,
                              width: width, height: max(1, bottom - top))
            context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, width / 4)),
                         with: .color(color))
        }
    }

    private func drawMA(context: GraphicsContext, layout: Layout) {
        var path = Path()
        var started = false
        for (index, value) in layout.ma.enumerated() {
            guard let value else { continue }
            let point = CGPoint(x: layout.x(index), y: layout.y(value))
            if started { path.addLine(to: point) } else { path.move(to: point); started = true }
        }
        guard started else { return }
        context.stroke(path, with: .color(ChartStyle.ma.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
    }

    private func drawLastPrice(context: GraphicsContext, layout: Layout) {
        guard let last = layout.visible.last else { return }
        let y = layout.y(last.close)
        let color = ChartStyle.trend(last.isBullish)
        context.stroke(
            Path.dashedHorizontal(y: y, from: 0, to: layout.geometry.plotWidth),
            with: .color(color.opacity(0.7)), lineWidth: 1)
        context.drawPriceTag(PriceFormatter.price(last.close, decimals: decimals),
                             y: y, geometry: layout.geometry, fill: color)
    }

    private func drawVolume(context: GraphicsContext, layout: Layout) {
        let width = layout.bodyWidth
        let base = layout.volumeTop + layout.volumeHeight
        for (index, candle) in layout.visible.enumerated() {
            let x = layout.x(index)
            let y = layout.volumeY(candle.volume)
            let rect = CGRect(x: x - width / 2, y: y, width: width, height: max(0.5, base - y))
            context.fill(Path(rect), with: .color(ChartStyle.trend(candle.isBullish).opacity(0.34)))
        }
    }

    private func drawTimeAxis(context: GraphicsContext, layout: Layout) {
        let geometry = layout.geometry
        let ticks = ChartMath.axisTicks(timestamps: layout.visible.map(\.ts),
                                        maxLabels: 5, barSeconds: bar.seconds)
        for tick in ticks {
            let x = layout.x(tick.index)
            guard x > 14, x < geometry.plotWidth - 14 else { continue }
            context.strokeLine(from: CGPoint(x: x, y: geometry.top),
                               to: CGPoint(x: x, y: layout.volumeTop + layout.volumeHeight),
                               color: ChartStyle.grid)
            let format = tick.isMajor || bar.seconds >= 86_400 ? "MM-dd" : "HH:mm"
            context.drawText(ChartFormatters.string(tick.date, format),
                             font: ChartStyle.axisFont,
                             color: tick.isMajor ? .secondary : ChartStyle.axisLabel,
                             at: CGPoint(x: x, y: geometry.axisBaseline), anchor: .bottom)
        }
    }

    private func drawCrosshair(context: GraphicsContext, layout: Layout, at point: CGPoint) {
        guard let index = layout.index(atX: point.x) else { return }
        let geometry = layout.geometry
        let x = layout.x(index)
        let candle = layout.visible[index]

        context.strokeLine(from: CGPoint(x: x, y: geometry.top),
                           to: CGPoint(x: x, y: layout.volumeTop + layout.volumeHeight),
                           color: ChartStyle.crosshair, dash: [2, 2])
        let format = bar.seconds >= 86_400 ? "MM-dd" : "MM-dd HH:mm"
        context.drawTimeTag(ChartFormatters.string(candle.ts, format), x: x, geometry: geometry,
                            fill: ChartStyle.tagFill, text: ChartStyle.tagText)

        // Horizontal arm + price tag only while inside the price pane.
        guard point.y >= layout.priceTop, point.y <= layout.priceTop + layout.priceHeight else { return }
        context.strokeLine(from: CGPoint(x: 0, y: point.y),
                           to: CGPoint(x: geometry.plotWidth, y: point.y),
                           color: ChartStyle.crosshair, dash: [2, 2])
        context.drawPriceTag(PriceFormatter.price(layout.price(atY: point.y), decimals: decimals),
                             y: point.y, geometry: geometry,
                             fill: ChartStyle.tagFill, text: ChartStyle.tagText)
    }
}
