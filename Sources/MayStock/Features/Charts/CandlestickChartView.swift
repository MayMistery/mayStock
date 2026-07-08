import SwiftUI

struct CandlestickChartView: View {
    let candles: [OHLC]

    var body: some View {
        if candles.isEmpty {
            ContentUnavailableView("No Data", systemImage: "chart.bar.fill")
        } else {
            Canvas { context, size in
                let allPrices = candles.flatMap { [$0.high, $0.low] }
                guard let minPrice = allPrices.min(), let maxPrice = allPrices.max(), maxPrice > minPrice else { return }

                let priceRange = maxPrice - minPrice
                let padding: CGFloat = 8
                let chartWidth = size.width - padding * 2
                let chartHeight = size.height - padding * 2
                let candleWidth = max(2, chartWidth / CGFloat(candles.count) - 2)
                let spacing = chartWidth / CGFloat(candles.count)

                for (index, candle) in candles.enumerated() {
                    let x = padding + CGFloat(index) * spacing + spacing / 2
                    let color: Color = candle.isBullish ? .green : .red

                    let wickTop = padding + (1 - (candle.high - minPrice) / priceRange) * chartHeight
                    let wickBottom = padding + (1 - (candle.low - minPrice) / priceRange) * chartHeight
                    let wickPath = Path { path in
                        path.move(to: CGPoint(x: x, y: wickTop))
                        path.addLine(to: CGPoint(x: x, y: wickBottom))
                    }
                    context.stroke(wickPath, with: .color(color), lineWidth: 1)

                    let bodyTop = padding + (1 - (max(candle.open, candle.close) - minPrice) / priceRange) * chartHeight
                    let bodyBottom = padding + (1 - (min(candle.open, candle.close) - minPrice) / priceRange) * chartHeight
                    let bodyHeight = max(1, bodyBottom - bodyTop)
                    let bodyRect = CGRect(x: x - candleWidth / 2, y: bodyTop, width: candleWidth, height: bodyHeight)
                    context.fill(Path(bodyRect), with: .color(color))
                }
            }
        }
    }
}
