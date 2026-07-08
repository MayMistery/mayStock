import SwiftUI

struct ChartSelectorView: View {
    @Bindable var viewModel: PopoverViewModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ChartType.allCases, id: \.self) { type in
                Button {
                    viewModel.selectedChartType = type
                } label: {
                    Image(systemName: iconName(for: type))
                        .font(.caption)
                        .frame(width: 28, height: 22)
                }
                .buttonStyle(.plain)
                .background(
                    viewModel.selectedChartType == type
                        ? Color.accentColor.opacity(0.2)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Spacer()

            Menu {
                ForEach(TimeSpan.allPresets, id: \.displayLabel) { span in
                    Button(span.displayLabel) {
                        viewModel.switchTimeSpan(to: span)
                    }
                }
            } label: {
                Text(viewModel.selectedTimeSpan.displayLabel)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func iconName(for type: ChartType) -> String {
        switch type {
        case .line: return "chart.xyaxis.line"
        case .candlestick: return "chart.bar.fill"
        case .depth: return "chart.line.downtrend.xyaxis"
        case .volume: return "chart.bar.xaxis"
        }
    }
}
