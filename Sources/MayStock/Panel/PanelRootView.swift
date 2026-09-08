import SwiftUI
import MayStockKit

/// Content of the hover panel: header, chart, stats, alerts, account strip.
///
/// The panel is the app's front door: it opens on hover, never takes focus,
/// and has to say everything worth knowing about one instrument in a glance.
/// Everything deeper — switching accounts, arming strategies, editing rules —
/// is one click away in the terminal window, never on the panel itself, where
/// an accidental click could put money at risk.
///
/// Every label that names a period reads it off the instrument's venue: a
/// coin has a trailing day, a share has a session, and the panel says which.
struct PanelRootView: View {
    let appState: AppState
    let instId: String
    var onHoverChange: (Bool) -> Void = { _ in }
    /// Reports the laid-out height so the window can follow it.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// The panel's fixed width. Its *height* is deliberately not fixed —
    /// `HoverPanelController` sizes the window to whatever this lays out to, so
    /// adding a row here can never silently clip the bottom of the panel.
    static let width: CGFloat = 400

    /// Published upward by whichever chart is on screen, so the readout has a
    /// dedicated row instead of floating over the bars being read.
    @State private var legend: [ChartLegendItem] = []

    private var session: InstrumentSession? { appState.hub.session(for: instId) }
    private var watchItem: WatchItem? { appState.store.config.watchlist.first { $0.instId == instId } }

    var body: some View {
        @Bindable var charts = appState.charts
        VStack(spacing: 10) {
            if let session {
                header(session)
                VStack(spacing: 6) {
                    ChartLegendRow(items: legend)
                    chartArea(session)
                    controls(session, mode: $charts.mode, lineWindow: $charts.lineWindow, depthZoom: $charts.depthZoom)
                }
                statsRow(session)
                alertsRow(session)
                if appState.store.config.trading.enabled {
                    PanelAccountStrip(appState: appState, instId: instId)
                }
                footer(session)
            } else {
                ChartPlaceholder(text: "未找到该标的会话")
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        .onHover(perform: onHoverChange)
        .onChange(of: appState.charts.mode, initial: true) { _, mode in
            // The 400-level book snapshot is only worth fetching while it is
            // actually on screen; the hub ignores venues without a book.
            if mode == .depth { appState.hub.startDepthPolling(instId: instId) }
            else { appState.hub.stopDepthPolling(instId: instId) }
        }
    }

    // MARK: Header

    private func header(_ session: InstrumentSession) -> some View {
        let venue = session.venue
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(instId).font(.system(size: 14, weight: .semibold))
                    Badge(text: venue.instrumentType(of: instId).displayName, tint: .secondary, size: .small)
                    if let phase = session.marketPhase {
                        MarketPhaseBadge(phase: phase)
                    }
                    connectionDot(session.connection)
                }
                Text("\(venue.displayName) · \(subtitle(session))").font(Theme.Text.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(session.formattedPrice ?? "—")
                    .font(.system(size: 24, weight: .medium, design: .rounded)).numeric()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: session.ticker?.last)
                if let ticker = session.ticker {
                    let up = ticker.changePct >= 0
                    Text("\(up ? "▲" : "▼") \(PriceFormatter.signedPercent(ticker.changePct)) · \(ticker.basis.periodLabel)")
                        .font(Theme.Text.secondaryMedium).numeric()
                        .foregroundStyle(Theme.trend(up))
                        .help(ticker.basis.changeLabel)
                }
            }
        }
    }

    private func subtitle(_ session: InstrumentSession) -> String {
        switch effectiveMode(for: session) {
        case .line: return "折线 \(appState.charts.lineWindow.title)"
        case .candles: return "K线 \(session.bar.rawValue)"
        case .depth: return "深度 \(appState.charts.depthZoom.title)"
        }
    }

    private func connectionDot(_ state: FeedState) -> some View {
        StatusDot(color: state == .connected ? Theme.up : state == .degraded ? Theme.warning : .secondary, size: 6)
            .help(state == .connected ? "行情连接正常" : state == .degraded ? "行情降级，正在重连" : "连接中…")
    }

    // MARK: Chart

    /// The panel's chart mode is shared across instruments; a venue without a
    /// book shows candles where the depth chart would be empty.
    private func effectiveMode(for session: InstrumentSession) -> ChartMode {
        appState.charts.mode.available(on: session.venue) ? appState.charts.mode : .candles
    }

    @ViewBuilder
    private func chartArea(_ session: InstrumentSession) -> some View {
        let decimals = watchItem?.decimals ?? session.priceDecimals
        let venue = session.venue
        ZStack {
            switch effectiveMode(for: session) {
            case .line:
                let window = appState.charts.lineWindow.resolved(for: venue)
                LineChartView(points: window.sparkWindow.points(from: session.spark, venue: venue),
                              window: window, decimals: decimals, venue: venue)
            case .candles:
                let display = session.displayCandles
                let isStale = session.isBackfilling && !display.candles.isEmpty
                CandleChartView(candles: display.candles, bar: display.bar, decimals: decimals,
                                timeZone: venue.tradesContinuously ? .current : venue.timeZone)
                    .opacity(isStale ? 0.45 : 1)
                if isStale {
                    // Keep the outgoing interval on screen while the new one
                    // backfills, rather than flashing an empty chart.
                    ChartLoadingBadge(text: "加载 \(session.bar.rawValue)…")
                }
            case .depth:
                DepthChartView(book: session.deepBook ?? session.liveBook, zoom: appState.charts.depthZoom, decimals: decimals)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .onPreferenceChange(ChartLegendKey.self) { legend = $0.items ?? [] }
    }

    private func controls(
        _ session: InstrumentSession, mode: Binding<ChartMode>,
        lineWindow: Binding<LineWindow>, depthZoom: Binding<DepthZoom>
    ) -> some View {
        let venue = session.venue
        return HStack(spacing: 6) {
            SegmentedFilter(segments: ChartMode.segments(for: venue), selection: Binding(
                get: { effectiveMode(for: session) },
                set: { mode.wrappedValue = $0 }))
            Spacer(minLength: 2)
            switch effectiveMode(for: session) {
            case .line:
                SegmentedFilter(segments: LineWindow.segments(for: venue), selection: Binding(
                    get: { lineWindow.wrappedValue.resolved(for: venue) },
                    set: { lineWindow.wrappedValue = $0 }))
            case .candles:
                SegmentedFilter(segments: BarInterval.segments(for: venue), selection: Binding(
                    get: { session.bar },
                    set: { appState.hub.switchBar(instId: instId, to: $0) }))
            case .depth:
                SegmentedFilter(segments: DepthZoom.segments, selection: depthZoom)
            }
        }
    }

    // MARK: Stats

    private func statsRow(_ session: InstrumentSession) -> some View {
        let ticker = session.ticker
        let decimals = watchItem?.decimals ?? session.priceDecimals
        let period = (ticker?.basis ?? session.venue.changeBasis).periodLabel
        return HStack(spacing: 0) {
            if session.venue.hasOrderBook {
                stat("\(period) 高", ticker.map { PriceFormatter.price($0.high, decimals: decimals) })
                stat("\(period) 低", ticker.map { PriceFormatter.price($0.low, decimals: decimals) })
                stat("\(period) 量", ticker.map { PriceFormatter.compact($0.volume) })
                stat("买一", (ticker?.bid ?? session.liveBook?.bestBid).map { PriceFormatter.price($0, decimals: decimals) }, tint: Theme.up)
                stat("卖一", (ticker?.ask ?? session.liveBook?.bestAsk).map { PriceFormatter.price($0, decimals: decimals) }, tint: Theme.down)
            } else {
                // A stock's day: where it opened, where it has been, what it
                // closed at yesterday, and how much of it changed hands.
                stat("今开", ticker?.open.map { PriceFormatter.price($0, decimals: decimals) })
                stat("\(period)高", ticker.map { PriceFormatter.price($0.high, decimals: decimals) })
                stat("\(period)低", ticker.map { PriceFormatter.price($0.low, decimals: decimals) })
                stat("昨收", ticker.map { PriceFormatter.price($0.reference, decimals: decimals) })
                stat("成交量", ticker.map { PriceFormatter.compact($0.volume) })
            }
        }
        .padding(.vertical, 6)
        .background(Theme.rowFill, in: RoundedRectangle(cornerRadius: Theme.rowRadius))
    }

    private func stat(_ label: String, _ value: String?, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(label).font(Theme.Text.caption).foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(Theme.Text.secondaryMedium).numeric().foregroundStyle(value == nil ? .secondary : tint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Alerts

    private func alertsRow(_ session: InstrumentSession) -> some View {
        let rules = appState.alerts.rules(for: instId)
        let basis = session.venue.changeBasis
        return HStack(spacing: 6) {
            Image(systemName: "bell").font(.system(size: 10)).foregroundStyle(.secondary)
            if rules.isEmpty {
                Text("暂无告警").font(Theme.Text.caption).foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(rules) { rule in
                            Text(rule.condition.summary(basis: basis))
                                .font(.system(size: 10, weight: .medium)).numeric()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background((rule.enabled ? Theme.accent : Color.secondary).opacity(0.14), in: Capsule())
                                .foregroundStyle(rule.enabled ? Color.primary : Color.secondary)
                        }
                    }
                }
            }
            Spacer()
            if let price = session.ticker?.last {
                Menu {
                    Button("上穿 +0.5%（\(PriceFormatter.auto(price * 1.005))）") { quickAlert(.priceAbove((price * 1.005).rounded())) }
                    Button("下穿 −0.5%（\(PriceFormatter.auto(price * 0.995))）") { quickAlert(.priceBelow((price * 0.995).rounded())) }
                    Button("5 分钟波动 ±1%") { quickAlert(.movePctWithin(windowMinutes: 5, pct: 1)) }
                    Divider()
                    Button("更多规则…") { appState.openTerminal(.alerts) }
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .frame(height: 20)
    }

    private func quickAlert(_ condition: AlertRule.Condition) {
        appState.alerts.add(AlertRule(instId: instId, condition: condition))
    }

    private func footer(_ session: InstrumentSession) -> some View {
        HStack(spacing: 6) {
            Text("数据源 \(session.venue.marketDataSourceName)").lineLimit(1)
            if let last = session.lastUpdate {
                Text("· 更新 \(last.formatted(date: .omitted, time: .standard))").numeric()
            }
            Spacer()
            Button {
                appState.openTerminal(.markets, instId: instId)
            } label: {
                HStack(spacing: 3) {
                    Text("打开终端")
                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
        .font(Theme.Text.caption)
        .foregroundStyle(.secondary)
    }
}

/// Where a market with sessions is in its day, as a chip: green while the
/// regular session runs, accent for the extended sessions, grey when closed.
struct MarketPhaseBadge: View {
    let phase: MarketPhase
    var size: Badge.Size = .small

    var body: some View {
        Badge(text: phase.displayName, tint: tint, size: size)
            .help(help)
    }

    private var tint: Color {
        switch phase {
        case .regular: return Theme.up
        case .preMarket, .afterHours: return Theme.accent
        case .closed: return .secondary
        }
    }

    private var help: String {
        switch phase {
        case .regular: return "常规交易时段（纽约 09:30–16:00）"
        case .preMarket: return "盘前交易（纽约 04:00–09:30），成交稀薄"
        case .afterHours: return "盘后交易（纽约 16:00–20:00），成交稀薄"
        case .closed: return "休市，显示的是最近一次成交"
        }
    }
}
