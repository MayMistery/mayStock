import Foundation

/// The close ticket behind the screen.
///
/// Holds the instrument's live book while the ticket is open, reads the
/// holding, the account, the fees and the working orders, and asks the
/// kernel for a plan whenever what is typed or the book changes — so every
/// estimate on screen is the kernel's answer for the book as drawn.
///
/// Two reads of the holding, on purpose: one when the ticket opens, so the
/// form starts from the real holding, and one when the person asks to
/// review, because a close sized from the first read may be a close of
/// something no longer there. The review freezes one plan, with the client
/// id it will be sent under; `confirm` sends exactly that plan and nothing
/// else.
@Observable
@MainActor
public final class CloseTicketModel {

    /// A failed order, in words that say what is now true.
    public struct Failure: Equatable, Sendable {
        public let title: String
        public let detail: String
        public let advice: String?
        /// The order may have been acted on; nothing about it is known yet.
        public let outcomeUnknown: Bool
    }

    public enum Stage: Equatable {
        case editing
        /// The plan as it will be sent, for a yes or a no.
        case reviewing(ClosePlan)
        case sending(ClosePlan)
        /// Sent; the venue's id for it, empty when it gave none.
        case sent(ClosePlan, id: String, elapsedMs: Int)
        case failed(ClosePlan, Failure)
    }

    /// Strategy id the ticket's orders are tagged under: a digest no
    /// strategy has, so a manual close is never booked to one.
    public static let manualTag = "manual"
    /// How often the book is read while the ticket is open. The kernel's
    /// book moves every 100 ms at most; the ticket follows it at that pace.
    public static let bookInterval: Duration = .milliseconds(100)
    /// A review older than this is confirmed only after reviewing again:
    /// the book it was priced from is too old to send against.
    public static let defaultReviewLifetime: TimeInterval = 60

    public let request: CloseTicketRequest
    private let venue: any ExchangeVenue

    // MARK: Read from the exchange

    public private(set) var holding: CloseHolding?
    /// Why there is no holding: the read failed, or nothing is held. Never
    /// both a holding and a note.
    public private(set) var holdingNote: String?
    public private(set) var book: BookDocument?
    public private(set) var bookError: String?
    /// The book's own document, exactly as the planner reads it.
    @ObservationIgnored private var bookJSON: Data?
    public private(set) var bookSeq: UInt64 = 0
    public private(set) var account: AccountTradingConfig?
    public private(set) var fees: FeeRates?
    public private(set) var feesNote: String?
    public private(set) var working: OpenOrderListing?
    public private(set) var workingError: String?
    public private(set) var readAt: Date?
    public private(set) var isLoading = false

    // MARK: Typed

    public var method: CloseMethod = .limit
    public var priceSource: ClosePriceSourceKind = .counterparty
    /// The level for a counterparty or queue price, from 1.
    public var level = 1
    public var fixedPriceText = ""
    public var limitKind: TradeOrderKind = .limit
    public var maxChaseText = PriceFormatter.plain(CloseTicketInput.defaultMaxChasePct)
    public var takeProfitText = ""
    public var stopLossText = ""
    /// The size as typed. While `sizeIsAll`, it shows the holding and means
    /// "all of it, as held when the plan is made" — a position partly closed
    /// elsewhere meanwhile is then closed in full, not refused as too large.
    public private(set) var sizeText = ""
    public private(set) var sizeIsAll = true

    public private(set) var stage: Stage = .editing
    public private(set) var reviewedAt: Date?
    public var reviewLifetime = CloseTicketModel.defaultReviewLifetime
    /// A plan that failed at review, or a cancel that failed, in words.
    public private(set) var problem: String?

    @ObservationIgnored private var feed: (any CloseBookFeed)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var planCache: (key: PlanKey, plan: Result<ClosePlan, CloseRefusal>)?
    @ObservationIgnored private var seenResyncs = 0
    @ObservationIgnored private var feesRequested = false
    @ObservationIgnored private var prefilled = false

    public init(request: CloseTicketRequest, venue: any ExchangeVenue) {
        self.request = request
        self.venue = venue
        let offered = capabilities
        if !offered.availability(of: method).available,
           let first = CloseMethod.allCases.first(where: { offered.availability(of: $0).available }) {
            method = first
        }
    }

    /// A target and a stop a few percent either side of the reference,
    /// never past liquidation — levels that plan, for the snapshot and the
    /// doctor to draw and review. Never sent.
    public static func illustrativeProtection(
        reference: Double, holding: CloseHolding, percent: Double = 3
    ) -> (takeProfit: Double, stopLoss: Double) {
        let direction = holding.isLong ? 1.0 : -1.0
        let target = reference * (1 + percent / 100 * direction)
        let stop = reference * (1 - percent / 100 * direction)
        guard let liquidation = holding.liquidationPrice, liquidation > 0 else { return (target, stop) }
        let halfway = (reference + liquidation) / 2
        return (target, abs(halfway - reference) < abs(stop - reference) ? halfway : stop)
    }

    /// What this venue can do for this family — the exchange's own filing
    /// once the holding has been read.
    public var capabilities: CloseCapabilities {
        guard let family = holding?.family ?? request.instType else {
            return .unsupportedFamily(request.filedAs, venue: request.venue)
        }
        return KernelClose.capabilities(venue: request.venue, family: family)
    }

    // MARK: Opening and closing

    /// Start the book, warm the trading connection, and read everything the
    /// ticket shows.
    public func open() async {
        if feed == nil, let family = request.instType {
            do {
                feed = try await venue.closeBook(instId: request.instId, instType: family, mode: request.mode)
                bookError = nil
            } catch {
                bookError = Self.describe(error)
            }
        }
        startPump()
        Task { [venue] in await venue.warmTrading() }
        await load()
    }

    /// Stop the book. The ticket is done with it.
    public func close() {
        pump?.cancel()
        pump = nil
        feed?.stop()
        feed = nil
    }

    /// For tests and the snapshotter: a book fed by hand.
    public func attach(_ feed: any CloseBookFeed) {
        self.feed = feed
        pullBook()
    }

    private func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                self?.pullBook()
                try? await Task.sleep(for: Self.bookInterval)
            }
        }
    }

    /// Take the book's latest document, when it has moved.
    public func pullBook() {
        guard let feed, let (seq, json) = feed.snapshot(since: bookSeq) else { return }
        bookSeq = seq
        bookJSON = json
        do {
            let document = try JSONDecoder().decode(BookDocument.self, from: json)
            book = document
            bookError = nil
            if let stats = document.stats, stats.resyncs > seenResyncs {
                seenResyncs = stats.resyncs
                Log.warn("close-ticket: 盘口 \(request.instId) 重建第 \(stats.resyncs) 次：\(stats.lastResync ?? "未给出原因")")
            }
            requestFeesIfReady(spec: document.spec)
        } catch {
            bookError = "盘口数据读不懂：\(error)"
        }
        prefillIfNeeded()
    }

    // MARK: Reading

    /// Read the holding, the account and the working orders. The form is
    /// filled in from the first successful read only; later reads never
    /// overwrite what was typed.
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        async let holdingRead = readHolding()
        async let accountRead = try? venue.accountTradingConfig(mode: request.mode)
        async let workingRead = readWorking()
        (holding, holdingNote) = await holdingRead
        account = await accountRead
        (working, workingError) = await workingRead
        readAt = Date()
        // The exchange's filing can offer less than the id suggested: keep
        // the form on a method this holding can use.
        let offered = capabilities
        if !offered.availability(of: method).available,
           let first = CloseMethod.allCases.first(where: { offered.availability(of: $0).available }) {
            method = first
        }
        prefillIfNeeded()
    }

    private func readHolding() async -> (CloseHolding?, String?) {
        switch request.holding {
        case .position(let isLong):
            do {
                let positions = try await venue.heldPositions(mode: request.mode)
                guard let position = positions.first(where: {
                    $0.instId == request.instId && $0.quantity != 0 && ($0.quantity > 0) == isLong
                }) else {
                    return (nil, "交易所上已经没有 \(request.instId) 的\(isLong ? "多" : "空")头持仓")
                }
                // The exchange's own filing, never a guess from the id.
                guard let family = request.venue.family(ofPositionFiledAs: position.instType) else {
                    return (nil, CloseCapabilities.unsupportedFamily(position.instType, venue: request.venue).market.reason)
                }
                return (CloseHolding(position: position, family: family), nil)
            } catch {
                return (nil, "读取持仓失败：\(Self.describe(error))")
            }
        case .coin(let coin):
            do {
                let available = try await venue.sellableBalance(ccy: coin, mode: request.mode)
                guard available > 0 else { return (nil, "交易账户里没有可卖的 \(coin)") }
                return (CloseHolding(coin: coin, available: available, instId: request.instId), nil)
            } catch {
                return (nil, "读取余额失败：\(Self.describe(error))")
            }
        }
    }

    private func readWorking() async -> (OpenOrderListing?, String?) {
        guard let family = holding?.family ?? request.instType else { return (nil, "不知道这个持仓属于哪个品种") }
        do {
            return (try await venue.workingOrders(instId: request.instId, instType: family, mode: request.mode), nil)
        } catch {
            return (nil, Self.describe(error))
        }
    }

    /// Fees are charged by the instrument's group, which its specification
    /// names — so they are asked for once the book has brought it.
    private func requestFeesIfReady(spec: BookDocument.Spec?) {
        guard !feesRequested, let spec, let family = holding?.family ?? request.instType else { return }
        feesRequested = true
        Task {
            do {
                fees = try await venue.feeRates(
                    instId: request.instId, instType: family,
                    groupId: spec.groupId.isEmpty ? nil : spec.groupId, mode: request.mode)
                feesNote = fees == nil ? "\(request.venue.displayName)不提供账户费率，预估不含手续费" : nil
            } catch {
                feesNote = "读不到手续费率（\(Self.describe(error))），预估不含手续费"
            }
        }
    }

    private func prefillIfNeeded() {
        guard !prefilled, let holding else { return }
        prefilled = true
        sizeIsAll = true
        sizeText = PriceFormatter.wire(holding.quantity)
        if let touch = holding.closingSide == .sell ? book?.bestBid : book?.bestAsk {
            fixedPriceText = PriceFormatter.wire(touch)
        }
    }

    // MARK: Editing

    public func editSize(_ text: String) {
        sizeText = text
        sizeIsAll = false
    }

    /// Size as a share of the holding, floored to the lot; all of it exactly.
    public func useFraction(_ fraction: Double) {
        guard let holding else { return }
        if fraction >= 1 {
            sizeIsAll = true
            sizeText = PriceFormatter.wire(holding.quantity)
            return
        }
        sizeIsAll = false
        let raw = holding.quantity * max(fraction, 0)
        let lot = book?.spec?.lot ?? 0
        let floored = lot > 0 ? InstrumentMeta(instId: request.instId, tickSize: 0, lotSize: lot, minSize: 0).flooredToLot(raw) : raw
        sizeText = PriceFormatter.wire(floored)
    }

    /// The share of the holding the size names, for the slider.
    public var fraction: Double {
        guard let holding, holding.quantity > 0 else { return 0 }
        if sizeIsAll { return 1 }
        return min(max((Self.number(sizeText) ?? 0) / holding.quantity, 0), 1)
    }

    /// A level on the ladder chosen by hand: the price becomes that level,
    /// counted from the side it sits on.
    public func pick(isBid: Bool, index: Int) {
        guard let holding else { return }
        let counterparty = (holding.closingSide == .sell) == isBid
        method = .limit
        priceSource = counterparty ? .counterparty : .queue
        level = index + 1
    }

    /// Fill the custom price with what a source resolves to now.
    public func copyResolvedPrice() {
        if case .success(let plan) = preview, let price = plan.price {
            fixedPriceText = PriceFormatter.wire(price.value)
        }
        priceSource = .fixed
    }

    public var input: CloseTicketInput {
        let source: ClosePriceSource
        switch priceSource {
        case .counterparty: source = .counterparty(level: level)
        case .queue: source = .queue(level: level)
        case .mid: source = .mid
        case .last: source = .last
        case .fixed: source = .fixed(Self.number(fixedPriceText) ?? 0)
        }
        return CloseTicketInput(
            method: method,
            size: sizeIsAll ? .all : .amount(Self.number(sizeText) ?? 0),
            price: source, limitKind: limitKind,
            maxChasePct: Self.number(maxChaseText) ?? -1,
            takeProfit: Self.number(takeProfitText), stopLoss: Self.number(stopLossText))
    }

    private struct PlanKey: Equatable {
        let input: CloseTicketInput
        let bookSeq: UInt64
        let holding: CloseHolding
        let fees: FeeRates?
        let accountLevel: Int?
        let working: [ExchangeOpenOrder]?
    }

    /// The plan the form describes against the book as drawn, recomputed
    /// only when one of them changes.
    public var preview: Result<ClosePlan, CloseRefusal>? {
        guard let holding, let bookJSON else { return nil }
        let key = PlanKey(
            input: input, bookSeq: bookSeq, holding: holding, fees: fees,
            accountLevel: account?.accountLevel, working: working?.orders)
        if let planCache, planCache.key == key { return planCache.plan }
        let plan = KernelClose.plan(planInput(holding: holding, clientId: nil), book: bookJSON)
        planCache = (key, plan)
        return plan
    }

    private func planInput(holding: CloseHolding, clientId: String?) -> ClosePlanInput {
        ClosePlanInput(
            venue: request.venue, mode: request.mode, holding: holding, ticket: input, account: account,
            fees: fees, working: working?.orders,
            workingUnread: working == nil ? (workingError ?? "未读取") : nil,
            clientId: clientId)
    }

    // MARK: Review and send

    /// Read the holding and the working orders again, and plan against them
    /// and the book as it is now, under a fresh client id. Nothing is sent.
    public func review() async {
        problem = nil
        await load()
        guard let holding else {
            problem = holdingNote ?? "读不到持仓"
            return
        }
        guard let bookJSON else {
            problem = bookError ?? "还没有盘口"
            return
        }
        let clientId = OrderTag.make(strategyId: Self.manualTag)
        switch KernelClose.plan(planInput(holding: holding, clientId: clientId), book: bookJSON) {
        case .failure(let refusal):
            problem = refusal.message
        case .success(let plan):
            Log.warn("close-ticket: 复核 \(request.mode.badge) \(plan.review.headline) clOrdId=\(clientId)"
                     + (plan.wire.map { " · \($0.method) \($0.path) \($0.body)" } ?? ""))
            reviewedAt = Date()
            stage = .reviewing(plan)
        }
    }

    public var reviewExpired: Bool {
        guard let reviewedAt else { return false }
        return Date().timeIntervalSince(reviewedAt) > reviewLifetime
    }

    public func backToEditing() {
        stage = .editing
        reviewedAt = nil
    }

    /// Send the reviewed plan, exactly. The live lock is the caller's to
    /// state; the kernel refuses a live order without it regardless.
    public func confirm(liveUnlocked: Bool) async {
        guard case .reviewing(let plan) = stage, !reviewExpired else { return }
        stage = .sending(plan)
        Log.warn("close-ticket: 提交 \(request.mode.badge) \(plan.review.headline)")
        let started = Date()
        do {
            let id = try await venue.execute(plan.action, mode: request.mode, liveUnlocked: liveUnlocked)
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            Log.warn("close-ticket: 已提交 \(plan.review.headline) · id=\(id.isEmpty ? "（交易所未返回）" : id) · \(elapsed)ms")
            stage = .sent(plan, id: id, elapsedMs: elapsed)
        } catch {
            let failure = Self.failure(error)
            Log.warn("close-ticket: \(failure.title) \(plan.review.headline)：\(failure.detail)")
            stage = .failed(plan, failure)
            if failure.outcomeUnknown { await resolve(plan) }
        }
        // What the exchange holds now, not what was hoped for.
        await load()
    }

    /// An order whose placement went unanswered, looked up by the client id
    /// it was sent under.
    private func resolve(_ plan: ClosePlan) async {
        guard case .place(let order) = plan.action, let clientId = order.clientId else { return }
        try? await Task.sleep(for: .seconds(1))
        let found: String
        do {
            switch try await venue.orderStatus(
                instId: order.instId, instType: order.instType, clOrdId: clientId, mode: request.mode) {
            case .unknown: found = "交易所查不到这笔订单（clOrdId \(clientId)）：它没有到达，可以重新下单。"
            case .live: found = "查到了：订单在交易所挂着（clOrdId \(clientId)），见下方挂单。"
            case .canceled: found = "查到了：订单已被撤销，没有成交。"
            case .filled(let size, let average):
                found = "查到了：已成交 \(PriceFormatter.plain(size))，均价 \(PriceFormatter.plain(average))。"
            case .rejected(let why): found = "查到了：交易所拒绝了它（\(why)）。"
            }
        } catch {
            found = "按 clOrdId \(clientId) 查询也失败了（\(Self.describe(error))）：请到交易所核对，不要直接重下。"
        }
        Log.warn("close-ticket: 核对未确认订单 \(clientId)：\(found)")
        if case .failed(let failed, let failure) = stage, failed == plan {
            stage = .failed(plan, Failure(
                title: failure.title, detail: failure.detail, advice: found, outcomeUnknown: true))
        }
    }

    /// Cancel one working order on this instrument.
    public func cancel(_ order: ExchangeOpenOrder, liveUnlocked: Bool) async {
        guard let family = holding?.family ?? request.instType else { return }
        problem = nil
        Log.warn("close-ticket: 撤单 \(request.mode.badge) \(order.instId) \(order.ordType) id=\(order.id)")
        do {
            try await venue.cancelWorkingOrder(order, instType: family, mode: request.mode, liveUnlocked: liveUnlocked)
            Log.warn("close-ticket: 已撤 id=\(order.id)")
        } catch {
            let failure = Self.failure(error)
            Log.warn("close-ticket: 撤单\(failure.title) id=\(order.id)：\(failure.detail)")
            problem = "撤单\(failure.title)：\(failure.detail)" + (failure.advice.map { "\n\($0)" } ?? "")
        }
        (working, workingError) = await readWorking()
    }

    // MARK: Helpers

    public static func number(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    static func describe(_ error: Error) -> String {
        if let trade = error as? TradeError {
            return trade.hint.map { "\(trade.description)\n\($0)" } ?? trade.description
        }
        return String(describing: error)
    }

    /// Where the failed order stands, in the words every screen uses. An
    /// unknown outcome is not a failure to retry: the ticket goes on to ask
    /// the exchange by clOrdId.
    static func failure(_ error: Error) -> Failure {
        let standing = TradeError.standing(of: error)
        let advice: String? = switch standing {
        case .unknown: "订单可能已经成交，也可能没有。正在按 clOrdId 查询…"
        case .undelivered: TradeError.undeliveredAdvice
        case .refused: nil
        }
        return Failure(title: standing.title, detail: describe(error), advice: advice,
                       outcomeUnknown: standing == .unknown)
    }
}

/// How an open order reads, wherever it is listed.
public enum OrderLabels {
    /// "卖出平多", "买入开空", or plain "买入" on a market without legs.
    ///
    /// On a leg, the side and the leg decide it, not `reduceOnly`: OKX only
    /// reads that flag in net mode, so a long/short account's close carries
    /// none, and reading it here labelled a sale of the long leg "卖出开多" —
    /// an order that cannot exist.
    public static func direction(_ order: ExchangeOpenOrder) -> String {
        let action = order.side == .buy ? "买入" : "卖出"
        guard let posSide = order.posSide, posSide != .net else {
            return order.reduceOnly ? action + "·只减仓" : action
        }
        let opens = (order.side == .buy) == (posSide == .long)
        return action + (opens ? "开" : "平") + (posSide == .long ? "多" : "空")
    }

    /// How an open order's size reads, whichever way it was sized — exactly,
    /// never rounded up past what the order is for.
    public static func size(_ order: ExchangeOpenOrder) -> String {
        if let size = order.size { return PriceFormatter.wire(size) }
        if let fraction = order.closeFraction {
            return fraction >= 1 ? "全平" : "平 \(PriceFormatter.decimals(fraction * 100, 0))%"
        }
        return "—"
    }
}
