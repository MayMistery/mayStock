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
