import SwiftUI
import Charts

struct VolumeChartView: View {
    let candles: [OHLC]

    var body: some View {
        if candles.isEmpty {
            ContentUnavailableView("No Data", systemImage: "chart.bar.xaxis")
        } else {
            Chart(candles) { candle in
                BarMark(
                    x: .value("Time", candle.timestamp),
                    y: .value("Volume", candle.volume)
                )
                .foregroundStyle(candle.isBullish ? Color.green.opacity(0.7) : Color.red.opacity(0.7))
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatVolume(v))
                                .font(.system(.caption2, design: .monospaced))
                        }
                    }
                }
            }
        }
    }

    private func formatVolume(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return String(format: "%.0f", v)
    }
}
