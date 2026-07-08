import Foundation
import Observation

@Observable
@MainActor
final class PopoverViewModel {
    var selectedChartType: ChartType = .candlestick
    var selectedTimeSpan: TimeSpan = .minutes(5)
    var selectedMonitorIndex: Int = 0

    let marketData: MarketDataProvider
    let cpuMonitor: CPUMonitor
    let memoryMonitor: MemoryMonitor
    let networkMonitor: NetworkMonitor
    let configService: ConfigurationService

    init(
        marketData: MarketDataProvider,
        cpuMonitor: CPUMonitor,
        memoryMonitor: MemoryMonitor,
        networkMonitor: NetworkMonitor,
        configService: ConfigurationService
    ) {
        self.marketData = marketData
        self.cpuMonitor = cpuMonitor
        self.memoryMonitor = memoryMonitor
        self.networkMonitor = networkMonitor
        self.configService = configService

        if let first = configService.monitorItems.first(where: { $0.isEnabled }) {
            self.selectedChartType = first.chartConfig.chartType
            self.selectedTimeSpan = first.chartConfig.timeSpan
        }
    }

    var activeItems: [MonitorItem] {
        configService.monitorItems.filter(\.isEnabled).sorted { $0.sortOrder < $1.sortOrder }
    }

    var selectedItem: MonitorItem? {
        let items = activeItems
        guard selectedMonitorIndex < items.count else { return items.first }
        return items[selectedMonitorIndex]
    }

    func switchTimeSpan(to span: TimeSpan) {
        let oldChannel = selectedTimeSpan.okxChannel
        selectedTimeSpan = span
        let newChannel = span.okxChannel
        if let item = selectedItem, case .okx(let instId) = item.source {
            marketData.switchTimeSpan(instId: instId, newChannel: newChannel, oldChannel: oldChannel)
        }
    }
}
