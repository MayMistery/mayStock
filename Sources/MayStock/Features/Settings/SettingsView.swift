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
