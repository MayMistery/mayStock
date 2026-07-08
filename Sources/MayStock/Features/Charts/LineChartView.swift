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

                    AreaMark(
                        x: .value("Time", tick.timestamp),
                        y: .value("Value", tick.price)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(areaGradient)
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
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

    private var areaGradient: LinearGradient {
        LinearGradient(colors: [.green.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
    }

    private func formatValue(_ v: Double) -> String {
        if v >= 10000 { return String(format: "%.0f", v) }
        if v >= 100 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}
