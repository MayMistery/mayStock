import SwiftUI
import MayStockKit

/// The close ticket: the instrument's live book on the left, the order on the
/// right, the kernel's estimate for exactly that order against exactly that
/// book underneath it.
///
/// Laid out the way the best exchanges lay out an order panel: a ladder with
/// every level labelled from the order's point of view (对1 fills now, 同1
/// joins the queue), a click on any level to price from it, price sources by
/// level (Binance's `priceMatch`: counterparty or queue, 1st to Nth),
/// time-in-force, a size slider, and a fill estimate walked level by level.
/// Nothing is sent without a review that shows the exact request.
struct CloseTicketSheet: View {
    let appState: AppState
    let request: CloseTicketRequest
    @State private var model: CloseTicketModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.snapshotMode) private var snapshotMode

    init(appState: AppState, request: CloseTicketRequest) {
        self.init(appState: appState, model: CloseTicketModel(
            request: request, venue: appState.exchangeVenue(for: request.venue)))
    }

    /// On a model someone else drives — the snapshot renderer, which draws
    /// the form and the review without ever confirming.
    init(appState: AppState, model: CloseTicketModel) {
        self.appState = appState
        self.request = model.request
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                BookLadder(model: model)
                    .frame(width: 318)
                    .padding(.vertical, 12).padding(.leading, 16).padding(.trailing, 12)
                Divider()
                PageScroll {
                    Group {
                        switch model.stage {
                        case .editing: TicketForm(model: model, appState: appState)
                        case .reviewing(let plan): ReviewPanel(model: model, plan: plan)
                        case .sending(let plan): OutcomePanel(model: model, appState: appState, plan: plan, outcome: .sending)
                        case .sent(let plan, let id, let elapsed):
                            OutcomePanel(model: model, appState: appState, plan: plan, outcome: .sent(id, elapsed))
                        case .failed(let plan, let failure):
                            OutcomePanel(model: model, appState: appState, plan: plan, outcome: .failed(failure))
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        // Unscrolled at its own height when drawn for a snapshot: a scroll
        // view whose content overflows captures black.
        .frame(width: 960, height: snapshotMode ? nil : 700)
        .task {
            guard !snapshotMode else { return }
            await model.open()
        }
        .onDisappear { if !snapshotMode { model.close() } }
    }

    private var blocker: String? { appState.closeTicketBlocker(request) }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let holding = model.holding {
                Badge(text: holding.isLong ? "多" : "空", tint: Theme.trend(holding.isLong), filled: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.holding?.actionLabel ?? "平仓").font(Theme.Text.title)
                    Text(request.instId).font(.system(size: 15, weight: .medium).monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(holdingLine).font(Theme.Text.secondary).foregroundStyle(.secondary).numeric()
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            BookStatus(book: model.book, error: model.bookError)
            ModeBadge(mode: request.mode, filled: request.mode == .live)
        }
    }

    private var holdingLine: String {
        guard let holding = model.holding else {
            return model.holdingNote ?? (model.isLoading ? "读取持仓中…" : "\(request.venue.displayName) · \(request.instId)")
        }
        let spec = model.book?.spec
        var parts = ["\(request.venue.displayName)", "持仓 \(TicketFormat.quantity(holding.quantity)) \(holding.unit)"]
        if let value = spec?.contractValue, holding.family.isDerivative, let ccy = spec?.ctValCcy, !ccy.isEmpty {
            parts[1] += "（≈\(TicketFormat.quantity(holding.quantity * value)) \(ccy)）"
        }
        if let mode = holding.marginMode { parts.append(MarginMode(rawValue: mode)?.displayName ?? mode) }
        if let leg = holding.posSide, leg != .net { parts.append(leg == .long ? "多仓腿" : "空仓腿") }
        let decimals = spec?.priceDecimals
        if let average = holding.averagePrice { parts.append("均价 " + TicketFormat.price(average, decimals: decimals)) }
        if let liquidation = holding.liquidationPrice, liquidation > 0 {
            parts.append("强平 " + TicketFormat.price(liquidation, decimals: decimals))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let blocker {
                Label(blocker, systemImage: "lock.fill")
                    .font(Theme.Text.secondary).foregroundStyle(Theme.warning).lineLimit(2)
            } else if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Text.secondary).foregroundStyle(Theme.down).lineLimit(3)
                    .textSelection(.enabled)
            } else if let readAt = model.readAt {
                Text("持仓与挂单读于 \(Format.clock(readAt))")
                    .font(Theme.Text.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            switch model.stage {
            case .editing:
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await model.review() }
                } label: {
                    Text(reviewTitle).frame(minWidth: 150)
                }
                .buttonStyle(ProminentButtonStyle(tint: tint))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(blocker != nil || !canReview)
            case .reviewing:
                Button("返回修改") { model.backToEditing() }.keyboardShortcut(.cancelAction)
                ConfirmButton(model: model, blocker: blocker, liveUnlocked: appState.liveTradingUnlocked, tint: tint)
            case .sending:
                ProgressView().controlSize(.small)
                Text("发送中…").font(Theme.Text.secondary).foregroundStyle(.secondary)
            case .sent, .failed:
                Button("再下一张") { model.backToEditing() }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private var tint: Color {
        request.mode == .live ? Theme.down : Theme.trend(model.holding?.closingSide == .buy)
    }

    private var canReview: Bool {
        if case .success = model.preview { return true }
        return false
    }

    private var reviewTitle: String {
        if model.isLoading && model.holding == nil { return "读取中…" }
        return "复核 · \(model.holding?.actionLabel ?? "平仓")  ⌘↩"
    }
}

// MARK: - Header pieces

/// The book's state, and how old its last frame is.
private struct BookStatus: View {
    let book: BookDocument?
    let error: String?

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color)
            Text(label).font(Theme.Text.caption).foregroundStyle(.secondary)
            if let ms = book?.exchangeMs, book?.isLive == true {
                AgeLabel(ms: ms, offsetMs: 0, staleAfterMs: 3_000)
            }
        }
        .help(help)
    }

    private var color: Color {
        guard let book else { return error == nil ? .secondary : Theme.down }
        switch book.state {
        case "live": return Theme.up
        case "syncing", "connecting": return Theme.warning
        default: return Theme.down
        }
    }

    private var label: String {
        guard let book else { return error == nil ? "盘口连接中" : "盘口不可用" }
        switch book.state {
        case "live": return book.sizesKnown ? "盘口实时" : "报价实时"
        case "syncing": return "等待快照"
        case "connecting": return "连接中"
        case "refused": return "被拒绝"
        default: return "重连中"
        }
    }

    private var help: String {
        var lines: [String] = []
        if let error { lines.append(error) }
        if let detail = book?.detail { lines.append(detail) }
        if let stats = book?.stats {
            lines.append("增量 \(stats.updates) · 最优报价 \(stats.tops) · 重建 \(stats.resyncs) 次")
            if let why = stats.lastResync { lines.append("上次重建：\(why)") }
        }
        if let seq = book?.seqId { lines.append("seqId \(seq)") }
        if book?.sizesKnown == false { lines.append("这个交易所只给一档报价，不给挂单量") }
        return lines.isEmpty ? "OKX books（400 档，100ms）+ bbo-tbt（10ms），按 seqId 合并" : lines.joined(separator: "\n")
    }
}

// MARK: - The ladder

/// The live book, best prices in the middle, every level labelled from the
/// order's side: 对N fills against it, 同N joins it. A click prices the order
/// at that level.
private struct BookLadder: View {
    let model: CloseTicketModel
    @Environment(\.snapshotMode) private var snapshotMode

    /// Levels drawn each side: enough to show the one chosen.
    private var depth: Int {
        let chosen = model.priceSource.takesLevel ? model.level : 0
        return min(max(12, chosen), BookLadder.maxDepth)
    }

    static let maxDepth = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("盘口").font(Theme.Text.heading)
                Spacer()
                if let spread = spreadText {
                    Text(spread).font(Theme.Text.caption).foregroundStyle(.secondary).numeric()
                }
            }
            LadderHeader()
            if let book = model.book, !(book.asks.isEmpty && book.bids.isEmpty) {
                ladder(book)
            } else {
                EmptyState(icon: "chart.bar.doc.horizontal", title: "等待盘口",
                           message: model.bookError ?? model.book?.detail ?? "正在连接交易所的盘口推送")
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var spreadText: String? {
        guard let book = model.book, let bid = book.bestBid, let ask = book.bestAsk, let mid = book.mid, mid > 0 else { return nil }
        let decimals = book.spec?.priceDecimals
        return "价差 \(TicketFormat.price(ask - bid, decimals: decimals)) · \(PriceFormatter.decimals((ask - bid) / mid * 1e4, 2)) bp"
    }

    /// One drawn level: where it sits, and the size from the touch to it.
    private struct Item: Identifiable {
        let ref: LevelRef
        let level: BookDocument.Level
        let cumulative: Double
        var id: LevelRef { ref }
    }

    private func items(_ levels: [BookDocument.Level], isBid: Bool) -> [Item] {
        var total = 0.0
        return levels.enumerated().map { index, level in
            total += level.size
            return Item(ref: LevelRef(isBid: isBid, index: index), level: level, cumulative: total)
        }
    }

    @ViewBuilder
    private func ladder(_ book: BookDocument) -> some View {
        let closingSell = model.holding?.closingSide != .buy
        let asks = items(Array(book.asks.prefix(depth)), isBid: false)
        let bids = items(Array(book.bids.prefix(depth)), isBid: true)
        let peak = max(asks.last?.cumulative ?? 0, bids.last?.cumulative ?? 0)
        let highlight = highlighted(closingSell: closingSell)
        let consumed = consumedLevels
        let decimals = book.spec?.priceDecimals
        let row = { (item: Item) -> LadderRow in
            // A sale's counterparty is the bids; a buy-back's is the asks.
            let counterparty = item.ref.isBid == closingSell
            return LadderRow(
                label: (counterparty ? "对" : "同") + "\(item.ref.index + 1)",
                level: item.level, cumulative: item.cumulative, peak: peak, isBid: item.ref.isBid,
                decimals: decimals, selected: highlight == item.ref,
                consumed: counterparty && item.ref.index < consumed,
                sizesKnown: book.sizesKnown
            ) { model.pick(isBid: item.ref.isBid, index: item.ref.index) }
        }
        let content = VStack(spacing: 0) {
            ForEach(asks.reversed()) { row($0) }
            MidRow(book: book, decimals: decimals).id("mid")
            ForEach(bids) { row($0) }
        }
        if snapshotMode {
            content
        } else {
            ScrollViewReader { proxy in
                ScrollView { content }
                    .onAppear { proxy.scrollTo("mid", anchor: .center) }
                    .onChange(of: depth) { proxy.scrollTo("mid", anchor: .center) }
            }
        }
    }

    /// The level the order is priced at, when it is priced from a level.
    private func highlighted(closingSell: Bool) -> LevelRef? {
        guard model.method == .limit, let level = model.input.price.level else { return nil }
        let counterparty = model.priceSource == .counterparty
        return LevelRef(isBid: counterparty == closingSell, index: level - 1)
    }

    /// How many levels the order would take on arrival, from the estimate.
    private var consumedLevels: Int {
        guard case .success(let plan) = model.preview else { return 0 }
        return plan.estimate.taker?.levels ?? 0
    }
}

/// A level by side and position from the touch.
private struct LevelRef: Hashable {
    let isBid: Bool
    let index: Int
}

private struct LadderHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("档").frame(width: 32, alignment: .leading)
            Text("价格").frame(maxWidth: .infinity, alignment: .trailing)
            Text("数量").frame(width: 76, alignment: .trailing)
            Text("累计").frame(width: 76, alignment: .trailing)
        }
        .font(Theme.Text.caption).foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
    }
}

private struct LadderRow: View {
    let label: String
    let level: BookDocument.Level
    let cumulative: Double
    let peak: Double
    let isBid: Bool
    let decimals: Int?
    let selected: Bool
    let consumed: Bool
    let sizesKnown: Bool
    let onPick: () -> Void

    var body: some View {
        let tint = Theme.trend(isBid)
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 10, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 32, alignment: .leading)
            Text(TicketFormat.grouped(level.px, decimals: decimals))
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(sizesKnown ? TicketFormat.size(level.size) : "—")
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 76, alignment: .trailing)
            Text(sizesKnown ? TicketFormat.size(cumulative) : "—")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 19)
        .background(alignment: .trailing) {
            GeometryReader { geometry in
                let share = peak > 0 && sizesKnown ? min(cumulative / peak, 1) : 0
                tint.opacity(0.10)
                    .frame(width: geometry.size.width * share)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .background(consumed ? Color.accentColor.opacity(0.10) : Color.clear)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
        .help("按\(label.hasPrefix("对") ? "对手价" : "同向价")第 \(label.dropFirst()) 档下单：\(level.px)"
              + (level.orders > 0 ? "（\(level.orders) 笔挂单）" : ""))
    }
}

private struct MidRow: View {
    let book: BookDocument
    let decimals: Int?

    var body: some View {
        HStack(spacing: 8) {
            if let last = book.lastPrice {
                Text(TicketFormat.price(last, decimals: decimals))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                Text("最新").font(Theme.Text.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if let mid = book.mid {
                Text("中间价 " + TicketFormat.price(mid, decimals: decimals.map { $0 + 1 }))
                    .font(Theme.Text.caption).foregroundStyle(.secondary).numeric()
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(Theme.rowFill)
    }
}

// MARK: - The form

private struct TicketForm: View {
    @Bindable var model: CloseTicketModel
    let appState: AppState

    var body: some View {
        let capabilities = model.capabilities
        VStack(alignment: .leading, spacing: 16) {
            PillSegments(
                segments: CloseMethod.allCases.map { method in
                    let availability = capabilities.availability(of: method)
                    return .init(value: method, title: method.displayName,
                                 help: availability.reason ?? method.displayName, enabled: availability.available)
                },
                selection: model.method, size: 12
            ) { model.method = $0 }

            if let reason = capabilities.availability(of: model.method).reason {
                InlineNotice(kind: .warning, message: reason)
            }

            switch model.method {
            case .limit: LimitFields(model: model, capabilities: capabilities)
            case .chase: ChaseFields(model: model)
            case .market:
                InlineNotice(kind: .info, message: "市价单按对手盘逐档吃单，直到成交完。下面的预估按当前盘口逐档算出。")
            case .protect: ProtectFields(model: model, capabilities: capabilities)
            }

            SizeFields(model: model)
            EstimateCard(model: model)
            WorkingOrdersCard(model: model, appState: appState)
        }
    }
}

/// A labelled row of the form.
private struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Theme.Text.secondary).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            content()
        }
    }
}

private struct LimitFields: View {
    @Bindable var model: CloseTicketModel
    let capabilities: CloseCapabilities

    static let quickLevels = [1, 2, 3, 5, 10, 20]

    var body: some View {
        let depth = min(capabilities.bookDepth, BookLadder.maxDepth)
        VStack(alignment: .leading, spacing: 12) {
            FieldRow(label: "价格来源") {
                PillSegments(
                    segments: ClosePriceSourceKind.allCases.map { kind in
                        .init(value: kind, title: kind.displayName, help: help(kind),
                              enabled: capabilities.priceSources.contains(kind))
                    },
                    selection: model.priceSource
                ) { model.priceSource = $0 }
            }
            if model.priceSource.takesLevel {
                FieldRow(label: "档位") {
                    HStack(spacing: 8) {
                        PillSegments(
                            segments: Self.quickLevels.map { level in
                                .init(value: level, title: "\(level)", help: "第 \(level) 档", enabled: level <= depth)
                            },
                            selection: model.level
                        ) { model.level = $0 }
                        Stepper(value: $model.level, in: 1...max(depth, 1)) {
                            Text("第 \(model.level) 档").font(Theme.Text.secondary).numeric()
                        }
                        .fixedSize()
                    }
                }
            }
            FieldRow(label: "价格") { priceField }
            FieldRow(label: "有效方式") {
                VStack(alignment: .leading, spacing: 4) {
                    PillSegments(
                        segments: TradeOrderKind.allCases.filter { $0 != .market }.map { kind in
                            .init(value: kind, title: kind == .limit ? "GTC 限价" : kind.displayName,
                                  help: kind.explanation, enabled: capabilities.limitKinds.contains(kind))
                        },
                        selection: model.limitKind
                    ) { model.limitKind = $0 }
                    Text(model.limitKind.explanation).font(Theme.Text.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var priceField: some View {
        let decimals = model.book?.spec?.priceDecimals
        if model.priceSource == .fixed {
            HStack(spacing: 8) {
                TextField("限价", text: $model.fixedPriceText)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13).monospacedDigit())
                    .multilineTextAlignment(.trailing).frame(width: 150)
                Text(quoteUnit).font(Theme.Text.secondary).foregroundStyle(.secondary)
                if let tick = model.book?.spec?.tickSz {
                    Text("最小变动 \(tick)").font(Theme.Text.caption).foregroundStyle(.tertiary)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if case .success(let plan) = model.preview, let price = plan.price {
                    Text(TicketFormat.price(price.value, decimals: decimals))
                        .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(quoteUnit).font(Theme.Text.secondary).foregroundStyle(.secondary)
                    Text("跟随盘口").font(Theme.Text.caption).foregroundStyle(.tertiary)
                    Button("改为固定价") { model.copyResolvedPrice() }
                        .controlSize(.small).buttonStyle(.borderless)
                } else {
                    Text("—").font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var quoteUnit: String {
        let spec = model.book?.spec
        if model.holding?.family == .option { return spec?.settleCcy ?? "" }
        if let quote = spec?.quoteCcy, !quote.isEmpty { return quote }
        return model.request.instId.split(separator: "-").dropFirst().first.map(String.init) ?? ""
    }

    private func help(_ kind: ClosePriceSourceKind) -> String {
        let sell = model.holding?.closingSide != .buy
        switch kind {
        case .counterparty: return "对手盘第 N 档（\(sell ? "买" : "卖")盘）：挂到这个价，会立即吃掉 1 到 N 档"
        case .queue: return "同向第 N 档（\(sell ? "卖" : "买")盘）：挂在这个价排队，等对手来成交"
        case .mid: return "买一和卖一的中间，按最小变动单位取整到对自己有利的一侧"
        case .last: return "最近一笔成交的价格"
        case .fixed: return "自己填一个价格，按最小变动单位取整到对自己有利的一侧"
        }
    }
}

private struct ChaseFields: View {
    @Bindable var model: CloseTicketModel

    static let quick = [0.1, 0.2, 0.5, 1.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldRow(label: "最大追价") {
                HStack(spacing: 8) {
                    TextField("0.2", text: $model.maxChaseText)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13).monospacedDigit())
                        .multilineTextAlignment(.trailing).frame(width: 80)
                    Text("%").foregroundStyle(.secondary)
                    PillSegments(
                        segments: Self.quick.map { .init(value: $0, title: PriceFormatter.plain($0) + "%") },
                        selection: CloseTicketModel.number(model.maxChaseText) ?? -1
                    ) { model.maxChaseText = PriceFormatter.plain($0) }
                }
            }
            Text("交易所代为挂在同向第 1 档只做 Maker，每秒跟一次盘口；盘口离开起点超过这个比例就撤单，已成交部分保留。")
                .font(Theme.Text.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProtectFields: View {
    @Bindable var model: CloseTicketModel
    let capabilities: CloseCapabilities

    static let steps = [1.0, 2.0, 5.0, 10.0]

    var body: some View {
        let reference = model.book?.lastPrice ?? model.book?.mid
        let isLong = model.holding?.isLong ?? true
        VStack(alignment: .leading, spacing: 12) {
            leg("止盈", text: $model.takeProfitText, availability: capabilities.takeProfit,
                reference: reference, direction: isLong ? 1 : -1)
            leg("止损", text: $model.stopLossText, availability: capabilities.stopLoss,
                reference: reference, direction: isLong ? -1 : 1)
            Text("按最新成交价触发，触发后市价成交；两边都填是 OCO，一边触发另一边自动撤销。")
                .font(Theme.Text.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func leg(_ label: String, text: Binding<String>, availability: CloseAvailability,
                     reference: Double?, direction: Double) -> some View {
        FieldRow(label: label) {
            if availability.available {
                HStack(spacing: 8) {
                    TextField("触发价", text: text)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13).monospacedDigit())
                        .multilineTextAlignment(.trailing).frame(width: 130)
                    if let reference {
                        ForEach(Self.steps, id: \.self) { step in
                            Button("\(direction > 0 ? "+" : "−")\(PriceFormatter.plain(step))%") {
                                let tick = model.book?.spec?.tick ?? 0
                                let raw = reference * (1 + direction * step / 100)
                                let snapped = tick > 0 ? (raw / tick).rounded() * tick : raw
                                text.wrappedValue = PriceFormatter.wire(snapped)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } else {
                Text(availability.reason ?? "不可用").font(Theme.Text.secondary).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SizeFields: View {
    @Bindable var model: CloseTicketModel

    var body: some View {
        let unit = model.holding?.unit ?? ""
        VStack(alignment: .leading, spacing: 8) {
            FieldRow(label: "数量") {
                HStack(spacing: 8) {
                    TextField("数量", text: Binding(get: { model.sizeText }, set: { model.editSize($0) }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 13).monospacedDigit())
                        .multilineTextAlignment(.trailing).frame(width: 150)
                    Text(unit).font(Theme.Text.secondary).foregroundStyle(.secondary)
                    if let base = baseText { Text(base).font(Theme.Text.caption).foregroundStyle(.tertiary) }
                    if model.sizeIsAll {
                        Badge(text: "全部", tint: .accentColor, size: .small)
                            .help("复核时按那一刻交易所上的持仓全部平掉")
                    }
                }
            }
            FieldRow(label: "") {
                HStack(spacing: 10) {
                    // Continuous: each position is floored to the lot as it is set.
                    Slider(value: Binding(get: { model.fraction }, set: { model.useFraction($0) }), in: 0...1)
                        .frame(width: 220)
                    ForEach([0.25, 0.5, 0.75], id: \.self) { share in
                        Button(PriceFormatter.percent(share * 100)) { model.useFraction(share) }.controlSize(.small)
                    }
                    Button("全部") { model.useFraction(1) }.controlSize(.small)
                }
            }
        }
    }

    private var baseText: String? {
        guard let spec = model.book?.spec, let value = spec.contractValue, model.holding?.family.isDerivative == true,
              let size = CloseTicketModel.number(model.sizeText), !spec.ctValCcy.isEmpty else { return nil }
        return "≈ \(TicketFormat.quantity(size * value)) \(spec.ctValCcy)"
    }
}

// MARK: - Estimate

private struct EstimateCard: View {
    let model: CloseTicketModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("预估").font(Theme.Text.heading)
                Spacer()
                if let seq = model.book?.seqId {
                    Text("按盘口 seq \(seq)").font(Theme.Text.caption).foregroundStyle(.tertiary).numeric()
                }
            }
            switch model.preview {
            case .none:
                Text(model.holding == nil ? (model.holdingNote ?? "读取持仓中…") : "等待盘口…")
                    .font(Theme.Text.secondary).foregroundStyle(.secondary)
            case .failure(let refusal):
                Label(refusal.message, systemImage: "xmark.octagon.fill")
                    .font(Theme.Text.secondary).foregroundStyle(Theme.down)
                    .fixedSize(horizontal: false, vertical: true)
            case .success(let plan):
                EstimateRows(plan: plan, decimals: model.book?.spec?.priceDecimals, unit: model.holding?.unit ?? "")
                if let note = model.feesNote {
                    Text(note).font(Theme.Text.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .cardStyle(padding: 12)
    }
}

private struct EstimateRows: View {
    let plan: ClosePlan
    let decimals: Int?
    let unit: String

    var body: some View {
        let estimate = plan.estimate
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            if let fill = estimate.taker {
                row("立即成交", "\(TicketFormat.quantity(fill.size)) \(unit) · 均价 \(price(fill.average)) · 吃 \(fill.levels) 档 · 最差 \(price(fill.worst))")
            }
            if let resting = estimate.maker {
                row("挂单", "\(TicketFormat.quantity(resting.size)) \(unit) @ \(price(resting.price))，成交前一直挂着")
            }
            if estimate.cancelled > 0 {
                row("撤销", "\(TicketFormat.quantity(estimate.cancelled)) \(unit)（这个价以内没有对手）", tint: Theme.warning)
            }
            if estimate.beyondBook > 0 {
                row("超出盘口", "\(TicketFormat.quantity(estimate.beyondBook)) \(unit) 在可见档位之外成交", tint: Theme.warning)
            }
            if let slip = estimate.slippageBps, let mid = estimate.mid {
                row("滑点", "\(PriceFormatter.decimals(slip, 1)) bp（相对中间价 \(price(mid))）",
                    tint: slip > 20 ? Theme.warning : .primary)
            }
            ForEach(estimate.legs, id: \.label) { leg in
                row(leg.label, "触发 \(price(leg.trigger))"
                    + (leg.distancePct.map { "（距现价 \(PriceFormatter.signedPercent($0))）" } ?? "")
                    + (leg.pnl.map { " → 盈亏 \($0.text)" } ?? ""),
                    tint: leg.pnl.map { Theme.signed($0.amount) } ?? .primary)
            }
            if let notional = estimate.notional {
                row("成交额", "≈ \(notional.text)")
            }
            if let fee = estimate.fee {
                row("手续费", "≈ \(fee.text)" + (estimate.feeBasis.map { "（\($0)）" } ?? ""))
            }
            if let pnl = estimate.pnl {
                row("实现盈亏", "≈ \(pnl.text)" + (estimate.netPnl.map { "，扣手续费 \($0.text)" } ?? ""),
                    tint: Theme.signed(pnl.amount))
            }
            if plan.remainder > 0 {
                row("余下", "\(TicketFormat.quantity(plan.remainder)) \(unit) 不足一手，留在账户里", tint: .secondary)
            }
        }
        .font(Theme.Text.secondary).numeric()
    }

    private func row(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func price(_ value: Double) -> String { TicketFormat.price(value, decimals: decimals) }
}

// MARK: - Working orders

private struct WorkingOrdersCard: View {
    let model: CloseTicketModel
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("这个标的上的挂单与条件单").font(Theme.Text.heading)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.mini) }
            }
            if let error = model.workingError {
                InlineNotice(kind: .warning, message: "读不到挂单：\(error)")
            } else if let listing = model.working {
                if !listing.unavailable.isEmpty {
                    Text("未能读取：" + listing.unavailable.joined(separator: "、"))
                        .font(Theme.Text.caption).foregroundStyle(Theme.warning)
                }
                if listing.orders.isEmpty {
                    Text("没有").font(Theme.Text.secondary).foregroundStyle(.tertiary)
                }
                ForEach(listing.orders) { order in
                    HStack(spacing: 8) {
                        Text(OrderLabels.direction(order)).foregroundStyle(Theme.trend(order.side == .buy))
                        Text(order.kindLabel).foregroundStyle(.secondary)
                        Text(OrderLabels.size(order)).numeric()
                        let decimals = model.book?.spec?.priceDecimals
                        if let price = order.price { Text("@ \(TicketFormat.price(price, decimals: decimals))").numeric() }
                        if let trigger = order.stopTriggerPrice { Text("止损 \(TicketFormat.price(trigger, decimals: decimals))").numeric() }
                        if let trigger = order.takeProfitTriggerPrice { Text("止盈 \(TicketFormat.price(trigger, decimals: decimals))").numeric() }
                        Spacer()
                        Button("撤单") {
                            Task { await model.cancel(order, liveUnlocked: appState.liveTradingUnlocked) }
                        }
                        .controlSize(.small)
                        .disabled(appState.closeTicketBlocker(model.request) != nil)
                    }
                    .font(Theme.Text.secondary)
                }
            }
        }
    }
}

// MARK: - Review

private struct ReviewPanel: View {
    let model: CloseTicketModel
    let plan: ClosePlan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("复核").font(Theme.Text.heading)
            Text(plan.review.headline)
                .font(.system(size: 15, weight: .semibold)).numeric()
                .fixedSize(horizontal: false, vertical: true)
            ForEach(plan.review.warnings, id: \.self) { warning in
                InlineNotice(kind: model.request.mode == .live && warning.contains("实盘") ? .danger : .warning, message: warning)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(plan.review.lines, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("·").foregroundStyle(.tertiary)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(Theme.Text.secondary).numeric()
            DriftLine(model: model, plan: plan)
            if let wire = plan.wire {
                VStack(alignment: .leading, spacing: 6) {
                    Text("将要发送的请求").font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                    Text("\(wire.method) \(wire.path)").font(Theme.Text.mono)
                    Text(wire.prettyBody).font(Theme.Text.monoSmall).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .rowStyle(padding: 10)
            }
        }
    }
}

/// How far the book has moved since the review priced the order.
private struct DriftLine: View {
    let model: CloseTicketModel
    let plan: ClosePlan

    var body: some View {
        if let reviewed = plan.price, case .success(let now) = model.preview, let current = now.price,
           reviewed.source == current.source, !reviewed.source.contains("自定义") {
            let delta = current.value - reviewed.value
            let decimals = model.book?.spec?.priceDecimals
            HStack(spacing: 6) {
                Image(systemName: delta == 0 ? "equal.circle" : "arrow.left.arrow.right.circle")
                Text(delta == 0
                     ? "盘口上\(current.source)仍是 \(TicketFormat.price(current.value, decimals: decimals))"
                     : "盘口在动：\(current.source)现在 \(TicketFormat.price(current.value, decimals: decimals))（复核时 \(TicketFormat.price(reviewed.value, decimals: decimals))）。确认发送的是复核时的价格；要跟上请返回修改后重新复核。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.Text.caption).foregroundStyle(delta == 0 ? Color.secondary : Theme.warning)
        }
    }
}

/// The send button, which stops accepting a review once it is too old to
/// send against.
private struct ConfirmButton: View {
    let model: CloseTicketModel
    let blocker: String?
    let liveUnlocked: Bool
    let tint: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let expired = model.reviewExpired
            Button {
                if expired {
                    Task { await model.review() }
                } else {
                    Task { await model.confirm(liveUnlocked: liveUnlocked) }
                }
            } label: {
                Text(expired ? "复核已过 \(Int(model.reviewLifetime)) 秒，重新复核"
                     : (model.request.mode == .live ? "确认发送 · 实盘  ⌘↩" : "确认发送  ⌘↩"))
                    .frame(minWidth: 170)
            }
            .buttonStyle(ProminentButtonStyle(tint: expired ? Theme.warning : tint))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(blocker != nil)
        }
    }
}

// MARK: - After sending

private struct OutcomePanel: View {
    enum Outcome {
        case sending
        case sent(String, Int)
        case failed(CloseTicketModel.Failure)
    }

    let model: CloseTicketModel
    let appState: AppState
    let plan: ClosePlan
    let outcome: Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch outcome {
            case .sending:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在发送：\(plan.review.headline)").font(Theme.Text.body)
                }
            case .sent(let id, let elapsed):
                InlineNotice(
                    kind: .success, title: "已提交",
                    message: plan.review.headline
                        + "\n交易所编号：\(id.isEmpty ? "未返回（下方挂单列表会显示）" : id) · 用时 \(elapsed) ms")
            case .failed(let failure):
                InlineNotice(
                    kind: failure.outcomeUnknown ? .warning : .danger, title: "订单\(failure.title)",
                    message: [failure.advice, failure.detail].compactMap { $0 }.joined(separator: "\n\n"))
            }
            WorkingOrdersCard(model: model, appState: appState)
        }
    }
}

// MARK: - Formatting

/// Formats for the ticket, cheap enough for a ladder redrawn ten times a
/// second: prices are the exchange's own text, grouped; no formatter object
/// is created per cell.
enum TicketFormat {
    /// "83606.1" at two decimals → "83,606.10".
    static func grouped(_ text: String, decimals: Int?) -> String {
        let (whole, fraction) = text.split(separator: ".", maxSplits: 1).map(String.init).splitPair
        var out = ""
        for (index, character) in whole.enumerated() {
            if index > 0, (whole.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        var digits = fraction
        if let decimals {
            if digits.count < decimals { digits += String(repeating: "0", count: decimals - digits.count) }
        }
        return digits.isEmpty ? out : out + "." + digits
    }

    static func price(_ value: Double, decimals: Int?) -> String {
        guard value.isFinite else { return "—" }
        let places = decimals ?? PriceFormatter.autoDecimals(for: value)
        return grouped(PriceFormatter.decimals(value, places), decimals: places)
    }

    /// Sizes with up to four decimals, compact above ten thousand.
    static func size(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value >= 10_000 { return PriceFormatter.compact(value) }
        let text = PriceFormatter.decimals(value, value >= 100 ? 1 : (value >= 1 ? 2 : 4))
        var trimmed = text
        if trimmed.contains(".") {
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
        }
        return trimmed
    }

    /// A quantity exactly, never rounded: a holding of 0.0408135 is not
    /// shown as 0.040814, which is more than is held.
    static func quantity(_ value: Double) -> String {
        PriceFormatter.wire(value)
    }
}

private extension Array where Element == String {
    var splitPair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}

// MARK: - The door

/// The door to the close ticket, wherever a holding is listed. Opens the
/// ticket; never sends anything itself.
struct CloseHoldingButton: View {
    let appState: AppState
    let request: CloseTicketRequest
    var title = "平仓"

    var body: some View {
        Button(title) { appState.openCloseTicket(request) }
            .controlSize(.mini)
            .help("限价（对手价/同向价任意档）、追逐限价、市价或止盈止损——下单前先复核")
    }
}
