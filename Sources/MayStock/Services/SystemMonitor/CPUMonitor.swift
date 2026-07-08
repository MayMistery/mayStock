import Foundation
import Observation
import Darwin

@Observable
@MainActor
final class CPUMonitor {
    private(set) var currentUsage: Double = 0.0
    private(set) var history: [MarketTick] = []
    private var previousTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private let maxHistory = 300

    func sample() {
        guard let ticks = readCPUTicks() else { return }
        if let prev = previousTicks {
            let userDelta = ticks.user - prev.user
            let systemDelta = ticks.system - prev.system
            let idleDelta = ticks.idle - prev.idle
            let niceDelta = ticks.nice - prev.nice
            let total = userDelta + systemDelta + idleDelta + niceDelta
            if total > 0 {
                currentUsage = Double(userDelta + systemDelta) / Double(total) * 100.0
                let tick = MarketTick(timestamp: Date(), price: currentUsage, volume: 0)
                history.append(tick)
                if history.count > maxHistory { history.removeFirst() }
            }
        }
        previousTicks = ticks
    }

    private nonisolated func readCPUTicks() -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? {
        let count = MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        var size = mach_msg_type_number_t(count)
        var cpuLoadInfo = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &cpuLoadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: count) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (
            user: UInt64(cpuLoadInfo.cpu_ticks.0),
            system: UInt64(cpuLoadInfo.cpu_ticks.1),
            idle: UInt64(cpuLoadInfo.cpu_ticks.2),
            nice: UInt64(cpuLoadInfo.cpu_ticks.3)
        )
    }
}
