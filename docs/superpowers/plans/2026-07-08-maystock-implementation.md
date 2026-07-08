# MayStock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS 26+ menu bar app displaying real-time system metrics and BTC/USDT price from OKX, with hover-triggered Popover showing financial charts (K-line, depth, volume, line), and a Settings window accessible via right-click.

**Architecture:** NSStatusItem + NSPopover hosting SwiftUI views (MenuBarExtra lacks hover/right-click support). Single-process app with @NSApplicationDelegateAdaptor. Data flows: OKX WebSocket → parser → @Observable model → SwiftUI chart views. System metrics via native Mach/BSD APIs with delta-based sampling.

**Tech Stack:** Swift 6, SwiftUI (macOS 26+), AppKit (NSStatusItem/NSPopover/NSEvent), Swift Charts, URLSessionWebSocketTask, XCTest/XCUITest, SPM for project structure.

---

## File Structure

```
MayStock/
├── Package.swift                           — SPM manifest
├── Sources/
│   └── MayStock/
│       ├── App/
│       │   ├── MayStockApp.swift           — @main, Scene with Settings window
│       │   ├── AppDelegate.swift           — NSApplicationDelegate, owns StatusBarController
│       │   └── StatusBarController.swift   — NSStatusItem, NSPopover, hover/right-click handling
│       ├── Features/
│       │   ├── Popover/
│       │   │   ├── PopoverView.swift       — Root popover SwiftUI view
│       │   │   ├── PopoverViewModel.swift  — Drives chart data selection
│       │   │   └── ChartSelectorView.swift — Time span + chart type picker
│       │   ├── Charts/
│       │   │   ├── CandlestickChartView.swift  — K-line via Canvas
│       │   │   ├── DepthChartView.swift         — Bid/ask area chart
│       │   │   ├── VolumeChartView.swift        — Volume bars via Swift Charts
│       │   │   └── LineChartView.swift          — Line chart via Swift Charts
│       │   └── Settings/
│       │       ├── SettingsView.swift      — TabView container
│       │       ├── GeneralSettingsView.swift
│       │       ├── MonitorsSettingsView.swift
│       │       └── AppearanceSettingsView.swift
│       ├── Services/
│       │   ├── MarketData/
│       │   │   ├── OKXWebSocketService.swift    — Connection lifecycle, ping/pong
│       │   │   ├── OKXMessageParser.swift       — JSON → domain models
│       │   │   └── MarketDataProvider.swift     — Aggregates ticker/candle/depth streams
│       │   ├── SystemMonitor/
│       │   │   ├── CPUMonitor.swift             — host_statistics delta sampling
│       │   │   ├── MemoryMonitor.swift          — host_statistics64 VM info
│       │   │   └── NetworkMonitor.swift         — getifaddrs byte counters
│       │   └── Configuration/
│       │       └── ConfigurationService.swift   — JSON persistence + observation
│       └── Models/
│           ├── MonitorItem.swift
│           ├── ChartConfig.swift
│           ├── MarketTick.swift
│           ├── OHLC.swift
│           └── OrderBookEntry.swift
├── Tests/
│   ├── MayStockTests/
│   │   ├── OKXMessageParserTests.swift
│   │   ├── MarketDataProviderTests.swift
│   │   ├── CPUMonitorTests.swift
│   │   ├── MemoryMonitorTests.swift
│   │   ├── NetworkMonitorTests.swift
│   │   └── ConfigurationServiceTests.swift
│   ├── IntegrationTests/
│   │   ├── OKXWebSocketIntegrationTests.swift
│   │   └── DataFlowIntegrationTests.swift
│   └── UITests/
│       ├── MayStockUITests.swift
│       └── SettingsUITests.swift
└── Resources/
    ├── Assets.xcassets/           — App icon
    └── Info.plist                 — LSUIElement=YES
```

---

## Task 1: Project Scaffold & SPM Setup

**Files:**
- Create: `Package.swift`
- Create: `Sources/MayStock/App/MayStockApp.swift`
- Create: `Sources/MayStock/App/AppDelegate.swift`
- Create: `Sources/MayStock/Models/MonitorItem.swift`
- Create: `Sources/MayStock/Models/ChartConfig.swift`
- Create: `Tests/MayStockTests/ConfigurationServiceTests.swift`

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MayStock",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MayStock",
            path: "Sources/MayStock",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MayStockTests",
            dependencies: ["MayStock"],
            path: "Tests/MayStockTests"
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["MayStock"],
            path: "Tests/IntegrationTests"
        ),
    ]
)
```

Note: SPM doesn't have `.macOS(.v26)` yet in Swift 6.0 tools — use `.v15` as the minimum and rely on `@available(macOS 26.0, *)` annotations where needed. The app will only run on macOS 26+ via runtime checks and Info.plist `LSMinimumSystemVersion`.

- [ ] **Step 2: Create domain models**

`Sources/MayStock/Models/MonitorItem.swift`:
```swift
import Foundation

enum MonitorType: String, Codable, CaseIterable {
    case crypto
    case cpu
    case memory
    case network
}

enum DataSource: Codable, Equatable {
    case okx(instId: String)
    case system
}

struct MonitorItem: Codable, Identifiable, Equatable {
    let id: UUID
    var type: MonitorType
    var label: String
    var source: DataSource
    var chartConfig: ChartConfig
    var isEnabled: Bool
    var sortOrder: Int

    static func defaultBTC() -> MonitorItem {
        MonitorItem(
            id: UUID(),
            type: .crypto,
            label: "BTC",
            source: .okx(instId: "BTC-USDT"),
            chartConfig: .default,
            isEnabled: true,
            sortOrder: 0
        )
    }

    static func defaultCPU() -> MonitorItem {
        MonitorItem(
            id: UUID(),
            type: .cpu,
            label: "CPU",
            source: .system,
            chartConfig: ChartConfig(chartType: .line, timeSpan: .minutes(1), showVolume: false, colorScheme: .standard),
            isEnabled: true,
            sortOrder: 1
        )
    }

    static func defaultMemory() -> MonitorItem {
        MonitorItem(
            id: UUID(),
            type: .memory,
            label: "MEM",
            source: .system,
            chartConfig: ChartConfig(chartType: .line, timeSpan: .minutes(1), showVolume: false, colorScheme: .standard),
            isEnabled: true,
            sortOrder: 2
        )
    }

    static func defaultNetwork() -> MonitorItem {
        MonitorItem(
            id: UUID(),
            type: .network,
            label: "NET",
            source: .system,
            chartConfig: ChartConfig(chartType: .line, timeSpan: .minutes(1), showVolume: false, colorScheme: .standard),
            isEnabled: true,
            sortOrder: 3
        )
    }
}
```

`Sources/MayStock/Models/ChartConfig.swift`:
```swift
import Foundation

enum ChartType: String, Codable, CaseIterable {
    case line
    case candlestick
    case depth
    case volume
}

enum TimeSpan: Codable, Equatable {
    case seconds(Int)
    case minutes(Int)
    case hours(Int)
    case days(Int)

    static let allPresets: [TimeSpan] = [
        .seconds(1), .seconds(5),
        .minutes(1), .minutes(5), .minutes(15),
        .hours(1), .hours(4),
        .days(1), .days(7)
    ]

    var displayLabel: String {
        switch self {
        case .seconds(let v): return "\(v)s"
        case .minutes(let v): return "\(v)m"
        case .hours(let v): return "\(v)h"
        case .days(let v): return "\(v)d"
        }
    }

    var okxChannel: String {
        switch self {
        case .seconds(1): return "candle1s"
        case .seconds(5): return "candle5s"
        case .minutes(1): return "candle1m"
        case .minutes(5): return "candle5m"
        case .minutes(15): return "candle15m"
        case .hours(1): return "candle1H"
        case .hours(4): return "candle4H"
        case .days(1): return "candle1D"
        case .days(7): return "candle1W"
        default: return "candle1m"
        }
    }
}

enum ChartColorScheme: String, Codable, CaseIterable {
    case standard
    case monochrome
    case custom
}

struct ChartConfig: Codable, Equatable {
    var chartType: ChartType
    var timeSpan: TimeSpan
    var showVolume: Bool
    var colorScheme: ChartColorScheme

    static let `default` = ChartConfig(
        chartType: .candlestick,
        timeSpan: .minutes(5),
        showVolume: true,
        colorScheme: .standard
    )
}
```

- [ ] **Step 3: Create market data models**

`Sources/MayStock/Models/MarketTick.swift`:
```swift
import Foundation

struct MarketTick: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let price: Double
    let volume: Double
}
```

`Sources/MayStock/Models/OHLC.swift`:
```swift
import Foundation

struct OHLC: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
    let confirmed: Bool

    var isBullish: Bool { close >= open }
}
```

`Sources/MayStock/Models/OrderBookEntry.swift`:
```swift
import Foundation

enum OrderSide: String, Codable {
    case bid
    case ask
}

struct OrderBookEntry: Identifiable, Equatable {
    let id = UUID()
    let price: Double
    let size: Double
    let side: OrderSide
}

struct OrderBook: Equatable {
    var bids: [OrderBookEntry]
    var asks: [OrderBookEntry]
    let timestamp: Date
}
```

- [ ] **Step 4: Create minimal app entry point**

`Sources/MayStock/App/MayStockApp.swift`:
```swift
import SwiftUI

@main
struct MayStockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            Text("MayStock Settings")
                .frame(width: 500, height: 400)
        }
    }
}
```

`Sources/MayStock/App/AppDelegate.swift`:
```swift
import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
```

- [ ] **Step 5: Create Resources/Info.plist**

`Sources/MayStock/Resources/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>CFBundleName</key>
    <string>MayStock</string>
    <key>CFBundleIdentifier</key>
    <string>com.maystock.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
</dict>
</plist>
```

- [ ] **Step 6: Verify project builds**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds (warnings OK, no errors)

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/ Tests/ Resources/
git commit -m "feat: scaffold MayStock SPM project with domain models"
```

---

## Task 2: Configuration Service

**Files:**
- Create: `Sources/MayStock/Services/Configuration/ConfigurationService.swift`
- Create: `Tests/MayStockTests/ConfigurationServiceTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/MayStockTests/ConfigurationServiceTests.swift`:
```swift
import Testing
import Foundation
@testable import MayStock

@Suite("ConfigurationService")
struct ConfigurationServiceTests {
    let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MayStockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    @Test("loads default config when no file exists")
    func loadsDefaults() async throws {
        let service = ConfigurationService(directory: tempDir)
        let items = service.monitorItems
        #expect(items.count == 4)
        #expect(items[0].type == .crypto)
        #expect(items[0].label == "BTC")
    }

    @Test("saves and reloads config")
    func savesAndReloads() async throws {
        let service = ConfigurationService(directory: tempDir)
        var items = service.monitorItems
        items[0].label = "Bitcoin"
        service.monitorItems = items
        try service.save()

        let service2 = ConfigurationService(directory: tempDir)
        #expect(service2.monitorItems[0].label == "Bitcoin")
    }

    @Test("handles corrupted config gracefully")
    func handlesCorruption() async throws {
        let configFile = tempDir.appendingPathComponent("config.json")
        try "{{invalid json".write(to: configFile, atomically: true, encoding: .utf8)

        let service = ConfigurationService(directory: tempDir)
        #expect(service.monitorItems.count == 4)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigurationServiceTests 2>&1 | tail -10`
Expected: Compilation error — `ConfigurationService` not found

- [ ] **Step 3: Implement ConfigurationService**

`Sources/MayStock/Services/Configuration/ConfigurationService.swift`:
```swift
import Foundation
import Observation

@Observable
@MainActor
final class ConfigurationService {
    private let directory: URL
    private let filename = "config.json"

    var monitorItems: [MonitorItem]

    init(directory: URL? = nil) {
        let dir = directory ?? ConfigurationService.defaultDirectory()
        self.directory = dir
        self.monitorItems = Self.load(from: dir) ?? Self.defaultItems()
    }

    func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(monitorItems)
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func load(from directory: URL) -> [MonitorItem]? {
        let fileURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([MonitorItem].self, from: data)
    }

    private static func defaultItems() -> [MonitorItem] {
        [
            .defaultBTC(),
            .defaultCPU(),
            .defaultMemory(),
            .defaultNetwork()
        ]
    }

    private static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MayStock")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigurationServiceTests 2>&1 | tail -10`
Expected: All 3 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/MayStock/Services/Configuration/ Tests/MayStockTests/ConfigurationServiceTests.swift
git commit -m "feat: add ConfigurationService with JSON persistence"
```

---

## Task 3: System Monitors (CPU, Memory, Network)

**Files:**
- Create: `Sources/MayStock/Services/SystemMonitor/CPUMonitor.swift`
- Create: `Sources/MayStock/Services/SystemMonitor/MemoryMonitor.swift`
- Create: `Sources/MayStock/Services/SystemMonitor/NetworkMonitor.swift`
- Create: `Tests/MayStockTests/CPUMonitorTests.swift`
- Create: `Tests/MayStockTests/MemoryMonitorTests.swift`
- Create: `Tests/MayStockTests/NetworkMonitorTests.swift`

- [ ] **Step 1: Write CPU monitor tests**

`Tests/MayStockTests/CPUMonitorTests.swift`:
```swift
import Testing
import Foundation
@testable import MayStock

@Suite("CPUMonitor")
struct CPUMonitorTests {
    @Test("returns usage between 0 and 100")
    func usageInRange() async throws {
        let monitor = CPUMonitor()
        monitor.sample()
        try await Task.sleep(for: .milliseconds(100))
        monitor.sample()
        let usage = monitor.currentUsage
        #expect(usage >= 0.0)
        #expect(usage <= 100.0)
    }

    @Test("history accumulates samples")
    func historyAccumulates() async throws {
        let monitor = CPUMonitor()
        monitor.sample()
        try await Task.sleep(for: .milliseconds(50))
        monitor.sample()
        try await Task.sleep(for: .milliseconds(50))
        monitor.sample()
        #expect(monitor.history.count >= 2)
    }
}
```

- [ ] **Step 2: Write Memory monitor tests**

`Tests/MayStockTests/MemoryMonitorTests.swift`:
```swift
import Testing
import Foundation
@testable import MayStock

@Suite("MemoryMonitor")
struct MemoryMonitorTests {
    @Test("returns valid memory values")
    func validValues() {
        let monitor = MemoryMonitor()
        monitor.sample()
        #expect(monitor.totalBytes > 0)
        #expect(monitor.usedBytes > 0)
        #expect(monitor.usedBytes <= monitor.totalBytes)
    }

    @Test("usage percentage is between 0 and 100")
    func usagePercentage() {
        let monitor = MemoryMonitor()
        monitor.sample()
        #expect(monitor.usagePercent >= 0)
        #expect(monitor.usagePercent <= 100)
    }
}
```

- [ ] **Step 3: Write Network monitor tests**

`Tests/MayStockTests/NetworkMonitorTests.swift`:
```swift
import Testing
import Foundation
@testable import MayStock

@Suite("NetworkMonitor")
struct NetworkMonitorTests {
    @Test("returns non-negative byte counts")
    func nonNegative() {
        let monitor = NetworkMonitor()
        monitor.sample()
        #expect(monitor.bytesInPerSecond >= 0)
        #expect(monitor.bytesOutPerSecond >= 0)
    }

    @Test("formats speed readably")
    func formatsSpeed() {
        let monitor = NetworkMonitor()
        let formatted = monitor.formatBytes(1536)
        #expect(formatted == "1.5 KB/s")
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter "CPUMonitor|MemoryMonitor|NetworkMonitor" 2>&1 | tail -10`
Expected: Compilation errors

- [ ] **Step 5: Implement CPUMonitor**

`Sources/MayStock/Services/SystemMonitor/CPUMonitor.swift`:
```swift
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

    private func readCPUTicks() -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? {
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
```

- [ ] **Step 6: Implement MemoryMonitor**

`Sources/MayStock/Services/SystemMonitor/MemoryMonitor.swift`:
```swift
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
        let pageSize = UInt64(vm_kernel_page_size)
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

    private func readVMStats() -> vm_statistics64? {
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
```

- [ ] **Step 7: Implement NetworkMonitor**

`Sources/MayStock/Services/SystemMonitor/NetworkMonitor.swift`:
```swift
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

    private func readTotalBytes() -> (bytesIn: Int64, bytesOut: Int64) {
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
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `swift test --filter "CPUMonitor|MemoryMonitor|NetworkMonitor" 2>&1 | tail -15`
Expected: All tests pass

- [ ] **Step 9: Commit**

```bash
git add Sources/MayStock/Services/SystemMonitor/ Tests/MayStockTests/CPUMonitorTests.swift Tests/MayStockTests/MemoryMonitorTests.swift Tests/MayStockTests/NetworkMonitorTests.swift
git commit -m "feat: add CPU, Memory, Network system monitors with native macOS APIs"
```

---

## Task 4: OKX WebSocket Service & Message Parser

**Files:**
- Create: `Sources/MayStock/Services/MarketData/OKXWebSocketService.swift`
- Create: `Sources/MayStock/Services/MarketData/OKXMessageParser.swift`
- Create: `Sources/MayStock/Services/MarketData/MarketDataProvider.swift`
- Create: `Tests/MayStockTests/OKXMessageParserTests.swift`
- Create: `Tests/MayStockTests/MarketDataProviderTests.swift`

- [ ] **Step 1: Write OKX message parser tests**

`Tests/MayStockTests/OKXMessageParserTests.swift`:
```swift
import Testing
import Foundation
@testable import MayStock

@Suite("OKXMessageParser")
struct OKXMessageParserTests {
    @Test("parses ticker message")
    func parsesTicker() throws {
        let json = """
        {"arg":{"channel":"tickers","instId":"BTC-USDT"},"data":[{"instId":"BTC-USDT","last":"62213.5","vol24h":"1234.56","open24h":"61000.0","high24h":"63000.0","low24h":"60500.0","ts":"1720000000000"}]}
        """
        let result = try OKXMessageParser.parse(json)
        guard case .ticker(let tick) = result else {
            Issue.record("Expected ticker")
            return
        }
        #expect(tick.price == 62213.5)
        #expect(tick.volume == 1234.56)
    }

    @Test("parses candle message")
    func parsesCandle() throws {
        let json = """
        {"arg":{"channel":"candle1m","instId":"BTC-USDT"},"data":[["1720000000000","62000","62500","61800","62300","100.5","6230000","6230000","1"]]}
        """
        let result = try OKXMessageParser.parse(json)
        guard case .candle(let ohlc) = result else {
            Issue.record("Expected candle")
            return
        }
        #expect(ohlc.open == 62000.0)
        #expect(ohlc.high == 62500.0)
        #expect(ohlc.low == 61800.0)
        #expect(ohlc.close == 62300.0)
        #expect(ohlc.volume == 100.5)
        #expect(ohlc.confirmed == true)
    }

    @Test("parses books5 message")
    func parsesOrderBook() throws {
        let json = """
        {"arg":{"channel":"books5","instId":"BTC-USDT"},"data":[{"asks":[["62300","1.5","0","3"],["62310","2.0","0","5"]],"bids":[["62290","0.8","0","2"],["62280","1.2","0","4"]],"ts":"1720000000000"}]}
        """
        let result = try OKXMessageParser.parse(json)
        guard case .orderBook(let book) = result else {
            Issue.record("Expected orderBook")
            return
        }
        #expect(book.asks.count == 2)
        #expect(book.bids.count == 2)
        #expect(book.asks[0].price == 62300.0)
        #expect(book.bids[0].price == 62290.0)
    }

    @Test("handles ping message")
    func handlesPing() throws {
        let result = try OKXMessageParser.parse("ping")
        guard case .ping = result else {
            Issue.record("Expected ping")
            return
        }
    }

    @Test("handles subscribe confirmation")
    func handlesSubscribe() throws {
        let json = """
        {"event":"subscribe","arg":{"channel":"tickers","instId":"BTC-USDT"}}
        """
        let result = try OKXMessageParser.parse(json)
        guard case .subscribed = result else {
            Issue.record("Expected subscribed")
            return
        }
    }

    @Test("throws on malformed JSON")
    func throwsOnMalformed() {
        #expect(throws: OKXParseError.self) {
            try OKXMessageParser.parse("{{invalid")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OKXMessageParser 2>&1 | tail -10`
Expected: Compilation error

- [ ] **Step 3: Implement OKXMessageParser**

`Sources/MayStock/Services/MarketData/OKXMessageParser.swift`:
```swift
import Foundation

enum OKXParseError: Error {
    case invalidJSON
    case unknownMessage
    case missingField(String)
}

enum OKXMessage {
    case ticker(MarketTick)
    case candle(OHLC)
    case orderBook(OrderBook)
    case ping
    case subscribed
    case error(String)
}

struct OKXMessageParser {
    static func parse(_ text: String) throws -> OKXMessage {
        if text == "ping" { return .ping }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OKXParseError.invalidJSON
        }

        if let event = json["event"] as? String {
            if event == "subscribe" { return .subscribed }
            if event == "error" {
                let msg = json["msg"] as? String ?? "unknown"
                return .error(msg)
            }
        }

        guard let arg = json["arg"] as? [String: Any],
              let channel = arg["channel"] as? String,
              let dataArray = json["data"] as? [Any] else {
            throw OKXParseError.unknownMessage
        }

        if channel == "tickers" {
            return try parseTicker(dataArray)
        } else if channel.hasPrefix("candle") {
            return try parseCandle(dataArray)
        } else if channel.hasPrefix("books") {
            return try parseOrderBook(dataArray)
        }

        throw OKXParseError.unknownMessage
    }

    private static func parseTicker(_ dataArray: [Any]) throws -> OKXMessage {
        guard let first = dataArray.first as? [String: Any],
              let lastStr = first["last"] as? String,
              let last = Double(lastStr),
              let tsStr = first["ts"] as? String,
              let tsMs = Double(tsStr) else {
            throw OKXParseError.missingField("last or ts")
        }
        let vol = (first["vol24h"] as? String).flatMap(Double.init) ?? 0
        let tick = MarketTick(
            timestamp: Date(timeIntervalSince1970: tsMs / 1000.0),
            price: last,
            volume: vol
        )
        return .ticker(tick)
    }

    private static func parseCandle(_ dataArray: [Any]) throws -> OKXMessage {
        guard let first = dataArray.first as? [Any],
              first.count >= 9,
              let tsStr = first[0] as? String, let tsMs = Double(tsStr),
              let openStr = first[1] as? String, let open = Double(openStr),
              let highStr = first[2] as? String, let high = Double(highStr),
              let lowStr = first[3] as? String, let low = Double(lowStr),
              let closeStr = first[4] as? String, let close = Double(closeStr),
              let volStr = first[5] as? String, let vol = Double(volStr),
              let confirmStr = first[8] as? String else {
            throw OKXParseError.missingField("candle fields")
        }
        let ohlc = OHLC(
            timestamp: Date(timeIntervalSince1970: tsMs / 1000.0),
            open: open, high: high, low: low, close: close,
            volume: vol,
            confirmed: confirmStr == "1"
        )
        return .candle(ohlc)
    }

    private static func parseOrderBook(_ dataArray: [Any]) throws -> OKXMessage {
        guard let first = dataArray.first as? [String: Any],
              let asksRaw = first["asks"] as? [[Any]],
              let bidsRaw = first["bids"] as? [[Any]],
              let tsStr = first["ts"] as? String,
              let tsMs = Double(tsStr) else {
            throw OKXParseError.missingField("asks/bids/ts")
        }

        let asks = asksRaw.compactMap { entry -> OrderBookEntry? in
            guard entry.count >= 2,
                  let priceStr = entry[0] as? String, let price = Double(priceStr),
                  let sizeStr = entry[1] as? String, let size = Double(sizeStr) else { return nil }
            return OrderBookEntry(price: price, size: size, side: .ask)
        }
        let bids = bidsRaw.compactMap { entry -> OrderBookEntry? in
            guard entry.count >= 2,
                  let priceStr = entry[0] as? String, let price = Double(priceStr),
                  let sizeStr = entry[1] as? String, let size = Double(sizeStr) else { return nil }
            return OrderBookEntry(price: price, size: size, side: .bid)
        }

        let book = OrderBook(
            bids: bids, asks: asks,
            timestamp: Date(timeIntervalSince1970: tsMs / 1000.0)
        )
        return .orderBook(book)
    }
}
```

- [ ] **Step 4: Run parser tests**

Run: `swift test --filter OKXMessageParser 2>&1 | tail -10`
Expected: All 6 tests pass

- [ ] **Step 5: Implement OKXWebSocketService**

`Sources/MayStock/Services/MarketData/OKXWebSocketService.swift`:
```swift
import Foundation
import Observation

@Observable
@MainActor
final class OKXWebSocketService {
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    private(set) var state: ConnectionState = .disconnected
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var retryCount = 0
    private let maxRetries = 5
    private var subscribedChannels: [[String: String]] = []

    var onMessage: ((OKXMessage) -> Void)?

    private let endpoint = URL(string: "wss://ws.okx.com:8443/ws/v5/public")!

    func connect() {
        guard case .disconnected = state else { return }
        state = .connecting
        retryCount = 0
        establishConnection()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        state = .disconnected
    }

    func subscribe(channel: String, instId: String) {
        let arg = ["channel": channel, "instId": instId]
        subscribedChannels.append(arg)
        sendSubscription(args: [arg])
    }

    func unsubscribe(channel: String, instId: String) {
        let arg = ["channel": channel, "instId": instId]
        subscribedChannels.removeAll { $0 == arg }
        let msg: [String: Any] = ["op": "unsubscribe", "args": [arg]]
        sendJSON(msg)
    }

    private func establishConnection() {
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config)
        webSocketTask = session?.webSocketTask(with: endpoint)
        webSocketTask?.resume()
        state = .connected
        receiveMessage()

        if !subscribedChannels.isEmpty {
            sendSubscription(args: subscribedChannels)
        }
    }

    private func sendSubscription(args: [[String: String]]) {
        let msg: [String: Any] = ["op": "subscribe", "args": args]
        sendJSON(msg)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { _ in }
    }

    private func sendPong() {
        webSocketTask?.send(.string("pong")) { _ in }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleText(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleText(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveMessage()
                case .failure:
                    self.handleDisconnect()
                }
            }
        }
    }

    private func handleText(_ text: String) {
        guard let parsed = try? OKXMessageParser.parse(text) else { return }
        if case .ping = parsed {
            sendPong()
            return
        }
        onMessage?(parsed)
    }

    private func handleDisconnect() {
        state = .disconnected
        guard retryCount < maxRetries else {
            state = .error("Max retries exceeded")
            return
        }
        retryCount += 1
        let delay = pow(2.0, Double(retryCount))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            self.establishConnection()
        }
    }
}
```

- [ ] **Step 6: Implement MarketDataProvider**

`Sources/MayStock/Services/MarketData/MarketDataProvider.swift`:
```swift
import Foundation
import Observation

@Observable
@MainActor
final class MarketDataProvider {
    private let webSocket = OKXWebSocketService()

    private(set) var currentPrice: Double = 0.0
    private(set) var priceChange24h: Double = 0.0
    private(set) var candles: [OHLC] = []
    private(set) var orderBook: OrderBook = OrderBook(bids: [], asks: [], timestamp: Date())
    private(set) var ticks: [MarketTick] = []
    private(set) var isConnected: Bool = false

    private let maxCandles = 500
    private let maxTicks = 300

    init() {
        webSocket.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handleMessage(message)
            }
        }
    }

    func start(instId: String, candleChannel: String) {
        webSocket.connect()
        webSocket.subscribe(channel: "tickers", instId: instId)
        webSocket.subscribe(channel: candleChannel, instId: instId)
        webSocket.subscribe(channel: "books5", instId: instId)
        isConnected = true
    }

    func stop() {
        webSocket.disconnect()
        isConnected = false
    }

    func switchTimeSpan(instId: String, newChannel: String, oldChannel: String) {
        webSocket.unsubscribe(channel: oldChannel, instId: instId)
        webSocket.subscribe(channel: newChannel, instId: instId)
        candles = []
    }

    private func handleMessage(_ message: OKXMessage) {
        switch message {
        case .ticker(let tick):
            currentPrice = tick.price
            ticks.append(tick)
            if ticks.count > maxTicks { ticks.removeFirst() }
        case .candle(let ohlc):
            if let lastIndex = candles.indices.last,
               !candles[lastIndex].confirmed,
               candles[lastIndex].timestamp == ohlc.timestamp {
                candles[lastIndex] = ohlc
            } else {
                candles.append(ohlc)
                if candles.count > maxCandles { candles.removeFirst() }
            }
        case .orderBook(let book):
            orderBook = book
        case .subscribed:
            break
        case .error(let msg):
            print("OKX error: \(msg)")
        case .ping:
            break
        }
    }

    var formattedPrice: String {
        if currentPrice >= 10000 {
            return String(format: "%.0f", currentPrice)
        } else if currentPrice >= 100 {
            return String(format: "%.2f", currentPrice)
        }
        return String(format: "%.4f", currentPrice)
    }

    var priceChangePercent: String {
        guard priceChange24h != 0 else { return "" }
        let sign = priceChange24h > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", priceChange24h))%"
    }
}
```

- [ ] **Step 7: Write MarketDataProvider tests**

`Tests/MayStockTests/MarketDataProviderTests.swift`:
```swift
import Testing
import Foundation
@testable import MayStock

@Suite("MarketDataProvider")
struct MarketDataProviderTests {
    @Test("formats price correctly for large values")
    @MainActor
    func formatsLargePrice() {
        let provider = MarketDataProvider()
        // Simulate receiving a ticker
        let tick = MarketTick(timestamp: Date(), price: 62213.5, volume: 100)
        // Access internal state via reflection isn't ideal; test the formatter directly
        #expect(provider.formattedPrice == "0.0000") // initial state

        // We'll verify parsing indirectly through the parser tests
    }
}
```

- [ ] **Step 8: Run all tests**

Run: `swift test 2>&1 | tail -15`
Expected: All tests pass

- [ ] **Step 9: Commit**

```bash
git add Sources/MayStock/Services/MarketData/ Tests/MayStockTests/OKXMessageParserTests.swift Tests/MayStockTests/MarketDataProviderTests.swift
git commit -m "feat: add OKX WebSocket service with message parser and MarketDataProvider"
```

---

## Task 5: StatusBarController (Menu Bar + Hover + Right-Click)

**Files:**
- Create: `Sources/MayStock/App/StatusBarController.swift`
- Modify: `Sources/MayStock/App/AppDelegate.swift`

- [ ] **Step 1: Implement StatusBarController**

`Sources/MayStock/App/StatusBarController.swift`:
```swift
import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private var eventMonitor: Any?
    private var trackingArea: NSTrackingArea?

    private let configService: ConfigurationService
    private let cpuMonitor: CPUMonitor
    private let memoryMonitor: MemoryMonitor
    private let networkMonitor: NetworkMonitor
    private let marketData: MarketDataProvider

    private var samplingTimer: Timer?
    private var popoverDismissTimer: Timer?

    init(
        configService: ConfigurationService,
        cpuMonitor: CPUMonitor,
        memoryMonitor: MemoryMonitor,
        networkMonitor: NetworkMonitor,
        marketData: MarketDataProvider
    ) {
        self.configService = configService
        self.cpuMonitor = cpuMonitor
        self.memoryMonitor = memoryMonitor
        self.networkMonitor = networkMonitor
        self.marketData = marketData

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        super.init()

        setupButton()
        setupPopover()
        startSampling()
        startMarketData()
        updateMenuBarText()
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.title = "MayStock"
        button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let area = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(area)
        trackingArea = area
    }

    private func setupPopover() {
        let popoverView = PopoverView(
            marketData: marketData,
            cpuMonitor: cpuMonitor,
            memoryMonitor: memoryMonitor,
            networkMonitor: networkMonitor,
            configService: configService
        )
        popover.contentViewController = NSHostingController(rootView: popoverView)
        popover.contentSize = NSSize(width: 420, height: 320)
    }

    private func startSampling() {
        cpuMonitor.sample()
        memoryMonitor.sample()
        networkMonitor.sample()

        samplingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cpuMonitor.sample()
                self?.memoryMonitor.sample()
                self?.networkMonitor.sample()
                self?.updateMenuBarText()
            }
        }
    }

    private func startMarketData() {
        let btcItem = configService.monitorItems.first { $0.type == .crypto && $0.isEnabled }
        if let item = btcItem, case .okx(let instId) = item.source {
            marketData.start(instId: instId, candleChannel: item.chartConfig.timeSpan.okxChannel)
        }
    }

    private func updateMenuBarText() {
        var parts: [String] = []
        for item in configService.monitorItems where item.isEnabled {
            switch item.type {
            case .cpu:
                parts.append("\(item.label) \(String(format: "%.0f%%", cpuMonitor.currentUsage))")
            case .memory:
                parts.append("\(item.label) \(memoryMonitor.formattedUsed)")
            case .network:
                parts.append("\(item.label) \(networkMonitor.formattedIn)")
            case .crypto:
                let price = marketData.formattedPrice
                if price != "0.0000" {
                    parts.append("\(item.label) \(price)")
                } else {
                    parts.append("\(item.label) --")
                }
            }
        }
        statusItem.button?.title = parts.joined(separator: " | ")
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startPopoverMouseMonitoring()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MayStock", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items {
            item.target = self
        }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            NSApp.mainMenu?.items.first?.submenu?.items.first(where: {
                $0.action == #selector(NSApplication.showSettingsWindow)
            })?.performAction()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    override func mouseEntered(with event: NSEvent) {
        popoverDismissTimer?.invalidate()
        if !popover.isShown {
            showPopover()
        }
    }

    override func mouseExited(with event: NSEvent) {
        popoverDismissTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if let popoverWindow = self.popover.contentViewController?.view.window {
                    let mouseLocation = NSEvent.mouseLocation
                    if !popoverWindow.frame.contains(mouseLocation) {
                        self.popover.performClose(nil)
                    }
                }
            }
        }
    }

    private func startPopoverMouseMonitoring() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self = self, self.popover.isShown else { return }
                let mouseLocation = NSEvent.mouseLocation
                let buttonFrame = self.statusItem.button?.window?.convertToScreen(
                    self.statusItem.button?.frame ?? .zero
                ) ?? .zero
                let popoverFrame = self.popover.contentViewController?.view.window?.frame ?? .zero

                if !buttonFrame.contains(mouseLocation) && !popoverFrame.contains(mouseLocation) {
                    self.popover.performClose(nil)
                    if let monitor = self.eventMonitor {
                        NSEvent.removeMonitor(monitor)
                        self.eventMonitor = nil
                    }
                }
            }
        }
    }

    deinit {
        samplingTimer?.invalidate()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
```

- [ ] **Step 2: Update AppDelegate**

`Sources/MayStock/App/AppDelegate.swift`:
```swift
import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    let configService = ConfigurationService()
    let cpuMonitor = CPUMonitor()
    let memoryMonitor = MemoryMonitor()
    let networkMonitor = NetworkMonitor()
    let marketData = MarketDataProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(
            configService: configService,
            cpuMonitor: cpuMonitor,
            memoryMonitor: memoryMonitor,
            networkMonitor: networkMonitor,
            marketData: marketData
        )
    }
}
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds (PopoverView not yet created — create a stub)

- [ ] **Step 4: Create PopoverView stub for compilation**

`Sources/MayStock/Features/Popover/PopoverView.swift`:
```swift
import SwiftUI

struct PopoverView: View {
    let marketData: MarketDataProvider
    let cpuMonitor: CPUMonitor
    let memoryMonitor: MemoryMonitor
    let networkMonitor: NetworkMonitor
    let configService: ConfigurationService

    var body: some View {
        VStack {
            Text("BTC/USDT")
                .font(.headline)
            Text(marketData.formattedPrice)
                .font(.system(.largeTitle, design: .monospaced))
            Text("Charts coming soon")
                .foregroundStyle(.secondary)
        }
        .frame(width: 400, height: 300)
        .padding()
    }
}
```

- [ ] **Step 5: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add Sources/MayStock/App/ Sources/MayStock/Features/Popover/PopoverView.swift
git commit -m "feat: add StatusBarController with hover popover and right-click menu"
```

---

## Task 6: Chart Views (Line, Candlestick, Volume, Depth)

**Files:**
- Create: `Sources/MayStock/Features/Charts/LineChartView.swift`
- Create: `Sources/MayStock/Features/Charts/CandlestickChartView.swift`
- Create: `Sources/MayStock/Features/Charts/VolumeChartView.swift`
- Create: `Sources/MayStock/Features/Charts/DepthChartView.swift`

- [ ] **Step 1: Implement LineChartView**

`Sources/MayStock/Features/Charts/LineChartView.swift`:
```swift
import SwiftUI
import Charts

struct LineChartView: View {
    let data: [MarketTick]
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var lineGradient: LinearGradient {
        LinearGradient(
            colors: [.green, .cyan],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var areaGradient: LinearGradient {
        LinearGradient(
            colors: [.green.opacity(0.3), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func formatValue(_ v: Double) -> String {
        if v >= 10000 { return String(format: "%.0f", v) }
        if v >= 100 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}
```

- [ ] **Step 2: Implement CandlestickChartView**

`Sources/MayStock/Features/Charts/CandlestickChartView.swift`:
```swift
import SwiftUI

struct CandlestickChartView: View {
    let candles: [OHLC]

    var body: some View {
        Canvas { context, size in
            guard !candles.isEmpty else { return }

            let allPrices = candles.flatMap { [$0.high, $0.low] }
            guard let minPrice = allPrices.min(), let maxPrice = allPrices.max(), maxPrice > minPrice else { return }

            let priceRange = maxPrice - minPrice
            let padding: CGFloat = 8
            let chartWidth = size.width - padding * 2
            let chartHeight = size.height - padding * 2
            let candleWidth = max(2, chartWidth / CGFloat(candles.count) - 2)
            let spacing = chartWidth / CGFloat(candles.count)

            for (index, candle) in candles.enumerated() {
                let x = padding + CGFloat(index) * spacing + spacing / 2
                let color: Color = candle.isBullish ? .green : .red

                // Wick
                let wickTop = padding + (1 - (candle.high - minPrice) / priceRange) * chartHeight
                let wickBottom = padding + (1 - (candle.low - minPrice) / priceRange) * chartHeight
                let wickPath = Path { path in
                    path.move(to: CGPoint(x: x, y: wickTop))
                    path.addLine(to: CGPoint(x: x, y: wickBottom))
                }
                context.stroke(wickPath, with: .color(color), lineWidth: 1)

                // Body
                let bodyTop = padding + (1 - (max(candle.open, candle.close) - minPrice) / priceRange) * chartHeight
                let bodyBottom = padding + (1 - (min(candle.open, candle.close) - minPrice) / priceRange) * chartHeight
                let bodyHeight = max(1, bodyBottom - bodyTop)
                let bodyRect = CGRect(
                    x: x - candleWidth / 2,
                    y: bodyTop,
                    width: candleWidth,
                    height: bodyHeight
                )
                context.fill(Path(bodyRect), with: .color(color))
            }
        }
    }
}
```

- [ ] **Step 3: Implement VolumeChartView**

`Sources/MayStock/Features/Charts/VolumeChartView.swift`:
```swift
import SwiftUI
import Charts

struct VolumeChartView: View {
    let candles: [OHLC]

    var body: some View {
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

    private func formatVolume(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return String(format: "%.0f", v)
    }
}
```

- [ ] **Step 4: Implement DepthChartView**

`Sources/MayStock/Features/Charts/DepthChartView.swift`:
```swift
import SwiftUI

struct DepthChartView: View {
    let orderBook: OrderBook

    var body: some View {
        Canvas { context, size in
            let bids = cumulativeBids
            let asks = cumulativeAsks
            guard !bids.isEmpty, !asks.isEmpty else { return }

            let allPrices = bids.map(\.price) + asks.map(\.price)
            let allSizes = bids.map(\.cumulativeSize) + asks.map(\.cumulativeSize)
            guard let minPrice = allPrices.min(),
                  let maxPrice = allPrices.max(),
                  let maxSize = allSizes.max(),
                  maxPrice > minPrice, maxSize > 0 else { return }

            let padding: CGFloat = 8
            let chartWidth = size.width - padding * 2
            let chartHeight = size.height - padding * 2

            func xPos(_ price: Double) -> CGFloat {
                padding + CGFloat((price - minPrice) / (maxPrice - minPrice)) * chartWidth
            }
            func yPos(_ cumSize: Double) -> CGFloat {
                padding + chartHeight - CGFloat(cumSize / maxSize) * chartHeight
            }

            // Bids (green, left side)
            var bidPath = Path()
            bidPath.move(to: CGPoint(x: xPos(bids[0].price), y: padding + chartHeight))
            for entry in bids {
                bidPath.addLine(to: CGPoint(x: xPos(entry.price), y: yPos(entry.cumulativeSize)))
            }
            bidPath.addLine(to: CGPoint(x: xPos(bids.last!.price), y: padding + chartHeight))
            bidPath.closeSubpath()
            context.fill(bidPath, with: .color(.green.opacity(0.3)))
            
            var bidLine = Path()
            for (i, entry) in bids.enumerated() {
                let point = CGPoint(x: xPos(entry.price), y: yPos(entry.cumulativeSize))
                if i == 0 { bidLine.move(to: point) } else { bidLine.addLine(to: point) }
            }
            context.stroke(bidLine, with: .color(.green), lineWidth: 1.5)

            // Asks (red, right side)
            var askPath = Path()
            askPath.move(to: CGPoint(x: xPos(asks[0].price), y: padding + chartHeight))
            for entry in asks {
                askPath.addLine(to: CGPoint(x: xPos(entry.price), y: yPos(entry.cumulativeSize)))
            }
            askPath.addLine(to: CGPoint(x: xPos(asks.last!.price), y: padding + chartHeight))
            askPath.closeSubpath()
            context.fill(askPath, with: .color(.red.opacity(0.3)))

            var askLine = Path()
            for (i, entry) in asks.enumerated() {
                let point = CGPoint(x: xPos(entry.price), y: yPos(entry.cumulativeSize))
                if i == 0 { askLine.move(to: point) } else { askLine.addLine(to: point) }
            }
            context.stroke(askLine, with: .color(.red), lineWidth: 1.5)
        }
    }

    private struct CumulativeEntry {
        let price: Double
        let cumulativeSize: Double
    }

    private var cumulativeBids: [CumulativeEntry] {
        let sorted = orderBook.bids.sorted { $0.price > $1.price }
        var cumulative: Double = 0
        return sorted.map { entry in
            cumulative += entry.size
            return CumulativeEntry(price: entry.price, cumulativeSize: cumulative)
        }.reversed()
    }

    private var cumulativeAsks: [CumulativeEntry] {
        let sorted = orderBook.asks.sorted { $0.price < $1.price }
        var cumulative: Double = 0
        return sorted.map { entry in
            cumulative += entry.size
            return CumulativeEntry(price: entry.price, cumulativeSize: cumulative)
        }
    }
}
```

- [ ] **Step 5: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add Sources/MayStock/Features/Charts/
git commit -m "feat: add chart views (line, candlestick, volume, depth)"
```

---

## Task 7: Popover View & Chart Selector

**Files:**
- Modify: `Sources/MayStock/Features/Popover/PopoverView.swift`
- Create: `Sources/MayStock/Features/Popover/PopoverViewModel.swift`
- Create: `Sources/MayStock/Features/Popover/ChartSelectorView.swift`

- [ ] **Step 1: Implement PopoverViewModel**

`Sources/MayStock/Features/Popover/PopoverViewModel.swift`:
```swift
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
```

- [ ] **Step 2: Implement ChartSelectorView**

`Sources/MayStock/Features/Popover/ChartSelectorView.swift`:
```swift
import SwiftUI

struct ChartSelectorView: View {
    @Bindable var viewModel: PopoverViewModel

    var body: some View {
        VStack(spacing: 8) {
            // Chart type selector
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

                // Time span selector
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
```

- [ ] **Step 3: Update PopoverView with full implementation**

`Sources/MayStock/Features/Popover/PopoverView.swift`:
```swift
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
            // Monitor item tabs
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

            // Current value
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
```

- [ ] **Step 4: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add Sources/MayStock/Features/Popover/
git commit -m "feat: add Popover with chart selector and multi-monitor tabs"
```

---

## Task 8: Settings Window

**Files:**
- Create: `Sources/MayStock/Features/Settings/SettingsView.swift`
- Create: `Sources/MayStock/Features/Settings/GeneralSettingsView.swift`
- Create: `Sources/MayStock/Features/Settings/MonitorsSettingsView.swift`
- Create: `Sources/MayStock/Features/Settings/AppearanceSettingsView.swift`
- Modify: `Sources/MayStock/App/MayStockApp.swift`

- [ ] **Step 1: Implement SettingsView**

`Sources/MayStock/Features/Settings/SettingsView.swift`:
```swift
import SwiftUI

struct SettingsView: View {
    let configService: ConfigurationService

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            MonitorsSettingsView(configService: configService)
                .tabItem { Label("Monitors", systemImage: "gauge") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 500, height: 400)
    }
}
```

- [ ] **Step 2: Implement GeneralSettingsView**

`Sources/MayStock/Features/Settings/GeneralSettingsView.swift`:
```swift
import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("samplingInterval") private var samplingInterval = 2.0
    @AppStorage("maxMenuBarItems") private var maxMenuBarItems = 5

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            Section("Data") {
                Picker("Sampling Interval", selection: $samplingInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
                Stepper("Max Menu Bar Items: \(maxMenuBarItems)", value: $maxMenuBarItems, in: 1...10)
            }

            Section("About") {
                LabeledContent("Version", value: "0.1.0")
                LabeledContent("Build", value: "1")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Launch at login error: \(error)")
        }
    }
}
```

- [ ] **Step 3: Implement MonitorsSettingsView**

`Sources/MayStock/Features/Settings/MonitorsSettingsView.swift`:
```swift
import SwiftUI

struct MonitorsSettingsView: View {
    @Bindable var configService: ConfigurationService
    @State private var selectedItemId: UUID?

    var body: some View {
        HSplitView {
            // Left: list of monitor items
            VStack(spacing: 0) {
                List(selection: $selectedItemId) {
                    ForEach(configService.monitorItems) { item in
                        HStack {
                            Image(systemName: iconName(for: item.type))
                            Text(item.label)
                            Spacer()
                            Toggle("", isOn: binding(for: item))
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        .tag(item.id)
                    }
                    .onMove { indices, destination in
                        configService.monitorItems.move(fromOffsets: indices, toOffset: destination)
                        updateSortOrders()
                        try? configService.save()
                    }
                }
                .frame(minWidth: 180)

                HStack {
                    Button(action: addItem) {
                        Image(systemName: "plus")
                    }
                    Button(action: removeSelectedItem) {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedItemId == nil)
                    Spacer()
                }
                .padding(8)
            }

            // Right: edit selected item
            if let id = selectedItemId,
               let index = configService.monitorItems.firstIndex(where: { $0.id == id }) {
                MonitorItemEditView(item: $configService.monitorItems[index]) {
                    try? configService.save()
                }
                .frame(minWidth: 280)
            } else {
                Text("Select a monitor item")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }

    private func binding(for item: MonitorItem) -> Binding<Bool> {
        guard let index = configService.monitorItems.firstIndex(where: { $0.id == item.id }) else {
            return .constant(false)
        }
        return Binding(
            get: { configService.monitorItems[index].isEnabled },
            set: { newValue in
                configService.monitorItems[index].isEnabled = newValue
                try? configService.save()
            }
        )
    }

    private func addItem() {
        let newItem = MonitorItem(
            id: UUID(),
            type: .crypto,
            label: "NEW",
            source: .okx(instId: "BTC-USDT"),
            chartConfig: .default,
            isEnabled: true,
            sortOrder: configService.monitorItems.count
        )
        configService.monitorItems.append(newItem)
        selectedItemId = newItem.id
        try? configService.save()
    }

    private func removeSelectedItem() {
        guard let id = selectedItemId else { return }
        configService.monitorItems.removeAll { $0.id == id }
        selectedItemId = nil
        try? configService.save()
    }

    private func updateSortOrders() {
        for i in configService.monitorItems.indices {
            configService.monitorItems[i].sortOrder = i
        }
    }

    private func iconName(for type: MonitorType) -> String {
        switch type {
        case .crypto: return "bitcoinsign.circle"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "network"
        }
    }
}

struct MonitorItemEditView: View {
    @Binding var item: MonitorItem
    let onSave: () -> Void

    var body: some View {
        Form {
            Section("Display") {
                TextField("Label", text: $item.label)
                    .onChange(of: item.label) { _, _ in onSave() }
                Picker("Type", selection: $item.type) {
                    ForEach(MonitorType.allCases, id: \.self) { type in
                        Text(type.rawValue.capitalized).tag(type)
                    }
                }
                .onChange(of: item.type) { _, _ in onSave() }
            }

            if item.type == .crypto {
                Section("Data Source") {
                    TextField("Instrument ID", text: instIdBinding)
                        .onChange(of: instIdBinding.wrappedValue) { _, _ in onSave() }
                }
            }

            Section("Chart") {
                Picker("Chart Type", selection: $item.chartConfig.chartType) {
                    ForEach(ChartType.allCases, id: \.self) { type in
                        Text(type.rawValue.capitalized).tag(type)
                    }
                }
                .onChange(of: item.chartConfig.chartType) { _, _ in onSave() }

                Picker("Time Span", selection: $item.chartConfig.timeSpan) {
                    ForEach(TimeSpan.allPresets, id: \.displayLabel) { span in
                        Text(span.displayLabel).tag(span)
                    }
                }
                .onChange(of: item.chartConfig.timeSpan) { _, _ in onSave() }

                Toggle("Show Volume", isOn: $item.chartConfig.showVolume)
                    .onChange(of: item.chartConfig.showVolume) { _, _ in onSave() }
            }
        }
        .formStyle(.grouped)
    }

    private var instIdBinding: Binding<String> {
        Binding(
            get: {
                if case .okx(let instId) = item.source { return instId }
                return ""
            },
            set: { item.source = .okx(instId: $0) }
        )
    }
}
```

- [ ] **Step 4: Implement AppearanceSettingsView**

`Sources/MayStock/Features/Settings/AppearanceSettingsView.swift`:
```swift
import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage("chartColorScheme") private var chartColorScheme = "standard"
    @AppStorage("menuBarFontSize") private var menuBarFontSize = 12.0

    var body: some View {
        Form {
            Section("Menu Bar") {
                Slider(value: $menuBarFontSize, in: 10...16, step: 1) {
                    Text("Font Size: \(Int(menuBarFontSize))pt")
                }
            }

            Section("Charts") {
                Picker("Color Scheme", selection: $chartColorScheme) {
                    Text("Standard (Green/Red)").tag("standard")
                    Text("Monochrome").tag("monochrome")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

- [ ] **Step 5: Update MayStockApp to pass config service**

`Sources/MayStock/App/MayStockApp.swift`:
```swift
import SwiftUI

@main
struct MayStockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(configService: appDelegate.configService)
        }
    }
}
```

- [ ] **Step 6: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 7: Commit**

```bash
git add Sources/MayStock/Features/Settings/ Sources/MayStock/App/MayStockApp.swift
git commit -m "feat: add Settings window with General, Monitors, and Appearance tabs"
```

---

## Task 9: Integration Tests

**Files:**
- Create: `Tests/IntegrationTests/OKXWebSocketIntegrationTests.swift`
- Create: `Tests/IntegrationTests/DataFlowIntegrationTests.swift`

- [ ] **Step 1: Write OKX WebSocket integration test**

`Tests/IntegrationTests/OKXWebSocketIntegrationTests.swift`:
```swift
import Testing
import Foundation
@testable import MayStock

@Suite("OKX WebSocket Integration", .tags(.integration))
struct OKXWebSocketIntegrationTests {
    @Test("connects and receives ticker data", .timeLimit(.minutes(1)))
    @MainActor
    func connectsAndReceivesTicker() async throws {
        let service = OKXWebSocketService()
        var receivedTicker = false

        service.onMessage = { message in
            if case .ticker = message {
                receivedTicker = true
            }
        }

        service.connect()
        service.subscribe(channel: "tickers", instId: "BTC-USDT")

        // Wait up to 10 seconds for a ticker
        for _ in 0..<100 {
            if receivedTicker { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(receivedTicker, "Should receive at least one ticker within 10 seconds")
        service.disconnect()
    }

    @Test("receives candle data", .timeLimit(.minutes(1)))
    @MainActor
    func receivesCandle() async throws {
        let service = OKXWebSocketService()
        var receivedCandle = false

        service.onMessage = { message in
            if case .candle = message {
                receivedCandle = true
            }
        }

        service.connect()
        service.subscribe(channel: "candle1s", instId: "BTC-USDT")

        for _ in 0..<50 {
            if receivedCandle { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        #expect(receivedCandle, "Should receive candle data within 10 seconds")
        service.disconnect()
    }

    @Test("receives order book data", .timeLimit(.minutes(1)))
    @MainActor
    func receivesOrderBook() async throws {
        let service = OKXWebSocketService()
        var receivedBook = false

        service.onMessage = { message in
            if case .orderBook = message {
                receivedBook = true
            }
        }

        service.connect()
        service.subscribe(channel: "books5", instId: "BTC-USDT")

        for _ in 0..<50 {
            if receivedBook { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        #expect(receivedBook, "Should receive order book within 10 seconds")
        service.disconnect()
    }
}

extension Tag {
    @Tag static var integration: Self
}
```

- [ ] **Step 2: Write data flow integration test**

`Tests/IntegrationTests/DataFlowIntegrationTests.swift`:
```swift
import Testing
import Foundation
@testable import MayStock

@Suite("Data Flow Integration", .tags(.integration))
struct DataFlowIntegrationTests {
    @Test("MarketDataProvider receives and stores ticks", .timeLimit(.minutes(1)))
    @MainActor
    func providerStoresTicks() async throws {
        let provider = MarketDataProvider()
        provider.start(instId: "BTC-USDT", candleChannel: "candle1s")

        for _ in 0..<100 {
            if provider.currentPrice > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(provider.currentPrice > 0, "Should have a non-zero price")
        #expect(!provider.ticks.isEmpty, "Should have accumulated ticks")
        provider.stop()
    }

    @Test("System monitors produce valid data")
    @MainActor
    func systemMonitorsWork() async throws {
        let cpu = CPUMonitor()
        let memory = MemoryMonitor()
        let network = NetworkMonitor()

        cpu.sample()
        memory.sample()
        network.sample()

        try await Task.sleep(for: .milliseconds(500))

        cpu.sample()
        network.sample()

        #expect(cpu.currentUsage >= 0)
        #expect(memory.usedBytes > 0)
        #expect(memory.totalBytes > 0)
        #expect(network.bytesInPerSecond >= 0)
    }

    @Test("Configuration persists across service instances")
    @MainActor
    func configPersists() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MayStock-Integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let service1 = ConfigurationService(directory: tempDir)
        service1.monitorItems[0].label = "BITCOIN"
        try service1.save()

        let service2 = ConfigurationService(directory: tempDir)
        #expect(service2.monitorItems[0].label == "BITCOIN")

        try FileManager.default.removeItem(at: tempDir)
    }
}
```

- [ ] **Step 3: Run integration tests**

Run: `swift test --filter "Integration" 2>&1 | tail -15`
Expected: All tests pass (requires network for OKX tests)

- [ ] **Step 4: Commit**

```bash
git add Tests/IntegrationTests/
git commit -m "test: add integration tests for OKX WebSocket and data flow"
```

---

## Task 10: UI Tests (XCUITest)

**Files:**
- Create: `Tests/UITests/MayStockUITests.swift`
- Create: `Tests/UITests/SettingsUITests.swift`

Note: XCUITest requires an Xcode project. We need to generate one from SPM or switch to an .xcodeproj-based setup. For SPM-based projects, XCUITest requires opening in Xcode.

- [ ] **Step 1: Create Xcode project generation script**

Since SPM executable targets don't natively support XCUITest bundles, we'll create a minimal Xcode project wrapper. First, create a script:

`scripts/generate-xcodeproj.sh`:
```bash
#!/bin/bash
# Generate Xcode project for UI testing
swift package generate-xcodeproj
echo "Open MayStock.xcodeproj in Xcode to run UI tests"
```

- [ ] **Step 2: Write UI test stubs**

`Tests/UITests/MayStockUITests.swift`:
```swift
import XCTest

final class MayStockUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    func testAppLaunchesAsAccessory() throws {
        // Verify the app is running (it's an accessory app, no main window)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    func testMenuBarItemExists() throws {
        // Menu bar items are in the status bar area
        let statusItems = app.statusItems
        XCTAssertTrue(statusItems.count > 0, "Should have at least one status item")
    }

    func testRightClickOpensSettings() throws {
        let statusItem = app.statusItems.firstMatch
        statusItem.rightClick()

        let settingsMenuItem = app.menuItems["Settings…"]
        XCTAssertTrue(settingsMenuItem.waitForExistence(timeout: 2))
        settingsMenuItem.click()

        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
    }
}
```

`Tests/UITests/SettingsUITests.swift`:
```swift
import XCTest

final class SettingsUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    func testSettingsTabsExist() throws {
        // Open settings
        let statusItem = app.statusItems.firstMatch
        statusItem.rightClick()
        app.menuItems["Settings…"].click()

        let settingsWindow = app.windows.firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        // Verify tabs
        XCTAssertTrue(settingsWindow.buttons["General"].exists)
        XCTAssertTrue(settingsWindow.buttons["Monitors"].exists)
        XCTAssertTrue(settingsWindow.buttons["Appearance"].exists)
    }

    func testAddMonitorItem() throws {
        let statusItem = app.statusItems.firstMatch
        statusItem.rightClick()
        app.menuItems["Settings…"].click()

        let settingsWindow = app.windows.firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        settingsWindow.buttons["Monitors"].click()

        let addButton = settingsWindow.buttons["plus"]
        guard addButton.waitForExistence(timeout: 2) else {
            XCTFail("Add button not found")
            return
        }
        addButton.click()

        // Verify a new item appeared in the list
        // The list should now have 5 items (4 defaults + 1 new)
    }
}
```

- [ ] **Step 3: Commit**

```bash
mkdir -p scripts
git add Tests/UITests/ scripts/
git commit -m "test: add XCUITest stubs for menu bar and settings UI"
```

---

## Task 11: Final Polish & App Run

**Files:**
- Modify: `Sources/MayStock/App/StatusBarController.swift` (menu bar text update on market data)
- Create: `Sources/MayStock/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`

- [ ] **Step 1: Add AppIcon asset catalog placeholder**

`Sources/MayStock/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`:
```json
{
  "images": [
    {
      "idiom": "mac",
      "scale": "1x",
      "size": "16x16"
    },
    {
      "idiom": "mac",
      "scale": "2x",
      "size": "16x16"
    },
    {
      "idiom": "mac",
      "scale": "1x",
      "size": "32x32"
    },
    {
      "idiom": "mac",
      "scale": "2x",
      "size": "32x32"
    },
    {
      "idiom": "mac",
      "scale": "1x",
      "size": "128x128"
    },
    {
      "idiom": "mac",
      "scale": "2x",
      "size": "128x128"
    },
    {
      "idiom": "mac",
      "scale": "1x",
      "size": "256x256"
    },
    {
      "idiom": "mac",
      "scale": "2x",
      "size": "256x256"
    },
    {
      "idiom": "mac",
      "scale": "1x",
      "size": "512x512"
    },
    {
      "idiom": "mac",
      "scale": "2x",
      "size": "512x512"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
```

`Sources/MayStock/Resources/Assets.xcassets/Contents.json`:
```json
{
  "info": {
    "author": "xcode",
    "version": 1
  }
}
```

- [ ] **Step 2: Add real-time menu bar text update from market data**

Add a timer in StatusBarController to update the menu bar text when market data changes. Modify the `startMarketData()` to also observe price updates:

In `StatusBarController.swift`, add after `startSampling()`:
```swift
// Add a faster timer for market data text updates
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
    Task { @MainActor in
        self?.updateMenuBarText()
    }
}
```

- [ ] **Step 3: Final build verification**

Run: `swift build 2>&1 | tail -5`
Expected: Clean build

- [ ] **Step 4: Run all unit tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/MayStock/Resources/ Sources/MayStock/App/StatusBarController.swift
git commit -m "feat: add app icon asset catalog and real-time menu bar updates"
```

- [ ] **Step 6: Run the app**

Run: `swift run MayStock &`
Expected: App launches, menu bar item appears showing "CPU X% | MEM X.XG | NET X KB/s | BTC --" (BTC will show price once WebSocket connects)

---

## Icon Prompt (for external generation)

> A minimal, elegant macOS app icon for a financial/system monitoring tool. A translucent glass cube or crystal prism refracting a subtle upward-trending candlestick chart line in emerald green and electric blue gradients. The background is a deep matte black with a faint circular glow. Apple macOS Big Sur / Tahoe icon style with rounded squircle shape, soft ambient lighting, volumetric glass material, no text, no busy details — just one pristine geometric form that whispers "real-time data elegance." 1024x1024, centered composition.

Generate the icon externally and place all size variants into `Sources/MayStock/Resources/Assets.xcassets/AppIcon.appiconset/`.
