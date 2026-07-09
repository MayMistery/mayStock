import SwiftUI
import MayStockKit

/// Smooth price line with gradient area fill — powered by the sparkline
/// buffer, so it moves tick-by-tick. Trend color from window start → now.
struct LineChartView: View {
    let points: [SparkPoint]
    let decimals: Int

    @State private var hover: CGPoint? = nil
    private let gutter: CGFloat = 58

    var body: some View {
        Group {
            if points.count < 2 {
                ChartPlaceholder(text: "正在收集实时价格…")
            } else {
                GeometryReader { geo in
                    Canvas { context, size in
                        draw(context: context, size: size)
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hover = p
                        case .ended: hover = nil
                        }
                    }
                }
            }
        }
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let plotWidth = max(1, size.width - gutter)
        let top: CGFloat = 8
        let bottom = size.height - 18
        let height = max(1, bottom - top)

        let prices = points.map(\.price)
        guard let rawMin = prices.min(), let rawMax = prices.max() else { return }
        let pad = max((rawMax - rawMin) * 0.08, rawMax * 0.0001)
        let minP = rawMin - pad, maxP = rawMax + pad
        let range = max(maxP - minP, .leastNonzeroMagnitude)

        func x(_ i: Int) -> CGFloat {
            plotWidth * CGFloat(i) / CGFloat(max(points.count - 1, 1))
        }
        func y(_ price: Double) -> CGFloat {
            top + (1 - CGFloat((price - minP) / range)) * height
        }

        let isUp = (prices.last ?? 0) >= (prices.first ?? 0)
        let color = ChartStyle.trend(isUp)

        // Grid + right-side price labels.
        let step = ChartStyle.niceStep(range: maxP - minP)
        var gridPrice = (minP / step).rounded(.up) * step
        while gridPrice <= maxP {
            let gy = y(gridPrice)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: gy))
            line.addLine(to: CGPoint(x: plotWidth, y: gy))
            context.stroke(line, with: .color(ChartStyle.grid), lineWidth: 1)
            context.draw(
                Text(PriceFormatter.price(gridPrice, decimals: decimals))
                    .font(ChartStyle.axisFont).foregroundStyle(ChartStyle.axisLabel),
                at: CGPoint(x: plotWidth + 6, y: gy), anchor: .leading)
            gridPrice += step
        }

        // Price path.
        var line = Path()
        for (i, point) in points.enumerated() {
            let pt = CGPoint(x: x(i), y: y(point.price))
            if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
        }

        // Gradient area under the line.
        var area = line
        area.addLine(to: CGPoint(x: x(points.count - 1), y: bottom))
        area.addLine(to: CGPoint(x: 0, y: bottom))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(
            Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]),
            startPoint: CGPoint(x: 0, y: top),
            endPoint: CGPoint(x: 0, y: bottom)))

        context.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))

        // Latest price marker + tag.
        if let lastPrice = prices.last {
            let lastPoint = CGPoint(x: x(points.count - 1), y: y(lastPrice))
            context.fill(Path(ellipseIn: CGRect(x: lastPoint.x - 2.5, y: lastPoint.y - 2.5, width: 5, height: 5)),
                         with: .color(color))
            let tag = CGRect(x: plotWidth + 2, y: lastPoint.y - 8, width: gutter - 4, height: 16)
            context.fill(Path(roundedRect: tag, cornerRadius: 4), with: .color(color))
            context.draw(
                Text(PriceFormatter.price(lastPrice, decimals: decimals))
                    .font(ChartStyle.axisFont.weight(.semibold)).foregroundStyle(.white),
                at: CGPoint(x: tag.midX, y: tag.midY), anchor: .center)
        }

        // Time axis: window start / midpoint / now.
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        for fraction in [0.0, 0.5, 1.0] {
            let idx = Int(Double(points.count - 1) * fraction)
            context.draw(
                Text(formatter.string(from: points[idx].ts))
                    .font(ChartStyle.axisFont).foregroundStyle(ChartStyle.axisLabel),
                at: CGPoint(x: x(idx), y: size.height - 4),
                anchor: fraction == 0 ? .bottomLeading : (fraction == 1 ? .bottomTrailing : .bottom))
        }

        // Crosshair readout.
        if let hover, hover.x < plotWidth {
            let idx = min(points.count - 1,
                          max(0, Int(round(hover.x / plotWidth * CGFloat(points.count - 1)))))
            let point = points[idx]
            let pt = CGPoint(x: x(idx), y: y(point.price))
            var cross = Path()
            cross.move(to: CGPoint(x: pt.x, y: top))
            cross.addLine(to: CGPoint(x: pt.x, y: bottom))
            context.stroke(cross, with: .color(ChartStyle.crosshair),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            context.fill(Path(ellipseIn: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)),
                         with: .color(color))

            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss"
            let label = "\(timeFormatter.string(from: point.ts))  \(PriceFormatter.price(point.price, decimals: decimals))"
            let anchorX: CGFloat = pt.x > plotWidth / 2 ? pt.x - 6 : pt.x + 6
            context.draw(
                Text(label).font(ChartStyle.readoutFont).foregroundStyle(.primary),
                at: CGPoint(x: anchorX, y: top + 2),
                anchor: pt.x > plotWidth / 2 ? .topTrailing : .topLeading)
        }
    }
}
