import SwiftUI

struct PopoverView: View {
    @State private var viewModel: PopoverViewModel

    init(
        marketData: MarketDataProvider,
        cpuMonitor: CPUMonitor,
        memoryMonitor: MemoryMonitor,
        networkMonitor: NetworkMonitor,
        configService: ConfigurationService
    ) {
        _viewModel = State(initialValue: PopoverViewModel(
            marketData: marketData,
            cpuMonitor: cpuMonitor,
            memoryMonitor: memoryMonitor,
            networkMonitor: networkMonitor,
            configService: configService
        ))
    }

    var body: some View {
        VStack(spacing: 12) {
            headerView
            chartView
            ChartSelectorView(viewModel: viewModel)
        }
        .padding(16)
        .frame(width: 420, height: 320)
    }

    @ViewBuilder
    private var headerView: some View {
        HStack {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.activeItems.enumerated()), id: \.element.id) { index, item in
                    Button {
                        viewModel.selectedMonitorIndex = index
                    } label: {
                        Text(item.label)
                            .font(.caption)
                            .fontWeight(viewModel.selectedMonitorIndex == index ? .bold : .regular)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            if let item = viewModel.selectedItem {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(currentValue(for: item))
                        .font(.system(.title2, design: .monospaced))
                        .fontWeight(.medium)
                    if item.type == .crypto {
                        Text(viewModel.marketData.priceChangePercent)
                            .font(.caption)
                            .foregroundStyle(
                                viewModel.marketData.priceChange24h >= 0 ? .green : .red
                            )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var chartView: some View {
        Group {
            if let item = viewModel.selectedItem, item.type != .crypto {
                LineChartView(data: lineData, title: "")
            } else {
                switch viewModel.selectedChartType {
                case .line:
                    LineChartView(data: lineData, title: "")
                case .candlestick:
                    CandlestickChartView(candles: viewModel.marketData.candles)
                case .volume:
                    VolumeChartView(candles: viewModel.marketData.candles)
                case .depth:
                    DepthChartView(orderBook: viewModel.marketData.orderBook)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lineData: [MarketTick] {
        guard let item = viewModel.selectedItem else { return [] }
        switch item.type {
        case .crypto: return viewModel.marketData.ticks
        case .cpu: return viewModel.cpuMonitor.history
        case .memory: return viewModel.memoryMonitor.history
        case .network: return viewModel.networkMonitor.history
        }
    }

    private func currentValue(for item: MonitorItem) -> String {
        switch item.type {
        case .crypto: return viewModel.marketData.formattedPrice
        case .cpu: return String(format: "%.1f%%", viewModel.cpuMonitor.currentUsage)
        case .memory: return viewModel.memoryMonitor.formattedUsed
        case .network: return viewModel.networkMonitor.formattedIn
        }
    }
}
