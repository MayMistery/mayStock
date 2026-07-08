import SwiftUI
import Charts

struct LineChartView: View {
    let data: [MarketTick]
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if data.isEmpty {
                ContentUnavailableView("No Data", systemImage: "chart.xyaxis.line")
            } else {
                Chart(data) { tick in
                    LineMark(
                        x: .value("Time", tick.timestamp),
                        y: .value("Value", tick.price)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(lineGradient)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: yDomain)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(formatValue(v))
                                    .font(.system(.caption2, design: .monospaced))
                            }
                        }
                    }
                }
            }
        }
    }

    private var lineGradient: LinearGradient {
        LinearGradient(colors: [.green, .cyan], startPoint: .leading, endPoint: .trailing)
    }

    private var yDomain: ClosedRange<Double> {
        let prices = data.map(\.price)
        guard let min = prices.min(), let max = prices.max(), max > min else {
            let val = prices.first ?? 0
            return (val - 1)...(val + 1)
        }
        let padding = (max - min) * 0.05
        return (min - padding)...(max + padding)
    }

    private func formatValue(_ v: Double) -> String {
        if v >= 10000 { return String(format: "%.0f", v) }
        if v >= 100 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}
