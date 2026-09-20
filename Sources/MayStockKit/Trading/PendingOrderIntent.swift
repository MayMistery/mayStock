import Foundation

/// An order someone proposed from outside the app and a human still has to
/// approve. The app never places one of these on its own: the point of the
/// type is to carry a proposal far enough that a person can read it and say
/// yes, so every field a reader needs to judge the trade travels with it.
///
/// Delivered as a `maystock://order?…` URL. Parsing is deliberately strict —
/// an unknown or malformed parameter is refused rather than ignored, because
/// the alternative is placing a real order that quietly differs from the one
/// that was written.
/// Which side of the live book a relative limit is measured from.
public enum PriceAnchor: String, Sendable, Equatable, Codable, CaseIterable {
    case ask, bid, mid, mark

    /// The anchor's value in a quote, or nil when the book did not report it.
    public func value(bid: Double?, ask: Double?, mark: Double?) -> Double? {
        switch self {
        case .ask: return ask
        case .bid: return bid
        case .mark: return mark
        case .mid:
            guard let bid, let ask else { return nil }
            return (bid + ask) / 2
        }
    }
}

/// How an order's limit price is decided.
///
/// A thin option book moves faster than a human can read a dialog: this one's
/// ask walked 0.005 → 0.0065 in three minutes, and every absolute limit written
/// against it was stale before it could be confirmed. `.relative` defers the
/// arithmetic to the moment of confirmation, so the price that goes out is
/// priced off the book that exists then.
public enum PriceBasis: Sendable, Equatable, Codable {
    /// Exactly this price. What the proposer wrote is what goes out.
    case absolute(Double)
    /// Chase the book: the anchor, crossed by `slipPct`, snapped to the tick.
    /// `capUSD` is the safety valve — if the book has run so far that the
    /// premium would exceed it, the order is refused rather than filled at a
    /// price nobody agreed to.
    case relative(anchor: PriceAnchor, slipPct: Double, capUSD: Double?)
}

public struct PendingOrderIntent: Sendable, Equatable, Codable {

    // MARK: What gets sent to the exchange

    public var instId: String
    public var instType: InstrumentType
    public var side: OrderSide
    public var kind: OrderKind
    /// Exchange units: contracts for swaps and options, base units for spot.
    public var size: Double
    /// Nil for a market order. Otherwise how the limit is arrived at; call
    /// `resolveLimit` at confirmation time to turn it into a number.
    public var priceBasis: PriceBasis?
    public var posSide: PositionSide?
    public var reduceOnly: Bool
    /// Stated outright and never inherited from whatever mode the UI happens
    /// to be showing: a proposal written against the demo account must not
    /// become a live order because someone flipped a switch in between.
    public var mode: TradingMode

    // MARK: What the human reads

    /// Why this order exists, in the proposer's words.
    public var rationale: String?
    /// The worst case in USD, as the proposer computed it.
    public var maxLossUSD: Double?
    /// Free text: an option's expiry, a session close, whatever bounds it.
    public var expiryNote: String?
    /// How far the book may have moved before the confirmation asks a second
    /// time. Percent of the limit price.
    public var priceTolerancePct: Double
    /// Idempotency key. The same nonce is honoured once, so a URL opened
    /// twice — a double click, a relaunch replaying its queue — cannot place
    /// the order twice.
    public var nonce: String

    public init(
        instId: String,
        instType: InstrumentType,
        side: OrderSide,
        kind: OrderKind,
        size: Double,
        priceBasis: PriceBasis? = nil,
        posSide: PositionSide? = nil,
        reduceOnly: Bool = false,
        mode: TradingMode,
        rationale: String? = nil,
        maxLossUSD: Double? = nil,
        expiryNote: String? = nil,
        priceTolerancePct: Double = PendingOrderIntent.defaultTolerancePct,
        nonce: String
    ) {
        self.instId = instId
        self.instType = instType
        self.side = side
        self.kind = kind
        self.size = size
        self.priceBasis = priceBasis
        self.posSide = posSide
        self.reduceOnly = reduceOnly
        self.mode = mode
        self.rationale = rationale
        self.maxLossUSD = maxLossUSD
        self.expiryNote = expiryNote
        self.priceTolerancePct = priceTolerancePct
        self.nonce = nonce
    }

    /// The absolute limit, when the proposal named one. Nil for a market order
    /// and for a relative basis, which has no price until it is resolved.
    public var statedLimitPrice: Double? {
        if case .absolute(let price) = priceBasis { return price }
        return nil
    }

    public static let defaultTolerancePct: Double = 5

    /// The URL host this type answers to: `maystock://order?…`.
    public static let urlHost = "order"
    public static let urlScheme = "maystock"

    // MARK: - Parsing

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case wrongScheme(String?)
        case wrongHost(String?)
        case noQuery
        case missing(String)
        case malformed(field: String, value: String, expected: String)
        case unknownParameters([String])
        case duplicateParameter(String)
        case unpricedLimit
        case pricedMarket
        case conflictingPrice
        case relativeNeedsSlip

        public var description: String {
            switch self {
            case .wrongScheme(let s):
                return "scheme 必须是 \(PendingOrderIntent.urlScheme)://，收到 \(s ?? "空")"
            case .wrongHost(let h):
                return "host 必须是 \(PendingOrderIntent.urlHost)，收到 \(h ?? "空")"
            case .noQuery:
                return "URL 没有查询参数"
            case .missing(let f):
                return "缺少必填参数 \(f)"
            case .malformed(let f, let v, let expected):
                return "参数 \(f) 的值 \"\(v)\" 无效，应为 \(expected)"
            case .unknownParameters(let keys):
                return "无法识别的参数：\(keys.sorted().joined(separator: ", "))"
            case .duplicateParameter(let k):
                return "参数 \(k) 重复出现"
            case .unpricedLimit:
                return "limit/ioc 订单必须给 limitPrice 或 priceMode"
            case .pricedMarket:
                return "market 订单不能带 limitPrice 或 priceMode"
            case .conflictingPrice:
                return "limitPrice 与 priceMode 互斥，只能给一个"
            case .relativeNeedsSlip:
                return "priceMode 必须同时给 maxSlipPct"
            }
        }
    }

    /// Every parameter this type understands. Anything else is an error, not a
    /// field to skip: a typo in a size or a price has to fail loudly.
    private static let knownKeys: Set<String> = [
        "instId", "instType", "side", "kind", "size", "limitPrice",
        "priceMode", "maxSlipPct", "maxPremiumUSD",
        "posSide", "reduceOnly", "mode", "rationale", "maxLossUSD",
        "expiryNote", "tolerancePct", "nonce",
    ]

    public static func parse(_ url: URL) throws -> PendingOrderIntent {
        guard url.scheme?.lowercased() == urlScheme else {
            throw ParseError.wrongScheme(url.scheme)
        }
        guard url.host?.lowercased() == urlHost else {
            throw ParseError.wrongHost(url.host)
        }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              !items.isEmpty
        else { throw ParseError.noQuery }

        var raw: [String: String] = [:]
        for item in items {
            if raw[item.name] != nil { throw ParseError.duplicateParameter(item.name) }
            raw[item.name] = item.value ?? ""
        }
        let unknown = Set(raw.keys).subtracting(knownKeys)
        if !unknown.isEmpty { throw ParseError.unknownParameters(Array(unknown)) }

        func required(_ key: String) throws -> String {
            guard let value = raw[key], !value.trimmingCharacters(in: .whitespaces).isEmpty
            else { throw ParseError.missing(key) }
            return value.trimmingCharacters(in: .whitespaces)
        }
        func optional(_ key: String) -> String? {
            guard let value = raw[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty
            else { return nil }
            return value
        }
        /// Finite and positive-only where the caller says so — NaN and
        /// infinity parse happily out of `Double("nan")` and would reach the
        /// exchange as garbage.
        func number(_ key: String, _ text: String, positive: Bool) throws -> Double {
            guard let value = Double(text), value.isFinite else {
                throw ParseError.malformed(field: key, value: text, expected: "数字")
            }
            if positive && value <= 0 {
                throw ParseError.malformed(field: key, value: text, expected: "大于 0 的数字")
            }
            return value
        }

        let instId = try required("instId")

        let instTypeText = try required("instType")
        guard let instType = InstrumentType(rawValue: instTypeText.uppercased()) else {
            throw ParseError.malformed(
                field: "instType", value: instTypeText,
                expected: InstrumentType.allCases.map(\.rawValue).joined(separator: "/"))
        }

        let sideText = try required("side")
        guard let side = OrderSide(rawValue: sideText.lowercased()) else {
            throw ParseError.malformed(
                field: "side", value: sideText, expected: "buy/sell")
        }

        let kindText = try required("kind")
        guard let kind = OrderKind(rawValue: kindText.lowercased()) else {
            throw ParseError.malformed(
                field: "kind", value: kindText, expected: "market/limit/ioc")
        }

        let sizeText = try required("size")
        let size = try number("size", sizeText, positive: true)

        var limitPrice: Double?
        if let text = optional("limitPrice") {
            limitPrice = try number("limitPrice", text, positive: true)
        }

        // Relative pricing: the limit is computed from the live book at
        // confirmation time rather than written now.
        var basis: PriceBasis?
        if let modeText = optional("priceMode") {
            guard let anchor = PriceAnchor(rawValue: modeText.lowercased()) else {
                throw ParseError.malformed(
                    field: "priceMode", value: modeText,
                    expected: PriceAnchor.allCases.map(\.rawValue).joined(separator: "/"))
            }
            if limitPrice != nil { throw ParseError.conflictingPrice }
            guard let slipText = optional("maxSlipPct") else {
                throw ParseError.relativeNeedsSlip
            }
            // Zero slip is meaningful — sit exactly on the anchor — but a
            // negative one would price the order away from the book.
            let slip = try number("maxSlipPct", slipText, positive: false)
            if slip < 0 {
                throw ParseError.malformed(
                    field: "maxSlipPct", value: slipText, expected: "不小于 0 的数字")
            }
            var cap: Double?
            if let capText = optional("maxPremiumUSD") {
                cap = try number("maxPremiumUSD", capText, positive: true)
            }
            basis = .relative(anchor: anchor, slipPct: slip, capUSD: cap)
        } else {
            if raw["maxSlipPct"] != nil || raw["maxPremiumUSD"] != nil {
                throw ParseError.malformed(
                    field: "maxSlipPct/maxPremiumUSD", value: "(无 priceMode)",
                    expected: "先给 priceMode")
            }
            if let limitPrice { basis = .absolute(limitPrice) }
        }

        // A priced kind without a price would reach OKX as a market order, and
        // a market order on a thin option book is a blank cheque on the ask.
        if kind.isPriced && basis == nil { throw ParseError.unpricedLimit }
        if !kind.isPriced && basis != nil { throw ParseError.pricedMarket }

        var posSide: PositionSide?
        if let text = optional("posSide") {
            guard let parsed = PositionSide(rawValue: text.lowercased()) else {
                throw ParseError.malformed(
                    field: "posSide", value: text, expected: "long/short/net")
            }
            posSide = parsed
        }

        var reduceOnly = false
        if let text = optional("reduceOnly") {
            switch text.lowercased() {
            case "true", "1", "yes": reduceOnly = true
            case "false", "0", "no": reduceOnly = false
            default:
                throw ParseError.malformed(
                    field: "reduceOnly", value: text, expected: "true/false")
            }
        }

        let modeText = try required("mode")
        guard let mode = TradingMode(rawValue: modeText.lowercased()) else {
            throw ParseError.malformed(
                field: "mode", value: modeText, expected: "demo/live")
        }

        var maxLossUSD: Double?
        if let text = optional("maxLossUSD") {
            maxLossUSD = try number("maxLossUSD", text, positive: false)
        }

        var tolerance = defaultTolerancePct
        if let text = optional("tolerancePct") {
            tolerance = try number("tolerancePct", text, positive: true)
        }

        let nonce = try required("nonce")

        return PendingOrderIntent(
            instId: instId, instType: instType, side: side, kind: kind,
            size: size, priceBasis: basis, posSide: posSide,
            reduceOnly: reduceOnly, mode: mode,
            rationale: optional("rationale"), maxLossUSD: maxLossUSD,
            expiryNote: optional("expiryNote"), priceTolerancePct: tolerance,
            nonce: nonce)
    }

    // MARK: - Resolving the price against the live book

    public enum ResolvedLimit: Sendable, Equatable {
        /// Use this price.
        case price(Double)
        /// No price needed — a market order.
        case marketOrder
        /// The book could not price it: the anchor this order needs was not
        /// quoted. Confirming blind is a different decision, so say so.
        case noQuote(anchor: PriceAnchor)
        /// The book ran past what the proposal was willing to pay. Refused
        /// rather than filled at a price nobody agreed to.
        case aboveCap(limit: Double, premiumUSD: Double, capUSD: Double)
    }

    /// Turn the basis into the price that will actually go out.
    ///
    /// - Parameters:
    ///   - tick: the instrument's tick; the result is snapped to it, crossing
    ///     the book (up for a buy, down for a sell) so the order can fill.
    ///   - contractValue: underlying units per contract, for valuing the
    ///     premium against `capUSD`. Nil for spot, where size is already in
    ///     base units.
    ///   - indexPrice: the underlying's price in USD, for the same valuation.
    ///     An option's premium is quoted in the settlement coin, so turning it
    ///     into dollars needs this.
    public func resolveLimit(
        bid: Double?, ask: Double?, mark: Double?,
        tick: Double, contractValue: Double? = nil, indexPrice: Double? = nil
    ) -> ResolvedLimit {
        guard let priceBasis else { return .marketOrder }
        switch priceBasis {
        case .absolute(let price):
            return .price(price)
        case .relative(let anchor, let slipPct, let capUSD):
            guard let reference = anchor.value(bid: bid, ask: ask, mark: mark),
                  reference > 0
            else { return .noQuote(anchor: anchor) }
            // Cross the book by the allowance: a buy pays up, a sell accepts
            // less. Snapping follows the same direction, so rounding never
            // lands on the wrong side of the price that was authorised.
            let crossed = side == .buy
                ? reference * (1 + slipPct / 100)
                : reference * (1 - slipPct / 100)
            let snapped = StrategyRunner.snapToTick(
                crossed, tick: tick, roundingUp: side == .buy)
            guard snapped > 0 else { return .noQuote(anchor: anchor) }
            if let capUSD, let indexPrice, indexPrice > 0 {
                let units = size * (contractValue ?? 1)
                let premiumUSD = units * snapped * indexPrice
                if premiumUSD > capUSD {
                    return .aboveCap(
                        limit: snapped, premiumUSD: premiumUSD, capUSD: capUSD)
                }
            }
            return .price(snapped)
        }
    }

    // MARK: - Handing it to the exchange

    /// The exchange request this intent stands for. `tradeMode` comes from the
    /// account, not the URL — `AccountTradingConfig.optionTradeMode` decides
    /// it, and letting a URL name it would let a proposal pick its own margin
    /// treatment.
    ///
    /// `limitPrice` is passed in rather than read off the intent: a relative
    /// basis has no price until `resolveLimit` has run against the live book.
    public func toOrderRequest(
        limitPrice: Double?, tradeMode: String?, clOrdId: String? = nil
    ) -> OrderRequest {
        OrderRequest(
            instId: instId,
            instType: instType,
            side: side,
            kind: kind,
            size: size,
            // Contracts and base units, never quote: quote sizing only means
            // anything for a spot market order.
            sizeUnit: .base,
            limitPrice: limitPrice,
            posSide: posSide,
            reduceOnly: reduceOnly,
            clOrdId: clOrdId,
            tradeMode: tradeMode)
    }

    /// How far a resolved limit sits from where the book is now, as a
    /// percentage of that limit. Positive means the market has moved against
    /// the order — above the limit for a buy, below it for a sell.
    ///
    /// Nil when there is nothing to compare: a market order, or a book that
    /// did not quote the side this order has to cross.
    public func priceDrift(limit: Double?, bid: Double?, ask: Double?) -> Double? {
        guard let limit, limit > 0 else { return nil }
        let reference: Double?
        switch side {
        case .buy: reference = ask
        case .sell: reference = bid
        }
        guard let reference, reference > 0 else { return nil }
        let drift = (reference - limit) / limit * 100
        return side == .buy ? drift : -drift
    }

    /// True when the book has moved further than this intent tolerates.
    ///
    /// Only ever asked of an absolute limit. A relative basis is priced off the
    /// book at confirmation time, so it cannot be stale by construction — that
    /// is the whole reason it exists.
    public func exceedsTolerance(limit: Double?, bid: Double?, ask: Double?) -> Bool {
        guard case .absolute = priceBasis else { return false }
        guard let drift = priceDrift(limit: limit, bid: bid, ask: ask) else { return false }
        return drift > priceTolerancePct
    }
}
