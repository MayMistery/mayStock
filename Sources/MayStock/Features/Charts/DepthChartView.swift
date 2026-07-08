import SwiftUI

struct DepthChartView: View {
    let orderBook: OrderBook

    var body: some View {
        if orderBook.bids.isEmpty && orderBook.asks.isEmpty {
            ContentUnavailableView("No Data", systemImage: "chart.line.downtrend.xyaxis")
        } else {
            Canvas { context, size in
                let bids = cumulativeBids
                let asks = cumulativeAsks
                guard !bids.isEmpty, !asks.isEmpty else { return }

                let allPrices = bids.map(\.price) + asks.map(\.price)
                let allSizes = bids.map(\.cumulativeSize) + asks.map(\.cumulativeSize)
                guard let minPrice = allPrices.min(),
                      let maxPrice = allPrices.max(),
                      let maxSize = allSizes.max(),
                      maxPrice > minPrice, maxSize > 0 else { return }

                let padding: CGFloat = 8
                let chartWidth = size.width - padding * 2
                let chartHeight = size.height - padding * 2

                func xPos(_ price: Double) -> CGFloat {
                    padding + CGFloat((price - minPrice) / (maxPrice - minPrice)) * chartWidth
                }
                func yPos(_ cumSize: Double) -> CGFloat {
                    padding + chartHeight - CGFloat(cumSize / maxSize) * chartHeight
                }

                // Bids area
                var bidPath = Path()
                bidPath.move(to: CGPoint(x: xPos(bids[0].price), y: padding + chartHeight))
                for entry in bids {
                    bidPath.addLine(to: CGPoint(x: xPos(entry.price), y: yPos(entry.cumulativeSize)))
                }
                bidPath.addLine(to: CGPoint(x: xPos(bids[bids.count - 1].price), y: padding + chartHeight))
                bidPath.closeSubpath()
                context.fill(bidPath, with: .color(.green.opacity(0.3)))

                var bidLine = Path()
                for (i, entry) in bids.enumerated() {
                    let point = CGPoint(x: xPos(entry.price), y: yPos(entry.cumulativeSize))
                    if i == 0 { bidLine.move(to: point) } else { bidLine.addLine(to: point) }
                }
                context.stroke(bidLine, with: .color(.green), lineWidth: 1.5)

                // Asks area
                var askPath = Path()
                askPath.move(to: CGPoint(x: xPos(asks[0].price), y: padding + chartHeight))
                for entry in asks {
                    askPath.addLine(to: CGPoint(x: xPos(entry.price), y: yPos(entry.cumulativeSize)))
                }
                askPath.addLine(to: CGPoint(x: xPos(asks[asks.count - 1].price), y: padding + chartHeight))
                askPath.closeSubpath()
                context.fill(askPath, with: .color(.red.opacity(0.3)))

                var askLine = Path()
                for (i, entry) in asks.enumerated() {
                    let point = CGPoint(x: xPos(entry.price), y: yPos(entry.cumulativeSize))
                    if i == 0 { askLine.move(to: point) } else { askLine.addLine(to: point) }
                }
                context.stroke(askLine, with: .color(.red), lineWidth: 1.5)
            }
        }
    }

    private struct CumulativeEntry {
        let price: Double
        let cumulativeSize: Double
    }

    private var cumulativeBids: [CumulativeEntry] {
        let sorted = orderBook.bids.sorted { $0.price > $1.price }
        var cumulative: Double = 0
        return sorted.map { entry in
            cumulative += entry.size
            return CumulativeEntry(price: entry.price, cumulativeSize: cumulative)
        }.reversed()
    }

    private var cumulativeAsks: [CumulativeEntry] {
        let sorted = orderBook.asks.sorted { $0.price < $1.price }
        var cumulative: Double = 0
        return sorted.map { entry in
            cumulative += entry.size
            return CumulativeEntry(price: entry.price, cumulativeSize: cumulative)
        }
    }
}
