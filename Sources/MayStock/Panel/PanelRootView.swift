import SwiftUI
import MayStockKit

enum ChartMode: String, CaseIterable, Identifiable {
    case line = "折线"
    case candles = "K线"
    case depth = "深度"
    var id: String { rawValue }
}

/// Content of the hover panel: header, chart, stats, alerts, trade strip.
struct PanelRootView: View {
    let appState: AppState
    let instId: String
    var onHoverChange: (Bool) -> Void = { _ in }

    @State private var mode: ChartMode = .candles
    @State private var lineWindowMinutes = 60
    @State private var showTradeTicket = false

    private var session: InstrumentSession? { appState.hub.session(for: instId) }
    private var watchItem: WatchItem? {
        appState.store.config.watchlist.first { $0.instId == instId }
    }

    var body: some View {
        VStack(spacing: 10) {
            if let session {
                header(session)
                chartArea(session)
                controls(session)
                statsRow(session)
                Divider().opacity(0.5)
                alertsRow(session)
                if appState.store.config.trading.enabled {
                    tradeStrip(session)
                }
                footer(session)
            } else {
                ChartPlaceholder(text: "未找到该标的会话")
            }
        }
        .padding(14)
        .frame(width: 384, height: 442)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .onHover(perform: onHoverChange)
    }

    // MARK: Header

    private func header(_ session: InstrumentSession) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(instId).font(.system(size: 13, weight: .semibold))
                    connectionDot(session.connection)
                }
                Text("OKX · \(session.bar.rawValue)")
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
        Group {
            switch mode {
            case .line:
                LineChartView(points: session.spark.window(minutes: lineWindowMinutes),
                              decimals: decimals)
            case .candles:
                CandleChartView(candles: session.candles, bar: session.bar, decimals: decimals)
            case .depth:
                DepthChartView(book: session.deepBook ?? session.liveBook, decimals: decimals)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 196)
    }

    private func controls(_ session: InstrumentSession) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: $mode) {
                ForEach(ChartMode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)

            Spacer()

            switch mode {
            case .candles:
                Picker("", selection: Binding(
                    get: { session.bar },
                    set: { appState.hub.switchBar(instId: instId, to: $0) }
                )) {
                    ForEach(BarInterval.allCases) { bar in Text(bar.rawValue).tag(bar) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            case .line:
                Picker("", selection: $lineWindowMinutes) {
                    Text("5m").tag(5)
                    Text("15m").tag(15)
                    Text("1H").tag(60)
                    Text("4H").tag(240)
                    Text("24H").tag(1440)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            case .depth:
                Text("50 档 · 3s 刷新")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
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

    // MARK: Trade

    @ViewBuilder
    private func tradeStrip(_ session: InstrumentSession) -> some View {
        if showTradeTicket {
            TradeTicketView(appState: appState, instId: instId,
                            referencePrice: session.ticker?.last,
                            onClose: { showTradeTicket = false })
        } else {
            HStack(spacing: 8) {
                Button {
                    showTradeTicket = true
                } label: {
                    Text("买入 / 卖出")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)

                if !appState.store.config.trading.liveTradingUnlocked {
                    Text("DEMO")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                        .help("当前为模拟盘。实盘需在设置 → 交易 中解锁。")
                }
            }
        }
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
