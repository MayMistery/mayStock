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
    private var marketUpdateTimer: Timer?

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

        marketUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
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

    func updateMenuBarText() {
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
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc func mouseEntered(with event: NSEvent) {
        if !popover.isShown {
            showPopover()
        }
    }

    @objc func mouseExited(with event: NSEvent) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if let popoverWindow = self.popover.contentViewController?.view.window {
                let mouseLocation = NSEvent.mouseLocation
                if !popoverWindow.frame.contains(mouseLocation) {
                    self.popover.performClose(nil)
                }
            }
        }
    }

    private func startPopoverMouseMonitoring() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] _ in
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
}
