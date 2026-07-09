import SwiftUI
import MayStockKit

/// Trading integration via OKX's official CLI (Agent Trade Kit).
/// MayStock never stores API keys — they live with the CLI itself.
struct TradingSettingsView: View {
    let appState: AppState
    @State private var detecting = false

    private var trading: TradingPrefs { appState.store.config.trading }

    var body: some View {
        Form {
            Section("okx CLI") {
                HStack {
                    if let cli = appState.cliInfo {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("已连接 \(cli.version)").font(.system(size: 12))
                                Text(cli.path).font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(ChartStyle.up)
                        }
                    } else {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("未检测到 okx CLI")
                                Text("npm install -g @okx_ai/okx-trade-cli")
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if detecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("重新检测") {
                            detecting = true
                            Task {
                                await appState.detectTradeCLI()
                                detecting = false
                            }
                        }
                    }
                }
                TextField("自定义 CLI 路径（可选）", text: Binding(
                    get: { trading.cliPath ?? "" },
                    set: { v in appState.store.update { $0.trading.cliPath = v.isEmpty ? nil : v } }))
                    .font(.system(size: 11, design: .monospaced))
                TextField("Profile（对应 ~/.okx/config.toml，可选）", text: Binding(
                    get: { trading.profile ?? "" },
                    set: { v in appState.store.update { $0.trading.profile = v.isEmpty ? nil : v } }))
            }

            Section("下单") {
                Toggle("在悬浮面板显示交易操作", isOn: Binding(
                    get: { trading.enabled },
                    set: { v in appState.store.update { $0.trading.enabled = v } }))
                TextField("默认下单金额（USDT）", text: Binding(
                    get: { PriceFormatter.plain(trading.defaultQuoteSize) },
                    set: { v in
                        if let d = Double(v) { appState.store.update { $0.trading.defaultQuoteSize = d } }
                    }))
                    .font(.body.monospacedDigit())
            }

            Section("安全") {
                Toggle(isOn: Binding(
                    get: { trading.liveTradingUnlocked },
                    set: { v in appState.store.update { $0.trading.liveTradingUnlocked = v } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("解锁实盘交易")
                        Text("关闭时所有订单都走 OKX 模拟盘（--demo）。实盘下单前仍需逐单确认。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if trading.liveTradingUnlocked {
                    Label("实盘已解锁 — 每一笔订单都会真实成交，请谨慎。",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text("API Key 由官方 okx CLI 管理（`okx config`），MayStock 不接触、不存储任何密钥。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}

/// General preferences.
struct GeneralSettingsView: View {
    let appState: AppState

    private var general: GeneralPrefs { appState.store.config.general }

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动", isOn: Binding(
                    get: { general.launchAtLogin },
                    set: { v in appState.store.update { $0.general.launchAtLogin = v } }))
            }
            Section("悬浮面板") {
                Picker("悬停出现延迟", selection: Binding(
                    get: { general.hoverDelayMs },
                    set: { v in appState.store.update { $0.general.hoverDelayMs = v } })) {
                    Text("立即").tag(0)
                    Text("150 ms").tag(150)
                    Text("300 ms").tag(300)
                    Text("500 ms").tag(500)
                }
                Picker("移开后隐藏延迟", selection: Binding(
                    get: { general.hideDelayMs },
                    set: { v in appState.store.update { $0.general.hideDelayMs = v } })) {
                    Text("150 ms").tag(150)
                    Text("350 ms").tag(350)
                    Text("700 ms").tag(700)
                }
                Text("提示：点击菜单栏图标可钉住面板；再次点击或点击面板外关闭。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Section("数据") {
                LabeledContent("行情来源", value: "OKX 公共 WebSocket / REST v5")
                LabeledContent("推送频率", value: "tick ~100ms · 盘口 100ms · 菜单栏渲染 10Hz")
                LabeledContent("版本", value: "2.0")
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}
