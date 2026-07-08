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
