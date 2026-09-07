import SwiftUI
import MayStockKit

/// The watchlist at full size: the same charts as the hover panel with room to
/// breathe, plus everything about how an instrument shows in the menu bar.
struct MarketsPage: View {
    let appState: AppState
    @Bindable var selection: TerminalSelection

    var body: some View {
        HStack(spacing: 0) {
            WatchlistColumn(appState: appState, selection: selection)
                .frame(width: 260)
            Divider()
            if let instId = selection.instId, let session = appState.hub.session(for: instId) {
                InstrumentDetail(appState: appState, instId: instId, session: session)
            } else if let instId = selection.instId {
                EmptyState(icon: "eye.slash", title: "\(instId) 未在菜单栏启用",
                           message: "标的关闭后不再订阅行情。打开左侧的开关即可恢复。")
            } else {
                EmptyState(icon: "chart.xyaxis.line", title: "选择一个标的",
                           message: "或在左下角输入 instId 添加，例如 SOL-USDT、BTC-USDT-SWAP。")
            }
        }
        .onAppear {
            if selection.instId == nil { selection.instId = appState.store.config.watchlist.first?.instId }
        }
    }
}

// MARK: - Watchlist column

private struct WatchlistColumn: View {
    let appState: AppState
    @Bindable var selection: TerminalSelection
    @State private var newInstId = ""
    @State private var validating = false
    @State private var addError: String?

    private var items: [WatchItem] { appState.store.config.watchlist }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection.instId) {
                ForEach(items) { item in
                    row(item).tag(item.instId)
                }
                .onMove { indices, destination in
                    appState.store.update { $0.watchlist.move(fromOffsets: indices, toOffset: destination) }
                }
            }
            .listStyle(.inset)
            Divider()
            addRow
        }
    }

    private func row(_ item: WatchItem) -> some View {
        let session = appState.hub.session(for: item.instId)
        let ticker = session?.ticker
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.displayLabel).font(Theme.Text.bodyMedium)
                    if !item.enabled {
                        Badge(text: "已隐藏", tint: .secondary, size: .small)
                    }
                }
                Text(item.instId).font(Theme.Text.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(session?.formattedPrice ?? "—")
                    .font(Theme.Text.numberSmall).numeric()
                if let ticker {
                    Text(PriceFormatter.signedPercent(ticker.changePct24h))
                        .font(Theme.Text.captionMedium).numeric()
                        .foregroundStyle(Theme.signed(ticker.changePct24h))
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("添加标的，如 ETH-USDT", text: $newInstId)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Text.mono)
                    .onSubmit { Task { await add() } }
                if validating {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await add() } } label: { Image(systemName: "plus") }
                        .disabled(newInstId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let addError {
                Text(addError).font(Theme.Text.caption).foregroundStyle(Theme.down)
            }
        }
        .padding(10)
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
        do {
            guard let meta = try await OKXRESTClient().instrumentMeta(instId: instId) else {
                addError = "OKX 上不存在该标的（示例：SOL-USDT / BTC-USDT-SWAP）"
                return
            }
            appState.store.update { $0.watchlist.append(WatchItem(instId: meta.instId)) }
            newInstId = ""
            selection.instId = meta.instId
        } catch {
            addError = "校验失败：\(error)"
        }
    }
}

// MARK: - Instrument detail

private struct InstrumentDetail: View {
    let appState: AppState
    let instId: String
    let session: InstrumentSession

    @State private var legend: [ChartLegendItem] = []

    private var watchItem: WatchItem? { appState.store.config.watchlist.first { $0.instId == instId } }
    private var decimals: Int { watchItem?.decimals ?? session.priceDecimals }
    private var charts: ChartPreferences { appState.terminalCharts }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                header
                chartCard
                statsRow
                HStack(alignment: .top, spacing: Theme.sectionSpacing) {
                    if let index = appState.store.config.watchlist.firstIndex(where: { $0.instId == instId }) {
                        MenuBarEditor(appState: appState, index: index).frame(maxWidth: .infinity)
                    }
                    alertsCard.frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.pagePadding)
        }
        .onChange(of: charts.mode, initial: true) { _, mode in syncDepthPolling(mode: mode) }
        .onChange(of: instId) { old, _ in
            appState.hub.stopDepthPolling(instId: old)
            syncDepthPolling(mode: charts.mode)
        }
        .onDisappear { appState.hub.stopDepthPolling(instId: instId) }
    }

    private func syncDepthPolling(mode: ChartMode) {
        if mode == .depth { appState.hub.startDepthPolling(instId: instId) }
        else { appState.hub.stopDepthPolling(instId: instId) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(instId).font(Theme.Text.title)
                    Badge(text: WatchItem.venue.instrumentType(of: instId).displayName, tint: .secondary, size: .small)
                    connectionBadge
                }
                Text("OKX · " + (session.meta.map { "最小价位 \(PriceFormatter.plain($0.tickSize)) · 最小数量 \(PriceFormatter.plain($0.minSize))" } ?? "公共行情"))
                    .font(Theme.Text.secondary).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.formattedPrice ?? "—")
                    .font(Theme.Text.hero).numeric()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: session.ticker?.last)
                if let ticker = session.ticker {
                    Text("\(ticker.changePct24h >= 0 ? "▲" : "▼") \(PriceFormatter.signedPercent(ticker.changePct24h)) · 24h · \(PriceFormatter.signedMoney(ticker.change24h, decimals: decimals))")
                        .font(Theme.Text.secondaryMedium).numeric()
                        .foregroundStyle(Theme.signed(ticker.changePct24h))
                }
            }
        }
    }

    private var connectionBadge: some View {
        let state = session.connection
        return Badge(text: state == .connected ? "实时" : state == .degraded ? "重连中" : "连接中",
                     tint: state == .connected ? Theme.up : state == .degraded ? Theme.warning : .secondary,
                     size: .small)
    }

    private var chartCard: some View {
        @Bindable var charts = appState.terminalCharts
        return Card {
            VStack(spacing: 8) {
                HStack {
                    SegmentedFilter(segments: ChartMode.segments, selection: $charts.mode)
                    Spacer()
                    switch charts.mode {
                    case .line:
                        SegmentedFilter(segments: LineWindow.segments, selection: $charts.lineWindow)
                    case .candles:
                        SegmentedFilter(segments: BarInterval.segments, selection: Binding(
                            get: { session.bar },
                            set: { appState.hub.switchBar(instId: instId, to: $0) }))
                    case .depth:
                        SegmentedFilter(segments: DepthZoom.segments, selection: $charts.depthZoom)
                    }
                }
                ChartLegendRow(items: legend)
                chart.frame(height: 340)
                    .onPreferenceChange(ChartLegendKey.self) { legend = $0.items ?? [] }
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        ZStack {
            switch charts.mode {
            case .line:
                LineChartView(points: session.spark.window(minutes: charts.lineWindow.minutes),
                              window: charts.lineWindow, decimals: decimals)
            case .candles:
                let display = session.displayCandles
                let isStale = session.isBackfilling && !display.candles.isEmpty
                CandleChartView(candles: display.candles, bar: display.bar, decimals: decimals)
                    .opacity(isStale ? 0.45 : 1)
                if isStale { ChartLoadingBadge(text: "加载 \(session.bar.rawValue)…") }
            case .depth:
                DepthChartView(book: session.deepBook ?? session.liveBook, zoom: charts.depthZoom, decimals: decimals)
            }
        }
    }

    private var statsRow: some View {
        let ticker = session.ticker
        let book = session.liveBook
        return HStack(spacing: Theme.itemSpacing) {
            StatTile(label: "24h 最高", value: ticker.map { PriceFormatter.price($0.high24h, decimals: decimals) } ?? "—")
            StatTile(label: "24h 最低", value: ticker.map { PriceFormatter.price($0.low24h, decimals: decimals) } ?? "—")
            StatTile(label: "24h 成交量", value: ticker.map { PriceFormatter.compact($0.vol24h) } ?? "—",
                     caption: WatchItem.venue.currencies(of: instId).base)
            StatTile(label: "买一", value: (ticker?.bid ?? book?.bestBid).map { PriceFormatter.price($0, decimals: decimals) } ?? "—", tint: Theme.up)
            StatTile(label: "卖一", value: (ticker?.ask ?? book?.bestAsk).map { PriceFormatter.price($0, decimals: decimals) } ?? "—", tint: Theme.down)
            StatTile(label: "价差", value: book?.spread.map { PriceFormatter.price($0, decimals: decimals) } ?? "—",
                     caption: book?.spreadBps.map { String(format: "%.2f bp", $0) })
        }
    }

    private var alertsCard: some View {
        let rules = appState.alerts.rules(for: instId)
        return Card(title: "告警", subtitle: rules.isEmpty ? "本标的暂无规则" : "\(rules.count) 条规则") {
            if let price = session.ticker?.last {
                Menu {
                    Button("上穿 +0.5%（\(PriceFormatter.auto(price * 1.005))）") { quickAlert(.priceAbove((price * 1.005).rounded())) }
                    Button("下穿 −0.5%（\(PriceFormatter.auto(price * 0.995))）") { quickAlert(.priceBelow((price * 0.995).rounded())) }
                    Button("5 分钟波动 ±1%") { quickAlert(.movePctWithin(windowMinutes: 5, pct: 1)) }
                    Divider()
                    Button("更多规则…") { appState.openTerminal(.alerts) }
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .controlSize(.small)
                .fixedSize()
            }
        } content: {
            if rules.isEmpty {
                Text("在这里一键加当前价附近的告警，或到「告警」页写更细的规则。")
                    .font(Theme.Text.secondary).foregroundStyle(.tertiary)
            }
            ForEach(rules) { rule in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { rule.enabled },
                        set: { enabled in
                            var updated = rule
                            updated.enabled = enabled
                            if enabled { updated.lastTriggeredAt = nil }
                            appState.alerts.update(updated)
                        }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    Text(rule.condition.summary).font(Theme.Text.mono)
                    if !rule.note.isEmpty {
                        Text(rule.note).font(Theme.Text.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let fired = rule.lastTriggeredAt {
                        Text("触发 " + Format.relative(fired)).font(Theme.Text.caption).foregroundStyle(.tertiary)
                    }
                    Button { appState.alerts.remove(id: rule.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func quickAlert(_ condition: AlertRule.Condition) {
        appState.alerts.add(AlertRule(instId: instId, condition: condition))
    }
}

// MARK: - Menu bar editor

/// How this instrument shows in the menu bar. Edits write straight to the
/// config; the status item re-renders on the next tick.
private struct MenuBarEditor: View {
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
            Card(title: "菜单栏显示", subtitle: "改动即时生效") {
                Toggle("显示", isOn: bind(\.enabled, default: true))
                    .toggleStyle(.switch).controlSize(.small)
            } content: {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        label("标签")
                        TextField(item.displayLabel, text: Binding(
                            get: { item.label ?? "" },
                            set: { value in
                                appState.store.update { config in
                                    guard index < config.watchlist.count else { return }
                                    config.watchlist[index].label = value.isEmpty ? nil : value
                                }
                            }))
                        .textFieldStyle(.roundedBorder).frame(width: 160)
                    }
                    GridRow {
                        label("样式")
                        Picker("", selection: bind(\.style, default: .full)) {
                            ForEach(WatchItem.MenuBarStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().frame(width: 160)
                    }
                    GridRow {
                        label("趋势图窗口")
                        Picker("", selection: bind(\.sparklineMinutes, default: 60)) {
                            Text("15 分钟").tag(15); Text("1 小时").tag(60)
                            Text("4 小时").tag(240); Text("24 小时").tag(1440)
                        }
                        .labelsHidden().frame(width: 160)
                    }
                    GridRow {
                        label("价格小数位")
                        Picker("", selection: Binding(
                            get: { item.decimals ?? -1 },
                            set: { value in
                                appState.store.update { config in
                                    guard index < config.watchlist.count else { return }
                                    config.watchlist[index].decimals = value < 0 ? nil : value
                                }
                            })) {
                            Text("自动（交易所精度）").tag(-1)
                            ForEach(0..<7, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden().frame(width: 160)
                    }
                    GridRow {
                        label("默认 K 线周期")
                        Picker("", selection: bind(\.defaultBar, default: .m1)) {
                            ForEach(BarInterval.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 160)
                    }
                }
                Divider()
                Button(role: .destructive) {
                    appState.store.update { config in
                        guard index < config.watchlist.count else { return }
                        config.watchlist.remove(at: index)
                    }
                } label: {
                    Label("从自选移除", systemImage: "trash")
                }
                .controlSize(.small)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.Text.secondary).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
    }
}
