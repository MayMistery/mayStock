import Foundation
import MayStockKit

/// How every screen words the account reading: where a figure came from, how
/// old it may get before it is called stale, and what a window's result is
/// made of. Written once, so the panel, the overview and the checkup cannot
/// describe the same figure two ways.
extension AppState {

    /// What the live layer is told about a venue's account.
    enum LiveAccountHandoff {
        /// A reading, which carries its own document.
        case reading(AccountReading)
        /// The latest read failed: the last reading stays, labelled.
        case failed(String)
        /// Nothing read before may be shown — a logout, a switch of account.
        case cleared(String?)
    }

    /// Hand a venue's account reading to the live layer, for a venue the
    /// layer does not read itself (`Venue.liveAccountTopic`): the same
    /// reading every other screen shows, so the checkup's figures are this
    /// one reading's rather than a second read on a clock of its own.
    func handAccountToLiveLayer(_ venue: Venue, _ handoff: LiveAccountHandoff) {
        guard let liveLayer, let topic = venue.liveAccountTopic else { return }
        let payload: String
        switch handoff {
        case .reading(let reading):
            guard let document = reading.liveDocument else {
                Log.warn("live: \(venue.displayName)的账户读数没有带给实时层的文档，体检里不会更新")
                return
            }
            payload = document.payload
        case .failed(let why):
            payload = Self.json(["error": why])
        case .cleared(let reason):
            payload = Self.json(["cleared": reason ?? "账户读数已清空"])
        }
        do {
            try liveLayer.ingest(topic: topic, payload: payload)
        } catch {
            Log.warn("live: 把\(venue.displayName)账户读数交给实时层失败：\(error)")
        }
    }

    /// What the live layer is told about a venue's working orders.
    enum LiveOrdersHandoff {
        case read([ExchangeOpenOrder])
        case failed(String)
    }

    /// Hand the working orders just read to the live layer, for a venue
    /// whose orders it does not read itself: the checkup lists a holding's
    /// stops from the same listing the overview shows.
    func handOrdersToLiveLayer(_ venue: Venue, _ handoff: LiveOrdersHandoff) {
        guard let liveLayer, let topic = venue.liveOrdersTopic else { return }
        let payload: String
        switch handoff {
        case .read(let orders):
            let rows: [[String: Any]] = orders.map { order in
                var row: [String: Any] = [
                    "id": order.id, "instId": order.instId, "ordType": order.ordType, "side": order.side.rawValue,
                    "filledSize": order.filledSize, "state": order.state, "reduceOnly": order.reduceOnly,
                ]
                if let price = order.price { row["price"] = price }
                if let stop = order.stopTriggerPrice ?? order.triggerPrice { row["stopPrice"] = stop }
                if let size = order.size { row["size"] = size }
                return row
            }
            let object: [String: Any] = ["orders": rows]
            payload = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        case .failed(let why):
            payload = Self.json(["error": why])
        }
        do {
            try liveLayer.ingest(topic: topic, payload: payload)
        } catch {
            Log.warn("live: 把\(venue.displayName)挂单交给实时层失败：\(error)")
        }
    }

    private static func json(_ object: [String: String]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Past this, a venue's equity reads amber: the age its reading carries
    /// (`VenueBooks.equityStaleAfter`) — a few intervals of whatever renews
    /// it, the marks' stream, the REST fallback or the poll, by the one rule
    /// the kernel ages its own feeds by. Zero before there is a reading.
    func equityStaleAfter(for venue: Venue) -> TimeInterval {
        books(for: venue).equityStaleAfter ?? 0
    }

    /// Where a venue's account figures come from, in a few words.
    func valuationSourceText(for venue: Venue) -> String {
        switch books(for: venue).accountSource {
        case .stream: return "实时 · 标记价重估"
        case .fallback: return "推送中断 · REST 兜底"
        case .polled: return "定时读取"
        case nil: return "未读到"
        }
    }

    /// The same, spelled out for a tooltip.
    func valuationHelp(for venue: Venue) -> String {
        switch books(for: venue).accountSource {
        case .stream:
            return "来源：交易所账户推送（每 2 秒一份快照，成交、划转即时推送），每个持仓在它的实时标记价上按交易所的公式重估，与 OKX App 同口径。"
        case .fallback:
            // Two fallbacks: the CLI behind the stream's document, and the
            // REST read when that document is not current either.
            let every = books(for: venue).isStreamed ? LiveAccountFeed.fallbackInterval : polledAccountInterval(for: venue)
            return "来源：账户推送中断，改由 REST 每 \(Int(every)) 秒读一次；推送恢复后自动切回。"
        case .polled:
            return "来源：\(venue.displayName)没有账户推送，直接读\(venue.displayName)自己的估值："
                + "账户里有随行情变动的持仓时每 \(Int(AccountReading.pricedPollInterval)) 秒一次，只有现金时每 \(Int(AccountReading.cashPollInterval)) 秒一次"
                + "（现在每 \(Int(polledAccountInterval(for: venue))) 秒）。"
        case nil:
            return books(for: venue).accountError.map { "还没有读到账户：\($0)" } ?? "还没有读到账户。"
        }
    }

    /// What the equity figure is, for its tooltip.
    func equityHelp(for venue: Venue) -> String {
        let books = books(for: venue)
        guard let snapshot = books.accountSnapshot else { return valuationHelp(for: venue) }
        var lines = [valuationHelp(for: venue)]
        if let equity = snapshot.displayEquity(in: venue.quoteCurrency), equity.currency != snapshot.equityCurrency,
           let total = snapshot.totalEquity, let rate = snapshot.usdRate(for: equity.currency) {
            lines.append("交易所给的总权益是 \(PriceFormatter.money(total)) \(snapshot.equityCurrency)，"
                         + "按同一次读数里的汇率 \(PriceFormatter.decimals(rate, 5)) 折成 \(equity.currency)。")
        } else if snapshot.displayEquity(in: venue.quoteCurrency)?.currency != venue.quoteCurrency {
            lines.append("这次读数没有给出 \(venue.quoteCurrency) 的汇率，按交易所给的 \(snapshot.equityCurrency) 显示。")
        }
        if let account = books.liveAccount, let equity = account.equity, !equity.unmarked.isEmpty {
            lines.append("以下币种的浮动盈亏按最近一次推送，没有实时重估：" + equity.unmarked.joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }

    /// How one position was valued, for its tooltip.
    static func positionValuationHelp(_ position: ExchangePosition) -> String {
        var parts: [String] = []
        if let mark = position.markPrice {
            parts.append("标记价 \(PriceFormatter.auto(mark))" + (position.isValuedLive ? "（实时推送）" : "（交易所推送）"))
        }
        if let markAt = position.markAt {
            parts.append(AgeLabel.format(Date().timeIntervalSince(markAt) * 1000) + "前")
        }
        if let ratio = position.unrealisedRatio {
            parts.append("收益率 \(PriceFormatter.signedPercent(ratio * 100))（交易所口径：浮盈 ÷ 开仓保证金）")
        }
        if let note = position.valuationNote { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    /// What the transfer bills since `start` were taken as, where that is
    /// worth saying: income counted in, movements the rule does not name
    /// left out, a listing that did not reach back far enough.
    private func transferNotes(on venue: Venue, since start: Date) -> [String] {
        guard let listing = books(for: venue).transfers else { return [] }
        let items = listing.items.filter { $0.at > start }
        var notes: [String] = []
        let income = items.filter { $0.kind == .income }
        if !income.isEmpty {
            let sum = income.reduce(0) { $0 + $1.amount }
            notes.append("其中自动赚币等收益 \(PriceFormatter.signedMoney(sum, decimals: 4))（\(income.count) 笔，记作盈亏，不当划转扣除）")
        }
        let unknown = items.filter { $0.kind == .unrecognised }
        if !unknown.isEmpty {
            let types = Set(unknown.map { $0.venueType ?? "未标" }).sorted().joined(separator: "、")
            notes.append("* 有 \(unknown.count) 笔未识别类型（\(types)）的资金变动，按转入转出处理"
                         + (unknown.contains { $0.amount == 0 } ? "；其中无法估值的按 0 计" : ""))
        }
        if !listing.complete {
            notes.append("* 划转记录没翻到起点，更早的划转没扣除")
        }
        if let error = books(for: venue).transfersError {
            notes.append("* 最近一次读取划转失败（用的是上一次读到的）：\(error)")
        }
        return notes
    }

    /// What a window's result is made of, for its tooltip: the rule, the two
    /// ends, the transfers left out, the caveats, and — where the venue keeps
    /// a bill ledger — how much of it was realised.
    func periodHelp(_ window: EquityWindow, venue: Venue) -> String {
        let label = window.longLabel(for: venue)
        guard let change = equityChange(window, venue: venue) else {
            return "\(label)：还没有任何权益采样"
        }
        let unit = equityCurrency(for: venue)
        var lines = [
            "\(label) · 当前权益 − 起点权益 − 期间净划入（与 OKX App「今日盈亏」同口径，含浮动盈亏）",
            "\(PriceFormatter.money(change.startEquity)) → \(PriceFormatter.money(change.endEquity)) \(unit)",
        ]
        if !change.transfersNote.isEmpty { lines.append(change.transfersNote) }
        lines += transferNotes(on: venue, since: change.referenceTs)
        if !transfersKnown(on: venue) {
            lines.append("* 还没读到\(venue.displayName)的划转记录：期间若有转入转出，会被算进收益"
                         + (books(for: venue).transfersError.map { "（\($0)）" } ?? ""))
        }
        if !change.coverageNote.isEmpty { lines.append(change.coverageNote) }
        if let billed = billedPnL(window, venue: venue) {
            lines.append("其中已实现（\(venue.displayName)账单）：平仓 \(PriceFormatter.signedMoney(billed.closedTradePnL))"
                         + " · 资金费 \(PriceFormatter.signedMoney(billed.funding))"
                         + " · 手续费 \(PriceFormatter.signedMoney(billed.fees))"
                         + (billed.interest != 0 ? " · 利息 \(PriceFormatter.signedMoney(billed.interest))" : "")
                         + (billed.coversWindow ? "" : "（账单只翻到 \(books(for: venue).exchangeBills?.oldestBillAt.map(Format.stamp) ?? "—")）"))
        } else if venue.publishesBills {
            lines.append("已实现部分：" + (books(for: venue).billsError.map { "账单读取失败：\($0)" } ?? "等待账单"))
        }
        return lines.joined(separator: "\n")
    }
}
