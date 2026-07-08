import Foundation
import Observation
import Darwin

@Observable
@MainActor
final class MemoryMonitor {
    private(set) var totalBytes: UInt64 = 0
    private(set) var usedBytes: UInt64 = 0
    private(set) var usagePercent: Double = 0.0
    private(set) var history: [MarketTick] = []
    private let maxHistory = 300

    func sample() {
        totalBytes = ProcessInfo.processInfo.physicalMemory
        guard let vmStats = readVMStats() else { return }
        let pageSize = UInt64(getpagesize())
        let active = UInt64(vmStats.active_count) * pageSize
        let wired = UInt64(vmStats.wire_count) * pageSize
        let compressed = UInt64(vmStats.compressor_page_count) * pageSize
        usedBytes = active + wired + compressed
        usagePercent = totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100.0 : 0.0

        let tick = MarketTick(timestamp: Date(), price: usagePercent, volume: 0)
        history.append(tick)
        if history.count > maxHistory { history.removeFirst() }
    }

    var formattedUsed: String {
        let gb = Double(usedBytes) / 1_073_741_824.0
        return String(format: "%.1fG", gb)
    }

    private nonisolated func readVMStats() -> vm_statistics64? {
        var size = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        var stats = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return stats
    }
}
