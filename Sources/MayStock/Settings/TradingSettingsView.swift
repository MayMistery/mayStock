import SwiftUI
import MayStockKit

/// Trading integration via OKX's official CLI (Agent Trade Kit).
/// MayStock never stores API keys — they live with the CLI itself.
struct TradingSettingsView: View {
    let appState: AppState
    @State private var detecting = false

    private var trading: TradingPrefs { appState.store.config.trading }
    private var strategyPrefs: StrategyPortfolioPrefs { appState.store.config.strategy }

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

            Section("策略交易") {
                Toggle("在悬浮面板显示仓位与收益", isOn: Binding(
                    get: { trading.enabled },
                    set: { v in appState.store.update { $0.trading.enabled = v } }))
                LabeledContent("下单方式") {
                    Text("由策略工作台按信号自动下单")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Text("回测起始资金")
                    Spacer()
                    TextField("", text: Binding(
                        get: { PriceFormatter.plain(strategyPrefs.backtestCapital) },
                        set: { v in
                            if let d = Double(v), d > 0 {
                                appState.store.update { $0.strategy.backtestCapital = d }
                            }
                        }))
                        .font(.body.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                    Text(strategyPrefs.quoteCurrency)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button("打开策略工作台…") { appState.openStrategyStudio() }
            }

            Section("安全") {
                Toggle(isOn: Binding(
                    get: { trading.liveTradingUnlocked },
                    set: { v in
                        appState.store.update { config in
                            config.trading.liveTradingUnlocked = v
                            // Locking live must not leave strategies armed
                            // against a real account.
                            if !v {
                                config.strategy.mode = .demo
                                for index in config.strategy.allocations.indices {
                                    config.strategy.allocations[index].running = false
                                }
                            }
                        }
                    })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("解锁实盘交易")
                        Text("关闭时所有订单都走 OKX 模拟盘（--demo）。解锁后仍需在工作台里逐个策略切换到实盘。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if trading.liveTradingUnlocked {
                    Label("实盘已解锁 — 策略下的每一笔订单都会真实成交，请谨慎。",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                Toggle(isOn: Binding(
                    get: { strategyPrefs.allowScriptEngines },
                    set: { v in appState.store.update { $0.strategy.allowScriptEngines = v } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("允许外部脚本策略")
                        Text("声明式清单只做数组运算，永远安全；外部脚本等于在本机执行导入文件带来的任意代码。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("账户凭证") {
                    Text(appState.tradeBridge.hasCredentials()
                         ? "已检测到 ~/.okx/config.toml"
                         : "未配置 —— 运行 `okx config` 添加模拟盘 API Key")
                        .font(.system(size: 11))
                        .foregroundStyle(appState.tradeBridge.hasCredentials() ? ChartStyle.up : .orange)
                }
                Text("API Key 由官方 okx CLI 管理（`okx config`），MayStock 不接触、不存储任何密钥。"
                     + "回测只用公开行情，无需任何凭证。")
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
