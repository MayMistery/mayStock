import SwiftUI
import MayStockKit

/// The watchlist at full size: the same charts as the hover panel with room to
/// breathe, plus everything about how an instrument shows in the menu bar.
///
/// One list for every venue, grouped: a coin and a share sit in the same
/// column, each read the way its own market reads — a trailing day for the
/// coin, a session for the share.
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
            } else if let instId = selection.instId,
                      let index = appState.store.config.watchlist.firstIndex(where: { $0.instId == instId }) {
                // A hidden item has no session and therefore no editor, so the
                // way back on has to live right here.
                EmptyState(icon: "eye.slash", title: "\(instId) 未在菜单栏启用",
                           message: "隐藏的标的不再订阅行情。启用后重新订阅，并回到菜单栏。",
                           actionTitle: "启用并订阅",
                           action: { appState.store.update { $0.watchlist[index].enabled = true } })
            } else {
                EmptyState(icon: "chart.xyaxis.line", title: "选择一个标的",
                           message: "或在左下角添加：OKX 标的如 SOL-USDT、BTC-USDT-SWAP，美股代码如 TSLA、QQQ。")
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
    @State private var newVenue: Venue = .okx
    @State private var validating = false
    @State private var addError: String?

    private var items: [WatchItem] { appState.store.config.watchlist }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection.instId) {
                ForEach(Venue.allCases) { venue in
                    let venueItems = items.filter { $0.venue == venue }
                    if !venueItems.isEmpty {
                        Section(venue.displayName) {
                            ForEach(venueItems) { item in
                                row(item).tag(item.instId)
                            }
                            .onMove { indices, destination in
                                move(venue: venue, indices: indices, destination: destination)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            addRow
        }
    }

    /// Reorder within one venue's group. The menu bar follows the whole
    /// list's order, so the group's items keep the slots they already occupy
    /// and only swap among themselves.
    private func move(venue: Venue, indices: IndexSet, destination: Int) {
        appState.store.update { config in
            let slots = config.watchlist.indices.filter { config.watchlist[$0].venue == venue }
            var group = slots.map { config.watchlist[$0] }
            group.move(fromOffsets: indices, toOffset: destination)
            for (slot, item) in zip(slots, group) { config.watchlist[slot] = item }
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
                    } else if let phase = session?.marketPhase, phase != .regular {
                        MarketPhaseBadge(phase: phase)
                    }
                }
                Text(item.instId).font(Theme.Text.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(session?.formattedPrice ?? "—")
                    .font(Theme.Text.numberSmall).numeric()
                if let ticker {
                    Text(PriceFormatter.signedPercent(ticker.changePct))
                        .font(Theme.Text.captionMedium).numeric()
                        .foregroundStyle(Theme.signed(ticker.changePct))
                        .help(ticker.basis.changeLabel)
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button(item.enabled ? "从菜单栏隐藏" : "在菜单栏启用") { setEnabled(!item.enabled, for: item) }
            Divider()
            Button("从自选移除", role: .destructive) {
                appState.store.update { $0.watchlist.removeAll { $0.id == item.id } }
                if selection.instId == item.instId { selection.instId = items.first?.instId }
            }
        }
    }

    private func setEnabled(_ enabled: Bool, for item: WatchItem) {
        appState.store.update { config in
            guard let index = config.watchlist.firstIndex(where: { $0.id == item.id }) else { return }
            config.watchlist[index].enabled = enabled
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $newVenue) {
                ForEach(Venue.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            HStack(spacing: 6) {
                TextField(newVenue == .okx ? "添加标的，如 ETH-USDT" : "添加美股代码，如 TSLA", text: $newInstId)
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

    /// Validate against the venue's own source before adding, so the list
    /// never holds a symbol nothing can quote. The id is unique across venues:
    /// the hub keys sessions by id, and one name must mean one instrument.
    private func add() async {
        let instId = newInstId.trimmingCharacters(in: .whitespaces).uppercased()
        guard !instId.isEmpty else { return }
        if let existing = items.first(where: { $0.instId == instId }) {
            addError = existing.venue == newVenue ? "已在自选中" : "\(instId) 已作为\(existing.venue.displayName)标的在自选中"
            return
        }
        guard let source = appState.hub.source(for: newVenue) else {
            addError = "\(newVenue.displayName)没有行情源"
            return
        }
        validating = true
        addError = nil
        defer { validating = false }
        do {
            let matches = try await source.search(instId)
            guard let match = matches.first(where: { $0.instId.uppercased() == instId }) else {
                let suggestions = matches.prefix(3).map { "\($0.instId)（\($0.name)）" }
                addError = suggestions.isEmpty
                    ? (newVenue == .okx
                       ? "OKX 上不存在该标的（示例：SOL-USDT / BTC-USDT-SWAP）"
                       : "没有找到美股代码 \(instId)")
                    : "没有 \(instId)；相近的有 " + suggestions.joined(separator: "、")
                return
            }
            let venue = newVenue
            appState.store.update { $0.watchlist.append(WatchItem(venue: venue, instId: match.instId)) }
            newInstId = ""
            selection.instId = match.instId
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
    private var venue: Venue { session.venue }

    /// The page's chart mode is shared across instruments; a venue without a
    /// book shows candles where the depth chart would be empty.
    private var mode: ChartMode { charts.mode.available(on: venue) ? charts.mode : .candles }

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
                    Badge(text: venue.instrumentType(of: instId).displayName, tint: .secondary, size: .small)
                    if let phase = session.marketPhase {
                        MarketPhaseBadge(phase: phase)
                    }
                    connectionBadge
                }
                Text(venue.displayName + " · " + (session.meta.map {
                    "最小价位 \(PriceFormatter.plain($0.tickSize)) · 最小数量 \(PriceFormatter.plain($0.minSize))"
                } ?? venue.marketDataSourceName))
                    .font(Theme.Text.secondary).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.formattedPrice ?? "—")
                    .font(Theme.Text.hero).numeric()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: session.ticker?.last)
                if let ticker = session.ticker {
                    Text("\(ticker.changePct >= 0 ? "▲" : "▼") \(PriceFormatter.signedPercent(ticker.changePct)) · \(ticker.basis.periodLabel) · \(PriceFormatter.signedMoney(ticker.change, decimals: decimals))")
                        .font(Theme.Text.secondaryMedium).numeric()
                        .foregroundStyle(Theme.signed(ticker.changePct))
                        .help(ticker.basis.changeLabel)
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
                    SegmentedFilter(segments: ChartMode.segments(for: venue), selection: Binding(
                        get: { mode }, set: { charts.mode = $0 }))
                    Spacer()
                    switch mode {
                    case .line:
                        SegmentedFilter(segments: LineWindow.segments(for: venue), selection: Binding(
                            get: { charts.lineWindow.resolved(for: venue) },
                            set: { charts.lineWindow = $0 }))
                    case .candles:
                        SegmentedFilter(segments: BarInterval.segments(for: venue), selection: Binding(
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
            switch mode {
            case .line:
                let window = charts.lineWindow.resolved(for: venue)
                LineChartView(points: window.sparkWindow.points(from: session.spark, venue: venue),
                              window: window, decimals: decimals, venue: venue)
            case .candles:
                let display = session.displayCandles
                let isStale = session.isBackfilling && !display.candles.isEmpty
                CandleChartView(candles: display.candles, bar: display.bar, decimals: decimals,
                                timeZone: venue.tradesContinuously ? .current : venue.timeZone)
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
        let period = (ticker?.basis ?? venue.changeBasis).periodLabel
        return HStack(spacing: Theme.itemSpacing) {
            if venue.hasOrderBook {
                StatTile(label: "\(period) 最高", value: ticker.map { PriceFormatter.price($0.high, decimals: decimals) } ?? "—")
                StatTile(label: "\(period) 最低", value: ticker.map { PriceFormatter.price($0.low, decimals: decimals) } ?? "—")
                StatTile(label: "\(period) 成交量", value: ticker.map { PriceFormatter.compact($0.volume) } ?? "—",
                         caption: venue.currencies(of: instId).base)
                StatTile(label: "买一", value: (ticker?.bid ?? book?.bestBid).map { PriceFormatter.price($0, decimals: decimals) } ?? "—", tint: Theme.up)
                StatTile(label: "卖一", value: (ticker?.ask ?? book?.bestAsk).map { PriceFormatter.price($0, decimals: decimals) } ?? "—", tint: Theme.down)
                StatTile(label: "价差", value: book?.spread.map { PriceFormatter.price($0, decimals: decimals) } ?? "—",
                         caption: book?.spreadBps.map { String(format: "%.2f bp", $0) })
            } else {
                StatTile(label: "今开", value: ticker?.open.map { PriceFormatter.price($0, decimals: decimals) } ?? "—")
                StatTile(label: "\(period)最高", value: ticker.map { PriceFormatter.price($0.high, decimals: decimals) } ?? "—")
                StatTile(label: "\(period)最低", value: ticker.map { PriceFormatter.price($0.low, decimals: decimals) } ?? "—")
                StatTile(label: "昨收", value: ticker.map { PriceFormatter.price($0.reference, decimals: decimals) } ?? "—",
                         caption: "涨跌幅的基准")
                StatTile(label: "成交量", value: ticker.map { PriceFormatter.compact($0.volume) } ?? "—",
                         caption: "股 · 常规时段")
                StatTile(label: "时段", value: session.marketPhase?.displayName ?? "—",
                         caption: "纽约 09:30–16:00")
            }
        }
    }

    private var alertsCard: some View {
        let rules = appState.alerts.rules(for: instId)
        let basis = venue.changeBasis
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
                    Text(rule.condition.summary(basis: basis)).font(Theme.Text.mono)
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

    /// The sparkline windows a venue offers, as (label, minutes). A market with
    /// sessions counts a day as the session and a week as five of them.
    private func sparklineOptions(for venue: Venue) -> [(label: String, minutes: Int)] {
        venue.tradesContinuously
            ? [("15 分钟", 15), ("1 小时", 60), ("4 小时", 240), ("24 小时", 1_440)]
            : [("15 分钟", 15), ("1 小时", 60), ("今日", 1_440), ("5 日", 7 * 1_440)]
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
                            ForEach(sparklineOptions(for: item.venue), id: \.minutes) { option in
                                Text(option.label).tag(option.minutes)
                            }
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
                            ForEach(item.venue.supportedBars) { Text($0.rawValue).tag($0) }
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
