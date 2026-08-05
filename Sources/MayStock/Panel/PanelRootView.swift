import SwiftUI
import MayStockKit

/// Content of the hover panel: header, chart, stats, alerts, trade strip.
struct PanelRootView: View {
    let appState: AppState
    let instId: String
    var onHoverChange: (Bool) -> Void = { _ in }
    /// Reports the laid-out height so the window can follow it.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// The panel's fixed width. Its *height* is deliberately not fixed —
    /// `HoverPanelController` sizes the window to whatever this lays out to, so
    /// adding a row here can never silently clip the bottom of the panel.
    static let width: CGFloat = 384

    /// Published upward by whichever chart is on screen, so the readout has a
    /// dedicated row instead of floating over the bars being read.
    @State private var legend: [ChartLegendItem] = []

    private var session: InstrumentSession? { appState.hub.session(for: instId) }
    private var watchItem: WatchItem? {
        appState.store.config.watchlist.first { $0.instId == instId }
    }

    var body: some View {
        @Bindable var charts = appState.charts
        VStack(spacing: 9) {
            if let session {
                header(session)
                VStack(spacing: 5) {
                    ChartLegendRow(items: legend)
                    chartArea(session)
                    controls(session,
                             mode: $charts.mode,
                             lineWindow: $charts.lineWindow,
                             depthZoom: $charts.depthZoom)
                }
                statsRow(session)
                Divider().opacity(0.5)
                alertsRow(session)
                if appState.store.config.trading.enabled {
                    PositionStripView(appState: appState, instId: instId)
                }
                Spacer(minLength: 0)
                footer(session)
            } else {
                ChartPlaceholder(text: "未找到该标的会话")
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        .onHover(perform: onHoverChange)
        .onChange(of: appState.charts.mode, initial: true) { _, mode in
            // The 400-level book snapshot is only worth fetching while it is
            // actually on screen.
            if mode == .depth {
                appState.hub.startDepthPolling(instId: instId)
            } else {
                appState.hub.stopDepthPolling(instId: instId)
            }
        }
    }

    // MARK: Header

    private func header(_ session: InstrumentSession) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(instId).font(.system(size: 13, weight: .semibold))
                    connectionDot(session.connection)
                }
                Text("OKX · \(subtitle(session))")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(session.formattedPrice ?? "—")
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: session.ticker?.last)
                if let ticker = session.ticker {
                    let up = ticker.changePct24h >= 0
                    Text("\(up ? "▲" : "▼") \(PriceFormatter.signedPercent(ticker.changePct24h)) · 24h")
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(ChartStyle.trend(up))
                }
            }
        }
    }

    private func subtitle(_ session: InstrumentSession) -> String {
        switch appState.charts.mode {
        case .line: return "折线 \(appState.charts.lineWindow.title)"
        case .candles: return "K线 \(session.bar.rawValue)"
        case .depth: return "深度 \(appState.charts.depthZoom.title)"
        }
    }

    private func connectionDot(_ state: OKXConnectionState) -> some View {
        Circle()
            .fill(state == .connected ? ChartStyle.up
                  : state == .degraded ? Color.orange : Color.secondary)
            .frame(width: 6, height: 6)
            .help(state == .connected ? "实时连接正常"
                  : state == .degraded ? "连接降级，正在重连" : "连接中…")
    }

    // MARK: Chart

    @ViewBuilder
    private func chartArea(_ session: InstrumentSession) -> some View {
        let decimals = watchItem?.decimals ?? session.priceDecimals
        ZStack {
            switch appState.charts.mode {
            case .line:
                LineChartView(
                    points: session.spark.window(minutes: appState.charts.lineWindow.minutes),
                    window: appState.charts.lineWindow,
                    decimals: decimals)
            case .candles:
                let display = session.displayCandles
                let isStale = session.isBackfilling && !display.candles.isEmpty
                CandleChartView(candles: display.candles, bar: display.bar, decimals: decimals)
                    .opacity(isStale ? 0.45 : 1)
                if isStale {
                    // Keep the outgoing interval on screen while the new one
                    // backfills, rather than flashing an empty chart.
                    ChartLoadingBadge(text: "加载 \(session.bar.rawValue)…")
                }
            case .depth:
                DepthChartView(book: session.deepBook ?? session.liveBook,
                               zoom: appState.charts.depthZoom,
                               decimals: decimals)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .onPreferenceChange(ChartLegendKey.self) { payload in
            legend = payload.items ?? []
        }
    }

    private func controls(
        _ session: InstrumentSession,
        mode: Binding<ChartMode>,
        lineWindow: Binding<LineWindow>,
        depthZoom: Binding<DepthZoom>
    ) -> some View {
        HStack(spacing: 6) {
            SegmentedFilter(segments: ChartMode.segments, selection: mode)
            Spacer(minLength: 2)
            switch mode.wrappedValue {
            case .line:
                SegmentedFilter(segments: LineWindow.segments, selection: lineWindow)
            case .candles:
                SegmentedFilter(segments: BarInterval.segments, selection: Binding(
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
        return HStack(spacing: 0) {
            stat("24h 高", ticker.map { PriceFormatter.price($0.high24h, decimals: decimals) })
            stat("24h 低", ticker.map { PriceFormatter.price($0.low24h, decimals: decimals) })
            stat("24h 量", ticker.map { PriceFormatter.compact($0.vol24h) })
            stat("买一", (ticker?.bid ?? session.liveBook?.bestBid).map { PriceFormatter.price($0, decimals: decimals) })
            stat("卖一", (ticker?.ask ?? session.liveBook?.bestAsk).map { PriceFormatter.price($0, decimals: decimals) })
        }
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value ?? "—")
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Alerts

    private func alertsRow(_ session: InstrumentSession) -> some View {
        let rules = appState.alerts.rules(for: instId)
        return HStack(spacing: 6) {
            Image(systemName: "bell").font(.system(size: 10)).foregroundStyle(.secondary)
            if rules.isEmpty {
                Text("暂无告警").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(rules) { rule in
                            Text(rule.condition.summary)
                                .font(.system(size: 9, weight: .medium)).monospacedDigit()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(
                                    (rule.enabled ? ChartStyle.accent : Color.secondary)
                                        .opacity(0.14),
                                    in: Capsule())
                                .foregroundStyle(rule.enabled ? Color.primary : Color.secondary)
                        }
                    }
                }
            }
            Spacer()
            if let price = session.ticker?.last {
                Menu {
                    Button("上穿 +0.5%（\(PriceFormatter.auto(price * 1.005))）") {
                        quickAlert(.priceAbove((price * 1.005).rounded()))
                    }
                    Button("下穿 −0.5%（\(PriceFormatter.auto(price * 0.995))）") {
                        quickAlert(.priceBelow((price * 0.995).rounded()))
                    }
                    Button("5 分钟波动 ±1%") {
                        quickAlert(.movePctWithin(windowMinutes: 5, pct: 1))
                    }
                    Divider()
                    Button("更多规则…") { appState.openSettings(tab: .alerts) }
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .frame(height: 20)
    }

    private func quickAlert(_ condition: AlertRule.Condition) {
        appState.alerts.add(AlertRule(instId: instId, condition: condition))
    }

    private func footer(_ session: InstrumentSession) -> some View {
        HStack {
            Text("数据源 OKX（公共行情）")
            Spacer()
            if let last = session.lastUpdate {
                Text("更新 \(last.formatted(date: .omitted, time: .standard))")
                    .monospacedDigit()
            }
        }
        .font(.system(size: 8))
        .foregroundStyle(.tertiary)
    }
}
