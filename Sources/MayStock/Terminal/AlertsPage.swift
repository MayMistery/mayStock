import SwiftUI
import MayStockKit

/// Every alert rule, grouped by instrument, plus what fired recently.
struct AlertsPage: View {
    let appState: AppState
    @State private var editing: AlertRule?
    @State private var creating = false

    private var groups: [(instId: String, rules: [AlertRule])] {
        let order = appState.store.config.watchlist.map(\.instId)
        let grouped = Dictionary(grouping: appState.alerts.rules, by: \.instId)
        return grouped.keys
            .sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) }
            .map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                PageHeader(title: "告警",
                           subtitle: "触发后发系统通知，可选提示音与 shell 命令（可联动 okx CLI）") {
                    Button { creating = true } label: { Label("新建规则", systemImage: "plus") }
                        .controlSize(.small)
                }

                if appState.alerts.rules.isEmpty {
                    Card {
                        EmptyState(icon: "bell.slash", title: "还没有告警规则",
                                   message: "在「行情」页可以一键添加当前价附近的告警；这里可以写更细的条件。",
                                   actionTitle: "新建规则", action: { creating = true })
                    }
                }

                ForEach(groups, id: \.instId) { group in
                    Card(title: group.instId, subtitle: "\(group.rules.filter(\.enabled).count)/\(group.rules.count) 条启用") {
                        Button("查看行情") { appState.openTerminal(.markets, instId: group.instId) }.controlSize(.small)
                    } content: {
                        VStack(spacing: 4) {
                            ForEach(group.rules) { rule in row(rule) }
                        }
                    }
                }

                recentCard
            }
            .padding(Theme.pagePadding)
        }
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

            Text(rule.condition.summary(basis: appState.changeBasis(for: rule.instId)))
                .font(Theme.Text.mono)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.accent.opacity(0.12), in: Capsule())

            VStack(alignment: .leading, spacing: 1) {
                if !rule.note.isEmpty {
                    Text(rule.note).font(Theme.Text.body)
                }
                HStack(spacing: 8) {
                    Text(rule.rearmAfterSeconds.map { "重复 · 冷却 \(Int($0 / 60)) 分钟" } ?? "一次性")
                    if let fired = rule.lastTriggeredAt {
                        Text("上次触发 " + Format.shortDate(fired))
                    }
                    if rule.shellHook?.isEmpty == false {
                        Label("shell", systemImage: "terminal").labelStyle(.titleAndIcon)
                    }
                    if !rule.playSound { Text("静音") }
                }
                .font(Theme.Text.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { editing = rule } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
            Button(role: .destructive) { appState.alerts.remove(id: rule.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .rowStyle(padding: 8)
    }

    private var recentCard: some View {
        let events = Array(appState.alerts.recentEvents.suffix(20).reversed())
        return Card(title: "最近触发", subtitle: events.isEmpty ? "本次运行以来没有触发" : "本次运行以来的 \(events.count) 次") {
            EmptyView()
        } content: {
            DataGrid(columns: [
                GridColumn(title: "时间"), GridColumn(title: "标的"), GridColumn(title: "条件"),
                GridColumn(title: "触发价", alignment: .trailing), GridColumn(title: "备注"),
            ], rows: events.map(IdentifiedEvent.init), emptyText: "尚无触发记录") { entry in
                GridText(Format.stamp(entry.event.firedAt), tint: .secondary, mono: true, fit: true)
                GridText(entry.event.rule.instId, weight: .medium, fit: true)
                GridText(entry.event.summary, mono: true, fit: true)
                GridText(PriceFormatter.auto(entry.event.price), mono: true, alignment: .trailing)
                GridText(entry.event.rule.note.isEmpty ? "—" : entry.event.rule.note, tint: .secondary)
            }
        }
    }

    private struct IdentifiedEvent: Identifiable {
        let event: AlertEvent
        var id: String { "\(event.rule.id)-\(event.firedAt.timeIntervalSince1970)" }
    }
}

/// Create or edit one rule.
struct AlertRuleEditor: View {
    let appState: AppState
    let rule: AlertRule?
    var onDone: () -> Void

    private enum Kind: String, CaseIterable, Identifiable {
        case above = "价格上穿"
        case below = "价格下穿"
        case pct24hUp = "涨幅 ≥"
        case pct24hDown = "跌幅 ≤"
        case window = "N 分钟波动 ≥"
        var id: String { rawValue }
    }

    @State private var instId = ""
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
                        ForEach(appState.store.config.watchlist.map(\.instId), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("类型", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if kind == .pct24hUp || kind == .pct24hDown {
                        // What a day's change is measured from is the
                        // market's business, and the rule follows the market.
                        Text("涨跌幅\(appState.changeBasis(for: instId).changeLabel)计算")
                            .font(Theme.Text.caption).foregroundStyle(.secondary)
                    }
                    if kind == .window {
                        Picker("时间窗口", selection: $windowMinutes) {
                            Text("1 分钟").tag(1); Text("5 分钟").tag(5)
                            Text("15 分钟").tag(15); Text("60 分钟").tag(60)
                        }
                    }
                    TextField(kind == .above || kind == .below ? "阈值价格" : "百分比（如 1.5）", text: $threshold)
                        .font(.body.monospacedDigit())
                    if let price = appState.hub.session(for: instId)?.ticker?.last {
                        Text("当前价 " + PriceFormatter.auto(price)).font(Theme.Text.caption).foregroundStyle(.secondary)
                    }
                }
                Section("触发") {
                    TextField("备注（通知里显示）", text: $note)
                    Toggle("提示音", isOn: $playSound)
                    Toggle("重复触发", isOn: $repeats)
                    if repeats {
                        Picker("冷却时间", selection: $cooldownMinutes) {
                            Text("1 分钟").tag(1); Text("5 分钟").tag(5)
                            Text("15 分钟").tag(15); Text("60 分钟").tag(60)
                        }
                    }
                    TextField("Shell 命令（可选，可调用 okx CLI）", text: $shellHook)
                        .font(Theme.Text.mono)
                    Text("命令里可用 $MAYSTOCK_INSTID、$MAYSTOCK_PRICE、$MAYSTOCK_RULE。")
                        .font(Theme.Text.caption).foregroundStyle(.tertiary)
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
        .frame(width: 460, height: 480)
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

        if rule == nil { appState.alerts.add(updated) } else { appState.alerts.update(updated) }
        onDone()
    }
}
