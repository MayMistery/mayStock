import Foundation

// MARK: - Session hours

/// One New York day's sessions, as the markets endpoint reports them.
///
/// The one source of "what phase is the market in": the feed stamps tickers
/// with it, the shadow book fills against it. When the endpoint cannot be
/// reached, `standard(on:open:)` supplies the ordinary hours with the kernel
/// calendar deciding whether the day trades at all.
public struct USSessionHours: Sendable, Equatable, Codable {
    /// `yyyy-MM-dd` in New York.
    public let day: String
    public let isOpen: Bool
    public let preMarket: [DateInterval]
    public let regular: [DateInterval]
    public let postMarket: [DateInterval]

    public init(day: String, isOpen: Bool, preMarket: [DateInterval], regular: [DateInterval], postMarket: [DateInterval]) {
        self.day = day
        self.isOpen = isOpen
        self.preMarket = preMarket
        self.regular = regular
        self.postMarket = postMarket
    }

    public func phase(at now: Date) -> MarketPhase {
        guard isOpen else { return .closed }
        // Half-open: 16:00:00 is the first instant of the after-hours
        // session, not the last of the regular one. `DateInterval.contains`
        // is closed at both ends and would call the closing print regular.
        func inside(_ windows: [DateInterval]) -> Bool {
            windows.contains { $0.start <= now && now < $0.end }
        }
        if inside(regular) { return .regular }
        if inside(preMarket) { return .preMarket }
        if inside(postMarket) { return .afterHours }
        return .closed
    }

    /// The day's regular session, if it has one.
    public var regularSession: DateInterval? { regular.first }

    /// Ordinary hours — 04:00–09:30 pre, 09:30–16:00 regular, 16:00–20:00
    /// post, New York — on a day the calendar trades. An early close is not
    /// known here; that is why the endpoint is asked first.
    public static func standard(on date: Date, open: Bool) -> USSessionHours {
        let zone = Venue.schwab.timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.startOfDay(for: date)
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: start) ?? start
        }
        let day = SchwabAPI.newYorkDay(date)
        guard open else { return USSessionHours(day: day, isOpen: false, preMarket: [], regular: [], postMarket: []) }
        return USSessionHours(
            day: day, isOpen: true,
            preMarket: [DateInterval(start: at(4, 0), end: at(9, 30))],
            regular: [DateInterval(start: at(9, 30), end: at(16, 0))],
            postMarket: [DateInterval(start: at(16, 0), end: at(20, 0))])
    }
}

// MARK: - Account

public struct SchwabAccountRef: Sendable, Equatable, Codable {
    public let accountNumber: String
    public let hashValue: String

    public init(accountNumber: String, hashValue: String) {
        self.accountNumber = accountNumber
        self.hashValue = hashValue
    }
}

public struct SchwabPosition: Sendable, Equatable {
    public let symbol: String
    public let assetType: String
    /// Long minus short, in shares.
    public let quantity: Double
    public let averagePrice: Double
    public let marketValue: Double
    public let dayProfitLoss: Double?

    public init(symbol: String, assetType: String, quantity: Double, averagePrice: Double, marketValue: Double, dayProfitLoss: Double?) {
        self.symbol = symbol
        self.assetType = assetType
        self.quantity = quantity
        self.averagePrice = averagePrice
        self.marketValue = marketValue
        self.dayProfitLoss = dayProfitLoss
    }

    public var isEquity: Bool { SchwabAPI.equityAssetTypes.contains(assetType) }
}

/// One account as the trader endpoint reports it, reduced to what the book
/// needs. `untracked` names holdings of families this app does not trade,
/// so a bond or an option on the account is reported rather than folded
/// into a share count or dropped.
public struct SchwabAccount: Sendable, Equatable {
    public let accountNumber: String
    public let type: String
    public let cash: Double
    /// Schwab's own liquidation value — what the account is worth now.
    public let equity: Double?
    public let availableFunds: Double?
    public let buyingPower: Double?
    public let maintenanceRequirement: Double?
    public let positions: [SchwabPosition]
    public let untracked: [String]

    public init(
        accountNumber: String, type: String, cash: Double, equity: Double?, availableFunds: Double?,
        buyingPower: Double?, maintenanceRequirement: Double?, positions: [SchwabPosition], untracked: [String]
    ) {
        self.accountNumber = accountNumber
        self.type = type
        self.cash = cash
        self.equity = equity
        self.availableFunds = availableFunds
        self.buyingPower = buyingPower
        self.maintenanceRequirement = maintenanceRequirement
        self.positions = positions
        self.untracked = untracked
    }

    public var isMargin: Bool { type.uppercased() == "MARGIN" }

    /// The book's shape: dollars, then one line per stock held, in shares —
    /// a short as a negative count. Same shape OKX spot takes, so the runner
    /// values both the same way.
    public var balances: [AccountBalance] {
        var out = [AccountBalance(
            ccy: Venue.schwab.quoteCurrency, available: availableFunds ?? cash, total: cash, valuationUsd: cash)]
        for position in positions where position.isEquity && position.quantity != 0 {
            out.append(AccountBalance(
                ccy: position.symbol, available: position.quantity, total: position.quantity,
                valuationUsd: position.marketValue))
        }
        return out
    }

    public var exchangePositions: [ExchangePosition] {
        positions.filter { $0.isEquity && $0.quantity != 0 }.map { position in
            let mark = position.quantity != 0 ? position.marketValue / position.quantity : nil
            return ExchangePosition(
                instId: position.symbol, posSide: .net, quantity: position.quantity,
                averagePrice: position.averagePrice, markPrice: mark,
                unrealisedPnL: position.marketValue - position.averagePrice * position.quantity,
                leverage: nil, liquidationPrice: nil)
        }
    }

    public var snapshot: AccountSnapshot {
        AccountSnapshot(balances: balances, totalEquity: equity)
    }

    /// Shares held in `symbol`, signed.
    public func held(_ symbol: String) -> Double {
        positions.filter { $0.symbol == symbol && $0.isEquity }.reduce(0) { $0 + $1.quantity }
    }
}

// MARK: - Orders

public struct SchwabExecution: Sendable, Equatable {
    public let price: Double
    public let quantity: Double
    public let time: Date

    public init(price: Double, quantity: Double, time: Date) {
        self.price = price
        self.quantity = quantity
        self.time = time
    }
}

public struct SchwabOrder: Sendable, Equatable, Identifiable {
    public let id: String
    public let status: String
    public let statusDescription: String?
    public let symbol: String?
    /// BUY, SELL, SELL_SHORT, BUY_TO_COVER.
    public let instruction: String?
    public let quantity: Double
    public let filledQuantity: Double
    public let remainingQuantity: Double
    public let orderType: String
    public let price: Double?
    public let stopPrice: Double?
    public let duration: String?
    public let session: String?
    public let enteredTime: Date?
    public let closeTime: Date?
    public let cancelable: Bool
    public let executions: [SchwabExecution]
    /// Legs of a conditional order, as Schwab nests them.
    public let children: [SchwabOrder]

    public init(
        id: String, status: String, statusDescription: String?, symbol: String?, instruction: String?,
        quantity: Double, filledQuantity: Double, remainingQuantity: Double, orderType: String,
        price: Double?, stopPrice: Double?, duration: String?, session: String?,
        enteredTime: Date?, closeTime: Date?, cancelable: Bool,
        executions: [SchwabExecution], children: [SchwabOrder]
    ) {
        self.id = id
        self.status = status
        self.statusDescription = statusDescription
        self.symbol = symbol
        self.instruction = instruction
        self.quantity = quantity
        self.filledQuantity = filledQuantity
        self.remainingQuantity = remainingQuantity
        self.orderType = orderType
        self.price = price
        self.stopPrice = stopPrice
        self.duration = duration
        self.session = session
        self.enteredTime = enteredTime
        self.closeTime = closeTime
        self.cancelable = cancelable
        self.executions = executions
        self.children = children
    }

    /// Statuses under which the order can still execute.
    public static let workingStatuses: Set<String> = [
        "WORKING", "QUEUED", "ACCEPTED", "PENDING_ACTIVATION", "AWAITING_PARENT_ORDER",
        "AWAITING_CONDITION", "AWAITING_STOP_CONDITION", "AWAITING_MANUAL_REVIEW", "NEW",
        "PENDING_ACKNOWLEDGEMENT", "AWAITING_RELEASE_TIME", "AWAITING_UR_OUT", "PENDING_REPLACE",
        "PENDING_CANCEL",
    ]

    public var isWorking: Bool { Self.workingStatuses.contains(status) }
    /// A stop of either kind: what the runner reads as a protective order.
    public var isStop: Bool { orderType.hasPrefix("STOP") }
    public var isSell: Bool { instruction == "SELL" || instruction == "SELL_SHORT" }

    public var averageFillPrice: Double? {
        let filled = executions.reduce(0.0) { $0 + $1.quantity }
        guard filled > 0 else { return nil }
        return executions.reduce(0.0) { $0 + $1.price * $1.quantity } / filled
    }

    /// The runner's reading of the status.
    public var venueStatus: VenueOrderStatus {
        switch status {
        case "FILLED":
            return .filled(filledSize: filledQuantity > 0 ? filledQuantity : quantity, averagePrice: averageFillPrice ?? price ?? 0)
        case "REJECTED":
            return .rejected(statusDescription ?? "REJECTED")
        case "CANCELED", "EXPIRED", "REPLACED":
            return filledQuantity > 0
                ? .filled(filledSize: filledQuantity, averagePrice: averageFillPrice ?? price ?? 0)
                : .canceled
        default:
            return isWorking ? .live : .unknown
        }
    }

    /// This order and every nested leg, depth first.
    public var flattened: [SchwabOrder] {
        [self] + children.flatMap(\.flattened)
    }
}

/// An order as Schwab wants it spelled, built from the app's request.
public struct SchwabOrderSpec: Sendable, Equatable {
    public var symbol: String
    public var instruction: String
    public var quantity: Double
    public var orderType: String
    public var price: Double?
    public var stopPrice: Double?
    public var duration: String
    public var session: String
    /// Legs released together when this one fills — the stop and the take
    /// profit, as a one-cancels-the-other pair.
    public var children: [SchwabOrderSpec]

    public init(
        symbol: String, instruction: String, quantity: Double, orderType: String,
        price: Double? = nil, stopPrice: Double? = nil,
        duration: String = "DAY", session: String = "NORMAL", children: [SchwabOrderSpec] = []
    ) {
        self.symbol = symbol
        self.instruction = instruction
        self.quantity = quantity
        self.orderType = orderType
        self.price = price
        self.stopPrice = stopPrice
        self.duration = duration
        self.session = session
        self.children = children
    }

    /// Which of Schwab's four instructions a side means, given what the
    /// account already holds. A sell from flat is a short; a buy against a
    /// short is a cover. Schwab refuses the plain verb in either case.
    public static func instruction(side: OrderSide, held: Double) -> String {
        switch side {
        case .buy: return held < 0 ? "BUY_TO_COVER" : "BUY"
        case .sell: return held > 0 ? "SELL" : "SELL_SHORT"
        }
    }

    /// The closing instruction for a position of `direction`.
    public static func closingInstruction(forLong: Bool) -> String {
        forLong ? "SELL" : "BUY_TO_COVER"
    }

    public var body: [String: Any] {
        var out: [String: Any] = [
            "orderType": orderType,
            "session": session,
            "duration": duration,
            "orderStrategyType": children.isEmpty ? "SINGLE" : "TRIGGER",
            "orderLegCollection": [[
                "instruction": instruction,
                "quantity": quantity,
                "instrument": ["symbol": symbol, "assetType": "EQUITY"],
            ] as [String: Any]],
        ]
        if let price { out["price"] = Self.priceString(price) }
        if let stopPrice { out["stopPrice"] = Self.priceString(stopPrice) }
        if !children.isEmpty {
            if children.count == 1 {
                out["childOrderStrategies"] = [children[0].body]
            } else {
                out["childOrderStrategies"] = [[
                    "orderStrategyType": "OCO",
                    "childOrderStrategies": children.map(\.body),
                ] as [String: Any]]
            }
        }
        return out
    }

    public var bodyData: Data {
        (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// Prices as Schwab accepts them: at most two decimals above a dollar,
    /// four below, never scientific notation.
    public static func priceString(_ price: Double) -> String {
        let decimals = price >= 1 ? 2 : 4
        let scale = pow(10.0, Double(decimals))
        let rounded = (price * scale).rounded() / scale
        return String(format: "%.\(decimals)f", rounded)
    }
}

// MARK: - Decoding

/// Schwab's JSON, read into the app's types. Every decoder here is shared by
/// the direct path (the app with a bearer token) and the subprocess path
/// (`schwabctl` printing the same JSON), which is what keeps the two from
/// drifting.
public enum SchwabWire {
    // MARK: Quotes

    /// Tickers by symbol. Symbols Schwab did not answer for are absent; the
    /// caller decides whether that is an unknown instrument.
    public static func tickers(from data: Data, hours: USSessionHours?, now: Date) throws -> [String: Ticker] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SchwabAPIError.decoding("quotes 不是 JSON 对象")
        }
        var out: [String: Ticker] = [:]
        for (symbol, value) in object {
            guard symbol != "errors", let entry = value as? [String: Any],
                  let quote = entry["quote"] as? [String: Any],
                  let last = number(quote, "lastPrice") ?? number(quote, "mark") else { continue }
            let previousClose = number(quote, "closePrice") ?? last
            let tradeTime = (number(quote, "tradeTime") ?? number(quote, "quoteTime")).map {
                Date(timeIntervalSince1970: $0 / 1000)
            } ?? now
            let phase: MarketPhase = hours?.phase(at: now)
                ?? USSessionHours.standard(on: now, open: quote["securityStatus"] as? String != "Closed").phase(at: now)
            out[symbol] = Ticker(
                instId: symbol, last: last,
                bid: number(quote, "bidPrice"), ask: number(quote, "askPrice"),
                reference: previousClose, open: number(quote, "openPrice"),
                high: number(quote, "highPrice") ?? last, low: number(quote, "lowPrice") ?? last,
                volume: number(quote, "totalVolume") ?? 0,
                basis: .previousClose, phase: phase, ts: tradeTime)
        }
        return out
    }

    // MARK: Price history

    /// Candles oldest first. Hourly bars are assembled from the half-hour
    /// bars Schwab serves, anchored on the session open like every other
    /// stock chart; confirmation is the kernel calendar's call.
    public static func candles(from data: Data, symbol: String, bar: BarInterval, now: Date) throws -> [Candle] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SchwabAPIError.decoding("pricehistory 不是 JSON 对象")
        }
        let rows = (object["candles"] as? [[String: Any]]) ?? []
        let raw: [Candle] = rows.compactMap { row in
            guard let millis = number(row, "datetime"),
                  let open = number(row, "open"), let high = number(row, "high"),
                  let low = number(row, "low"), let close = number(row, "close") else { return nil }
            return Candle(
                ts: Date(timeIntervalSince1970: millis / 1000), open: open, high: high, low: low,
                close: close, volume: number(row, "volume") ?? 0, confirmed: false)
        }.sorted { $0.ts < $1.ts }
        let assembled = bar == .h1 ? aggregateHourly(raw) : raw
        let calendar = KernelCalendar(market: StrategyMarket(instId: symbol, instType: .stock, bar: bar, venue: .schwab))
        return assembled.map { candle in
            Candle(ts: candle.ts, open: candle.open, high: candle.high, low: candle.low,
                   close: candle.close, volume: candle.volume, confirmed: calendar.barClose(candle.ts) <= now)
        }
    }

    /// Half-hour bars into hourly bars anchored on 09:30 New York, so the
    /// seventh bar of the day is the half hour before the close. Bars before
    /// the open (extended hours, if ever requested) keep their own hour.
    public static func aggregateHourly(_ halves: [Candle]) -> [Candle] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Venue.schwab.timeZone
        var grouped: [Date: [Candle]] = [:]
        for half in halves {
            let dayStart = calendar.startOfDay(for: half.ts)
            let minutes = Int(half.ts.timeIntervalSince(dayStart) / 60)
            let sinceOpen = minutes - 570
            let anchorMinutes = sinceOpen >= 0 ? 570 + (sinceOpen / 60) * 60 : (minutes / 60) * 60
            let anchor = dayStart.addingTimeInterval(Double(anchorMinutes) * 60)
            grouped[anchor, default: []].append(half)
        }
        return grouped.keys.sorted().map { anchor in
            let parts = grouped[anchor]!.sorted { $0.ts < $1.ts }
            return Candle(
                ts: anchor, open: parts[0].open,
                high: parts.map(\.high).max() ?? parts[0].high,
                low: parts.map(\.low).min() ?? parts[0].low,
                close: parts[parts.count - 1].close,
                volume: parts.reduce(0) { $0 + $1.volume }, confirmed: false)
        }
    }

    // MARK: Hours

    public static func sessionHours(from data: Data, day: String) throws -> USSessionHours {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let equity = object["equity"] as? [String: Any] else {
            throw SchwabAPIError.decoding("markets 不是预期的 JSON")
        }
        // The product is keyed "EQ" on a trading day and "equity" on a closed
        // one; either way there is exactly one entry.
        guard let entry = equity.values.compactMap({ $0 as? [String: Any] }).first else {
            throw SchwabAPIError.decoding("markets 没有 equity 条目")
        }
        let isOpen = (entry["isOpen"] as? Bool) ?? false
        let reported = (entry["date"] as? String) ?? day
        let sessions = entry["sessionHours"] as? [String: Any] ?? [:]
        func intervals(_ key: String) -> [DateInterval] {
            ((sessions[key] as? [[String: Any]]) ?? []).compactMap { window in
                guard let start = (window["start"] as? String).flatMap(date(_:)),
                      let end = (window["end"] as? String).flatMap(date(_:)), end > start else { return nil }
                return DateInterval(start: start, end: end)
            }
        }
        return USSessionHours(
            day: reported, isOpen: isOpen,
            preMarket: intervals("preMarket"), regular: intervals("regularMarket"),
            postMarket: intervals("postMarket"))
    }

    // MARK: Instruments

    public static func matches(from data: Data) throws -> [InstrumentMatch] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw SchwabAPIError.decoding("instruments 不是 JSON")
        }
        let rows: [[String: Any]]
        if let wrapped = object as? [String: Any], let list = wrapped["instruments"] as? [[String: Any]] {
            rows = list
        } else if let list = object as? [[String: Any]] {
            rows = list
        } else {
            rows = []
        }
        return rows.compactMap { row in
            guard let symbol = row["symbol"] as? String, !symbol.isEmpty,
                  let assetType = row["assetType"] as? String,
                  SchwabAPI.equityAssetTypes.contains(assetType) else { return nil }
            return InstrumentMatch(
                instId: symbol, name: (row["description"] as? String) ?? symbol,
                exchange: (row["exchange"] as? String) ?? "US", instType: .stock)
        }
    }

    // MARK: Accounts

    public static func accountNumbers(from data: Data) throws -> [SchwabAccountRef] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SchwabAPIError.decoding("accountNumbers 不是 JSON 数组")
        }
        return rows.compactMap { row in
            guard let number = row["accountNumber"] as? String, let hash = row["hashValue"] as? String else { return nil }
            return SchwabAccountRef(accountNumber: number, hashValue: hash)
        }
    }

    /// One account — the object `GET /accounts/{hash}` returns, or the first
    /// element of the array `GET /accounts` returns.
    public static func account(from data: Data) throws -> SchwabAccount {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw SchwabAPIError.decoding("account 不是 JSON")
        }
        let wrapper: [String: Any]
        if let single = object as? [String: Any] {
            wrapper = single
        } else if let list = object as? [[String: Any]], let first = list.first {
            wrapper = first
        } else {
            throw SchwabAPIError.decoding("account 为空")
        }
        guard let account = wrapper["securitiesAccount"] as? [String: Any] else {
            throw SchwabAPIError.decoding("account 没有 securitiesAccount")
        }
        let balances = (account["currentBalances"] as? [String: Any]) ?? [:]
        let aggregated = (wrapper["aggregatedBalance"] as? [String: Any]) ?? [:]
        var positions: [SchwabPosition] = []
        var untracked: [String] = []
        for row in (account["positions"] as? [[String: Any]]) ?? [] {
            let instrument = (row["instrument"] as? [String: Any]) ?? [:]
            let symbol = (instrument["symbol"] as? String) ?? "?"
            let assetType = (instrument["assetType"] as? String) ?? "?"
            let long = number(row, "longQuantity") ?? 0
            let short = number(row, "shortQuantity") ?? 0
            guard SchwabAPI.equityAssetTypes.contains(assetType) else {
                untracked.append("\(symbol)（\(assetType)）")
                continue
            }
            positions.append(SchwabPosition(
                symbol: symbol, assetType: assetType, quantity: long - short,
                averagePrice: number(row, "averagePrice") ?? 0,
                marketValue: number(row, "marketValue") ?? 0,
                dayProfitLoss: number(row, "currentDayProfitLoss")))
        }
        return SchwabAccount(
            accountNumber: (account["accountNumber"] as? String) ?? "",
            type: (account["type"] as? String) ?? "",
            cash: number(balances, "cashBalance") ?? 0,
            equity: number(balances, "liquidationValue") ?? number(aggregated, "liquidationValue"),
            availableFunds: number(balances, "availableFunds") ?? number(balances, "cashAvailableForTrading"),
            buyingPower: number(balances, "buyingPower"),
            maintenanceRequirement: number(balances, "maintenanceRequirement"),
            positions: positions, untracked: untracked)
    }

    // MARK: Orders

    public static func order(from data: Data) throws -> SchwabOrder {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SchwabAPIError.decoding("order 不是 JSON 对象")
        }
        return order(object)
    }

    public static func orders(from data: Data) throws -> [SchwabOrder] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SchwabAPIError.decoding("orders 不是 JSON 数组")
        }
        return rows.map(order(_:))
    }

    static func order(_ object: [String: Any]) -> SchwabOrder {
        let legs = (object["orderLegCollection"] as? [[String: Any]]) ?? []
        let leg = legs.first ?? [:]
        let instrument = (leg["instrument"] as? [String: Any]) ?? [:]
        var executions: [SchwabExecution] = []
        for activity in (object["orderActivityCollection"] as? [[String: Any]]) ?? [] {
            guard (activity["activityType"] as? String) == "EXECUTION" else { continue }
            for executionLeg in (activity["executionLegs"] as? [[String: Any]]) ?? [] {
                guard let price = number(executionLeg, "price"), let quantity = number(executionLeg, "quantity") else { continue }
                executions.append(SchwabExecution(
                    price: price, quantity: quantity,
                    time: (executionLeg["time"] as? String).flatMap(date(_:)) ?? Date()))
            }
        }
        let children = ((object["childOrderStrategies"] as? [[String: Any]]) ?? []).flatMap { child -> [SchwabOrder] in
            // An OCO wrapper has no legs of its own; its children are the orders.
            if (child["orderStrategyType"] as? String) == "OCO", (child["orderLegCollection"] as? [[String: Any]])?.isEmpty ?? true {
                return ((child["childOrderStrategies"] as? [[String: Any]]) ?? []).map(order(_:))
            }
            return [order(child)]
        }
        let idValue: String
        if let id = object["orderId"] as? Int64 { idValue = String(id) }
        else if let id = object["orderId"] as? Int { idValue = String(id) }
        else if let id = object["orderId"] as? Double { idValue = String(Int64(id)) }
        else { idValue = (object["orderId"] as? String) ?? "" }
        return SchwabOrder(
            id: idValue,
            status: (object["status"] as? String) ?? "UNKNOWN",
            statusDescription: object["statusDescription"] as? String,
            symbol: instrument["symbol"] as? String,
            instruction: leg["instruction"] as? String,
            quantity: number(object, "quantity") ?? number(leg, "quantity") ?? 0,
            filledQuantity: number(object, "filledQuantity") ?? 0,
            remainingQuantity: number(object, "remainingQuantity") ?? 0,
            orderType: (object["orderType"] as? String) ?? "",
            price: number(object, "price"), stopPrice: number(object, "stopPrice"),
            duration: object["duration"] as? String, session: object["session"] as? String,
            enteredTime: (object["enteredTime"] as? String).flatMap(date(_:)),
            closeTime: (object["closeTime"] as? String).flatMap(date(_:)),
            cancelable: (object["cancelable"] as? Bool) ?? false,
            executions: executions, children: children)
    }

    /// The order id out of the `Location` header a placement returns.
    public static func orderId(fromLocation location: String?) -> String? {
        guard let location, let last = location.split(separator: "/").last, !last.isEmpty else { return nil }
        return String(last)
    }

    // MARK: Transactions

    /// Every equity trade in a transactions listing as an exchange fill.
    /// Fees are booked negative, the convention `ExchangeFill` states; the
    /// order id is carried so the venue can attach the strategy tag it
    /// remembered at placement.
    public static func fills(from data: Data) throws -> [ExchangeFill] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SchwabAPIError.decoding("transactions 不是 JSON 数组")
        }
        var out: [ExchangeFill] = []
        for row in rows {
            guard (row["type"] as? String) == "TRADE" else { continue }
            let activityId = (row["activityId"] as? Int64).map(String.init)
                ?? (row["activityId"] as? Int).map(String.init)
                ?? (row["activityId"] as? Double).map { String(Int64($0)) }
                ?? (row["activityId"] as? String) ?? ""
            let orderId = (row["orderId"] as? Int64).map(String.init)
                ?? (row["orderId"] as? Int).map(String.init)
                ?? (row["orderId"] as? Double).map { String(Int64($0)) }
                ?? (row["orderId"] as? String)
            let time = (row["time"] as? String).flatMap(date(_:)) ?? (row["tradeDate"] as? String).flatMap(date(_:)) ?? Date()
            let items = (row["transferItems"] as? [[String: Any]]) ?? []
            let fees = items.filter { $0["feeType"] != nil }.reduce(0.0) { $0 + abs(number($1, "cost") ?? number($1, "amount") ?? 0) }
            let trades = items.filter { item in
                let instrument = (item["instrument"] as? [String: Any]) ?? [:]
                return item["feeType"] == nil && SchwabAPI.equityAssetTypes.contains((instrument["assetType"] as? String) ?? "")
            }
            for (index, item) in trades.enumerated() {
                let instrument = (item["instrument"] as? [String: Any]) ?? [:]
                guard let symbol = instrument["symbol"] as? String,
                      let amount = number(item, "amount"), amount != 0,
                      let price = number(item, "price") else { continue }
                out.append(ExchangeFill(
                    id: trades.count > 1 ? "\(activityId)-\(index)" : activityId,
                    instId: symbol, side: amount > 0 ? .buy : .sell, posSide: nil,
                    price: price, size: abs(amount),
                    fee: index == 0 ? -fees : 0, feeCcy: Venue.schwab.quoteCurrency,
                    ordId: orderId, clOrdId: nil, ts: time))
            }
        }
        return out.sorted { $0.ts < $1.ts }
    }

    // MARK: Helpers

    static func number(_ dict: [String: Any], _ key: String) -> Double? {
        if let value = dict[key] as? Double { return value }
        if let value = dict[key] as? Int { return Double(value) }
        if let value = dict[key] as? Int64 { return Double(value) }
        if let value = dict[key] as? String { return Double(value) }
        return nil
    }

    /// Schwab writes timestamps three ways — `2026-09-15T13:30:00+0000`,
    /// `2026-09-15T13:30:00.000+0000` and, on the markets endpoint,
    /// `2026-09-15T09:30:00-04:00`. All three are read.
    public static func date(_ text: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return isoFormatter.date(from: text) ?? isoFractionalFormatter.date(from: text)
    }

    private static let dateFormatters: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"].map { pattern in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// JSON as `schwabctl` prints it: stable key order, so two runs of the
    /// same command diff cleanly.
    public static func prettyJSON(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return text
    }
}
