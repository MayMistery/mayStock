import SwiftUI
import MayStockKit

/// One screen that answers the four questions a live position keeps raising:
/// how close am I to liquidation, who is crowded, where does the option book
/// pull, and is the macro tape helping.
///
/// These readings were previously gathered by hand, one shell command at a
/// time, in the middle of a trade. Every one of them shaped a decision and none
/// of them lived in the app.
///
/// Two rules the layout enforces, both learned by getting them wrong:
/// **a stale reading is labelled, never shown plainly** — a quote fifteen
/// minutes old looks identical to a live one and reads as fact — and
/// **notional sits beside market value**, because on a far-dated chain they
/// differ by a factor of twenty-five and only one of them is money at risk.
///
/// Read-only. Orders still go through the confirmation dialog.
struct CheckupPage: View {
    let appState: AppState
    @State private var model: CheckupModel?
    @State private var refreshing = false

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                PageHeader(
                    title: "体检",
                    subtitle: "持仓风险、永续结构、期权引力、宏观——只读，不下单"
                ) {
                    HStack(spacing: 8) {
                        ModeBadge(mode: appState.tradingMode)
                        Button {
                            guard let model else { return }
                            refreshing = true
                            Task { await model.refreshAll(); refreshing = false }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .disabled(refreshing || model == nil)
                    }
                }

                if let model {
                    riskCard(model)
                    structureCard(model)
                    gravityCard(model)
                    macroCard(model)
                } else {
                    Card { EmptyState(icon: "stethoscope", title: "正在准备", message: "读取账户与行情…") }
                }
            }
            .padding(Theme.pagePadding)
        }
        .task {
            if model == nil {
                // A deep link may have named an instrument; otherwise follow
                // whatever is held.
                let requested = appState.requestedCheckupInstId
                let created = CheckupModel(
                    venue: appState.venue, mode: appState.tradingMode,
                    instId: requested ?? Self.fallbackInstId,
                    followsHeldPosition: requested == nil)
                appState.pendingCheckupInstId = nil
                model = created
                created.start()
            }
        }
        .onDisappear { model?.stop() }
        .onChange(of: appState.tradingMode) { _, mode in
            model?.mode = mode
            Task { await model?.refreshAll() }
        }
    }

    /// Which instrument to put under review.
    ///
    /// **Not taken from the watchlist.** The watchlist holds what someone wants
    /// to watch — spot pairs and equities — and an account's risk lives in
    /// positions, which are perpetuals. Deriving this from the watchlist showed
    /// "no position" while a perpetual was open and losing money, which is the
    /// worst thing this page can say. It is filled in from whatever the account
    /// actually holds, and only falls back to a default when flat.
    private static let fallbackInstId = "ETH-USDT-SWAP"

    // MARK: - Freshness

    /// Says, in one line, how old a group's data is — or why it is missing.
    /// Never silently renders an old value as current.
    @ViewBuilder
    private func freshness(_ state: CheckupModel.Freshness, tolerance: TimeInterval) -> some View {
        switch state {
        case .never, .loading:
            Text("读取中…").font(Theme.Text.caption).foregroundStyle(.tertiary)
        case .ok(let date):
            let stale = Date().timeIntervalSince(date) > tolerance
            Text(stale ? "⚠️ \(age(date)) 前，已过期" : "\(age(date)) 前")
                .font(Theme.Text.caption)
                .foregroundStyle(stale ? Theme.warning : .secondary)
        case .failed(let message, let date):
            Text("⚠️ \(message)（\(age(date)) 前）")
                .font(Theme.Text.caption).foregroundStyle(Theme.warning)
        }
    }

    /// An empty grid means "nothing to show", which is not the same as "still
    /// loading". After a failed read, saying "读取中…" would describe a fetch
    /// that is not happening.
    private func emptyLabel(_ state: CheckupModel.Freshness, loading: String) -> String {
        if let error = state.errorText { return "⚠️ \(error)" }
        return loading
    }

    private func age(_ date: Date) -> String {
        let seconds = Int(max(0, Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds < 3600 { return "\(seconds / 60) 分钟" }
        return "\(seconds / 3600) 小时"
    }

    private func pnlTint(_ value: Double) -> Color {
        value > 0 ? Theme.up : (value < 0 ? Theme.down : .primary)
    }

    // MARK: - Risk

    @ViewBuilder
    private func riskCard(_ model: CheckupModel) -> some View {
        let risk = model.risk
        // "No position" is a factual claim, so only make it once the account
        // has actually been read. While loading, or after a failed read, saying
        // it would be worse than saying nothing: someone holding a position
        // would be told they are flat.
        let readSucceeded: Bool = if case .ok = model.riskState { true } else { false }
        Card(
            title: "持仓风险",
            subtitle: readSucceeded ? (risk.hasPosition ? risk.instId : "无持仓") : nil
        ) {
            freshness(model.riskState, tolerance: 60)
        } content: {
            if !readSucceeded {
                riskPlaceholder(model.riskState)
            } else if !risk.hasPosition {
                EmptyState(icon: "checkmark.shield", title: "当前没有持仓",
                           message: "开仓后这里显示强平距离、敞口与强平概率。")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        StatTile(
                            label: "方向 / 张数",
                            value: "\(risk.isShort ? "空" : "多") \(PriceFormatter.plain(abs(risk.contracts)))",
                            caption: "\(PriceFormatter.plain(abs(risk.baseQuantity))) 个标的")
                        StatTile(
                            label: "浮动盈亏", value: PriceFormatter.money(risk.unrealisedPnL),
                            tint: pnlTint(risk.unrealisedPnL),
                            caption: "均价 \(PriceFormatter.plain(risk.averagePrice))")
                        StatTile(
                            label: "强平缓冲",
                            value: risk.liquidationBuffer.map { String(format: "%.2f%%", $0) } ?? "—",
                            tint: bufferTint(risk.liquidationBuffer),
                            caption: risk.liquidationPrice.map { "强平 \(PriceFormatter.plain($0))" },
                            help: "标记价要走多远才触发强平")
                        StatTile(
                            label: "实际杠杆",
                            value: risk.exposure.map { String(format: "%.1fx", $0.effectiveLeverage) } ?? "—",
                            caption: risk.leverageSetting.map { "合约设置 \(PriceFormatter.plain($0))x" },
                            help: "名义 ÷ 权益。决定生死的是这个，不是合约上的倍数")
                    }
                    if let exposure = risk.exposure {
                        HStack(spacing: 8) {
                            StatTile(
                                label: "敞口（名义）", value: PriceFormatter.money(exposure.notional),
                                caption: "权益 \(PriceFormatter.money(exposure.equity))")
                            StatTile(
                                label: "标的每动 1%",
                                value: PriceFormatter.money(exposure.lossPerOnePercent),
                                caption: String(format: "权益的 %.1f%%", exposure.onePercentAsEquityPct))
                            StatTile(
                                label: "资金费累计",
                                value: PriceFormatter.money(risk.fundingCollected),
                                tint: pnlTint(risk.fundingCollected),
                                caption: "\(risk.fundingPaymentCount) 次结算")
                            StatTile(
                                label: "标记价", value: PriceFormatter.plain(risk.markPrice),
                                caption: "保证金 \(PriceFormatter.money(exposure.margin))",
                                help: risk.maintenanceMargin.map {
                                    "维持保证金 \(PriceFormatter.money($0))"
                                })
                        }
                    }
                    if let ratio = risk.marginRatio {
                        // The exchange's own health figure — the one it would
                        // act on, as opposed to any ratio this app computes.
                        StatTile(
                            label: "交易所保证金率",
                            value: PriceFormatter.plain(ratio),
                            tint: ratio < 15 ? Theme.warning : .primary,
                            caption: "交易所自己的口径，越低越接近强平",
                            help: "与「强平缓冲」不同：缓冲是价格距离，这是保证金健康度")
                    }

                    if !risk.liquidationOdds.isEmpty {
                        Text("强平概率（由期权隐含波动率反推）")
                            .font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(risk.liquidationOdds, id: \.hours) { odds in
                                StatTile(
                                    label: horizonLabel(odds.hours),
                                    value: String(format: "%.1f%%", odds.touching * 100),
                                    tint: odds.touching > 0.2 ? Theme.down : .primary,
                                    caption: String(format: "到期时 %.1f%%", odds.atHorizon * 100),
                                    help: "「触及」是期间任意时刻碰到强平价的概率——强平不可逆，所以这个比到期概率更要紧")
                            }
                        }
                    }

                    if risk.protectiveOrders.isEmpty {
                        InlineNotice(kind: .warning, message: "没有止盈止损单——仓位在交易所侧没有自动保护。")
                    } else {
                        Text("条件单").font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                        DataGrid(
                            columns: [.init(title: "触发价"), .init(title: "类型"),
                                      .init(title: "数量", alignment: .trailing)],
                            rows: risk.protectiveOrders
                        ) { order in
                            GridText(PriceFormatter.plain(
                                order.takeProfitTriggerPrice ?? order.stopTriggerPrice ?? 0))
                            GridText(order.takeProfitTriggerPrice != nil ? "止盈" : "止损")
                            GridText(PriceFormatter.plain(order.size), alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    /// Shown while the account is being read, or after the read failed —
    /// distinct from "flat", which is a claim only a successful read may make.
    @ViewBuilder
    private func riskPlaceholder(_ state: CheckupModel.Freshness) -> some View {
        switch state {
        case .failed(let message, _):
            InlineNotice(
                kind: .danger, title: "读不到账户",
                message: "\(message)\n\n这里显示不了持仓，不代表没有持仓——下单或调整前请以交易所为准。")
        default:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在读取账户…").font(Theme.Text.secondary).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
    }

    private func bufferTint(_ buffer: Double?) -> Color {
        guard let buffer else { return .primary }
        if buffer < 5 { return Theme.down }
        if buffer < 10 { return Theme.warning }
        return Theme.up
    }

    private func horizonLabel(_ hours: Double) -> String {
        hours < 48 ? "\(Int(hours / 24)) 天" : "\(Int(hours / 24)) 天"
    }

    // MARK: - Structure

    @ViewBuilder
    private func structureCard(_ model: CheckupModel) -> some View {
        let structure = model.structure
        Card(title: "永续结构", subtitle: "谁在付钱、谁在撤退") {
            freshness(model.structureState, tolerance: 180)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatTile(
                        label: "资金费率",
                        value: structure.fundingRate.map { String(format: "%.4f%%", $0 * 100) } ?? "—",
                        tint: structure.isFundingAtCap ? Theme.warning : .primary,
                        caption: structure.fundingRate == nil ? nil
                            : (structure.longsPayShorts ? "多头付给空头" : "空头付给多头"),
                        help: "贴在上限说明一侧拥挤到要付最高成本才能留在场内")
                    StatTile(
                        label: "未平仓量",
                        value: structure.openInterestUsd.map {
                            String(format: "%.0fM", $0 / 1_000_000)
                        } ?? "—",
                        caption: structure.openInterest.map { "\(PriceFormatter.plain($0)) 张" })
                    StatTile(
                        label: "OI 1 小时",
                        value: structure.openInterestChange1h.map { String(format: "%+.2f%%", $0) } ?? "—",
                        tint: (structure.openInterestChange1h ?? 0) < 0 ? Theme.down : Theme.up,
                        caption: "涨=新钱进场，跌=平仓离场")
                    StatTile(
                        label: "OI 4 小时",
                        value: structure.openInterestChange4h.map { String(format: "%+.2f%%", $0) } ?? "—",
                        tint: (structure.openInterestChange4h ?? 0) < 0 ? Theme.down : Theme.up)
                }
                if structure.isFundingAtCap {
                    InlineNotice(
                        kind: .warning,
                        message: "资金费率贴在上限——\(structure.longsPayShorts ? "多头" : "空头")正在付最高成本维持仓位。")
                }

                if let positioning = structure.positioning {
                    Text("多空比（>1 多头占优）")
                        .font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        StatTile(
                            label: "大户·按金额",
                            value: positioning.topByPosition.map { String(format: "%.2f", $0) } ?? "—",
                            caption: "保证金前 20% 账户，按仓位规模加权")
                        StatTile(
                            label: "大户·按人头",
                            value: positioning.topByAccount.map { String(format: "%.2f", $0) } ?? "—",
                            caption: "同一批账户，每户算一次")
                        StatTile(
                            label: "全体账户",
                            value: positioning.allAccounts.map { String(format: "%.2f", $0) } ?? "—")
                        StatTile(
                            label: "主动买卖",
                            value: positioning.takerBuySell.map { String(format: "%.2f", $0) } ?? "—",
                            tint: (positioning.takerBuySell ?? 1) < 1 ? Theme.down : Theme.up,
                            caption: "吃单方向")
                    }
                    if let byPosition = positioning.topByPosition,
                       let byAccount = positioning.topByAccount,
                       abs(byPosition - byAccount) > 0.25 {
                        InlineNotice(
                            kind: .info,
                            message: String(
                                format: "按金额 %.2f 与按人头 %.2f 的差距说明：大仓位集中在%@一侧。",
                                byPosition, byAccount, byPosition > byAccount ? "多头" : "空头"))
                    }
                }
            }
        }
    }

    // MARK: - Gravity

    @ViewBuilder
    private func gravityCard(_ model: CheckupModel) -> some View {
        let gravity = model.gravity
        Card(
            title: "期权引力",
            subtitle: gravity.spot > 0 ? "指数 \(PriceFormatter.plain(gravity.spot))" : nil
        ) {
            freshness(model.gravityState, tolerance: 300)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                DataGrid(
                    columns: [
                        .init(title: "到期"), .init(title: "剩余", alignment: .trailing),
                        .init(title: "ATM IV", alignment: .trailing),
                        .init(title: "max pain", alignment: .trailing),
                        .init(title: "距现价", alignment: .trailing),
                        .init(title: "1σ", alignment: .trailing),
                        .init(title: "名义", alignment: .trailing),
                        .init(title: "真实市值", alignment: .trailing),
                    ],
                    rows: gravity.expiries,
                    emptyText: emptyLabel(model.gravityState, loading: "读取期权链中…")
                ) { row in
                    GridText(Self.expiryFormatter.string(from: row.expiry))
                    GridText(String(format: "%.1fh", row.hoursRemaining), alignment: .trailing)
                    GridText(row.atmIV.map { String(format: "%.1f%%", $0) } ?? "—",
                             alignment: .trailing)
                    GridText(row.maxPain.map { PriceFormatter.plain($0.strike) } ?? "—",
                             tint: (row.maxPain?.isWeak ?? true) ? .secondary : .primary,
                             alignment: .trailing)
                    GridText(
                        row.maxPain.map { String(format: "%+.1f%%", $0.distancePct) } ?? "—",
                        tint: (row.maxPain?.distancePct ?? 0) < 0 ? Theme.down : Theme.up,
                        alignment: .trailing)
                    GridText(row.oneSigma.map { "±\(PriceFormatter.plain($0))" } ?? "—",
                             alignment: .trailing)
                    GridText(String(format: "%.0fM", row.notionalUsd / 1_000_000),
                             alignment: .trailing)
                    GridText(
                        row.marketValueUsd.map { String(format: "%.0fK", $0 / 1_000) } ?? "—",
                        tint: .secondary, alignment: .trailing)
                }

                InlineNotice(
                    kind: .info,
                    message: "名义是合约代表的标的价值，真实市值才是这些期权当下值多少钱——远月链上两者可以差几十倍，把名义当成在场资金会读出完全错误的结论。")

                if let weak = gravity.expiries.first(where: { $0.maxPain?.isWeak == true }) {
                    InlineNotice(
                        kind: .info,
                        message: "\(Self.expiryFormatter.string(from: weak.expiry)) 的赔付曲线很平——max pain 的吸附力弱，不宜据此定位。")
                }
                if let noisy = gravity.expiries.first(where: { ($0.skew?.isNoisy ?? false) }),
                   let skew = noisy.skew {
                    InlineNotice(
                        kind: .warning,
                        message: String(
                            format: "当日到期偏斜 %+.1f（%@）——两翼报价太薄，一晚可摆动十几点，不要用它择时。",
                            skew.points, skew.favoursUpside ? "偏看涨" : "偏看跌"))
                }

                if !gravity.nearStrikes.isEmpty, let nearExpiry = gravity.nearExpiry {
                    Text("\(Self.expiryFormatter.string(from: nearExpiry)) 现价附近的未平仓分布")
                        .font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                    DataGrid(
                        columns: [
                            .init(title: "行权价"), .init(title: "call", alignment: .trailing),
                            .init(title: "put", alignment: .trailing),
                            .init(title: "净（call−put）", alignment: .trailing),
                        ],
                        rows: gravity.nearStrikes
                    ) { row in
                        GridText(
                            PriceFormatter.plain(row.strike),
                            tint: abs(row.strike - gravity.spot) / max(gravity.spot, 1) < 0.004
                                ? Theme.warning : .primary)
                        GridText(PriceFormatter.plain(row.callOI), alignment: .trailing)
                        GridText(PriceFormatter.plain(row.putOI), alignment: .trailing)
                        GridText(
                            String(format: "%+.0f", row.net),
                            tint: row.net > 0 ? Theme.up : Theme.down, alignment: .trailing)
                    }
                }
            }
        }
    }

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    // MARK: - Macro

    @ViewBuilder
    private func macroCard(_ model: CheckupModel) -> some View {
        Card(title: "宏观", subtitle: "只用实时交易的标的——收益率指数延迟 15 分钟，不用") {
            freshness(model.macroState, tolerance: 300)
        } content: {
            DataGrid(
                columns: [
                    .init(title: "标的"), .init(title: "现价", alignment: .trailing),
                    .init(title: "涨跌", alignment: .trailing),
                    .init(title: "数据时间", alignment: .trailing),
                    .init(title: "含义"),
                ],
                rows: model.macro,
                emptyText: emptyLabel(model.macroState, loading: "读取中…")
            ) { quote in
                GridText(quote.label)
                GridText(PriceFormatter.plain(quote.price), alignment: .trailing)
                GridText(
                    quote.changePct.map { String(format: "%+.2f%%", $0) } ?? "—",
                    tint: (quote.changePct ?? 0) >= 0 ? Theme.up : Theme.down,
                    alignment: .trailing)
                GridText(
                    quote.isStale() ? "⚠️ \(age(quote.asOf))前" : "\(age(quote.asOf))前",
                    tint: quote.isStale() ? Theme.warning : .secondary,
                    alignment: .trailing)
                GridText(quote.meaning, tint: .secondary)
            }
        }
    }
}
