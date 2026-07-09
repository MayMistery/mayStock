import SwiftUI
import MayStockKit

/// Market depth chart: cumulative bid/ask volume around mid price, with a
/// hover readout (price / cumulative size / distance from mid).
struct DepthChartView: View {
    let book: OrderBook?
    let decimals: Int

    @State private var hover: CGPoint? = nil

    var body: some View {
        Group {
            if let book, !book.bids.isEmpty, !book.asks.isEmpty {
                GeometryReader { geo in
                    Canvas { context, size in
                        draw(context: context, size: size, book: book)
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hover = p
                        case .ended: hover = nil
                        }
                    }
                }
            } else {
                ChartPlaceholder(text: "正在加载盘口深度…")
            }
        }
    }

    private func draw(context: GraphicsContext, size: CGSize, book: OrderBook) {
        let top: CGFloat = 8
        let bottom = size.height - 18
        let height = max(1, bottom - top)
        let width = size.width

        let bids = book.cumulativeBids // descending price, rising cumulative
        let asks = book.cumulativeAsks // ascending price, rising cumulative
        guard let mid = book.mid,
              let minPrice = bids.last?.price,
              let maxPrice = asks.last?.price,
              maxPrice > minPrice else { return }

        // Symmetric price window around mid keeps the mid line centered.
        let span = max(mid - minPrice, maxPrice - mid)
        let lo = mid - span, hi = mid + span
        let maxCum = max(bids.last?.size ?? 1, asks.last?.size ?? 1)

        func x(_ price: Double) -> CGFloat {
            CGFloat((price - lo) / (hi - lo)) * width
        }
        func y(_ cum: Double) -> CGFloat {
            top + (1 - CGFloat(cum / maxCum) * 0.92) * height
        }

        // Step-line builder (order books are step functions, not slopes).
        func steps(_ levels: [BookLevel], closingEdgeX: CGFloat) -> (line: Path, area: Path) {
            var line = Path()
            guard let first = levels.first else { return (line, line) }
            line.move(to: CGPoint(x: x(first.price), y: y(first.size)))
            var lastY = y(first.size)
            for level in levels.dropFirst() {
                line.addLine(to: CGPoint(x: x(level.price), y: lastY)) // horizontal
                lastY = y(level.size)
                line.addLine(to: CGPoint(x: x(level.price), y: lastY)) // vertical
            }
            var area = line
            let endX = x(levels.last!.price)
            area.addLine(to: CGPoint(x: endX, y: bottom))
            area.addLine(to: CGPoint(x: closingEdgeX, y: bottom))
            area.closeSubpath()
            return (line, area)
        }

        let bidShape = steps(bids, closingEdgeX: x(bids.first!.price))
        let askShape = steps(asks, closingEdgeX: x(asks.first!.price))

        context.fill(bidShape.area, with: .color(ChartStyle.up.opacity(0.22)))
        context.stroke(bidShape.line, with: .color(ChartStyle.up), lineWidth: 1.5)
        context.fill(askShape.area, with: .color(ChartStyle.down.opacity(0.22)))
        context.stroke(askShape.line, with: .color(ChartStyle.down), lineWidth: 1.5)

        // Mid price line + label.
        let midX = x(mid)
        var midLine = Path()
        midLine.move(to: CGPoint(x: midX, y: top))
        midLine.addLine(to: CGPoint(x: midX, y: bottom))
        context.stroke(midLine, with: .color(ChartStyle.crosshair),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        context.draw(
            Text(PriceFormatter.price(mid, decimals: decimals))
                .font(ChartStyle.axisFont.weight(.medium)).foregroundStyle(.secondary),
            at: CGPoint(x: midX, y: top), anchor: .top)

        // Price axis: window edges.
        context.draw(Text(PriceFormatter.price(lo, decimals: decimals))
            .font(ChartStyle.axisFont).foregroundStyle(ChartStyle.axisLabel),
            at: CGPoint(x: 4, y: size.height - 4), anchor: .bottomLeading)
        context.draw(Text(PriceFormatter.price(hi, decimals: decimals))
            .font(ChartStyle.axisFont).foregroundStyle(ChartStyle.axisLabel),
            at: CGPoint(x: width - 4, y: size.height - 4), anchor: .bottomTrailing)

        // Hover readout.
        if let hover, hover.y < bottom {
            let price = lo + Double(hover.x / width) * (hi - lo)
            let isBidSide = price < mid
            let levels = isBidSide ? bids : asks
            // Cumulative size at this price distance.
            let cum: Double
            if isBidSide {
                cum = levels.last(where: { $0.price >= price })?.size ?? 0
            } else {
                cum = levels.last(where: { $0.price <= price })?.size ?? 0
            }
            let distancePct = abs(price - mid) / mid * 100
            let label = "\(PriceFormatter.price(price, decimals: decimals))  " +
                        "累计 \(PriceFormatter.compact(cum))  " +
                        String(format: "±%.2f%%", distancePct)
            var cross = Path()
            cross.move(to: CGPoint(x: hover.x, y: top))
            cross.addLine(to: CGPoint(x: hover.x, y: bottom))
            context.stroke(cross, with: .color(ChartStyle.crosshair),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            context.draw(
                Text(label).font(ChartStyle.readoutFont)
                    .foregroundStyle(isBidSide ? ChartStyle.up : ChartStyle.down),
                at: CGPoint(x: hover.x > width / 2 ? hover.x - 6 : hover.x + 6, y: top + 14),
                anchor: hover.x > width / 2 ? .topTrailing : .topLeading)
        }
    }
}
