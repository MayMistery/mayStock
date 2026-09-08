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

                Card(title: "数据") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Venue.allCases) { venue in
                            KeyValueRow(label: "\(venue.displayName)行情", value: venue.marketDataSourceName)
                        }
                        KeyValueRow(label: "推送频率",
                                    value: "OKX tick ~100ms · 盘口 100ms · 美股轮询 \(Int(YahooMarketFeed.tradingInterval)) 秒"
                                        + "（休市 \(Int(YahooMarketFeed.closedInterval)) 秒）· 菜单栏渲染 10Hz")
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
