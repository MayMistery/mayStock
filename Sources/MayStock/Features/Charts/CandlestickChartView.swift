import SwiftUI

struct CandlestickChartView: View {
    let candles: [OHLC]

    private let visibleCount = 50
    private let volumeHeightRatio: CGFloat = 0.2
    private let maLength = 20

    var body: some View {
        if candles.isEmpty {
            ContentUnavailableView("No Data", systemImage: "chart.bar.fill")
        } else {
            Canvas { context, size in
                let visible = Array(candles.suffix(visibleCount))
                guard !visible.isEmpty else { return }

                let allPrices = visible.flatMap { [$0.high, $0.low] }
                guard let minPrice = allPrices.min(), let maxPrice = allPrices.max() else { return }
                let priceRange = max(maxPrice - minPrice, 0.01)

                let padding = EdgeInsets(top: 8, leading: 4, bottom: 20, trailing: 50)
                let chartWidth = size.width - padding.leading - padding.trailing
                let totalHeight = size.height - padding.top - padding.bottom
                let mainHeight = totalHeight * (1 - volumeHeightRatio)
                let volHeight = totalHeight * volumeHeightRatio
                let volTop = padding.top + mainHeight + 4

                let spacing = chartWidth / CGFloat(visible.count)
                let candleWidth = max(2, spacing * 0.65)

                // Grid lines
                drawGrid(context: context, size: size, padding: padding, mainHeight: mainHeight, minPrice: minPrice, maxPrice: maxPrice, priceRange: priceRange)

                // MA20 line
                drawMA(context: context, visible: visible, padding: padding, mainHeight: mainHeight, minPrice: minPrice, priceRange: priceRange, spacing: spacing)

                // Candles
                let maxVol = visible.map(\.volume).max() ?? 1

                for (index, candle) in visible.enumerated() {
                    let x = padding.leading + CGFloat(index) * spacing + spacing / 2
                    let color: Color = candle.isBullish ? .green : .red

                    // Wick
                    let wickTop = padding.top + (1 - (candle.high - minPrice) / priceRange) * mainHeight
                    let wickBottom = padding.top + (1 - (candle.low - minPrice) / priceRange) * mainHeight
                    var wickPath = Path()
                    wickPath.move(to: CGPoint(x: x, y: wickTop))
                    wickPath.addLine(to: CGPoint(x: x, y: wickBottom))
                    context.stroke(wickPath, with: .color(color), lineWidth: 1)

                    // Body
                    let bodyTop = padding.top + (1 - (max(candle.open, candle.close) - minPrice) / priceRange) * mainHeight
                    let bodyBottom = padding.top + (1 - (min(candle.open, candle.close) - minPrice) / priceRange) * mainHeight
                    let bodyH = max(1, bodyBottom - bodyTop)
                    let bodyRect = CGRect(x: x - candleWidth / 2, y: bodyTop, width: candleWidth, height: bodyH)
                    context.fill(Path(bodyRect), with: .color(color))

                    // Volume bar
                    let volBarHeight = CGFloat(candle.volume / maxVol) * (volHeight - 4)
                    let volRect = CGRect(x: x - candleWidth / 2, y: volTop + (volHeight - 4) - volBarHeight, width: candleWidth, height: volBarHeight)
                    context.fill(Path(volRect), with: .color(color.opacity(0.5)))
                }

                // Current price line
                if let last = visible.last {
                    let y = padding.top + (1 - (last.close - minPrice) / priceRange) * mainHeight
                    drawDashedLine(context: context, y: y, from: padding.leading, to: size.width - padding.trailing, color: last.isBullish ? .green : .red)

                    // Price label
                    let priceText = formatPrice(last.close)
                    let labelRect = CGRect(x: size.width - padding.trailing + 4, y: y - 8, width: 46, height: 16)
                    context.fill(Path(labelRect), with: .color(last.isBullish ? .green : .red))
                    context.draw(Text(priceText).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(.white), in: labelRect)
                }

                // X-axis time labels
                drawTimeLabels(context: context, visible: visible, padding: padding, mainHeight: mainHeight, volHeight: volHeight, spacing: spacing, size: size)
            }
        }
    }

    private func drawGrid(context: GraphicsContext, size: CGSize, padding: EdgeInsets, mainHeight: CGFloat, minPrice: Double, maxPrice: Double, priceRange: Double) {
        let gridCount = 4
        for i in 0...gridCount {
            let ratio = CGFloat(i) / CGFloat(gridCount)
            let y = padding.top + ratio * mainHeight
            var path = Path()
            path.move(to: CGPoint(x: padding.leading, y: y))
            path.addLine(to: CGPoint(x: size.width - padding.trailing, y: y))
            context.stroke(path, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)

            let price = maxPrice - Double(ratio) * priceRange
            let label = formatPrice(price)
            let labelRect = CGRect(x: size.width - padding.trailing + 4, y: y - 6, width: 46, height: 12)
            context.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), in: labelRect)
        }
    }

    private func drawMA(context: GraphicsContext, visible: [OHLC], padding: EdgeInsets, mainHeight: CGFloat, minPrice: Double, priceRange: Double, spacing: CGFloat) {
        guard visible.count >= maLength else { return }
        var maPath = Path()
        var started = false
        for i in (maLength - 1)..<visible.count {
            let slice = visible[(i - maLength + 1)...i]
            let avg = slice.map(\.close).reduce(0, +) / Double(maLength)
            let x = padding.leading + CGFloat(i) * spacing + spacing / 2
            let y = padding.top + (1 - (avg - minPrice) / priceRange) * mainHeight
            if !started { maPath.move(to: CGPoint(x: x, y: y)); started = true }
            else { maPath.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(maPath, with: .color(.orange.opacity(0.8)), lineWidth: 1.2)
    }

    private func drawDashedLine(context: GraphicsContext, y: CGFloat, from: CGFloat, to: CGFloat, color: Color) {
        var path = Path()
        var x = from
        while x < to {
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: min(x + 4, to), y: y))
            x += 7
        }
        context.stroke(path, with: .color(color.opacity(0.8)), lineWidth: 1)
    }

    private func drawTimeLabels(context: GraphicsContext, visible: [OHLC], padding: EdgeInsets, mainHeight: CGFloat, volHeight: CGFloat, spacing: CGFloat, size: CGSize) {
        let labelCount = min(5, visible.count)
        guard labelCount > 1 else { return }
        let step = visible.count / labelCount
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        for i in stride(from: 0, to: visible.count, by: step) {
            let x = padding.leading + CGFloat(i) * spacing + spacing / 2
            let y = padding.top + mainHeight + volHeight + 6
            let time = formatter.string(from: visible[i].timestamp)
            let rect = CGRect(x: x - 16, y: y, width: 32, height: 12)
            context.draw(Text(time).font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary), in: rect)
        }
    }

    private func formatPrice(_ price: Double) -> String {
        if price >= 10000 { return String(format: "%.0f", price) }
        if price >= 100 { return String(format: "%.1f", price) }
        return String(format: "%.2f", price)
    }
}
