import SwiftUI
import MayStockKit

/// Candlestick chart with MA20 overlay, volume strip, last-price line and a
/// crosshair with an OHLCV readout. Index-based layout (no time-drift), fully
/// Canvas-drawn for high-frequency updates.
struct CandleChartView: View {
    let candles: [Candle]
    let bar: BarInterval
    let decimals: Int

    @State private var hover: CGPoint? = nil

    private let maxVisible = 96
    private let priceGutter: CGFloat = 58
    private let volumeRatio: CGFloat = 0.16
    private let maLength = 20

    var body: some View {
        Group {
            if candles.count < 2 {
                ChartPlaceholder(text: "正在加载 K 线…")
            } else {
                GeometryReader { geo in
                    let layout = Layout(candles: candles, size: geo.size,
                                        maxVisible: maxVisible, gutter: priceGutter,
                                        volumeRatio: volumeRatio)
                    ZStack(alignment: .topLeading) {
                        Canvas { context, size in
                            draw(context: context, size: size, layout: layout)
                        }
                        if let hover, let idx = layout.index(atX: hover.x) {
                            readout(candle: layout.visible[idx])
                                .padding(6)
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hover = point
                        case .ended: hover = nil
                        }
                    }
                }
            }
        }
    }

    // MARK: Layout maths

    private struct Layout {
        let visible: [Candle]
        let size: CGSize
        let gutter: CGFloat
        let plotWidth: CGFloat
        let priceTop: CGFloat = 6
        let priceHeight: CGFloat
        let volumeTop: CGFloat
        let volumeHeight: CGFloat
        let minPrice: Double
        let maxPrice: Double
        let maxVolume: Double
        let step: CGFloat

        init(candles: [Candle], size: CGSize, maxVisible: Int, gutter: CGFloat, volumeRatio: CGFloat) {
            self.visible = Array(candles.suffix(maxVisible))
            self.size = size
            self.gutter = gutter
            self.plotWidth = max(1, size.width - gutter)
            let totalHeight = max(1, size.height - 10)
            self.volumeHeight = totalHeight * volumeRatio
            self.priceHeight = totalHeight - volumeHeight - 6
            self.volumeTop = priceTop + priceHeight + 6

            let lows = visible.map(\.low), highs = visible.map(\.high)
            let rawMin = lows.min() ?? 0, rawMax = highs.max() ?? 1
            let pad = max((rawMax - rawMin) * 0.06, rawMax * 0.0001)
            self.minPrice = rawMin - pad
            self.maxPrice = rawMax + pad
            self.maxVolume = max(visible.map(\.volume).max() ?? 1, .leastNonzeroMagnitude)
            self.step = plotWidth / CGFloat(max(visible.count, 1))
        }

        func x(_ index: Int) -> CGFloat { (CGFloat(index) + 0.5) * step }

        func y(_ price: Double) -> CGFloat {
            let range = max(maxPrice - minPrice, .leastNonzeroMagnitude)
            return priceTop + (1 - CGFloat((price - minPrice) / range)) * priceHeight
        }

        func volumeY(_ volume: Double) -> CGFloat {
            volumeTop + volumeHeight * (1 - CGFloat(volume / maxVolume))
        }

        func index(atX x: CGFloat) -> Int? {
            guard x >= 0, x < plotWidth, !visible.isEmpty else { return nil }
            return min(visible.count - 1, max(0, Int(x / step)))
        }
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
        let step = ChartStyle.niceStep(range: layout.maxPrice - layout.minPrice)
        var price = (layout.minPrice / step).rounded(.up) * step
        while price <= layout.maxPrice {
            let y = layout.y(price)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: layout.plotWidth, y: y))
            context.stroke(line, with: .color(ChartStyle.grid), lineWidth: 1)
            context.draw(
                Text(PriceFormatter.price(price, decimals: decimals))
                    .font(ChartStyle.axisFont).foregroundStyle(ChartStyle.axisLabel),
                at: CGPoint(x: layout.plotWidth + 6, y: y), anchor: .leading)
            price += step
        }
    }

    private func drawCandles(context: GraphicsContext, layout: Layout) {
        let bodyWidth = max(1.5, layout.step * 0.62)
        for (i, candle) in layout.visible.enumerated() {
            let x = layout.x(i)
            let color = ChartStyle.trend(candle.isBullish)

            var wick = Path()
            wick.move(to: CGPoint(x: x, y: layout.y(candle.high)))
            wick.addLine(to: CGPoint(x: x, y: layout.y(candle.low)))
            context.stroke(wick, with: .color(color.opacity(0.9)), lineWidth: 1)

            let top = layout.y(max(candle.open, candle.close))
            let bottom = layout.y(min(candle.open, candle.close))
            let rect = CGRect(x: x - bodyWidth / 2, y: top,
                              width: bodyWidth, height: max(1, bottom - top))
            context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, bodyWidth / 4)),
                         with: .color(color))
        }
    }

    private func drawMA(context: GraphicsContext, layout: Layout) {
        let values = layout.visible.map(\.close)
        guard values.count > maLength else { return }
        var path = Path()
        var sum = values.prefix(maLength).reduce(0, +)
        var started = false
        for i in (maLength - 1)..<values.count {
            if i >= maLength { sum += values[i] - values[i - maLength] }
            let avg = sum / Double(maLength)
            let point = CGPoint(x: layout.x(i), y: layout.y(avg))
            if started { path.addLine(to: point) } else { path.move(to: point); started = true }
        }
        context.stroke(path, with: .color(ChartStyle.ma.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
    }

    private func drawLastPrice(context: GraphicsContext, layout: Layout) {
        guard let last = layout.visible.last else { return }
        let y = layout.y(last.close)
        let color = ChartStyle.trend(last.isBullish)
        context.stroke(
            Path.dashedHorizontal(y: y, from: 0, to: layout.plotWidth),
            with: .color(color.opacity(0.75)), lineWidth: 1)

        let label = PriceFormatter.price(last.close, decimals: decimals)
        let tag = CGRect(x: layout.plotWidth + 2, y: y - 8, width: layout.gutter - 4, height: 16)
        context.fill(Path(roundedRect: tag, cornerRadius: 4), with: .color(color))
        context.draw(
            Text(label).font(ChartStyle.axisFont.weight(.semibold)).foregroundStyle(.white),
            at: CGPoint(x: tag.midX, y: tag.midY), anchor: .center)
    }

    private func drawVolume(context: GraphicsContext, layout: Layout) {
        let bodyWidth = max(1.5, layout.step * 0.62)
        for (i, candle) in layout.visible.enumerated() {
            let x = layout.x(i)
            let y = layout.volumeY(candle.volume)
            let rect = CGRect(x: x - bodyWidth / 2, y: y,
                              width: bodyWidth,
                              height: max(0.5, layout.volumeTop + layout.volumeHeight - y))
            context.fill(Path(rect), with: .color(ChartStyle.trend(candle.isBullish).opacity(0.35)))
        }
    }

    private func drawTimeAxis(context: GraphicsContext, layout: Layout) {
        guard layout.visible.count > 4 else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = bar.seconds >= 86_400 ? "MM-dd" : "HH:mm"
        let count = 4
        for slot in 0...count {
            let idx = Int(round(Double(layout.visible.count - 1) * Double(slot) / Double(count)))
            let x = layout.x(idx)
            context.draw(
                Text(formatter.string(from: layout.visible[idx].ts))
                    .font(ChartStyle.axisFont).foregroundStyle(ChartStyle.axisLabel),
                at: CGPoint(x: x, y: layout.size.height - 4), anchor: .center)
        }
    }

    private func drawCrosshair(context: GraphicsContext, layout: Layout, at point: CGPoint) {
        guard let idx = layout.index(atX: point.x) else { return }
        let x = layout.x(idx)
        var vertical = Path()
        vertical.move(to: CGPoint(x: x, y: layout.priceTop))
        vertical.addLine(to: CGPoint(x: x, y: layout.volumeTop + layout.volumeHeight))
        context.stroke(vertical, with: .color(ChartStyle.crosshair),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

        if point.y >= layout.priceTop, point.y <= layout.priceTop + layout.priceHeight {
            var horizontal = Path()
            horizontal.move(to: CGPoint(x: 0, y: point.y))
            horizontal.addLine(to: CGPoint(x: layout.plotWidth, y: point.y))
            context.stroke(horizontal, with: .color(ChartStyle.crosshair),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
    }

    private func readout(candle: Candle) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = bar.seconds >= 86_400 ? "MM-dd" : "MM-dd HH:mm"
        let color = ChartStyle.trend(candle.isBullish)
        return HStack(spacing: 8) {
            Text(formatter.string(from: candle.ts)).foregroundStyle(.secondary)
            Text("开 \(PriceFormatter.price(candle.open, decimals: decimals))")
            Text("高 \(PriceFormatter.price(candle.high, decimals: decimals))")
            Text("低 \(PriceFormatter.price(candle.low, decimals: decimals))")
            Text("收 \(PriceFormatter.price(candle.close, decimals: decimals))").foregroundStyle(color)
            Text("量 \(PriceFormatter.compact(candle.volume))").foregroundStyle(.secondary)
        }
        .font(ChartStyle.readoutFont)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Shared empty-state for all charts.
struct ChartPlaceholder: View {
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
