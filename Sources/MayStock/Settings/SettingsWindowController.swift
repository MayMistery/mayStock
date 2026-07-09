import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case watchlist, alerts, trading, general
    var id: String { rawValue }

    var label: String {
        switch self {
        case .watchlist: return "自选"
        case .alerts: return "告警"
        case .trading: return "交易"
        case .general: return "通用"
        }
    }

    var icon: String {
        switch self {
        case .watchlist: return "chart.line.uptrend.xyaxis"
        case .alerts: return "bell.badge"
        case .trading: return "arrow.left.arrow.right"
        case .general: return "gearshape"
        }
    }
}

/// Owns the settings window — created lazily, reused, never changes the
/// app's activation policy (stays a clean menu bar accessory).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private var window: NSWindow?
    private let selection = SettingsSelection()

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func show(tab: SettingsTab) {
        selection.tab = tab
        if window == nil {
            let root = SettingsRootView(appState: appState, selection: selection)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "MayStock 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 620, height: 460))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Tab selection shared between controller and SwiftUI.
@Observable
@MainActor
final class SettingsSelection {
    var tab: SettingsTab = .watchlist
}

struct SettingsRootView: View {
    let appState: AppState
    @Bindable var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            WatchlistSettingsView(appState: appState)
                .tabItem { Label(SettingsTab.watchlist.label, systemImage: SettingsTab.watchlist.icon) }
                .tag(SettingsTab.watchlist)
            AlertsSettingsView(appState: appState)
                .tabItem { Label(SettingsTab.alerts.label, systemImage: SettingsTab.alerts.icon) }
                .tag(SettingsTab.alerts)
            TradingSettingsView(appState: appState)
                .tabItem { Label(SettingsTab.trading.label, systemImage: SettingsTab.trading.icon) }
                .tag(SettingsTab.trading)
            GeneralSettingsView(appState: appState)
                .tabItem { Label(SettingsTab.general.label, systemImage: SettingsTab.general.icon) }
                .tag(SettingsTab.general)
        }
        .frame(width: 620, height: 460)
    }
}
