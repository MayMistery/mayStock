import Foundation

/// The strategy tags Schwab cannot carry, kept on our side.
///
/// Schwab orders have no client id, so every placement records the order
/// ids it produced under the strategy tag, and every fill and status read
/// looks the tag back up by order id. On disk, because a restart between
/// placing and filling would otherwise book the fill as somebody else's.
public actor SchwabOrderTags {
    struct Entry: Codable, Sendable {
        var orderIds: [String]
        var instId: String
        var placedAt: Date
    }

    private let fileURL: URL?
    private var entries: [String: Entry]
    /// Older tags are dropped on save; the ledger already holds their fills.
    static let retention: TimeInterval = 90 * 86_400

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let loaded = try? Self.decoder.decode([String: Entry].self, from: data) {
            entries = loaded
        } else {
            entries = [:]
        }
    }

    public func record(clOrdId: String, orderId: String, instId: String, now: Date = Date()) {
        if var existing = entries[clOrdId] {
            if !existing.orderIds.contains(orderId) { existing.orderIds.append(orderId) }
            entries[clOrdId] = existing
        } else {
            entries[clOrdId] = Entry(orderIds: [orderId], instId: instId, placedAt: now)
        }
        persist(now: now)
    }

    public func orderIds(for clOrdId: String) -> [String] {
        entries[clOrdId]?.orderIds ?? []
    }

    public func clOrdId(forOrderId orderId: String) -> String? {
        entries.first { $0.value.orderIds.contains(orderId) }?.key
    }

    private func persist(now: Date) {
        guard let fileURL else { return }
        entries = entries.filter { now.timeIntervalSince($0.value.placedAt) < Self.retention }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            Log.warn("schwab: 订单标签写盘失败：\(error)")
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// Charles Schwab as the runner sees it.
///
/// Market data comes from `SchwabMarketDataSource` — the official feed with
/// a thirty-minute token from `schwabctl`, Yahoo while there is none. Demo
/// mode is the shadow book: Schwab has no paper account, so simulated
/// orders fill here against the live quote. Live mode sends every order
/// through `schwabctl`, which holds the credentials and insists on
/// `--live`.
public struct SchwabVenue: ExchangeVenue {
    public let venue = Venue.schwab
    public let data: SchwabMarketDataSource
    public let bridge: SchwabBridge
    public let shadow: ShadowBook
    public let tags: SchwabOrderTags
    public let economics: ShadowBook.Economics

    public init(
        data: SchwabMarketDataSource, bridge: SchwabBridge, shadow: ShadowBook,
        tags: SchwabOrderTags, economics: ShadowBook.Economics
    ) {
        self.data = data
        self.bridge = bridge
        self.shadow = shadow
        self.tags = tags
        self.economics = economics
    }

    /// How far back a fills listing reaches. Long enough to cover a weekend
    /// plus a holiday between placing and reading; the ledger already holds
    /// anything older.
    public static let fillsLookback: TimeInterval = 7 * 86_400

    public func isReady() async -> Bool {
        (try? await bridge.status())?.loggedIn ?? false
    }

    // MARK: Market data

    public func candles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle] {
        try await data.candles(instId: instId, bar: bar, target: target)
    }

    public func historyCandles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle] {
        try await data.historyCandles(instId: instId, bar: bar, target: target, progress: nil)
    }

    public func lastPrice(instId: String, mode: TradingMode) async throws -> Double {
        let ticker = try await data.ticker(instId: instId)
        if mode == .demo {
            await shadow.settle(quotes: [instId: ShadowBook.Quote(ticker)], economics: economics)
        }
        return ticker.last
    }

    public func instrumentMeta(instId: String, mode: TradingMode) async throws -> InstrumentMeta? {
        try await data.instrumentMeta(instId: instId)
    }

    // MARK: Trading

    public func place(_ order: OrderRequest, mode: TradingMode, liveUnlocked: Bool) async throws -> OrderResult {
        guard order.instType == .stock else { throw TradeError.unsupportedInstrument(order.instType) }
        switch mode {
        case .demo:
            let quote = (try? await data.ticker(instId: order.instId)).map(ShadowBook.Quote.init)
            let placed = try await shadow.place(order, quote: quote, economics: economics)
            return OrderResult(ordId: placed.id, clOrdId: order.clOrdId, raw: placed.note ?? placed.status.rawValue)
        case .live:
            guard liveUnlocked else { throw TradeError.liveTradingLocked }
            let held = try await bridge.account().held(order.instId)
            var ids: [String] = []
            for spec in Self.specs(for: order, held: held) {
                let id = try await bridge.place(spec, liveUnlocked: liveUnlocked)
                ids.append(id)
                if let tag = order.clOrdId { await tags.record(clOrdId: tag, orderId: id, instId: order.instId) }
            }
            return OrderResult(ordId: ids.last ?? "", clOrdId: order.clOrdId, raw: ids.joined(separator: ","))
        }
    }

    /// Schwab's spelling of one request. A sell that closes a long and opens
    /// a short is two orders — SELL the holding, SELL_SHORT the rest — because
    /// Schwab refuses a SELL larger than the position. Protective levels ride
    /// on the opening order as a triggered one-cancels-other pair.
    static func specs(for order: OrderRequest, held: Double) -> [SchwabOrderSpec] {
        let orderType: String
        switch order.kind {
        case .market: orderType = "MARKET"
        case .limit, .ioc: orderType = "LIMIT"
        }
        let signed = order.side == .buy ? order.size : -order.size
        let after = held + signed
        var legs: [(instruction: String, quantity: Double)] = []
        if held != 0, (held > 0) != (after > 0), after != 0 {
            // Crosses flat: close what is held, then open the other way.
            legs.append((SchwabOrderSpec.closingInstruction(forLong: held > 0), abs(held)))
            legs.append((order.side == .buy ? "BUY" : "SELL_SHORT", abs(after)))
        } else {
            legs.append((SchwabOrderSpec.instruction(side: order.side, held: held), order.size))
        }
        var specs = legs.map { leg in
            SchwabOrderSpec(
                symbol: order.instId, instruction: leg.instruction, quantity: leg.quantity,
                orderType: orderType, price: order.kind.isPriced ? order.limitPrice : nil,
                duration: "DAY", session: "NORMAL")
        }
        // Protection belongs to whichever leg opens exposure — the last one.
        if let index = specs.indices.last, after != 0, !order.reduceOnly {
            let closing = SchwabOrderSpec.closingInstruction(forLong: after > 0)
            var children: [SchwabOrderSpec] = []
            if let stop = order.stopTriggerPrice {
                children.append(SchwabOrderSpec(
                    symbol: order.instId, instruction: closing, quantity: specs[index].quantity,
                    orderType: "STOP", stopPrice: stop, duration: "GOOD_TILL_CANCEL"))
            }
            if let takeProfit = order.takeProfitTriggerPrice {
                children.append(SchwabOrderSpec(
                    symbol: order.instId, instruction: closing, quantity: specs[index].quantity,
                    orderType: "LIMIT", price: takeProfit, duration: "GOOD_TILL_CANCEL"))
            }
            specs[index].children = children
        }
        return specs
    }

    public func orderStatus(instId: String, instType: InstrumentType, clOrdId: String, mode: TradingMode) async throws -> VenueOrderStatus {
        switch mode {
        case .demo:
            return await shadow.status(clOrdId: clOrdId)
        case .live:
            let ids = await tags.orderIds(for: clOrdId)
            guard !ids.isEmpty else { return .unknown }
            var statuses: [VenueOrderStatus] = []
            for id in ids { statuses.append(try await bridge.order(id: id).venueStatus) }
            return Self.combine(statuses)
        }
    }

    /// One verdict for the orders a single request became.
    static func combine(_ statuses: [VenueOrderStatus]) -> VenueOrderStatus {
        if statuses.contains(.live) { return .live }
        var filled = 0.0, notional = 0.0
        for case .filled(let size, let price) in statuses {
            filled += size
            notional += size * price
        }
        if filled > 0 { return .filled(filledSize: filled, averagePrice: notional / filled) }
        if let rejected = statuses.first(where: { if case .rejected = $0 { return true } else { return false } }) { return rejected }
        if statuses.contains(.canceled) { return .canceled }
        return .unknown
    }

    public func fills(instId: String?, instType: InstrumentType, mode: TradingMode) async throws -> [ExchangeFill] {
        switch mode {
        case .demo:
            return await shadow.fills(instId: instId)
        case .live:
            let now = Date()
            let listing = try await bridge.fills(from: now.addingTimeInterval(-Self.fillsLookback), to: now, symbol: instId)
            var tagged: [ExchangeFill] = []
            for fill in listing {
                var tag: String?
                if let ordId = fill.ordId { tag = await tags.clOrdId(forOrderId: ordId) }
                tagged.append(ExchangeFill(
                    id: fill.id, instId: fill.instId, side: fill.side, posSide: fill.posSide,
                    price: fill.price, size: fill.size, fee: fill.fee, feeCcy: fill.feeCcy,
                    ordId: fill.ordId, clOrdId: tag, ts: fill.ts))
            }
            return tagged
        }
    }

    public func positions(mode: TradingMode, instType: InstrumentType) async throws -> [ExchangePosition] {
        guard instType == .stock else { return [] }
        switch mode {
        case .demo: return await shadow.positions()
        case .live: return try await bridge.account().exchangePositions
        }
    }

    public func accountSnapshot(mode: TradingMode) async throws -> AccountSnapshot {
        switch mode {
        case .demo:
            // Mark every holding fresh so the shadow's equity moves with
            // the market between fills.
            let held = await shadow.positions().map(\.instId)
            var quotes: [String: ShadowBook.Quote] = [:]
            for instId in held {
                if let ticker = try? await data.ticker(instId: instId) { quotes[instId] = ShadowBook.Quote(ticker) }
            }
            await shadow.settle(quotes: quotes, economics: economics)
            return await shadow.snapshot()
        case .live:
            return try await bridge.account().snapshot
        }
    }

    // MARK: Open orders

    /// Everything the account is holding open — resting limits and armed
    /// stops — for the overview. Not part of `ExchangeVenue`: the runner
    /// never needs the whole book, only the page does.
    public func openOrders(mode: TradingMode) async throws -> [ExchangeOpenOrder] {
        switch mode {
        case .demo:
            return await shadow.openOrders.map { order in
                ExchangeOpenOrder(
                    id: order.id, book: order.protective ? .algo : .order, instId: order.instId,
                    ordType: order.stopPrice != nil ? "stop" : order.kind.rawValue, side: order.side, posSide: nil,
                    price: order.limitPrice, triggerPrice: order.stopPrice, stopTriggerPrice: order.stopPrice,
                    takeProfitTriggerPrice: nil, size: order.size, closeFraction: nil, filledSize: order.filledSize,
                    state: order.note ?? order.status.rawValue, reduceOnly: order.reduceOnly,
                    clOrdId: order.clOrdId, createdAt: order.placedAt)
            }
        case .live:
            let now = Date()
            let orders = try await bridge.orders(from: now.addingTimeInterval(-60 * 86_400), to: now)
            var out: [ExchangeOpenOrder] = []
            for order in orders.flatMap(\.flattened) where order.isWorking {
                let tag = await tags.clOrdId(forOrderId: order.id)
                out.append(ExchangeOpenOrder(
                    id: order.id, book: order.isStop ? .algo : .order, instId: order.symbol ?? "",
                    ordType: order.orderType.lowercased(), side: order.isSell ? .sell : .buy, posSide: nil,
                    price: order.price, triggerPrice: order.stopPrice, stopTriggerPrice: order.stopPrice,
                    takeProfitTriggerPrice: nil, size: order.quantity, closeFraction: nil,
                    filledSize: order.filledQuantity, state: order.status.lowercased(),
                    reduceOnly: order.instruction == "SELL" || order.instruction == "BUY_TO_COVER",
                    clOrdId: tag, createdAt: order.enteredTime))
            }
            return out
        }
    }

    // MARK: Protective orders

    public func protectiveOrders(instId: String, instType: InstrumentType, mode: TradingMode) async throws -> [VenueProtectiveOrder] {
        switch mode {
        case .demo:
            return await shadow.protectiveOrders(instId: instId)
        case .live:
            let now = Date()
            let orders = try await bridge.orders(from: now.addingTimeInterval(-60 * 86_400), to: now)
            return orders.flatMap(\.flattened)
                .filter { $0.symbol == instId && $0.isWorking && $0.isStop }
                .map { order in
                    VenueProtectiveOrder(
                        algoId: order.id, instId: instId, stopTriggerPrice: order.stopPrice,
                        takeProfitTriggerPrice: nil, size: order.remainingQuantity > 0 ? order.remainingQuantity : order.quantity,
                        posSide: nil)
                }
        }
    }

    public func amendProtectiveOrder(
        instId: String, instType: InstrumentType, algoId: String,
        stopPrice: Double, mode: TradingMode, liveUnlocked: Bool
    ) async throws {
        switch mode {
        case .demo:
            try await shadow.amendProtective(id: algoId, stopPrice: stopPrice)
        case .live:
            let existing = try await bridge.order(id: algoId)
            let spec = SchwabOrderSpec(
                symbol: instId, instruction: existing.instruction ?? "SELL",
                quantity: existing.remainingQuantity > 0 ? existing.remainingQuantity : existing.quantity,
                orderType: "STOP", stopPrice: stopPrice,
                duration: existing.duration ?? "GOOD_TILL_CANCEL", session: existing.session ?? "NORMAL")
            _ = try await bridge.replace(id: algoId, with: spec, liveUnlocked: liveUnlocked)
        }
    }

    public func placeProtectiveOrder(
        instId: String, instType: InstrumentType, posSide: PositionSide?,
        size: Double, stopPrice: Double, mode: TradingMode, liveUnlocked: Bool
    ) async throws {
        switch mode {
        case .demo:
            let held = await shadow.positions().first { $0.instId == instId }?.quantity ?? 0
            await shadow.placeProtective(instId: instId, side: held >= 0 ? .sell : .buy, size: size, stopPrice: stopPrice)
        case .live:
            let held = try await bridge.account().held(instId)
            let spec = SchwabOrderSpec(
                symbol: instId, instruction: SchwabOrderSpec.closingInstruction(forLong: held >= 0),
                quantity: size, orderType: "STOP", stopPrice: stopPrice, duration: "GOOD_TILL_CANCEL")
            _ = try await bridge.place(spec, liveUnlocked: liveUnlocked)
        }
    }
}
