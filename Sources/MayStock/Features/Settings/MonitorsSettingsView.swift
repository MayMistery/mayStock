import SwiftUI

struct MonitorsSettingsView: View {
    var configService: ConfigurationService
    @State private var selectedItemId: UUID?

    var body: some View {
        HSplitView {
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

            if let id = selectedItemId,
               let index = configService.monitorItems.firstIndex(where: { $0.id == id }) {
                MonitorItemEditView(item: Binding(
                    get: { configService.monitorItems[index] },
                    set: { configService.monitorItems[index] = $0 }
                )) {
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
            id: UUID(), type: .crypto, label: "NEW",
            source: .okx(instId: "BTC-USDT"), chartConfig: .default,
            isEnabled: true, sortOrder: configService.monitorItems.count
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
            get: { if case .okx(let instId) = item.source { return instId }; return "" },
            set: { item.source = .okx(instId: $0); onSave() }
        )
    }
}
