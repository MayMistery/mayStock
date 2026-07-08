import Foundation

enum MonitorType: String, Codable, CaseIterable, Sendable {
    case crypto
    case cpu
    case memory
    case network
}

enum DataSource: Codable, Equatable, Sendable {
    case okx(instId: String)
    case system
}

struct MonitorItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var type: MonitorType
    var label: String
    var source: DataSource
    var chartConfig: ChartConfig
    var isEnabled: Bool
    var sortOrder: Int

    static func defaultBTC() -> MonitorItem {
        MonitorItem(id: UUID(), type: .crypto, label: "BTC", source: .okx(instId: "BTC-USDT"), chartConfig: .default, isEnabled: true, sortOrder: 0)
    }
    static func defaultCPU() -> MonitorItem {
        MonitorItem(id: UUID(), type: .cpu, label: "CPU", source: .system, chartConfig: ChartConfig(chartType: .line, timeSpan: .minutes(1), showVolume: false, colorScheme: .standard), isEnabled: true, sortOrder: 1)
    }
    static func defaultMemory() -> MonitorItem {
        MonitorItem(id: UUID(), type: .memory, label: "MEM", source: .system, chartConfig: ChartConfig(chartType: .line, timeSpan: .minutes(1), showVolume: false, colorScheme: .standard), isEnabled: true, sortOrder: 2)
    }
    static func defaultNetwork() -> MonitorItem {
        MonitorItem(id: UUID(), type: .network, label: "NET", source: .system, chartConfig: ChartConfig(chartType: .line, timeSpan: .minutes(1), showVolume: false, colorScheme: .standard), isEnabled: true, sortOrder: 3)
    }
}
