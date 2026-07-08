import SwiftUI
import Charts

struct VolumeChartView: View {
    let candles: [OHLC]

    private let visibleCount = 50

    var body: some View {
        if candles.isEmpty {
            ContentUnavailableView("No Data", systemImage: "chart.bar.xaxis")
        } else {
            let visible = Array(candles.suffix(visibleCount))
            Chart(visible) { candle in
                BarMark(
                    x: .value("Time", candle.timestamp),
                    y: .value("Volume", candle.volume)
                )
                .foregroundStyle(candle.isBullish ? Color.green.opacity(0.7) : Color.red.opacity(0.7))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(formatTime(date))
                                .font(.system(.caption2, design: .monospaced))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(.gray.opacity(0.2))
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

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
