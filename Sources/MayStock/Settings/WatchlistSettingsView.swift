import SwiftUI
import MayStockKit

/// Watchlist management: add (with live OKX validation), remove, reorder,
/// and per-item menu bar presentation.
struct WatchlistSettingsView: View {
    let appState: AppState

    @State private var selectedID: UUID?
    @State private var newInstId = ""
    @State private var validating = false
    @State private var addError: String?

    private var items: [WatchItem] { appState.store.config.watchlist }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(items) { item in
                        HStack {
                            Circle()
                                .fill(item.enabled ? ChartStyle.up : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.displayLabel).font(.system(size: 12, weight: .medium))
                                Text(item.instId).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .tag(item.id)
                    }
                    .onMove { indices, destination in
                        appState.store.update { config in
                            config.watchlist.move(fromOffsets: indices, toOffset: destination)
                        }
                    }
                }
                .listStyle(.inset)

                Divider()
                addRow
            }
            .frame(minWidth: 210, maxWidth: 240)

            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("如 ETH-USDT", text: $newInstId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { Task { await add() } }
                if validating {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await add() } } label: { Image(systemName: "plus") }
                        .disabled(newInstId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let addError {
                Text(addError).font(.system(size: 9)).foregroundStyle(.red)
            }
        }
        .padding(8)
    }

    private func add() async {
        let instId = newInstId.trimmingCharacters(in: .whitespaces).uppercased()
        guard !instId.isEmpty else { return }
        guard !items.contains(where: { $0.instId == instId }) else {
            addError = "已在自选中"
            return
        }
        validating = true
        addError = nil
        defer { validating = false }

        // Validate against the exchange before accepting.
        do {
            guard let meta = try await OKXRESTClient().instrumentMeta(instId: instId) else {
                addError = "OKX 上不存在该标的（示例：SOL-USDT / BTC-USDT-SWAP）"
                return
            }
            appState.store.update { config in
                config.watchlist.append(WatchItem(instId: meta.instId))
            }
            newInstId = ""
        } catch {
            addError = "校验失败：\(error)"
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let index = items.firstIndex(where: { $0.id == id }) {
            WatchItemEditor(appState: appState, index: index)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "sidebar.left").font(.title2).foregroundStyle(.tertiary)
                Text("选择左侧标的进行配置").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WatchItemEditor: View {
    let appState: AppState
    let index: Int

    private var item: WatchItem? {
        let list = appState.store.config.watchlist
        return index < list.count ? list[index] : nil
    }

    private func bind<T>(_ keyPath: WritableKeyPath<WatchItem, T>, default def: T) -> Binding<T> {
        Binding(
            get: {
                let list = appState.store.config.watchlist
                return index < list.count ? list[index][keyPath: keyPath] : def
            },
            set: { newValue in
                appState.store.update { config in
                    guard index < config.watchlist.count else { return }
                    config.watchlist[index][keyPath: keyPath] = newValue
                }
            })
    }

    var body: some View {
        if let item {
            Form {
                Section("显示") {
                    Toggle("在菜单栏显示", isOn: bind(\.enabled, default: true))
                    TextField("自定义标签", text: Binding(
                        get: { item.label ?? "" },
                        set: { newValue in
                            appState.store.update { config in
                                guard index < config.watchlist.count else { return }
                                config.watchlist[index].label = newValue.isEmpty ? nil : newValue
                            }
                        }))
                    Picker("菜单栏样式", selection: bind(\.style, default: .full)) {
                        ForEach(WatchItem.MenuBarStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    Picker("趋势图窗口", selection: bind(\.sparklineMinutes, default: 60)) {
                        Text("15 分钟").tag(15)
                        Text("1 小时").tag(60)
                        Text("4 小时").tag(240)
                        Text("24 小时").tag(1440)
                    }
                    Picker("价格小数位", selection: Binding(
                        get: { item.decimals ?? -1 },
                        set: { newValue in
                            appState.store.update { config in
                                guard index < config.watchlist.count else { return }
                                config.watchlist[index].decimals = newValue < 0 ? nil : newValue
                            }
                        })) {
                        Text("自动（交易所精度）").tag(-1)
                        ForEach(0..<7, id: \.self) { d in Text("\(d)").tag(d) }
                    }
                }
                Section("图表") {
                    Picker("默认 K 线周期", selection: bind(\.defaultBar, default: .m1)) {
                        ForEach(BarInterval.allCases) { bar in Text(bar.rawValue).tag(bar) }
                    }
                }
                Section {
                    Button(role: .destructive) {
                        appState.store.update { config in
                            guard index < config.watchlist.count else { return }
                            config.watchlist.remove(at: index)
                        }
                    } label: {
                        Label("移除该标的", systemImage: "trash")
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            EmptyView()
        }
    }
}
