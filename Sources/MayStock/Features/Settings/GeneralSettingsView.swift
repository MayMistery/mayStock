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
