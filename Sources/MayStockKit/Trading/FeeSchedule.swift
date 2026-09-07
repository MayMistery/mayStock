import Foundation

// MARK: - Fee model
//
// Mirrors `kernel/src/fees.rs` field for field: the kernel is what charges
// the fees in a backtest, so these types exist to be encoded for it and to
// describe what it will do. The arithmetic here duplicates the kernel's only
// for display — a round-trip hurdle in a summary line — never for a
// simulation result.

/// Which side of a trade a component is charged on.
public enum FeeSide: String, Codable, Sendable, Equatable, CaseIterable {
    case both, buy, sell

    public func applies(to side: OrderSide) -> Bool {
        switch self {
        case .both: return true
        case .buy: return side == .buy
        case .sell: return side == .sell
        }
    }
}

/// What a component is proportional to.
public enum FeeBasis: Sendable, Equatable {
    /// Basis points of the traded notional. Negative is a rebate.
    case notional(bps: Double)
    /// Quote currency per base unit traded — per share, per coin, per contract.
    case unit(perUnit: Double)
    /// Quote currency per order, whatever its size.
    case order(perOrder: Double)
}

public struct FeeComponent: Codable, Sendable, Equatable {
    public var basis: FeeBasis
    public var side: FeeSide
    /// Floor on what one order pays for this component, in quote currency.
    public var minPerOrder: Double?
    /// Ceiling on what one order pays for this component. A per-share levy
    /// with a cap is the common case.
    public var maxPerOrder: Double?
    /// What this line is, for the report: "SEC §31", "FINRA TAF", "taker".
    public var label: String?

    public init(
        basis: FeeBasis, side: FeeSide = .both,
        minPerOrder: Double? = nil, maxPerOrder: Double? = nil, label: String? = nil
    ) {
        self.basis = basis
        self.side = side
        self.minPerOrder = minPerOrder
        self.maxPerOrder = maxPerOrder
        self.label = label
    }

    /// The classic exchange fee: a percentage of notional, both sides.
    public static func flatBps(_ bps: Double) -> FeeComponent {
        FeeComponent(basis: .notional(bps: bps))
    }

    /// Basis points when — and only when — this is the plain both-sides
    /// percentage component, so a manifest can keep writing `feeBps`.
    public var flatBps: Double? {
        guard case .notional(let bps) = basis, side == .both,
              minPerOrder == nil, maxPerOrder == nil, label == nil else { return nil }
        return bps
    }

    /// What one fill pays for this component. `units` and `notional` are
    /// magnitudes.
    public func charge(side orderSide: OrderSide, units: Double, notional: Double) -> Double {
        guard side.applies(to: orderSide) else { return 0 }
        let raw: Double
        switch basis {
        case .notional(let bps): raw = notional * bps / 10_000
        case .unit(let perUnit): raw = units * perUnit
        case .order(let perOrder): raw = perOrder
        }
        var bounded = raw
        if let minPerOrder { bounded = Swift.max(bounded, minPerOrder) }
        if let maxPerOrder { bounded = Swift.min(bounded, maxPerOrder) }
        return bounded
    }

    public var displayName: String {
        let amount: String
        switch basis {
        case .notional(let bps): amount = "\(PriceFormatter.decimals(bps, 3)) bps"
        case .unit(let perUnit): amount = "\(PriceFormatter.plain(perUnit))/单位"
        case .order(let perOrder): amount = "\(PriceFormatter.plain(perOrder))/单"
        }
        var parts = [label ?? "", amount].filter { !$0.isEmpty }
        switch side {
        case .both: break
        case .buy: parts.append("仅买入")
        case .sell: parts.append("仅卖出")
        }
        if let maxPerOrder { parts.append("上限 \(PriceFormatter.plain(maxPerOrder))") }
        if let minPerOrder { parts.append("下限 \(PriceFormatter.plain(minPerOrder))") }
        return parts.joined(separator: " ")
    }

    // MARK: Codable — the kernel's wire shape

    private enum CodingKeys: String, CodingKey {
        case basis, bps, perUnit, perOrder, side, minPerOrder, maxPerOrder, label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .basis)
        switch kind {
        case "notional": basis = .notional(bps: try c.decode(Double.self, forKey: .bps))
        case "unit": basis = .unit(perUnit: try c.decode(Double.self, forKey: .perUnit))
        case "order": basis = .order(perOrder: try c.decode(Double.self, forKey: .perOrder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .basis, in: c, debugDescription: "未知的费用基数「\(kind)」（可选 notional / unit / order）")
        }
        side = try c.decodeIfPresent(FeeSide.self, forKey: .side) ?? .both
        minPerOrder = try c.decodeIfPresent(Double.self, forKey: .minPerOrder)
        maxPerOrder = try c.decodeIfPresent(Double.self, forKey: .maxPerOrder)
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch basis {
        case .notional(let bps):
            try c.encode("notional", forKey: .basis)
            try c.encode(bps, forKey: .bps)
        case .unit(let perUnit):
            try c.encode("unit", forKey: .basis)
            try c.encode(perUnit, forKey: .perUnit)
        case .order(let perOrder):
            try c.encode("order", forKey: .basis)
            try c.encode(perOrder, forKey: .perOrder)
        }
        try c.encode(side, forKey: .side)
        try c.encodeIfPresent(minPerOrder, forKey: .minPerOrder)
        try c.encodeIfPresent(maxPerOrder, forKey: .maxPerOrder)
        try c.encodeIfPresent(label, forKey: .label)
    }
}

/// What a fill costs beyond its price: a list of components, each with its
/// own basis and side. The percentage-of-notional model is the one-component
/// special case.
public struct FeeModel: Codable, Sendable, Equatable {
    public var components: [FeeComponent]

    public init(_ components: [FeeComponent]) {
        self.components = components
    }

    public static func flatBps(_ bps: Double) -> FeeModel {
        FeeModel([.flatBps(bps)])
    }

    /// The model as a single both-sides percentage, when it is one.
    public var flatBps: Double? {
        guard components.count == 1 else { return nil }
        return components[0].flatBps
    }

    public func charge(side: OrderSide, units: Double, notional: Double) -> Double {
        components.reduce(0) { $0 + $1.charge(side: side, units: units, notional: notional) }
    }

    /// Cost of buying and then selling `units` at `price`, in quote currency.
    public func roundTrip(units: Double, price: Double) -> Double {
        let notional = units * price
        return charge(side: .buy, units: units, notional: notional)
            + charge(side: .sell, units: units, notional: notional)
    }

    /// The round trip as a percentage of notional — the hurdle every signal
    /// must clear before it has made a cent. Per-unit and per-order
    /// components depend on the trade, so a reference trade is stated.
    public func roundTripPct(units: Double, price: Double) -> Double {
        let notional = units * price
        guard notional > 0 else { return 0 }
        return roundTrip(units: units, price: price) / notional * 100
    }

    public var summary: String {
        if let bps = flatBps { return "\(PriceFormatter.decimals(bps, 3)) bps" }
        return components.map(\.displayName).joined(separator: " + ")
    }

    public init(from decoder: Decoder) throws {
        components = try decoder.singleValueContainer().decode([FeeComponent].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(components)
    }
}

// MARK: - Schedules

/// A venue's cost model: what its instruments cost to trade, and the slippage
/// assumed on top.
///
/// One conformance per venue. The backtester asks the schedule for the fee
/// model of the strategy's instrument and hands that to the kernel; a
/// manifest that states its own `costs` overrides it.
public protocol FeeSchedule: Codable, Sendable, Equatable {
    var venue: Venue { get }
    /// Assumed adverse fill offset, in basis points, on top of the fees.
    var slippageBps: Double { get set }
    /// Nil when the venue does not trade this instrument type — there is no
    /// cost model for something that cannot be bought.
    func feeModel(for instType: InstrumentType) -> FeeModel?
    var summary: String { get }
}

extension FeeSchedule {
    /// Fees and slippage together, in the shape a manifest's `costs` block has.
    public func costs(for instType: InstrumentType) -> StrategyCosts? {
        feeModel(for: instType).map { StrategyCosts(fees: $0, slippageBps: slippageBps) }
    }

    /// Round-trip cost of one reference trade, in percent — fees both ways
    /// plus slippage both ways. Nil when the venue does not trade the type.
    public func roundTripCostPct(
        for instType: InstrumentType,
        referenceUnits: Double = 100, referencePrice: Double = 100
    ) -> Double? {
        feeModel(for: instType).map {
            $0.roundTripPct(units: referenceUnits, price: referencePrice) + slippageBps * 2 / 100
        }
    }
}

/// Charles Schwab's cost model for US equities.
///
/// Zero commission on listed stocks and ETFs; what remains is regulatory and
/// charged on sales only. Both levies are set by rule and change on a
/// schedule — the SEC §31 rate each fiscal year, FINRA's TAF occasionally —
/// so the numbers are fields with a date on them rather than constants, and a
/// stale figure is a visible field to update rather than a buried literal.
public struct SchwabFeeSchedule: FeeSchedule {
    public let venue = Venue.schwab
    /// Commission per order on listed equities, in dollars. Zero since 2019.
    public var commissionPerOrder: Double
    /// SEC Section 31 transaction fee on the value of every sale, in basis
    /// points. Restated each fiscal year.
    public var secFeeBpsOfSale: Double
    /// FINRA Trading Activity Fee per share sold, in dollars.
    public var tafPerShareSold: Double
    /// Cap on the TAF for one order, in dollars.
    public var tafCapPerOrder: Double
    /// When the two regulatory rates above were last checked against the
    /// published schedules.
    public var ratesAsOf: String
    /// Assumed adverse fill offset per side, in basis points.
    ///
    /// Two rather than the one bps measured on BTC-USDT-SWAP: a liquid US
    /// large-cap trades at a one-cent spread on a hundred-dollar stock, which
    /// is itself a basis point. Still an assumption, and `ms_calibrate_slippage`
    /// exists to replace it with the account's own fills.
    public var slippageBps: Double

    public init(
        commissionPerOrder: Double = 0,
        secFeeBpsOfSale: Double = 0.278,
        tafPerShareSold: Double = 0.000_166,
        tafCapPerOrder: Double = 8.30,
        ratesAsOf: String = "2025-05",
        slippageBps: Double = 2
    ) {
        self.commissionPerOrder = commissionPerOrder
        self.secFeeBpsOfSale = secFeeBpsOfSale
        self.tafPerShareSold = tafPerShareSold
        self.tafCapPerOrder = tafCapPerOrder
        self.ratesAsOf = ratesAsOf
        self.slippageBps = slippageBps
    }

    public func feeModel(for instType: InstrumentType) -> FeeModel? {
        guard venue.trades(instType) else { return nil }
        var components: [FeeComponent] = []
        if commissionPerOrder != 0 {
            components.append(FeeComponent(
                basis: .order(perOrder: commissionPerOrder), side: .both, label: "佣金"))
        }
        components.append(FeeComponent(
            basis: .notional(bps: secFeeBpsOfSale), side: .sell, label: "SEC §31"))
        components.append(FeeComponent(
            basis: .unit(perUnit: tafPerShareSold), side: .sell,
            maxPerOrder: tafCapPerOrder, label: "FINRA TAF"))
        return FeeModel(components)
    }

    public var summary: String {
        "嘉信美股 · 佣金 \(PriceFormatter.plain(commissionPerOrder))"
            + " · 卖出 SEC \(PriceFormatter.decimals(secFeeBpsOfSale, 3)) bps"
            + " + TAF \(PriceFormatter.plain(tafPerShareSold))/股（上限 \(PriceFormatter.plain(tafCapPerOrder))）"
            + " · 滑点 \(PriceFormatter.plain(slippageBps)) bps"
            + "（费率核对于 \(ratesAsOf)）"
    }

    private enum CodingKeys: String, CodingKey {
        case commissionPerOrder, secFeeBpsOfSale, tafPerShareSold, tafCapPerOrder
        case ratesAsOf, slippageBps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SchwabFeeSchedule()
        commissionPerOrder = try c.decodeIfPresent(Double.self, forKey: .commissionPerOrder)
            ?? fallback.commissionPerOrder
        secFeeBpsOfSale = try c.decodeIfPresent(Double.self, forKey: .secFeeBpsOfSale)
            ?? fallback.secFeeBpsOfSale
        tafPerShareSold = try c.decodeIfPresent(Double.self, forKey: .tafPerShareSold)
            ?? fallback.tafPerShareSold
        tafCapPerOrder = try c.decodeIfPresent(Double.self, forKey: .tafCapPerOrder)
            ?? fallback.tafCapPerOrder
        ratesAsOf = try c.decodeIfPresent(String.self, forKey: .ratesAsOf) ?? fallback.ratesAsOf
        slippageBps = try c.decodeIfPresent(Double.self, forKey: .slippageBps) ?? fallback.slippageBps
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(commissionPerOrder, forKey: .commissionPerOrder)
        try c.encode(secFeeBpsOfSale, forKey: .secFeeBpsOfSale)
        try c.encode(tafPerShareSold, forKey: .tafPerShareSold)
        try c.encode(tafCapPerOrder, forKey: .tafCapPerOrder)
        try c.encode(ratesAsOf, forKey: .ratesAsOf)
        try c.encode(slippageBps, forKey: .slippageBps)
    }
}

/// One schedule per venue, so a book that trades on two exchanges has a cost
/// model for each. Adding a venue means adding a field here and a case in
/// `schedule(for:)`; the test suite walks `Venue.allCases` and refuses a venue
/// without a schedule.
public struct FeeSchedules: Codable, Sendable, Equatable {
    public var okx: OKXFeeSchedule
    public var schwab: SchwabFeeSchedule

    public init(okx: OKXFeeSchedule = OKXFeeSchedule(), schwab: SchwabFeeSchedule = SchwabFeeSchedule()) {
        self.okx = okx
        self.schwab = schwab
    }

    public func schedule(for venue: Venue) -> any FeeSchedule {
        switch venue {
        case .okx: return okx
        case .schwab: return schwab
        }
    }

    /// Set every venue's slippage at once — the research bench's `--slippage`
    /// flag means "whatever I am backtesting".
    public mutating func setSlippageBps(_ bps: Double) {
        okx.slippageBps = bps
        schwab.slippageBps = bps
    }

    private enum CodingKeys: String, CodingKey {
        case okx, schwab
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        okx = try c.decodeIfPresent(OKXFeeSchedule.self, forKey: .okx) ?? OKXFeeSchedule()
        schwab = try c.decodeIfPresent(SchwabFeeSchedule.self, forKey: .schwab) ?? SchwabFeeSchedule()
    }
}
