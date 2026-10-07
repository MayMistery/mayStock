import SwiftUI
import MayStockKit

/// One screen that answers the questions a live position keeps raising: how
/// close is liquidation, where will the option market let price settle, where
/// does the option book pull, who is crowded, and is the macro tape helping.
///
/// Everything on it streams from the kernel's live layer. Three rules the
/// layout enforces, each learned by getting it wrong:
/// - **Every number shows its age**, in milliseconds, on its own clock: a
///   feed that goes quiet visibly ages even though no new data arrives. A
///   number fifteen minutes old looks identical to a live one otherwise.
/// - **"No position" is only said after positions were actually read.** A
///   failed read says so; telling someone holding a position that they are
///   flat is the worst thing this page could do.
/// - **Notional sits beside market value**, because on a far-dated chain they
///   differ by orders of magnitude and only one of them is money at risk.
///
/// Read-only. Orders still go through the confirmation dialog.
struct CheckupPage: View {
    let appState: AppState
    @State private var model: CheckupModel?
    /// How finely the probability table is cut, kept across launches. Only
    /// ever set from the widths the kernel offers.
    @AppStorage("checkup.gridDivisor") private var gridDivisor = 1

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                PageHeader(
                    title: "体检",
                    subtitle: "持仓风险、价格区间概率、期权引力、永续结构、宏观、预测市场——实时推送，只读，不下单"
                ) {
                    ModeBadge(mode: appState.tradingMode)
                }
                content
            }
            .padding(Theme.pagePadding)
        }
        .background(WindowVisibilityReader { visible in model?.isVisible = visible })
        .task {
            if model == nil {
                // A deep link may have named an instrument; otherwise the
                // kernel follows whatever perpetual the account holds.
                let requested = appState.requestedCheckupInstId
                let bridge = appState.tradeBridge
                let created = CheckupModel(
                    venue: appState.exchangeVenue(for: appState.venue(of: Self.fallbackInstId)),
                    mode: appState.tradingMode,
                    instId: requested ?? Self.fallbackInstId,
                    followsHeldPosition: requested == nil,
                    okxProfile: { bridge.profile(for: $0) },
                    okxConfigPath: OKXProfileCatalog.defaultFileURL().path,
                    schwabctlPath: appState.schwabBridge.resolveCLIPath(),
                    gridDivisor: gridDivisor)
                appState.pendingCheckupInstId = nil
                model = created
                created.start()
            }
        }
        .onDisappear { model?.stop() }
        .onChange(of: appState.tradingMode) { _, mode in
            model?.mode = mode
        }
        .onChange(of: gridDivisor) { _, divisor in
            model?.gridDivisor = divisor
        }
    }

    /// Which instrument to put under review when the account holds none.
    ///
    /// **Not taken from the watchlist.** The watchlist holds what someone wants
    /// to watch — spot pairs and equities — and an account's risk lives in
    /// positions, which are perpetuals. The kernel replaces this with whatever
    /// the account actually holds.
    private static let fallbackInstId = "ETH-USDT-SWAP"

    @ViewBuilder
    private var content: some View {
        if let model {
            if let failure = model.failure {
                Card {
                    InlineNotice(kind: .danger, title: "实时层没有运行", message: failure)
                }
            } else if model.instrument != nil {
                // Each card reads only its own section of the snapshot, so a
                // tick in one redraws that card and nothing else.
                FeedsCard(model: model)
                RiskCard(model: model, appState: appState)
                ProbabilityCard(model: model, gridDivisor: $gridDivisor)
                GravityCard(model: model)
                StructureCard(model: model)
                MacroCard(model: model)
                PredictionCard(model: model)
            } else {
                Card { EmptyState(icon: "antenna.radiowaves.left.and.right", title: "正在连接", message: "打开行情、账户与期权推送…") }
            }
        } else {
            Card { EmptyState(icon: "stethoscope", title: "正在准备", message: "启动实时层…") }
        }
    }
}

// MARK: - Formatting

/// The page's shared wording and number formats.
enum CheckupText {
    static func percent(_ probability: Double) -> String {
        if probability < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%", probability * 100)
    }

    static func signedPercent(_ value: Double?) -> String {
        value.map { String(format: "%+.2f%%", $0) } ?? "—"
    }

    /// A price as a trader reads it: two decimals, whatever the venue sent.
    static func price(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func pnlTint(_ value: Double) -> Color {
        value > 0 ? Theme.up : (value < 0 ? Theme.down : .primary)
    }

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    static func expiry(_ ms: Int64) -> String {
        expiryFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func hours(_ hours: Double) -> String {
        hours < 48 ? String(format: "%.1fh", hours) : String(format: "%.0f 天", hours / 24)
    }

    static func state(_ state: String) -> String {
        switch state {
        case "live": return "在线"
        case "connecting": return "连接中"
        case "degraded": return "重连中"
        case "refused": return "被拒"
        default: return "关闭"
        }
    }

    static func stateTint(_ state: String) -> Color {
        switch state {
        case "live": return Theme.up
        case "degraded", "refused": return Theme.warning
        default: return .secondary
        }
    }

    static func source(_ source: String) -> String {
        switch source {
        case "okx.private": return "账户推送"
        case "cli": return "CLI 读取（推送不可用）"
        default: return "未读到"
        }
    }

    /// The machine-wide outage, in one sentence and what to do about it.
    static func network(_ network: LiveSnapshot.Network) -> String {
        var text = "\(network.unreachable.joined(separator: "、")) 同时连不上。几家交易所不会一起出事，断的是这台机器到它们的网络（公司 VPN 的线路）。"
        if !network.reachable.isEmpty {
            text += "\(network.reachable.joined(separator: "、")) 还能连上，说明网没全断，是去这几家的线路断了。"
        }
        text += "各个源会自己重连，下面的数都是最后读到的、带着年龄。要下单或调仓，请以交易所 App 为准。"
        return text
    }

    /// A leg's heading: side, size, and whether its liquidation is its own.
    static func legTitle(_ position: LiveSnapshot.Position) -> String {
        let side = position.isShort ? "空头腿" : "多头腿"
        let mode = position.marginMode == "isolated" ? "逐仓" : (position.marginMode == "cross" ? "全仓" : nil)
        return ([side, "\(PriceFormatter.plain(abs(position.contracts))) 张", mode].compactMap { $0 }).joined(separator: " · ")
    }

    /// Net notional with its direction, e.g. `净空 $3,955`.
    static func netNotional(_ exposure: LiveSnapshot.Exposure, hedged: Bool) -> String {
        let amount = PriceFormatter.money(abs(exposure.netNotional))
        guard hedged else { return amount }
        if exposure.netNotional == 0 { return "完全对冲 $0" }
        return (exposure.netNotional > 0 ? "净多 " : "净空 ") + amount
    }

    /// What a liquidation on one isolated leg leaves behind: the other leg,
    /// unhedged. Nil unless at least one leg is isolated with a known price.
    static func nakedLegs(_ positions: [LiveSnapshot.Position]) -> String? {
        let lines = positions.compactMap { leg -> String? in
            guard leg.isIsolated, let liquidation = leg.liquidationPrice else { return nil }
            let others = positions.filter { $0.isShort != leg.isShort }
            guard !others.isEmpty else { return nil }
            let left = others.map { "\($0.isShort ? "空" : "多") \(PriceFormatter.plain(abs($0.contracts))) 张" }.joined(separator: "、")
            return "\(leg.isShort ? "空头腿" : "多头腿")在 \(price(liquidation)) 被强平后，剩下的\(left)就没有对冲了"
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "；") + "。上面的净敞口只在两条腿都还在时成立。"
    }

    /// `买入平空`, `卖出开空` …: what a standalone order does when it fires.
    static func orderDirection(side: String?, posSide: String?) -> String {
        let verb = side == "buy" ? "买入" : (side == "sell" ? "卖出" : "—")
        switch (side, posSide) {
        case ("buy", "long"): return "买入开多"
        case ("sell", "long"): return "卖出平多"
        case ("sell", "short"): return "卖出开空"
        case ("buy", "short"): return "买入平空"
        default: return verb
        }
    }

    static func orderSize(_ order: LiveSnapshot.Protective) -> String {
        order.size.map { PriceFormatter.plain($0) }
            ?? order.fraction.map { String(format: "全仓 × %.0f%%", $0 * 100) } ?? "—"
    }

    static func bufferTint(_ buffer: Double?) -> Color {
        guard let buffer else { return .primary }
        if buffer < 5 { return Theme.down }
        if buffer < 10 { return Theme.warning }
        return Theme.up
    }

    /// Which expiries a horizon's odds were read from.
    static func horizonSource(_ odds: LiveSnapshot.Odds) -> String {
        switch odds.placement {
        case "between":
            return "按 \(expiry(odds.expiryMs)) 与 \(odds.farExpiryMs.map(expiry) ?? "—") 两个到期的曲线，在总方差上按期限插值。"
        case "before-first":
            return "期限短于最近的到期，沿用 \(expiry(odds.expiryMs)) 的曲线。"
        default:
            return "期限长于最远的到期，沿用 \(expiry(odds.expiryMs)) 的曲线（外推）。"
        }
    }
}

// MARK: - Feeds

/// Every source as a dot, its name and how old its last frame is; the ones in
/// trouble are spelled out underneath. A table of fourteen rows cost a screen
/// of scrolling to say "all live".
private struct FeedsCard: View {
    let model: CheckupModel

    var body: some View {
        let offset = model.clock?.offsetMs ?? 0
        Card(title: "数据源", subtitle: clockLine) {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(model.feeds) { feed in
                        HStack(spacing: 6) {
                            Circle().fill(CheckupText.stateTint(feed.state)).frame(width: 7, height: 7)
                            Text(feed.label).font(Theme.Text.caption).lineLimit(1)
                            if let last = feed.lastFrameMs {
                                AgeLabel(ms: last, offsetMs: offset, staleAfterMs: feed.staleAfterMs)
                            } else if !feed.isLive {
                                Text(CheckupText.state(feed.state)).font(Theme.Text.caption).foregroundStyle(.secondary)
                            }
                        }
                        .help(feed.detail ?? CheckupText.state(feed.state))
                    }
                }
                if let network = model.outage {
                    InlineNotice(kind: .danger, title: "本机网络断了，不是交易所或 App", message: CheckupText.network(network))
                    if let ms = network.lastHeardMs {
                        HStack(spacing: 6) {
                            Text("最后一次收到它们的数据").font(Theme.Text.caption).foregroundStyle(.secondary)
                            AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: 0)
                        }
                    }
                }
                // Under a machine-wide outage the unreachable operators' own
                // lines say the same thing a dozen times; their details stay
                // in each dot's tooltip and the event log.
                ForEach(model.feeds.filter { feed in
                    (feed.state == "degraded" || feed.state == "refused")
                        && !(model.outage?.unreachable.contains(feed.operator ?? "") ?? false)
                }) { feed in
                    InlineNotice(kind: .warning, message: "\(feed.label)\(CheckupText.state(feed.state))：\(feed.detail ?? "")")
                }
            }
        }
    }

    private var clockLine: String {
        guard let clock = model.clock else { return "本机时钟尚未与交易所校准" }
        return String(format: "本机时钟偏差 %+.0f ms（误差 ±%.0f ms），所有「多久前」都已按此校正",
                      clock.offsetMs, clock.roundTripMs / 2)
    }
}

// MARK: - Risk

private struct RiskCard: View {
    let model: CheckupModel
    let appState: AppState

    var body: some View {
        if let risk = model.risk {
            let offset = model.clock?.offsetMs ?? 0
            Card(
                title: "持仓风险",
                subtitle: risk.positions.isEmpty
                    ? (risk.wasRead ? "无持仓" : nil)
                    : risk.instId + (risk.isHedged ? " · 多空双向" : "")
            ) {
                HStack(spacing: 6) {
                    Text(CheckupText.source(risk.source)).font(Theme.Text.caption).foregroundStyle(.secondary)
                    if let ms = risk.positionsMs { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: 10_000) }
                    // One ticket per leg: closing a long/short account's short
                    // must not open on its long.
                    ForEach(risk.positions) { position in
                        CloseHoldingButton(
                            appState: appState,
                            request: appState.closeTicket(instId: position.instId, isLong: !position.isShort, on: .okx),
                            title: risk.positions.count > 1
                                ? "\(position.isShort ? "平空" : "平多") / 止盈止损" : "平仓 / 止盈止损")
                    }
                }
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    if let fallbackError = model.fallbackError {
                        InlineNotice(kind: .warning, message: "账户推送不可用，CLI 读取也失败了：\(fallbackError)")
                    }
                    if !risk.positions.isEmpty {
                        instrumentTiles(risk, offset: offset)
                        if risk.isHedged, let notice = CheckupText.nakedLegs(risk.positions) {
                            InlineNotice(kind: .warning, title: "两条腿各自逐仓", message: notice)
                        }
                        ForEach(risk.positions) { position in
                            leg(position, risk: risk, offset: offset)
                        }
                        unattached(risk, offset: offset)
                    } else if risk.wasRead {
                        EmptyState(icon: "checkmark.shield", title: "当前没有持仓",
                                   message: "开仓后这里显示强平距离、敞口与强平概率。")
                    } else {
                        // Distinct from flat: nothing was read, so nothing may be claimed.
                        InlineNotice(
                            kind: .danger, title: "读不到账户",
                            message: "\(risk.note ?? "账户推送还没有数据")\n\n这里显示不了持仓，不代表没有持仓——下单或调整前请以交易所为准。")
                    }
                }
            }
        }
    }

    /// What the instrument as a whole risks: every leg netted for price,
    /// summed for margin.
    @ViewBuilder
    private func instrumentTiles(_ risk: LiveSnapshot.Risk, offset: Double) -> some View {
        let single = risk.positions.count == 1 ? risk.positions.first : nil
        HStack(spacing: 8) {
            StatTile(
                label: "实际杠杆",
                value: risk.exposure.map { String(format: "%.1fx", $0.effectiveLeverage) } ?? "—",
                caption: risk.isHedged
                    ? risk.exposure.map { String(format: "按净额；总名义 %.1fx", $0.grossLeverage) }
                    : single?.leverageSetting.map { "合约设置 \(PriceFormatter.plain($0))x" },
                help: "名义 ÷ 权益。决定生死的是这个，不是合约上的倍数。多空同时持有时，价格风险看净额，保证金和一条腿被强平后的裸仓看总额")
            if let exposure = risk.exposure {
                StatTile(
                    label: risk.isHedged ? "净敞口（名义）" : "敞口（名义）",
                    value: CheckupText.netNotional(exposure, hedged: risk.isHedged),
                    caption: risk.isHedged
                        ? "多 \(PriceFormatter.money(exposure.longNotional)) · 空 \(PriceFormatter.money(exposure.shortNotional))"
                        : "权益 \(PriceFormatter.money(exposure.equity))")
                StatTile(
                    label: "标的每涨 1%", value: PriceFormatter.money(exposure.pnlPerOnePercentRise),
                    tint: CheckupText.pnlTint(exposure.pnlPerOnePercentRise),
                    caption: String(format: "权益的 %.1f%%", exposure.onePercentAsEquityPct))
            }
            StatTile(
                label: "标记价", value: risk.mark.map { CheckupText.price($0.price) } ?? "—",
                caption: risk.mark?.source == "okx.mark-price" ? "实时标记价推送" : "来自最近一次持仓推送")
        }
        if let ms = risk.mark?.ms {
            HStack(spacing: 6) {
                Text("标记价").font(Theme.Text.caption).foregroundStyle(.secondary)
                AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: 8_000)
                Text("· OKX 标记价的时间戳本身约晚 4 秒（2026-09-23 实测），不是本机延迟")
                    .font(Theme.Text.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// One leg: its own liquidation, odds and protection.
    @ViewBuilder
    private func leg(_ position: LiveSnapshot.Position, risk: LiveSnapshot.Risk, offset: Double) -> some View {
        if risk.positions.count > 1 {
            Divider()
            Text(CheckupText.legTitle(position))
                .font(Theme.Text.captionMedium)
                .foregroundStyle(position.isShort ? Theme.down : Theme.up)
        }
        HStack(spacing: 8) {
            StatTile(
                label: "方向 / 张数",
                value: "\(position.isShort ? "空" : "多") \(PriceFormatter.plain(abs(position.contracts)))",
                caption: String(format: "%.3f 个标的", abs(position.baseQuantity)))
            StatTile(
                label: "浮动盈亏", value: position.unrealisedPnl.map { PriceFormatter.money($0) } ?? "—",
                tint: CheckupText.pnlTint(position.unrealisedPnl ?? 0),
                caption: position.averagePrice.map { "均价 \(CheckupText.price($0))" })
            StatTile(
                label: "强平缓冲",
                value: position.liquidationBufferPct.map { String(format: "%.2f%%", $0) } ?? "—",
                tint: CheckupText.bufferTint(position.liquidationBufferPct),
                caption: position.liquidationPrice.map { "强平 \(CheckupText.price($0))" },
                help: "标记价要走多远才触发强平，按实时标记价算")
            StatTile(
                label: "资金费累计", value: position.fundingFee.map { PriceFormatter.money($0) } ?? "—",
                tint: CheckupText.pnlTint(position.fundingFee ?? 0), caption: "这个仓位至今")
        }
        if let ratio = position.marginRatio {
            // The exchange's own health figure — the one it would act on.
            StatTile(
                label: "交易所保证金率", value: String(format: "%.2f", ratio),
                tint: ratio < 15 ? Theme.warning : .primary,
                caption: "交易所自己的口径，越低越接近强平"
                    + (position.maintenanceMargin.map { " · 维持保证金 \(PriceFormatter.money($0))" } ?? ""),
                help: "与「强平缓冲」不同：缓冲是价格距离，这是保证金健康度")
        }
        if !position.liquidationOdds.isEmpty {
            Text("强平概率（在这条腿的强平价处读期权曲线；触及按 put–call 对称静态复制）")
                .font(Theme.Text.captionMedium).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(position.liquidationOdds) { odds in
                    StatTile(
                        label: "\(Int(odds.hours / 24)) 天内触及",
                        value: String(format: "%.1f%%", odds.touching * 100),
                        tint: odds.touching > 0.2 ? Theme.down : .primary,
                        caption: String(format: "到期时 %.1f%% · 强平价处 IV %.0f%%", odds.atHorizon * 100, odds.iv),
                        help: "「触及」是期间任意时刻碰到强平价的概率——强平不可逆，所以这个比到期概率更要紧。\(CheckupText.horizonSource(odds))")
                }
            }
            if !position.isShort {
                Text("这是风险中性模型。ETH 过去 3 年（小时线，按波动率缩放，2026-09-24 实测），下跌 3.7–5% 的「触及」次数是「收在那之下」的 2.4–2.7 倍——插针会弹回，模型只按约 2 倍算，多头的实际触及风险可能更高。")
                    .font(Theme.Text.caption).foregroundStyle(.tertiary)
            }
        }
        protective(position, risk: risk, offset: offset)
    }

    @ViewBuilder
    private func protective(_ position: LiveSnapshot.Position, risk: LiveSnapshot.Risk, offset: Double) -> some View {
        if risk.stopsMs == nil {
            // Not read yet (or never readable) is not "none".
            InlineNotice(kind: .info, message: risk.stopsError.map { "条件单读取失败：\($0)" } ?? "正在读取条件单…")
        } else if position.protective.isEmpty {
            InlineNotice(kind: .warning, message: "\(risk.positions.count > 1 ? (position.isShort ? "空头腿" : "多头腿") : "仓位")没有止盈止损单——在交易所侧没有自动保护。")
        } else {
            HStack(spacing: 6) {
                Text("止盈止损").font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                if let ms = risk.stopsMs { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: risk.stopsStaleAfterMs) }
            }
            DataGrid(
                columns: [.init(title: "类型"), .init(title: "止损触发", alignment: .trailing),
                          .init(title: "止盈触发", alignment: .trailing), .init(title: "数量", alignment: .trailing)],
                rows: position.protective
            ) { order in
                GridText(order.kind)
                GridText(order.stopPrice.map { CheckupText.price($0) } ?? "—", alignment: .trailing)
                GridText(order.takeProfitPrice.map { CheckupText.price($0) } ?? "—", alignment: .trailing)
                GridText(CheckupText.orderSize(order), alignment: .trailing)
            }
            if let error = risk.stopsError {
                InlineNotice(kind: .warning, message: "最近一次条件单读取失败，下面是上一次成功读到的：\(error)")
            }
        }
    }

    /// Orders on this instrument that close no leg. Shown apart, so a
    /// trigger that would open or add is never read as protection.
    @ViewBuilder
    private func unattached(_ risk: LiveSnapshot.Risk, offset: Double) -> some View {
        if !risk.unattachedOrders.isEmpty {
            Divider()
            HStack(spacing: 6) {
                Text("不平任何持仓的条件单（\(risk.unattachedOrders.count) 张）")
                    .font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                if let ms = risk.stopsMs { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: risk.stopsStaleAfterMs) }
            }
            DataGrid(
                columns: [.init(title: "类型"), .init(title: "方向"), .init(title: "止损触发", alignment: .trailing),
                          .init(title: "止盈触发", alignment: .trailing), .init(title: "数量", alignment: .trailing)],
                rows: risk.unattachedOrders
            ) { order in
                GridText(order.kind)
                GridText(CheckupText.orderDirection(side: order.side, posSide: order.posSide))
                GridText(order.stopPrice.map { CheckupText.price($0) } ?? "—", alignment: .trailing)
                GridText(order.takeProfitPrice.map { CheckupText.price($0) } ?? "—", alignment: .trailing)
                GridText(CheckupText.orderSize(order), alignment: .trailing)
            }
            Text("这些单子触发后是开仓或加仓，不会减少上面任何一条腿——它们不算保护。")
                .font(Theme.Text.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Probability

private struct ProbabilityCard: View {
    let model: CheckupModel
    @Binding var gridDivisor: Int

    /// One row of the table: a price range.
    private struct RangeRow: Identifiable {
        let id: Int
        let label: String
        let isSpot: Bool
    }

    var body: some View {
        if let probability = model.probability {
            let offset = model.clock?.offsetMs ?? 0
            Card(
                title: "价格区间概率",
                subtitle: "期权市场给出的结算价分布（\(probability.smileVenue) 波动率曲面 + OKX 指数实时平移）"
            ) {
                HStack(spacing: 6) {
                    Text("曲面").font(Theme.Text.caption).foregroundStyle(.secondary)
                    if let ms = probability.surfaceMs { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: 5_000) }
                    Text("指数").font(Theme.Text.caption).foregroundStyle(.secondary)
                    if let ms = probability.indexMs { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: 3_000) }
                }
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    if !probability.gridChoices.isEmpty { widthPicker(probability) }
                    if probability.columns.isEmpty {
                        Text(model.feeds.first { $0.id == "deribit" }?.isLive == true ? "等待期权曲面与指数…" : "Deribit 曲面推送不在线，算不出概率")
                            .font(Theme.Text.secondary).foregroundStyle(.secondary)
                    } else {
                        table(probability)
                    }
                }
            }
        }
    }

    /// The widths the kernel offers. The selection shown is the one the
    /// kernel applied, so a stored width it no longer offers reads as what
    /// is actually on screen.
    private func widthPicker(_ probability: LiveSnapshot.Probability) -> some View {
        HStack(spacing: 8) {
            Text("每档宽度").font(Theme.Text.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { probability.gridDivisor }, set: { gridDivisor = $0 })) {
                ForEach(probability.gridChoices) { Text(PriceFormatter.plain($0.step)).tag($0.divisor) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
        }
    }

    private func ranges(_ probability: LiveSnapshot.Probability) -> [RangeRow] {
        let edges = probability.edges
        guard let first = edges.first, let last = edges.last else { return [] }
        var rows = [RangeRow(id: 0, label: "< \(PriceFormatter.plain(first))", isSpot: probability.spotBucket == 0)]
        for index in 1..<edges.count {
            rows.append(RangeRow(
                id: index,
                label: "\(PriceFormatter.plain(edges[index - 1]))–\(PriceFormatter.plain(edges[index]))",
                isSpot: probability.spotBucket == index))
        }
        rows.append(RangeRow(id: edges.count, label: "≥ \(PriceFormatter.plain(last))", isSpot: probability.spotBucket == edges.count))
        // Highest prices on top, the way a price axis reads.
        return rows.reversed()
    }

    @ViewBuilder
    private func table(_ probability: LiveSnapshot.Probability) -> some View {
        let columns = probability.columns
        DataGrid(
            columns: [.init(title: "结算价区间")] + columns.map {
                .init(title: "\(CheckupText.expiry($0.expiryMs))  \(CheckupText.hours($0.hours))", alignment: .trailing)
            },
            rows: ranges(probability)
        ) { row in
            GridText(row.isSpot ? "\(row.label)  ← 现价" : row.label,
                     tint: row.isSpot ? Theme.warning : .primary,
                     weight: row.isSpot ? .semibold : .regular)
            ForEach(columns) { column in
                let value = row.id < column.probabilities.count ? column.probabilities[row.id] : 0
                let pain = column.maxPainBucket == row.id
                GridText(
                    (pain ? "◆ " : "") + CheckupText.percent(value),
                    tint: column.clamped.contains(row.id) ? Theme.warning : (value >= 0.2 ? .primary : .secondary),
                    alignment: .trailing,
                    weight: value >= 0.2 ? .semibold : .regular)
            }
        }
        Text(columns.map { column in
            String(format: "%@：远期 %.1f · ATM IV %.1f%% · %@ 拟合 %d 个报价，误差 %.2f 个波动率点",
                   CheckupText.expiry(column.expiryMs), column.forward, column.atmIv ?? 0,
                   column.curve, column.quotes, column.fitError)
        }.joined(separator: "\n"))
            .font(Theme.Text.caption).foregroundStyle(.tertiary)
        InlineNotice(
            kind: .info,
            message: "风险中性概率：含风险溢价，通常高估下跌尾部。◆ 是该到期四家合并的 max pain 所在区间。列是持仓占全市场 2% 以上的到期日。")
        if columns.contains(where: { $0.curve == "SSVI" }) {
            InlineNotice(kind: .info, message: "标 SSVI 的到期：五参数 SVI 拟合出的分布不合法（尾部为负或越过 1），改用定理保证无套利的 SSVI。")
        }
        if columns.contains(where: { !$0.clamped.isEmpty }) {
            InlineNotice(kind: .warning, message: "黄色格子的原始概率为负（曲线在那里不满足无套利），按 0 显示。")
        }
        if probability.forwardAnchor == "approximate" {
            InlineNotice(kind: .warning, message: "有到期的远期没能按报价时刻的指数平移（指数历史还不够），有几个基点的近似。")
        }
    }
}

// MARK: - Gravity

private struct GravityCard: View {
    let model: CheckupModel

    var body: some View {
        if let gravity = model.gravity {
            let offset = model.clock?.offsetMs ?? 0
            Card(title: "期权引力（四家合并）", subtitle: venueLine(gravity)) {
                if let ms = gravity.bookMs { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: gravity.bookStaleAfterMs) }
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    expiries(gravity)
                    notices(gravity)
                    nearStrikes(gravity)
                }
            }
        }
    }

    @ViewBuilder
    private func expiries(_ gravity: LiveSnapshot.Gravity) -> some View {
        DataGrid(
            columns: [
                .init(title: "到期"), .init(title: "剩余", alignment: .trailing),
                .init(title: "ATM IV", alignment: .trailing),
                .init(title: "max pain", alignment: .trailing),
                .init(title: "距现价", alignment: .trailing),
                .init(title: "到位概率", alignment: .trailing),
                .init(title: "1σ", alignment: .trailing),
                .init(title: "持仓", alignment: .trailing),
                .init(title: "名义", alignment: .trailing),
                .init(title: "真实市值", alignment: .trailing),
            ],
            rows: gravity.expiries,
            emptyText: model.feeds.first { $0.id == "options.book" }?.detail.map { "⚠️ \($0)" } ?? "读取四家期权持仓中…"
        ) { row in
            GridText(CheckupText.expiry(row.expiryMs))
            GridText(CheckupText.hours(row.hours), alignment: .trailing)
            GridText(row.atmIv.map { String(format: "%.1f%%", $0) } ?? "—", alignment: .trailing)
            GridText(row.maxPain.map { PriceFormatter.plain($0.strike) } ?? "—",
                     tint: (row.maxPain?.weak ?? true) ? .secondary : .primary, alignment: .trailing)
            GridText(row.maxPain.map { String(format: "%+.1f%%", $0.distancePct) } ?? "—",
                     tint: (row.maxPain?.distancePct ?? 0) < 0 ? Theme.down : Theme.up, alignment: .trailing)
            GridText(row.pBeyondMaxPain.map { CheckupText.percent($0) } ?? "—", alignment: .trailing)
            GridText(row.oneSigma.map { String(format: "±%.0f", $0) } ?? "—", alignment: .trailing)
            GridText(String(format: "%.0fk", row.oiBase / 1000), alignment: .trailing)
            GridText(String(format: "%.0fM", row.notionalUsd / 1_000_000), alignment: .trailing)
            GridText(row.marketValueUsd.map { String(format: "%.1fM", $0 / 1_000_000) } ?? "—",
                     tint: .secondary, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func notices(_ gravity: LiveSnapshot.Gravity) -> some View {
        InlineNotice(
            kind: .info,
            message: "到位概率：按期权隐含分布，结算价落在 max pain 或更远一侧的概率。max pain 由现有持仓决定，远月合约的持仓多是过去建的，它常落在建仓时的价位附近——会不会过去，看到位概率。名义是合约代表的标的价值，真实市值才是这些期权当下值多少钱。")
        let weak = gravity.expiries.filter { $0.maxPain?.weak == true }
        if !weak.isEmpty {
            InlineNotice(
                kind: .info,
                message: weak.map { row in
                    let rise = row.maxPain.flatMap { pain in
                        pain.payoutOneSigmaAwayUsd.map { ($0 / max(pain.payoutUsd, 1) - 1) * 100 }
                    }
                    return "\(CheckupText.expiry(row.expiryMs))：离开 max pain 一个 1σ，卖方赔付只多 \(rise.map { String(format: "%.1f%%", $0) } ?? "不到 5%")"
                }.joined(separator: "；") + "——赔付曲线是一片洼地，不是一个价位，不宜据此定位。")
        }
        if let noisy = gravity.expiries.first(where: { $0.skew?.noisy == true }), let skew = noisy.skew {
            InlineNotice(
                kind: .warning,
                message: String(format: "%@ 到期不足一天，偏斜 %+.1f 点（%@）——两翼报价太薄，一晚可摆动十几点，不要用它择时。",
                                CheckupText.expiry(noisy.expiryMs), skew.points, skew.points < 0 ? "偏看涨" : "偏看跌"))
        }
    }

    @ViewBuilder
    private func nearStrikes(_ gravity: LiveSnapshot.Gravity) -> some View {
        if !gravity.nearStrikes.isEmpty, let near = gravity.nearExpiryMs {
            let spot = model.spot?.value ?? 0
            Text("\(CheckupText.expiry(near)) 现价 ±6% 内持仓最大的 \(gravity.nearStrikes.count) 个行权价（\(model.instrument?.base ?? "")，四家合并）")
                .font(Theme.Text.captionMedium).foregroundStyle(.secondary)
            DataGrid(
                columns: [.init(title: "行权价"), .init(title: "call", alignment: .trailing),
                          .init(title: "put", alignment: .trailing), .init(title: "净（call−put）", alignment: .trailing)],
                rows: gravity.nearStrikes
            ) { row in
                GridText(PriceFormatter.plain(row.strike),
                         tint: spot > 0 && abs(row.strike - spot) / spot < 0.004 ? Theme.warning : .primary)
                GridText(PriceFormatter.plain(row.callOi), alignment: .trailing)
                GridText(PriceFormatter.plain(row.putOi), alignment: .trailing)
                GridText(String(format: "%+.0f", row.net), tint: row.net > 0 ? Theme.up : Theme.down, alignment: .trailing)
            }
        }
    }

    private func venueLine(_ gravity: LiveSnapshot.Gravity) -> String {
        let total = gravity.venues.reduce(0) { $0 + $1.oiBase }
        return gravity.venues.map { venue in
            guard venue.ok else { return "\(venue.venue) ✗" }
            return total > 0 ? String(format: "%@ %.0f%%", venue.venue, venue.oiBase / total * 100) : venue.venue
        }.joined(separator: " · ")
    }
}

// MARK: - Structure

private struct StructureCard: View {
    let model: CheckupModel

    /// One row of the two-venue table.
    private struct Row: Identifiable {
        let id: String
        let label: String
        let meaning: String
        let cell: (LiveSnapshot.VenueStructure) -> AnyView
    }

    var body: some View {
        let venues = model.structure
        Card(title: "永续结构", subtitle: "谁在付钱、谁在撤退——OKX 是你的仓位所在，Binance 是最大的场") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                DataGrid(columns: [.init(title: "")] + venues.map { .init(title: "\($0.venue) \($0.symbol)", alignment: .trailing) } + [.init(title: "怎么读")],
                         rows: rows()) { row in
                    GridText(row.label, weight: .medium)
                    ForEach(venues) { venue in row.cell(venue) }
                    GridText(row.meaning, tint: .secondary)
                }
                InlineNotice(
                    kind: .info,
                    message: "OI 是总量，多空比是分布：每张合约都是一多一空，全市场多头仓位永远等于空头仓位。「全体账户 2.5」是说持仓账户里约 71% 净多（人头），不是多头仓位更多——空头是更少的人拿着更大的仓位。OI 跌同时多空比高，常见于大户平仓离场、散户仍然做多。")
                ForEach(venues.compactMap { venue in venue.historyError.map { (venue.venue, $0) } }, id: \.0) { venue, error in
                    InlineNotice(kind: .warning, message: "\(venue) 5 分钟历史读取失败：\(error)")
                }
            }
        }
    }

    /// A number with its age beside it, sized like any other numeric cell:
    /// exactly as wide as it needs, right-aligned in its column.
    private func stamped(_ value: String, ms: Int64?, staleAfterMs: Double) -> AnyView {
        let offset = model.clock?.offsetMs ?? 0
        return AnyView(HStack(spacing: 6) {
            Text(value).font(.system(size: 11)).monospacedDigit()
            if let ms { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: staleAfterMs) }
        }
        .fixedSize()
        .gridColumnAlignment(.trailing))
    }

    private func rows() -> [Row] {
        let base = model.instrument?.base ?? ""
        let bucketStale: Double = 7 * 60_000
        return [
            Row(id: "price", label: "价格", meaning: "OKX 为最新成交，Binance 为标记价") { v in
                stamped(v.price.map { CheckupText.price($0.value) } ?? "—", ms: v.price?.ms, staleAfterMs: 5_000)
            },
            Row(id: "funding", label: "资金费率", meaning: "正=多头付给空头") { v in
                stamped(v.fundingRate.map { String(format: "%.4f%%", $0.value * 100) } ?? "—", ms: v.fundingRate?.ms, staleAfterMs: 120_000)
            },
            Row(id: "oi", label: "未平仓量", meaning: "实时（OKX 推送 / Binance 3 秒）") { v in
                stamped(v.openInterest.map { String(format: "%.0fk %@", $0.base / 1_000, base) } ?? "—", ms: v.openInterest?.ms, staleAfterMs: 15_000)
            },
            // The change is as fresh as its live end; the reference is the
            // five-minute bucket an hour (four hours) before it.
            Row(id: "oi1h", label: "OI 1 小时", meaning: "实时持仓量对比 1 小时前的 5 分钟桶") { v in
                stamped(CheckupText.signedPercent(v.oiChange1h?.pct), ms: v.oiChange1h?.currentMs, staleAfterMs: 15_000)
            },
            Row(id: "oi4h", label: "OI 4 小时", meaning: "涨=新钱进场，跌=平仓离场") { v in
                stamped(CheckupText.signedPercent(v.oiChange4h?.pct), ms: v.oiChange4h?.currentMs, staleAfterMs: 15_000)
            },
            Row(id: "top-pos", label: "大户·按金额", meaning: "前 20% 账户，按仓位规模，>1 偏多") { v in
                stamped(v.topByPosition.map { String(format: "%.2f", $0.value) } ?? "—", ms: v.topByPosition?.ms, staleAfterMs: bucketStale)
            },
            Row(id: "top-acc", label: "大户·按人头", meaning: "同一批账户，每户算一次") { v in
                stamped(v.topByAccount.map { String(format: "%.2f", $0.value) } ?? "—", ms: v.topByAccount?.ms, staleAfterMs: bucketStale)
            },
            Row(id: "all-acc", label: "全体账户", meaning: "人头比，不是仓位比") { v in
                stamped(v.allAccounts.map { String(format: "%.2f", $0.value) } ?? "—", ms: v.allAccounts?.ms, staleAfterMs: bucketStale)
            },
            Row(id: "taker", label: "主动买卖（5 分钟桶）", meaning: "吃单买/卖，<1 卖方主动") { v in
                stamped(v.takerBuySell.map { String(format: "%.2f", $0.value) } ?? "—", ms: v.takerBuySell?.ms, staleAfterMs: bucketStale)
            },
            Row(id: "live-taker", label: "主动买卖（实时）", meaning: "逐笔成交滚动 5 分钟") { v in
                guard let live = v.liveTaker else { return stamped("—", ms: nil, staleAfterMs: 0) }
                let note = live.windowSeconds < 300 ? String(format: "（已累积 %.0f 秒）", live.windowSeconds) : ""
                return stamped(String(format: "%.2f%@", live.ratio, note), ms: live.ms, staleAfterMs: 30_000)
            },
        ]
    }
}

// MARK: - Macro

private struct MacroCard: View {
    let model: CheckupModel

    var body: some View {
        if let tape = model.macro {
            let offset = model.clock?.offsetMs ?? 0
            Card(title: "宏观", subtitle: tape.source == "schwab" ? "嘉信逐笔推送" : (tape.source == "yahoo" ? "Yahoo 分钟线（回落）" : "没有数据源")) {
                EmptyView()
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    if let note = tape.note {
                        InlineNotice(kind: tape.source == "yahoo" ? .warning : .info, message: note)
                    }
                    DataGrid(
                        columns: [
                            .init(title: "标的"), .init(title: "现价", alignment: .trailing),
                            .init(title: "涨跌", alignment: .trailing),
                            .init(title: "数据年龄", alignment: .trailing),
                            .init(title: "含义"),
                        ],
                        rows: tape.rows
                    ) { row in
                        GridText(row.delayed ? "\(row.label)（延迟行情）" : row.label, tint: row.delayed ? Theme.warning : .primary)
                        GridText(row.price.map { CheckupText.price($0) } ?? "—", alignment: .trailing)
                        GridText(CheckupText.signedPercent(row.changePct),
                                 tint: (row.changePct ?? 0) >= 0 ? Theme.up : Theme.down, alignment: .trailing)
                        if let ms = row.ms {
                            AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: 60_000)
                        } else {
                            GridText("—", tint: .secondary, alignment: .trailing)
                        }
                        GridText(row.meaning, tint: .secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Predictions

/// Polymarket's prices for the rate decisions and the war behind the macro
/// tape. The price is the probability; every row shows the book it came
/// from, so a thin market reads as thin.
private struct PredictionCard: View {
    let model: CheckupModel

    private struct Row: Identifiable {
        let id: Int
        let cell: LiveSnapshot.PredictionCell
        let label: String
    }

    var body: some View {
        if let predictions = model.predictions {
            let offset = model.clock?.offsetMs ?? 0
            Card(title: "预测市场", subtitle: "Polymarket 对议息与美伊局势的定价——交代背景，不做择时") {
                EmptyView()
            } content: {
                VStack(alignment: .leading, spacing: 14) {
                    InlineNotice(
                        kind: .info,
                        message: "价格即概率（66.5¢ = 66.5%）；涨跌按价格点数计（+3.0 = 概率升 3 个百分点）。2026-09 实测：这些概率的小时变化与 ETH 不相关（ρ≈0），它们说明市场押的方向，不提示进出场时机。")
                    ForEach(predictions.topics) { topic in
                        section(topic, offset: offset, staleAfterMs: predictions.staleAfterMs)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ topic: LiveSnapshot.PredictionTopic, offset: Double, staleAfterMs: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(topic.label).font(Theme.Text.bodyMedium)
                if let ms = topic.fetchedMs { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: staleAfterMs) }
                Text(topic.meaning).font(Theme.Text.caption).foregroundStyle(.secondary)
            }
            if let error = topic.error {
                InlineNotice(kind: .warning, message: "最近一次读取失败，下面是上一次读数：\(error)")
            }
            if topic.lines.isEmpty {
                Text(topic.fetchedMs == nil ? "正在读取…" : "没有未结束的事件")
                    .font(Theme.Text.secondary).foregroundStyle(.secondary)
            }
            ForEach(Array(topic.lines.enumerated()), id: \.offset) { _, line in
                Text(summary(line, of: topic)).font(Theme.Text.caption).foregroundStyle(.secondary)
                grid(line)
            }
        }
    }

    /// The line's event and its money. A line that spans a topic's
    /// deadlines is titled with the topic itself, already in the header.
    private func summary(_ line: LiveSnapshot.PredictionLine, of topic: LiveSnapshot.PredictionTopic) -> String {
        let title = line.title == topic.label ? "" : "\(line.title)  "
        let when = line.deadline.map { "\(Self.day($0)) 结算 · " } ?? ""
        return "\(title)\(when)24h 成交 $\(PriceFormatter.compact(line.volume24h)) · 挂单深度 $\(PriceFormatter.compact(line.liquidity))"
    }

    private func grid(_ line: LiveSnapshot.PredictionLine) -> some View {
        let byDeadline = line.cells.contains { $0.deadline != nil }
        let rows = line.cells.enumerated().map { index, cell in
            Row(id: index, cell: cell, label: cell.deadline.map { "\(Self.day($0)) 前" } ?? (cell.label.isEmpty ? line.title : cell.label))
        }
        return DataGrid(
            columns: [
                .init(title: byDeadline ? "截止" : "结果"),
                .init(title: "概率", alignment: .trailing),
                .init(title: "买一", alignment: .trailing), .init(title: "卖一", alignment: .trailing),
                .init(title: "最新成交", alignment: .trailing),
                .init(title: "1 小时", alignment: .trailing), .init(title: "24 小时", alignment: .trailing),
                .init(title: "1 周", alignment: .trailing),
                .init(title: "24h 成交", alignment: .trailing),
            ],
            rows: rows
        ) { row in
            let cell = row.cell
            GridText(row.label)
            if let probability = cell.probability {
                GridText(CheckupText.percent(probability) + (cell.fromLastTrade ? " · 成交价" : ""),
                         tint: cell.fromLastTrade ? Theme.warning : .primary, alignment: .trailing,
                         weight: probability >= 0.2 ? .semibold : .regular)
            } else {
                GridText("无有效报价", tint: .secondary, alignment: .trailing)
            }
            GridText(Self.cents(cell.bid), tint: .secondary, alignment: .trailing)
            GridText(Self.cents(cell.ask), tint: .secondary, alignment: .trailing)
            GridText(Self.cents(cell.lastTrade), tint: .secondary, alignment: .trailing)
            change(cell.change1h)
            change(cell.change1d)
            change(cell.change1w)
            GridText("$" + PriceFormatter.compact(cell.volume24h), tint: .secondary, alignment: .trailing)
        }
    }

    private func change(_ value: Double?) -> some View {
        guard let value else { return GridText("—", tint: .secondary, alignment: .trailing) }
        return GridText(String(format: "%+.1f", value * 100),
                        tint: value > 0 ? Theme.up : (value < 0 ? Theme.down : .secondary), alignment: .trailing)
    }

    /// A price in cents, the way Polymarket quotes it.
    private static func cents(_ price: Double?) -> String {
        guard let price else { return "—" }
        return PriceFormatter.plain((price * 1000).rounded() / 10) + "¢"
    }

    /// `2026-10-31` → `10/31`.
    private static func day(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return iso }
        return "\(month)/\(day)"
    }
}
