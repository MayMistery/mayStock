import SwiftUI
import MayStockKit

/// Alert rule management: list + editor sheet.
struct AlertsSettingsView: View {
    let appState: AppState
    @State private var editing: AlertRule?
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            if appState.alerts.rules.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash").font(.title).foregroundStyle(.tertiary)
                    Text("还没有告警规则").font(.callout).foregroundStyle(.secondary)
                    Text("也可以在悬浮面板里一键添加当前价告警")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(appState.alerts.rules) { rule in
                        row(rule)
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Button {
                    creating = true
                } label: {
                    Label("新建规则", systemImage: "plus")
                }
                Spacer()
                Text("触发后发送系统通知，可选执行 shell 命令（联动 okx CLI）")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(10)
        }
        .padding(12)
        .sheet(isPresented: $creating) {
            AlertRuleEditor(appState: appState, rule: nil) { creating = false }
        }
        .sheet(item: $editing) { rule in
            AlertRuleEditor(appState: appState, rule: rule) { editing = nil }
        }
    }

    private func row(_ rule: AlertRule) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { enabled in
                    var updated = rule
                    updated.enabled = enabled
                    if enabled { updated.lastTriggeredAt = nil } // re-arm
                    appState.alerts.update(updated)
                }))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(rule.instId).font(.system(size: 11, weight: .semibold))
                    Text(rule.condition.summary)
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(ChartStyle.accent.opacity(0.12), in: Capsule())
                }
                HStack(spacing: 8) {
                    Text(rule.rearmAfterSeconds == nil
                         ? "一次性"
                         : "重复（冷却 \(Int(rule.rearmAfterSeconds! / 60)) 分钟）")
                    if let fired = rule.lastTriggeredAt {
                        Text("上次触发 \(fired.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if rule.shellHook?.isEmpty == false {
                        Label("hook", systemImage: "terminal").labelStyle(.iconOnly)
                    }
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { editing = rule } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
            Button(role: .destructive) {
                appState.alerts.remove(id: rule.id)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

/// Create/edit one rule.
private struct AlertRuleEditor: View {
    let appState: AppState
    let rule: AlertRule?
    var onDone: () -> Void

    private enum Kind: String, CaseIterable, Identifiable {
        case above = "价格上穿"
        case below = "价格下穿"
        case pct24hUp = "24h 涨幅 ≥"
        case pct24hDown = "24h 跌幅 ≤"
        case window = "N 分钟波动 ≥"
        var id: String { rawValue }
    }

    @State private var instId = "BTC-USDT"
    @State private var kind: Kind = .above
    @State private var threshold = ""
    @State private var windowMinutes = 5
    @State private var note = ""
    @State private var playSound = true
    @State private var repeats = false
    @State private var cooldownMinutes = 15
    @State private var shellHook = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("条件") {
                    Picker("标的", selection: $instId) {
                        ForEach(appState.store.config.watchlist.map(\.instId), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Picker("类型", selection: $kind) {
                        ForEach(Kind.allCases) { k in Text(k.rawValue).tag(k) }
                    }
                    if kind == .window {
                        Picker("时间窗口", selection: $windowMinutes) {
                            Text("1 分钟").tag(1)
                            Text("5 分钟").tag(5)
                            Text("15 分钟").tag(15)
                            Text("60 分钟").tag(60)
                        }
                    }
                    TextField(kind == .above || kind == .below ? "阈值价格" : "百分比（如 1.5）",
                              text: $threshold)
                        .font(.body.monospacedDigit())
                }
                Section("触发") {
                    TextField("备注（通知里显示）", text: $note)
                    Toggle("提示音", isOn: $playSound)
                    Toggle("重复触发", isOn: $repeats)
                    if repeats {
                        Picker("冷却时间", selection: $cooldownMinutes) {
                            Text("1 分钟").tag(1)
                            Text("5 分钟").tag(5)
                            Text("15 分钟").tag(15)
                            Text("60 分钟").tag(60)
                        }
                    }
                    TextField("Shell 命令（可选，可调用 okx CLI）", text: $shellHook)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("取消") { onDone() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(rule == nil ? "创建" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(Double(threshold) == nil)
            }
            .padding(12)
        }
        .frame(width: 440, height: 430)
        .onAppear(perform: loadExisting)
    }

    private func loadExisting() {
        if let first = appState.store.config.watchlist.first?.instId, rule == nil {
            instId = first
        }
        guard let rule else { return }
        instId = rule.instId
        note = rule.note
        playSound = rule.playSound
        shellHook = rule.shellHook ?? ""
        if let rearm = rule.rearmAfterSeconds {
            repeats = true
            cooldownMinutes = max(1, Int(rearm / 60))
        }
        switch rule.condition {
        case .priceAbove(let v): kind = .above; threshold = PriceFormatter.plain(v)
        case .priceBelow(let v): kind = .below; threshold = PriceFormatter.plain(v)
        case .changePct24hAbove(let v): kind = .pct24hUp; threshold = PriceFormatter.plain(v)
        case .changePct24hBelow(let v): kind = .pct24hDown; threshold = PriceFormatter.plain(abs(v))
        case .movePctWithin(let m, let p):
            kind = .window; windowMinutes = m; threshold = PriceFormatter.plain(p)
        }
    }

    private func save() {
        guard let value = Double(threshold) else { return }
        let condition: AlertRule.Condition
        switch kind {
        case .above: condition = .priceAbove(value)
        case .below: condition = .priceBelow(value)
        case .pct24hUp: condition = .changePct24hAbove(value)
        case .pct24hDown: condition = .changePct24hBelow(-abs(value))
        case .window: condition = .movePctWithin(windowMinutes: windowMinutes, pct: value)
        }
        var updated = rule ?? AlertRule(instId: instId, condition: condition)
        updated.instId = instId
        updated.condition = condition
        updated.note = note
        updated.playSound = playSound
        updated.shellHook = shellHook.isEmpty ? nil : shellHook
        updated.rearmAfterSeconds = repeats ? TimeInterval(cooldownMinutes * 60) : nil
        updated.enabled = true
        updated.lastTriggeredAt = nil

        if rule == nil {
            appState.alerts.add(updated)
        } else {
            appState.alerts.update(updated)
        }
        onDone()
    }
}
