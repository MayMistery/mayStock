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
