import AppKit
import SwiftUI
import MayStockKit

/// General preferences: launch, hover timing, and where the data lives.
struct SettingsPage: View {
    let appState: AppState

    private var general: GeneralPrefs { appState.store.config.general }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                PageHeader(title: "设置", subtitle: "MayStock \(AppInfo.version)")

                Card(title: "启动") {
                    Toggle("登录时自动启动", isOn: Binding(
                        get: { general.launchAtLogin },
                        set: { value in appState.store.update { $0.general.launchAtLogin = value } }))
                    .toggleStyle(.switch).controlSize(.small)
                    if Bundle.main.bundleIdentifier == nil {
                        Text("以 swift run 方式运行时没有 app bundle，这个开关不生效。")
                            .font(Theme.Text.caption).foregroundStyle(.tertiary)
                    }
                }

                Card(title: "悬浮面板", subtitle: "点击菜单栏图标可钉住面板；再次点击或点击面板外关闭") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            label("悬停出现延迟")
                            Picker("", selection: Binding(
                                get: { general.hoverDelayMs },
                                set: { value in appState.store.update { $0.general.hoverDelayMs = value } })) {
                                Text("立即").tag(0); Text("150 ms").tag(150)
                                Text("300 ms").tag(300); Text("500 ms").tag(500)
                            }
                            .labelsHidden().frame(width: 140)
                        }
                        GridRow {
                            label("移开后隐藏延迟")
                            Picker("", selection: Binding(
                                get: { general.hideDelayMs },
                                set: { value in appState.store.update { $0.general.hideDelayMs = value } })) {
                                Text("150 ms").tag(150); Text("350 ms").tag(350); Text("700 ms").tag(700)
                            }
                            .labelsHidden().frame(width: 140)
                        }
                    }
                }

                Card(title: "行情", subtitle: "加密货币全天交易，「今日涨跌」从哪一刻算是个选择；和手机上用同一个基准，两边的涨跌幅才对得上") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            label("涨跌幅基准")
                            Picker("", selection: Binding(
                                get: { general.changeBasis },
                                set: { value in appState.store.update { $0.general.changeBasis = value } })) {
                                ForEach(ChangeBasis.continuous, id: \.self) { basis in
                                    Text(basis.settingName).tag(basis)
                                }
                            }
                            .labelsHidden().frame(width: 160)
                        }
                    }
                    Text("菜单栏、悬浮面板、行情页与告警都按这个基准；美股始终较昨收。高低价与成交量仍是 24 小时。")
                        .font(Theme.Text.caption).foregroundStyle(.tertiary)
                }

                Card(title: "模型路由 · 情报站",
                     subtitle: "情报站每次运行时读这份连接文件，改完下一轮就生效；保存前先由情报运行环境按它自己的规则校验") {
                    IntelligenceConnectionEditor(appState: appState)
                }

                Card(title: "数据") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Venue.allCases) { venue in
                            KeyValueRow(label: "\(venue.displayName)行情", value: appState.hub.sourceName(for: venue))
                        }
                        KeyValueRow(label: "推送频率",
                                    value: "OKX tick ~100ms · 盘口 100ms · 美股轮询 \(Int(SchwabMarketFeed.tradingInterval)) 秒"
                                        + "（休市 \(Int(SchwabMarketFeed.closedInterval)) 秒）· 菜单栏渲染 10Hz")
                        KeyValueRow(label: "交易循环", value: "每 \(Int(StrategyRunner.defaultTickInterval)) 秒轮询 · 权益每 \(Int(StrategyRunner.equitySampleInterval)) 秒采样")
                        KeyValueRow(label: "数据目录", value: appState.dataDirectory.path, mono: true)
                    }
                    HStack(spacing: 8) {
                        Button("在访达中打开数据目录") {
                            NSWorkspace.shared.activateFileViewerSelecting([appState.dataDirectory])
                        }
                        .controlSize(.small)
                        Button("查看引擎日志") {
                            NSWorkspace.shared.open(appState.dataDirectory.appendingPathComponent("engine-log.txt"))
                        }
                        .controlSize(.small)
                        Spacer()
                        Button("关于 MayStock") { appState.openAbout() }.controlSize(.small)
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.Text.secondary).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
    }
}

// MARK: - Intelligence routing

/// The intelligence runtime's connection file — the relay address and its
/// headers — edited in place. Where the file is, what is valid and which
/// route wins are the runtime's rules (`Intelligence/connection.py`); this
/// page asks the runtime for all three rather than keeping its own copy.
private struct IntelligenceConnectionEditor: View {
    let appState: AppState
    @State private var file: IntelligenceConnectionFile?
    @State private var baseURL = ""
    @State private var headers = ""
    @State private var route: IntelligenceRoute?
    @State private var problem: String?
    @State private var busy = false
    @State private var editingHeaders = false
    @State private var headersDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let route {
                KeyValueRow(label: "当前路由", value: [
                    route.sourceName, route.origin,
                    route.headerNames.isEmpty ? nil : "header " + route.headerNames.joined(separator: "、"),
                ].compactMap { $0 }.joined(separator: " · "))
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(IntelligenceConnectionFile.baseURLKey).font(Theme.Text.secondary).foregroundStyle(.secondary)
                    CommitTextField(placeholder: "https://…（留空表示删除）", value: baseURL, width: nil, mono: true, alignment: .leading) { text in
                        save(baseURL: text, headers: nil)
                    }
                    .frame(maxWidth: 440)
                }
                GridRow {
                    Text(IntelligenceConnectionFile.customHeadersKey).font(Theme.Text.secondary).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 8) {
                        Text(headers.isEmpty ? "未设置" : IntelligenceConnectionFile.maskedHeaders(headers))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(headers.isEmpty ? .tertiary : .primary)
                        Button(headers.isEmpty ? "设置…" : "替换…") {
                            headersDraft = ""
                            editingHeaders = true
                        }
                        .controlSize(.small)
                        if !headers.isEmpty {
                            Button("清除") { save(baseURL: nil, headers: "") }.controlSize(.small)
                        }
                    }
                }
            }
            Text("有连接文件就只用它；没有时依次用启动 App 的环境里的路由、Claude 用户设置的 env、Claude 原生登录。"
                 + "两项都清空会移除这个文件，而不是留一个空文件——空文件本身就是「只用原生登录」。认证值只存在这个文件里（仅本用户可读），不进日志和报告。"
                 + (file.map { "\n路径 \($0.url.path)" } ?? ""))
                .font(Theme.Text.caption).foregroundStyle(.tertiary)
            if busy {
                ProgressView().controlSize(.small)
            }
            if let problem {
                InlineNotice(kind: .danger, title: "连接文件", message: problem)
            }
        }
        .disabled(busy)
        .task { await reload() }
        .sheet(isPresented: $editingHeaders) {
            VStack(alignment: .leading, spacing: 10) {
                Text(IntelligenceConnectionFile.customHeadersKey).font(Theme.Text.bodyMedium)
                Text("每行一个「名称: 值」，与 Claude Code 同名环境变量的格式一致；会整体替换现有的值。保存前由运行环境校验，保存后这里只显示掩码。")
                    .font(Theme.Text.caption).foregroundStyle(.secondary)
                TextEditor(text: $headersDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 540, height: 120)
                HStack {
                    Spacer()
                    Button("取消") { editingHeaders = false }.keyboardShortcut(.cancelAction)
                    Button("保存") {
                        let cleaned = headersDraft
                            .split(separator: "\n", omittingEmptySubsequences: true)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .joined(separator: "\n")
                        editingHeaders = false
                        save(baseURL: nil, headers: cleaned)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(headersDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
        }
    }

    private func reload() async {
        do {
            let bridge = try appState.intelligence.runtimeBridge()
            let located = try await bridge.connectionFile()
            file = located
            let values = try located.route()
            baseURL = values.baseURL ?? ""
            headers = values.headers ?? ""
            route = try await bridge.doctor()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func save(baseURL newBaseURL: String?, headers newHeaders: String?) {
        guard let file else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let bridge = try appState.intelligence.runtimeBridge()
                route = try await file.update(baseURL: newBaseURL, headers: newHeaders, using: bridge)
                let values = try file.route()
                baseURL = values.baseURL ?? ""
                headers = values.headers ?? ""
                problem = nil
            } catch {
                problem = "没有保存，原文件未改动：\(error.localizedDescription)"
            }
        }
    }
}
