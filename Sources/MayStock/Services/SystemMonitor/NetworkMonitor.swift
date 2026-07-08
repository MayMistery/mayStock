import Foundation
import Observation
import Darwin

@Observable
@MainActor
final class NetworkMonitor {
    private(set) var bytesInPerSecond: Int64 = 0
    private(set) var bytesOutPerSecond: Int64 = 0
    private(set) var history: [MarketTick] = []
    private var previousReading: (bytesIn: Int64, bytesOut: Int64, time: Date)?
    private let maxHistory = 300

    func sample() {
        let current = readTotalBytes()
        let now = Date()
        if let prev = previousReading {
            let elapsed = now.timeIntervalSince(prev.time)
            if elapsed > 0 {
                bytesInPerSecond = Int64(Double(current.bytesIn - prev.bytesIn) / elapsed)
                bytesOutPerSecond = Int64(Double(current.bytesOut - prev.bytesOut) / elapsed)
                let totalPerSec = Double(bytesInPerSecond + bytesOutPerSecond)
                let tick = MarketTick(timestamp: now, price: totalPerSec, volume: 0)
                history.append(tick)
                if history.count > maxHistory { history.removeFirst() }
            }
        }
        previousReading = (current.bytesIn, current.bytesOut, now)
    }

    func formatBytes(_ bytes: Int64) -> String {
        let absBytes = Double(abs(bytes))
        if absBytes < 1024 { return "\(bytes) B/s" }
        if absBytes < 1_048_576 { return String(format: "%.1f KB/s", absBytes / 1024.0) }
        return String(format: "%.1f MB/s", absBytes / 1_048_576.0)
    }

    var formattedIn: String { formatBytes(bytesInPerSecond) }
    var formattedOut: String { formatBytes(bytesOutPerSecond) }

    private nonisolated func readTotalBytes() -> (bytesIn: Int64, bytesOut: Int64) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let firstAddr = ifap else {
            return (0, 0)
        }
        defer { freeifaddrs(ifap) }

        var totalIn: Int64 = 0
        var totalOut: Int64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let addr = cursor {
            let name = String(cString: addr.pointee.ifa_name)
            if (name.hasPrefix("en") || name.hasPrefix("lo")),
               let data = addr.pointee.ifa_data {
                let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                totalIn += Int64(networkData.ifi_ibytes)
                totalOut += Int64(networkData.ifi_obytes)
            }
            cursor = addr.pointee.ifa_next
        }

        return (totalIn, totalOut)
    }
}
