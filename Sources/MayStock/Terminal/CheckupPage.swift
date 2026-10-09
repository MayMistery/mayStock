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
                    if let model { ReviewPicker(model: model) }
                    ModeBadge(mode: appState.tradingMode)
                }
                content
            }
            .padding(Theme.pagePadding)
        }
        .background(WindowVisibilityReader { visible in model?.isVisible = visible })
        .task {
            if let model {
                model.start()
            } else if let kernel = appState.liveLayer {
                // A deep link may have named an instrument; otherwise the
                // kernel follows whatever perpetual the account holds. The
                // account it reads is the app's (`AppState.syncLiveLayer`).
                let requested = appState.requestedCheckupInstId
                let created = CheckupModel(
                    kernel: kernel,
                    instId: requested?.instId ?? Self.fallbackInstId,
                    reviewMarket: requested?.market ?? LiveSnapshot.Reviewable.crypto,
                    followsHeldPosition: requested == nil,
                    gridDivisor: gridDivisor)
                appState.pendingCheckupInstId = nil
                model = created
                created.start()
            }
        }
        // Closing the page switches the market analytics off; the account
        // part of the layer runs on for every other screen.
        .onDisappear { model?.stop() }
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
        if let failure = appState.liveLayerError {
            Card {
                InlineNotice(kind: .danger, title: "实时层没有运行", message: failure)
            }
        } else if let model {
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

    /// The venue's margin ratio as its app writes it: `mgnRatio` 23.17 is
    /// 2,317.20%, and 100% is liquidation.
    static func marginRatio(_ ratio: Double) -> String {
        PriceFormatter.decimals(ratio * 100, 2) + "%"
    }

    static func pnlTint(_ value: Double) -> Color {
        value > 0 ? Theme.up : (value < 0 ? Theme.down : .primary)
    }

    /// An expiry as the instant it settles, on the display clock: a coin's
    /// at 08:00 UTC, a US option at its New York session's close — the
    /// 20NOV contract reads "11-21 05:00" in Singapore.
    static func expiry(_ ms: Int64) -> String {
        DisplayTime.string(Date(timeIntervalSince1970: Double(ms) / 1000), "MM-dd HH:mm")
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
        case "rest": return "REST 读取（推送不可用）"
        case "schwab": return "嘉信账户（App 定时读取，与其他页面同一份）"
        case "shadow": return "嘉信影子账户（模拟盘）"
        default: return "未读到"
        }
    }

    /// The option book the gravity card reads: `4 家合并`, or the one venue
    /// whose book is the whole market's (`嘉信（全美合并）`).
    static func bookName(_ gravity: LiveSnapshot.Gravity?) -> String {
        guard let venues = gravity?.venues, !venues.isEmpty else { return "期权簿" }
        return venues.count == 1 ? venues[0].venue : "\(venues.count) 家合并"
    }

    /// `11-20 1040C`: an option leg, short enough for a button.
    static func contract(_ option: LiveSnapshot.OptionLeg) -> String {
        "\(expiryDay(option.expiryDay)) \(PriceFormatter.plain(option.strike))\(option.call ? "C" : "P")"
    }

    /// `2026-11-20` → `11-20`.
    static func expiryDay(_ day: String) -> String {
        day.count == 10 ? String(day.dropFirst(5)) : day
    }

    /// Dollars, signed where a gain or a cost: Schwab's figures and a US
    /// leg's are all dollars.
    static func usd(_ amount: Double) -> String {
        money(amount, "USD")
    }

    static func signedUsd(_ amount: Double) -> String {
        PriceFormatter.signedMoney(amount) + " USD"
    }

    /// Which smile a leg's odds were read from.
    static func oddsBasis(_ basis: LiveSnapshot.OddsBasis?) -> String {
        guard let basis else { return "期权链还没拟合出曲面，算不出概率。" }
        if basis.exact { return "按这份合约自己的到期（\(expiry(basis.expiryMs))）那条曲线读。" }
        switch basis.placement {
        case "between":
            return "这个到期没有拟合出曲线，按 \(expiry(basis.expiryMs)) 与 \(basis.farExpiryMs.map(expiry) ?? "—") 两个到期在总方差上插值。"
        case "before-first":
            return "早于最近一个有曲线的到期，沿用 \(expiry(basis.expiryMs)) 的曲线。"
        default:
            return "晚于最远一个有曲线的到期，沿用 \(expiry(basis.expiryMs)) 的曲线（外推）。"
        }
    }

    /// Where a topic's ETH columns come from, and how strong the relation is.
    static func reactionBasis(_ reaction: LiveSnapshot.Reaction) -> String {
        if let analog = reaction.analog {
            let head = "ETH 推算（\(reaction.eventLabel)，经油价）："
            guard let excess = analog.oilExcess, let se = analog.oilExcessSe, let window = reaction.windows.first else {
                return head + "\(analog.since) 以来只有 \(analog.n) 次\(analog.label)可量，样本不足，不推算。"
            }
            let oil = String(format: "%@ 以来 %d 次%@，事发前一天到当天布伦特比平常多 %+.1f%%（±%.1f，t %.1f）",
                             analog.since, analog.n, analog.label, excess, se, se > 0 ? excess / se : 0)
            let beta = String(format: "ETH 对布伦特 %@ β %+.2f（±%.2f，t %.1f）", analog.spanLabel, analog.beta, analog.betaSe,
                              analog.betaSe > 0 ? analog.beta / analog.betaSe : 0)
            guard window.significant else {
                let weak = [analog.oilSignificant ? nil : "油价反应", analog.betaSignificant ? nil : "β"].compactMap { $0 }.joined(separator: "和")
                return head + oil + "；" + beta + String(format: "。%@不到 %.1f 倍标准误，看不出稳定方向，不给概率。", weak, analog.significance)
            }
            return head + oil + "；" + beta + String(format: "。一次完全出乎意料的事件约让 ETH %+.2f%%，已被价格计入的部分按概率扣掉。", window.perStep)
        }
        let parts = reaction.windows.map { window -> String in
            let t = window.perStepSe > 0 ? window.perStep / window.perStepSe : 0
            guard window.significant else {
                return String(format: "%@看不出关系（%d 次，t %.1f，门槛 %.1f）", window.label, window.n, t, window.significance)
            }
            return String(format: "%@内每超预期%@，ETH %+.2f%%（±%.2f，t %.1f，%d 次）", window.label, window.stepLabel, window.perStep, window.perStepSe, t, window.n)
        }
        let why = reaction.why.map { "样本：\($0)。" } ?? ""
        return "ETH 对照（\(reaction.eventLabel)）：\(reaction.source)。" + parts.joined(separator: "；")
            + "。" + why + "只算事件本身的影响，不含样本期的整体涨势；\(reaction.measured) 测。"
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
        if let option = position.option {
            return "\(position.isShort ? "卖出" : "买入") \(PriceFormatter.plain(abs(position.contracts))) 张 \(option.label)"
        }
        if position.isShares {
            return "\(position.isShort ? "做空" : "持有") \(PriceFormatter.plain(abs(position.contracts))) 股 \(position.instId)"
        }
        let side = position.isShort ? "空头腿" : "多头腿"
        let mode = position.marginMode == "isolated" ? "逐仓" : (position.marginMode == "cross" ? "全仓" : nil)
        return ([side, "\(PriceFormatter.plain(abs(position.contracts))) 张", mode].compactMap { $0 }).joined(separator: " · ")
    }

    /// A figure in the currency it is stated in, labelled.
    static func money(_ amount: Double, _ currency: String?) -> String {
        PriceFormatter.money(amount) + (currency.map { " " + $0 } ?? "")
    }

    /// A dollar figure — the kernel measures exposure in dollars — stated in
    /// the account's quote currency at the account reading's own rate: the
    /// unit every other screen states the account in. The page used to show
    /// these dollars unlabelled beside a floating profit in USDT (2026-10-08).
    /// Dollars, labelled, when the reading gives no rate.
    static func dollars(_ usd: Double, reading: AccountSnapshot?) -> String {
        let quote = Venue.okx.quoteCurrency
        if let amount = reading?.amount(usd: usd, in: quote) { return money(amount, quote) }
        return money(usd, AccountSnapshot.usdCode)
    }

    /// Net notional with its direction, e.g. `净空 3,955.00 USDT`.
    static func netNotional(_ exposure: LiveSnapshot.Exposure, hedged: Bool, reading: AccountSnapshot?) -> String {
        let amount = dollars(abs(exposure.netNotional), reading: reading)
        guard hedged else { return amount }
        if exposure.netNotional == 0 { return "完全对冲" }
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
                            // Stale by definition: nothing has arrived since.
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

// MARK: - Review

/// What the page reviews: whatever is held, followed, or one of the held
/// instruments chosen by hand — an OKX perpetual or a US share with its
/// options. Its own view, so a tick elsewhere does not redraw the menu.
private struct ReviewPicker: View {
    let model: CheckupModel

    var body: some View {
        if let instrument = model.instrument, !model.reviewable.isEmpty {
            let current = model.reviewable.first { $0.market == instrument.market && $0.instId == instrument.instId }
            Menu {
                Button((instrument.followsHeld ? "✓ " : "") + "跟随持仓") { model.review(nil) }
                Divider()
                ForEach(model.reviewable) { item in
                    let chosen = !instrument.followsHeld && item.id == current?.id
                    Button((chosen ? "✓ " : "") + item.label + (item.held ? "" : "（未持有）")) { model.review(item) }
                }
            } label: {
                Text("体检对象：\(current?.label ?? instrument.instId)\(instrument.followsHeld ? "（跟随持仓）" : "")")
                    .font(Theme.Text.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("持有的 OKX 永续和嘉信美股（含期权）都可以体检；跟随持仓时优先 OKX 永续，没有就看嘉信上持有最多的标的")
        }
    }
}

// MARK: - Risk

private struct RiskCard: View {
    let model: CheckupModel
    let appState: AppState

    var body: some View {
        if let risk = model.risk {
            let offset = model.clock?.offsetMs ?? 0
            let venue: Venue = risk.venue == "schwab" ? .schwab : .okx
            Card(title: "持仓风险", subtitle: subtitle(risk, venue: venue)) {
                HStack(spacing: 6) {
                    Text(CheckupText.source(risk.source)).font(Theme.Text.caption).foregroundStyle(.secondary)
                    if let ms = risk.positionsMs { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: risk.positionsStaleAfterMs ?? 0) }
                    // One ticket per leg: closing a long/short account's short
                    // must not open on its long, and each option is its own
                    // contract.
                    ForEach(risk.positions) { position in
                        CloseHoldingButton(
                            appState: appState,
                            request: appState.closeTicket(instId: position.instId, isLong: !position.isShort, on: venue),
                            title: closeTitle(position, risk: risk))
                    }
                }
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    if venue == .okx, let fallbackError = appState.accountFeed?.fallbackError {
                        InlineNotice(kind: .warning, message: "账户推送不可用，REST 读取也失败了：\(fallbackError)")
                    }
                    // OKX's note names the source, which the header already says;
                    // Schwab's says the latest read failed.
                    if venue == .schwab, let note = risk.note, risk.wasRead {
                        InlineNotice(kind: .warning, message: note)
                    }
                    if !risk.positions.isEmpty {
                        if venue == .schwab { usTiles(risk, offset: offset) } else { instrumentTiles(risk, offset: offset) }
                        if risk.isHedged, let notice = CheckupText.nakedLegs(risk.positions) {
                            InlineNotice(kind: .warning, title: "两条腿各自逐仓", message: notice)
                        }
                        ForEach(risk.positions) { position in
                            leg(position, risk: risk, offset: offset)
                        }
                        unattached(risk, offset: offset)
                    } else if risk.wasRead {
                        EmptyState(icon: "checkmark.shield",
                                   title: venue == .schwab ? "嘉信账户里没有 \(risk.instId) 的持仓" : "当前没有持仓",
                                   message: venue == .schwab
                                       ? "持有这只股票或它的期权后，这里显示每条腿的报价、希腊值、盈亏平衡和到期概率。"
                                       : "开仓后这里显示强平距离、敞口与强平概率。")
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

    private func subtitle(_ risk: LiveSnapshot.Risk, venue: Venue) -> String? {
        if risk.positions.isEmpty { return risk.wasRead ? "无持仓" : nil }
        if venue == .schwab { return "\(risk.instId) · 美股（嘉信）" }
        return risk.instId + (risk.isHedged ? " · 多空双向" : "")
    }

    private func closeTitle(_ position: LiveSnapshot.Position, risk: LiveSnapshot.Risk) -> String {
        let single = risk.positions.count == 1
        if let option = position.option {
            return single ? "平仓 / 止损" : "平 \(CheckupText.contract(option))"
        }
        if position.isShares { return single ? "平仓 / 止损" : "平股票" }
        return single ? "平仓 / 止盈止损" : "\(position.isShort ? "平空" : "平多") / 止盈止损"
    }

    /// What the instrument as a whole risks: every leg netted for price,
    /// summed for margin.
    @ViewBuilder
    private func instrumentTiles(_ risk: LiveSnapshot.Risk, offset: Double) -> some View {
        let single = risk.positions.count == 1 ? risk.positions.first : nil
        let reading = model.snapshot?.account.snapshot
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
                    value: CheckupText.netNotional(exposure, hedged: risk.isHedged, reading: reading),
                    caption: risk.isHedged
                        ? "多 \(CheckupText.dollars(exposure.longNotional, reading: reading)) · 空 \(CheckupText.dollars(exposure.shortNotional, reading: reading))"
                        : "权益 \(CheckupText.dollars(exposure.equity, reading: reading))")
                StatTile(
                    label: "标的每涨 1%", value: CheckupText.dollars(exposure.pnlPerOnePercentRise, reading: reading),
                    tint: CheckupText.pnlTint(exposure.pnlPerOnePercentRise),
                    caption: String(format: "权益的 %.1f%%", exposure.onePercentAsEquityPct))
            }
            StatTile(
                label: "标记价", value: risk.mark.map { CheckupText.price($0.price) } ?? "—",
                caption: risk.mark?.source == "okx.mark-price" ? "实时标记价推送" : "来自最近一次持仓推送")
        }
        if let mark = risk.mark, let ms = mark.ms {
            HStack(spacing: 6) {
                Text("标记价").font(Theme.Text.caption).foregroundStyle(.secondary)
                AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: mark.staleAfterMs ?? 0)
            }
        }
    }

    /// A US underlying as a whole: its shares and options folded into the
    /// shares they move like (delta), in dollars — Schwab's unit.
    @ViewBuilder
    private func usTiles(_ risk: LiveSnapshot.Risk, offset: Double) -> some View {
        HStack(spacing: 8) {
            StatTile(
                label: "实际杠杆（按 Delta）",
                value: risk.exposure.map { String(format: "%.2fx", $0.effectiveLeverage) } ?? "—",
                caption: risk.exposure.map { "权益 \(CheckupText.usd($0.equity))" },
                help: "每条腿按 Delta 折成股数，乘以标的价得到美元敞口，再除以嘉信账户的清算价值")
            if let exposure = risk.exposure {
                StatTile(
                    label: "Delta 敞口",
                    value: (exposure.netNotional >= 0 ? "净多 " : "净空 ") + CheckupText.usd(abs(exposure.netNotional)),
                    caption: "多 \(CheckupText.usd(exposure.longNotional)) · 空 \(CheckupText.usd(exposure.shortNotional))")
                StatTile(
                    label: "标的每涨 1%", value: CheckupText.signedUsd(exposure.pnlPerOnePercentRise),
                    tint: CheckupText.pnlTint(exposure.pnlPerOnePercentRise),
                    caption: String(format: "权益的 %.2f%%", exposure.onePercentAsEquityPct))
                StatTile(
                    label: "维持保证金", value: CheckupText.usd(exposure.margin),
                    caption: String(format: "权益的 %.1f%%", exposure.marginAsEquityPct),
                    help: "嘉信给每条腿的维持保证金要求之和；买入的期权和全额股票为 0")
            }
            StatTile(
                label: "标的价", value: risk.mark.map { CheckupText.price($0.price) } ?? "—",
                caption: model.spot?.source)
        }
        if let mark = risk.mark, let ms = mark.ms {
            HStack(spacing: 6) {
                Text("标的价").font(Theme.Text.caption).foregroundStyle(.secondary)
                AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: mark.staleAfterMs ?? 0)
            }
        }
        if let note = risk.exposureNote {
            Text(note).font(Theme.Text.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One leg, by what it is: an option, shares, or a perpetual.
    @ViewBuilder
    private func leg(_ position: LiveSnapshot.Position, risk: LiveSnapshot.Risk, offset: Double) -> some View {
        if risk.positions.count > 1 {
            Divider()
            Text(CheckupText.legTitle(position))
                .font(Theme.Text.captionMedium)
                .foregroundStyle(position.isShort ? Theme.down : Theme.up)
        }
        if let option = position.option {
            optionLeg(position, option, offset: offset)
        } else if position.isShares {
            shareLeg(position)
        } else {
            perpetualLeg(position, risk: risk)
        }
        if let note = position.note {
            InlineNotice(kind: .info, message: note)
        }
        protective(position, risk: risk, offset: offset)
    }

    /// A held option: its contract and quote, its profit, where it breaks
    /// even and how likely that is, what it can lose, and its greeks.
    @ViewBuilder
    private func optionLeg(_ position: LiveSnapshot.Position, _ option: LiveSnapshot.OptionLeg, offset: Double) -> some View {
        let quote = option.quote
        let spot = model.risk?.mark?.price
        HStack(spacing: 8) {
            StatTile(
                label: "合约",
                value: "\(position.isShort ? "卖" : "买")\(option.call ? "看涨" : "看跌") \(PriceFormatter.plain(option.strike))",
                caption: "\(CheckupText.expiry(option.expiryMs)) 到期 · 剩 \(CheckupText.hours(option.daysLeft * 24)) · \(PriceFormatter.plain(abs(position.contracts))) 张",
                help: "\(option.label)，每张 \(PriceFormatter.plain(option.multiplier)) 股")
            StatTile(
                label: "期权价",
                value: quote.map { CheckupText.price($0.mark) } ?? "—",
                caption: quote.map { q in
                    [q.bid.map { "买 \(CheckupText.price($0))" }, q.ask.map { "卖 \(CheckupText.price($0))" },
                     option.extrinsic.map { "时间价值 \(CheckupText.price($0))" }].compactMap { $0 }.joined(separator: " · ")
                },
                help: "按买卖中间价估值（没有双边报价时按最新成交）。来源：\(quote?.source == "schwab.stream" ? "嘉信逐笔推送" : "嘉信期权链")"
                    + (quote?.openInterest.map { "；持仓 \(PriceFormatter.plain($0)) 张" } ?? "")
                    + (quote?.volume.map { "，今日成交 \(PriceFormatter.plain($0)) 张" } ?? ""))
            StatTile(
                label: "浮动盈亏", value: position.unrealisedPnl.map(CheckupText.signedUsd) ?? "—",
                tint: CheckupText.pnlTint(position.unrealisedPnl ?? 0),
                caption: ["均价 \(position.averagePrice.map(CheckupText.price) ?? "—")",
                          position.venueFigures?.openProfitLoss.map { "嘉信口径 \(CheckupText.signedUsd($0))" }]
                    .compactMap { $0 }.joined(separator: " · "),
                help: position.remarked
                    ? "（期权价 − 均价）× 张数 × \(PriceFormatter.plain(option.multiplier))，与平仓面板同一个公式；嘉信口径是它最近一次账户读数里的数"
                    : "嘉信账户读数里的数（还没有这张合约的报价）")
            StatTile(
                label: "盈亏平衡", value: CheckupText.price(option.breakeven),
                caption: spot.map { String(format: "距标的 %+.2f%%", (option.breakeven / $0 - 1) * 100) },
                help: "到期时标的要在这个价\(option.call ? "之上" : "之下")，这条腿才不亏（按均价）")
        }
        if let quote, let ms = quote.ms {
            HStack(spacing: 6) {
                Text("期权报价").font(Theme.Text.caption).foregroundStyle(.secondary)
                AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: quote.staleAfterMs)
            }
        }
        if let nonstandard = option.nonstandard {
            InlineNotice(kind: .warning, message: "非标准合约：每张交割 \(nonstandard)。行权价对应的不是标的本身，按标的算的到期概率和希腊值会出错，这里不给。")
        } else {
            HStack(spacing: 8) {
                StatTile(
                    label: "到期价内", value: option.pItm.map(CheckupText.percent) ?? "—",
                    caption: "结算\(option.call ? "高于" : "低于") \(PriceFormatter.plain(option.strike))")
                StatTile(
                    label: "到期盈利", value: option.pProfit.map(CheckupText.percent) ?? "—",
                    tint: (option.pProfit ?? 1) < 0.3 ? Theme.warning : .primary,
                    caption: "结算\((option.call != position.isShort) ? "高于" : "低于") \(CheckupText.price(option.breakeven))")
                if position.isShort {
                    StatTile(
                        label: "到期前触及行权价", value: option.pTouchStrike.map(CheckupText.percent) ?? "—",
                        tint: (option.pTouchStrike ?? 0) > 0.3 ? Theme.down : .primary,
                        caption: "碰到就可能被行权",
                        help: "期间任意时刻碰到行权价的风险中性概率（put–call 对称静态复制），比到期价内更早发生")
                }
                StatTile(
                    label: "最大亏损", value: option.maxLoss.map(CheckupText.usd) ?? "无上限",
                    tint: option.maxLoss == nil ? Theme.down : .primary,
                    caption: option.maxLossText)
            }
            Text("风险中性概率：" + CheckupText.oddsBasis(option.oddsBasis))
                .font(Theme.Text.caption).foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                StatTile(
                    label: "Delta", value: option.positionDelta.map { String(format: "%+.1f 股", $0) } ?? "—",
                    caption: [option.delta.map { String(format: "每股 %.3f", $0) }, option.dollarDelta.map { "≈ \(CheckupText.signedUsd($0))" }]
                        .compactMap { $0 }.joined(separator: " · "),
                    help: "这条腿像多少股标的一样涨跌（正为看多）")
                StatTile(
                    label: "Theta（每天）", value: option.thetaPerDay.map(CheckupText.signedUsd) ?? "—",
                    tint: CheckupText.pnlTint(option.thetaPerDay ?? 0),
                    caption: option.theta.map { String(format: "每股 %.3f", $0) },
                    help: "其他不变时，过一天这条腿的价值变化")
                StatTile(
                    label: "Vega（每 1 个波动率点）", value: option.vegaPerPoint.map(CheckupText.signedUsd) ?? "—",
                    caption: option.iv.map { String(format: "IV %.1f%%", $0) })
                StatTile(
                    label: "Gamma", value: option.positionGamma.map { String(format: "%+.2f 股/美元", $0) } ?? "—",
                    caption: option.gamma.map { String(format: "每股 %.4f", $0) },
                    help: "标的每涨 1 美元，Delta 变多少股")
            }
            if let source = option.greeksSource {
                Text("希腊值、IV 是嘉信的模型\(source == "stream" ? "（逐笔推送）" : "（期权链）")；概率是用期权链报价重新拟合的曲面。")
                    .font(Theme.Text.caption).foregroundStyle(.tertiary)
            }
        }
        if let assignment = option.assignment {
            InlineNotice(kind: .warning, message: assignment)
        }
    }

    /// Shares of the underlying.
    @ViewBuilder
    private func shareLeg(_ position: LiveSnapshot.Position) -> some View {
        HStack(spacing: 8) {
            StatTile(
                label: "方向 / 股数", value: "\(position.isShort ? "空" : "多") \(PriceFormatter.plain(abs(position.contracts)))",
                caption: position.notionalUsd.map { "市值 \(CheckupText.usd($0))" })
            StatTile(
                label: "浮动盈亏", value: position.unrealisedPnl.map(CheckupText.signedUsd) ?? "—",
                tint: CheckupText.pnlTint(position.unrealisedPnl ?? 0),
                caption: ["均价 \(position.averagePrice.map(CheckupText.price) ?? "—")",
                          position.venueFigures?.openProfitLoss.map { "嘉信口径 \(CheckupText.signedUsd($0))" }]
                    .compactMap { $0 }.joined(separator: " · "),
                help: position.remarked ? "按上方实时标的价计算；嘉信口径是它最近一次账户读数里的数" : "嘉信账户读数里的数")
            StatTile(
                label: "维持保证金", value: position.margin.map(CheckupText.usd) ?? "—",
                caption: "嘉信的要求")
        }
    }

    /// A perpetual leg: its liquidation, odds and margin.
    @ViewBuilder
    private func perpetualLeg(_ position: LiveSnapshot.Position, risk: LiveSnapshot.Risk) -> some View {
        HStack(spacing: 8) {
            StatTile(
                label: "方向 / 张数",
                value: "\(position.isShort ? "空" : "多") \(PriceFormatter.plain(abs(position.contracts)))",
                caption: String(format: "%.3f 个标的", abs(position.baseQuantity)))
            StatTile(
                label: "浮动盈亏", value: position.unrealisedPnl.map { CheckupText.money($0, position.settlementCurrency) } ?? "—",
                tint: CheckupText.pnlTint(position.unrealisedPnl ?? 0),
                caption: [position.unrealisedRatio.map { "收益率 " + PriceFormatter.signedPercent($0 * 100) },
                          position.averagePrice.map { "均价 \(CheckupText.price($0))" }]
                    .compactMap { $0 }.joined(separator: " · "),
                help: position.remarked
                    ? "在上方的实时标记价上按交易所的公式计算，与 OKX App 同口径；收益率是交易所口径（浮盈 ÷ 开仓保证金）"
                    : "交易所最近一次持仓推送里的数")
            StatTile(
                label: "强平缓冲",
                value: position.liquidationBufferPct.map { String(format: "%.2f%%", $0) } ?? "—",
                tint: CheckupText.bufferTint(position.liquidationBufferPct),
                caption: position.liquidationPrice.map { "强平 \(CheckupText.price($0))" },
                help: "标记价要走多远才触发强平，按实时标记价算")
            StatTile(
                label: "资金费累计", value: position.fundingFee.map { CheckupText.money($0, position.settlementCurrency) } ?? "—",
                tint: CheckupText.pnlTint(position.fundingFee ?? 0), caption: "这个仓位至今")
        }
        if let ratio = position.marginRatio {
            // The exchange's own health figure — the one it would act on —
            // as its app writes it: a percentage, liquidation at 100%.
            StatTile(
                label: "交易所保证金率", value: CheckupText.marginRatio(ratio),
                tint: ratio < 15 ? Theme.warning : .primary,
                caption: "交易所自己的口径，100% 触发强平"
                    + (position.maintenanceMargin.map { " · 维持保证金 \(CheckupText.money($0, position.settlementCurrency))" } ?? ""),
                help: "与「强平缓冲」不同：缓冲是价格距离，这是保证金健康度。交易所按 2 秒一次的持仓推送给出，低于 1500% 标黄")
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
    }

    @ViewBuilder
    private func protective(_ position: LiveSnapshot.Position, risk: LiveSnapshot.Risk, offset: Double) -> some View {
        let schwab = risk.venue == "schwab"
        let name = risk.positions.count > 1
            ? (position.option.map { CheckupText.contract($0) } ?? (position.isShares ? "股票" : (position.isShort ? "空头腿" : "多头腿")))
            : "仓位"
        if risk.stopsMs == nil {
            // Not read yet (or never readable) is not "none".
            InlineNotice(kind: .info, message: risk.stopsError.map { "\(schwab ? "挂单" : "条件单")读取失败：\($0)" }
                ?? (schwab ? "正在读取嘉信挂单…" : "正在读取条件单…"))
        } else if position.protective.isEmpty {
            InlineNotice(kind: .warning, message: schwab
                ? "\(name)在嘉信没有平仓挂单（止损或限价）——没有自动保护。" + (position.option != nil && !position.isShort ? "买入的期权最多亏掉权利金。" : "")
                : "\(name)没有止盈止损单——在交易所侧没有自动保护。")
        } else {
            HStack(spacing: 6) {
                Text(schwab ? "平仓挂单" : "止盈止损").font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                if let ms = risk.stopsMs { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: risk.stopsStaleAfterMs) }
            }
            DataGrid(
                columns: [.init(title: "类型"), .init(title: "止损触发", alignment: .trailing),
                          .init(title: schwab ? "平仓限价" : "止盈触发", alignment: .trailing), .init(title: "数量", alignment: .trailing)],
                rows: position.protective
            ) { order in
                GridText(order.kind)
                GridText(order.stopPrice.map { CheckupText.price($0) } ?? "—", alignment: .trailing)
                GridText(order.takeProfitPrice.map { CheckupText.price($0) } ?? "—", alignment: .trailing)
                GridText(CheckupText.orderSize(order), alignment: .trailing)
            }
            if let error = risk.stopsError {
                InlineNotice(kind: .warning, message: "最近一次\(schwab ? "挂单" : "条件单")读取失败，下面是上一次成功读到的：\(error)")
            }
        }
    }

    /// Orders on this instrument that close no leg. Shown apart, so a
    /// trigger that would open or add is never read as protection.
    @ViewBuilder
    private func unattached(_ risk: LiveSnapshot.Risk, offset: Double) -> some View {
        if !risk.unattachedOrders.isEmpty {
            let schwab = risk.venue == "schwab"
            Divider()
            HStack(spacing: 6) {
                Text("不平任何持仓的\(schwab ? "挂单" : "条件单")（\(risk.unattachedOrders.count) 张）")
                    .font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                if let ms = risk.stopsMs { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: risk.stopsStaleAfterMs) }
            }
            DataGrid(
                columns: [.init(title: "类型"), .init(title: "方向"), .init(title: "止损触发", alignment: .trailing),
                          .init(title: schwab ? "限价" : "止盈触发", alignment: .trailing), .init(title: "数量", alignment: .trailing)],
                rows: risk.unattachedOrders
            ) { order in
                GridText(order.kind)
                GridText(CheckupText.orderDirection(side: order.side, posSide: order.posSide))
                GridText(order.stopPrice.map { CheckupText.price($0) } ?? "—", alignment: .trailing)
                GridText(order.takeProfitPrice.map { CheckupText.price($0) } ?? "—", alignment: .trailing)
                GridText(CheckupText.orderSize(order), alignment: .trailing)
            }
            Text("这些单子成交后是开仓或加仓，不会减少上面任何一条腿——它们不算保护。")
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
                subtitle: "期权市场给出的结算价分布（\(probability.smileVenue)波动率曲面 + \(probability.spotSource ?? "标的价")实时平移）"
            ) {
                HStack(spacing: 6) {
                    Text("曲面").font(Theme.Text.caption).foregroundStyle(.secondary)
                    if let ms = probability.surfaceMs { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: probability.surfaceStaleAfterMs) }
                    Text("标的").font(Theme.Text.caption).foregroundStyle(.secondary)
                    if let ms = probability.indexMs { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: probability.indexStaleAfterMs) }
                }
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    if !probability.gridChoices.isEmpty { widthPicker(probability) }
                    if probability.columns.isEmpty {
                        let feed = model.feeds.first { $0.id == probability.smileFeed }
                        Text(feed?.isLive == true ? "等待期权曲面与标的价…" : "\(feed?.label ?? probability.smileVenue)不在线，算不出概率\(feed?.detail.map { "：\($0)" } ?? "")")
                            .font(Theme.Text.secondary).foregroundStyle(.secondary)
                    } else {
                        table(probability)
                    }
                    ForEach(probability.notes, id: \.self) { note in
                        InlineNotice(kind: .info, message: note)
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
            message: "风险中性概率：含风险溢价，通常高估下跌尾部。◆ 是该到期\(CheckupText.bookName(model.gravity))的 max pain 所在区间。列是持仓占全市场 2% 以上的到期日\(model.risk?.positions.contains { $0.option != nil } == true ? "，以及所持合约自己的到期" : "")。")
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
            Card(title: "期权引力（\(CheckupText.bookName(gravity))）", subtitle: venueLine(gravity)) {
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
                .init(title: "持仓（\(gravity.oiUnit)）", alignment: .trailing),
                .init(title: "名义", alignment: .trailing),
                .init(title: "真实市值", alignment: .trailing),
            ],
            rows: gravity.expiries,
            emptyText: model.feeds.first { $0.id == gravity.bookFeed }?.detail.map { "⚠️ \($0)" } ?? "读取\(CheckupText.bookName(gravity))期权持仓中…"
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
            GridText(PriceFormatter.compact(row.oiBase / gravity.oiPerUnit), alignment: .trailing)
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
            Text("\(CheckupText.expiry(near)) 现价 ±6% 内持仓最大的 \(gravity.nearStrikes.count) 个行权价（\(model.instrument?.base ?? "")，\(CheckupText.bookName(gravity))，单位 \(gravity.oiUnit)）")
                .font(Theme.Text.captionMedium).foregroundStyle(.secondary)
            DataGrid(
                columns: [.init(title: "行权价"), .init(title: "call", alignment: .trailing),
                          .init(title: "put", alignment: .trailing), .init(title: "净（call−put）", alignment: .trailing)],
                rows: gravity.nearStrikes
            ) { row in
                GridText(PriceFormatter.plain(row.strike),
                         tint: spot > 0 && abs(row.strike - spot) / spot < 0.004 ? Theme.warning : .primary)
                GridText(PriceFormatter.plain(row.callOi / gravity.oiPerUnit), alignment: .trailing)
                GridText(PriceFormatter.plain(row.putOi / gravity.oiPerUnit), alignment: .trailing)
                GridText(String(format: "%+.0f", row.net / gravity.oiPerUnit), tint: row.net > 0 ? Theme.up : Theme.down, alignment: .trailing)
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
        // A share has no perpetual positioning: the kernel sends none.
        if !venues.isEmpty {
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
    }

    /// A number with its age beside it, sized like any other numeric cell:
    /// exactly as wide as it needs, right-aligned in its column. The stale
    /// age is the one the kernel stamped the value with.
    private func stamped(_ value: String, ms: Int64?, staleAfterMs: Double?) -> AnyView {
        let offset = model.clock?.offsetMs ?? 0
        return AnyView(HStack(spacing: 6) {
            Text(value).font(.system(size: 11)).monospacedDigit()
            if let ms { AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: staleAfterMs ?? 0) }
        }
        .fixedSize()
        .gridColumnAlignment(.trailing))
    }

    private func rows() -> [Row] {
        let base = model.instrument?.base ?? ""
        return [
            Row(id: "price", label: "价格", meaning: "OKX 为最新成交，Binance 为标记价") { v in
                stamped(v.price.map { CheckupText.price($0.value) } ?? "—", ms: v.price?.ms, staleAfterMs: v.price?.staleAfterMs)
            },
            Row(id: "funding", label: "资金费率", meaning: "正=多头付给空头") { v in
                stamped(v.fundingRate.map { String(format: "%.4f%%", $0.value * 100) } ?? "—", ms: v.fundingRate?.ms, staleAfterMs: v.fundingRate?.staleAfterMs)
            },
            Row(id: "oi", label: "未平仓量", meaning: "实时（OKX 推送 / Binance 3 秒）") { v in
                stamped(v.openInterest.map { String(format: "%.0fk %@", $0.base / 1_000, base) } ?? "—", ms: v.openInterest?.ms, staleAfterMs: v.openInterest?.staleAfterMs)
            },
            // The change is as fresh as its live end; the reference is the
            // five-minute bucket an hour (four hours) before it.
            Row(id: "oi1h", label: "OI 1 小时", meaning: "实时持仓量对比 1 小时前的 5 分钟桶") { v in
                stamped(CheckupText.signedPercent(v.oiChange1h?.pct), ms: v.oiChange1h?.currentMs, staleAfterMs: v.oiChange1h?.staleAfterMs)
            },
            Row(id: "oi4h", label: "OI 4 小时", meaning: "涨=新钱进场，跌=平仓离场") { v in
                stamped(CheckupText.signedPercent(v.oiChange4h?.pct), ms: v.oiChange4h?.currentMs, staleAfterMs: v.oiChange4h?.staleAfterMs)
            },
            Row(id: "top-pos", label: "大户·按金额", meaning: "前 20% 账户，按仓位规模，>1 偏多") { v in
                stamped(v.topByPosition.map { String(format: "%.2f", $0.value) } ?? "—", ms: v.topByPosition?.ms, staleAfterMs: v.topByPosition?.staleAfterMs)
            },
            Row(id: "top-acc", label: "大户·按人头", meaning: "同一批账户，每户算一次") { v in
                stamped(v.topByAccount.map { String(format: "%.2f", $0.value) } ?? "—", ms: v.topByAccount?.ms, staleAfterMs: v.topByAccount?.staleAfterMs)
            },
            Row(id: "all-acc", label: "全体账户", meaning: "人头比，不是仓位比") { v in
                stamped(v.allAccounts.map { String(format: "%.2f", $0.value) } ?? "—", ms: v.allAccounts?.ms, staleAfterMs: v.allAccounts?.staleAfterMs)
            },
            Row(id: "taker", label: "主动买卖（5 分钟桶）", meaning: "吃单买/卖，<1 卖方主动") { v in
                stamped(v.takerBuySell.map { String(format: "%.2f", $0.value) } ?? "—", ms: v.takerBuySell?.ms, staleAfterMs: v.takerBuySell?.staleAfterMs)
            },
            Row(id: "live-taker", label: "主动买卖（实时）", meaning: "逐笔成交滚动 5 分钟") { v in
                guard let live = v.liveTaker else { return stamped("—", ms: nil, staleAfterMs: nil) }
                let note = live.windowSeconds < 300 ? String(format: "（已累积 %.0f 秒）", live.windowSeconds) : ""
                return stamped(String(format: "%.2f%@", live.ratio, note), ms: live.ms, staleAfterMs: live.staleAfterMs)
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
                            AgeLabel(ms: ms, offsetMs: offset, staleAfterMs: row.staleAfterMs)
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
            Card(title: "预测市场", subtitle: "Polymarket：未来 \(predictions.upcomingDays) 天要结算的大事件，和议息、霍尔木兹这些更长的主线——交代背景，不做择时") {
                EmptyView()
            } content: {
                VStack(alignment: .leading, spacing: 14) {
                    InlineNotice(
                        kind: .info,
                        message: "价格即概率（66.5¢ = 66.5%）；涨跌按价格点数计（+3.0 = 概率升 3 个百分点）。2026-09 实测：这些概率的小时变化与 ETH 不相关（ρ≈0），它们说明市场押的方向，不提示进出场时机。")
                    if !predictions.upcoming.isEmpty {
                        Text("未来 \(predictions.upcomingDays) 天（按纽约日期，结算早的在前）").font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                        ForEach(predictions.upcoming) { topic in
                            section(topic, offset: offset, staleAfterMs: predictions.staleAfterMs)
                        }
                    }
                    if !predictions.later.isEmpty {
                        Divider()
                        Text("更远的主线").font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                        ForEach(predictions.later) { topic in
                            section(topic, offset: offset, staleAfterMs: predictions.staleAfterMs)
                        }
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
            if let reaction = topic.reaction {
                Text(CheckupText.reactionBasis(reaction))
                    .font(Theme.Text.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = topic.error {
                InlineNotice(kind: .warning, message: "最近一次读取失败，下面是上一次读数：\(error)")
            }
            if topic.lines.isEmpty {
                Text(topic.fetchedMs == nil ? "正在读取…" : "没有还没到截止的盘")
                    .font(Theme.Text.secondary).foregroundStyle(.secondary)
            }
            ForEach(Array(topic.lines.enumerated()), id: \.offset) { _, line in
                Text(summary(line, of: topic)).font(Theme.Text.caption).foregroundStyle(.secondary)
                grid(line, layout: topic.layout, reaction: topic.reaction)
            }
            if topic.settling > 0 {
                Text("另有 \(topic.settling) 个盘已过截止、等待结算，不显示")
                    .font(Theme.Text.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// The line's event and its money. A line that spans a topic's
    /// deadlines is titled with the topic itself, already in the header.
    private func summary(_ line: LiveSnapshot.PredictionLine, of topic: LiveSnapshot.PredictionTopic) -> String {
        let title = line.title == topic.label ? "" : "\(line.title)  "
        let when = line.deadlineEndsMs.map { "\(Self.moment($0)) 前结算 · " } ?? ""
        return "\(title)\(when)24h 成交 $\(PriceFormatter.compact(line.volume24h)) · 挂单深度 $\(PriceFormatter.compact(line.liquidity))"
    }

    private func grid(_ line: LiveSnapshot.PredictionLine, layout: String, reaction: LiveSnapshot.Reaction?) -> some View {
        let rows = line.cells.enumerated().map { index, cell in
            Row(id: index, cell: cell, label: Self.rowLabel(cell, layout: layout, title: line.title))
        }
        let windows = reaction?.windows ?? []
        let head: [GridColumn] = [
            GridColumn(title: layout == "daily" ? "日期" : (layout == "deadlines" ? "截止" : "结果")),
            GridColumn(title: "概率", alignment: .trailing),
        ]
        let eth: [GridColumn] = windows.map { GridColumn(title: "ETH·\($0.label)", alignment: .trailing) }
        let book: [GridColumn] = [
            GridColumn(title: "买一", alignment: .trailing), GridColumn(title: "卖一", alignment: .trailing),
            GridColumn(title: "最新成交", alignment: .trailing),
            GridColumn(title: "1 小时", alignment: .trailing), GridColumn(title: "24 小时", alignment: .trailing),
            GridColumn(title: "1 周", alignment: .trailing),
            GridColumn(title: "24h 成交", alignment: .trailing),
        ]
        return DataGrid(
            columns: head + eth + book,
            rows: rows
        ) { row in
            let cell = row.cell
            GridText(row.label, weight: cell.upcoming && layout != "outcomes" ? .semibold : .regular)
            if let probability = cell.probability {
                GridText(CheckupText.percent(probability) + (cell.fromLastTrade ? " · 成交价" : ""),
                         tint: cell.fromLastTrade ? Theme.warning : .primary, alignment: .trailing,
                         weight: probability >= 0.2 ? .semibold : .regular)
            } else {
                GridText("无有效报价", tint: .secondary, alignment: .trailing)
            }
            ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                Self.ethCell(index < cell.reactions.count ? cell.reactions[index] : nil, window: window)
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

    /// "涨 59% · +0.3%": the chance ETH ends the window higher if this
    /// outcome happens, and its expected move. "无关" where history shows no
    /// relation; "—" where this outcome has no price to read a surprise from;
    /// "外推" past the largest surprise on record.
    @ViewBuilder
    private static func ethCell(_ reading: LiveSnapshot.CellReaction?, window: LiveSnapshot.ReactionWindow) -> some View {
        if !window.significant {
            GridText("无关", tint: .secondary, alignment: .trailing)
        } else if let reading, let up = reading.up, let median = reading.median {
            let side = up >= 0.5 ? up : 1 - up
            let odds = side > 0.99 ? ">99%" : String(format: "%.0f%%", side * 100)
            let tint = up >= 0.5 ? Theme.up : Theme.down
            // Beyond the largest surprise on record the line is carried past
            // its data: said in the cell, and drawn faint.
            GridText(String(format: "%@ %@ · %+.1f%%", up >= 0.5 ? "涨" : "跌", odds, median) + (reading.extrapolated ? " · 外推" : ""),
                     tint: reading.extrapolated ? tint.opacity(0.55) : tint, alignment: .trailing,
                     weight: !reading.extrapolated && abs(up - 0.5) >= 0.2 ? .semibold : .regular)
        } else {
            GridText("—", tint: .secondary, alignment: .trailing)
        }
    }

    /// `10/10 12:00 前` for a deadline — the instant it runs out, on the
    /// display clock — `10/8 当天` for a day's question, which is named for
    /// its New York day, the outcome's own name otherwise; a deadline inside
    /// the coming week adds its weekday.
    private static func rowLabel(_ cell: LiveSnapshot.PredictionCell, layout: String, title: String) -> String {
        if layout == "daily", let day = cell.deadline { return "\(Self.day(day)) 当天" }
        guard let ends = cell.deadlineEndsMs else { return cell.label.isEmpty ? title : cell.label }
        let label = "\(moment(ends)) 前"
        return cell.upcoming ? label + " · " + DisplayTime.string(date(ends), "EEE") : label
    }

    /// `10/10 12:00`, on the display clock.
    private static func moment(_ ms: Int64) -> String {
        DisplayTime.string(date(ms), "M/d HH:mm")
    }

    private static func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
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
