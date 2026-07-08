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
