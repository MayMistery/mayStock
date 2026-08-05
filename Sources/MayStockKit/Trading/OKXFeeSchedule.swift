import Foundation

/// OKX fee tier. Regular users climb Lv1→Lv5 on assets or 30-day volume;
/// VIP tiers sit above them. A new account is **Lv1**, which is the default
/// everywhere in MayStock — assuming anything better silently understates the
/// cost of every backtest.
public enum OKXFeeTier: String, Codable, Sendable, CaseIterable, Identifiable {
    case lv1, lv2, lv3, lv4, lv5
    case vip1, vip2, vip3, vip4, vip5, vip6, vip7, vip8, vip9

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lv1: return "普通 Lv1"
        case .lv2: return "普通 Lv2"
        case .lv3: return "普通 Lv3"
        case .lv4: return "普通 Lv4"
        case .lv5: return "普通 Lv5"
        default: return rawValue.uppercased()
        }
    }

    /// What it takes to reach this tier (assets **or** 30-day volume).
    public var requirement: String {
        switch self {
        case .lv1: return "默认档位"
        case .lv2: return "≥ 100 OKB 或 30 日交易量 ≥ 50K USD"
        case .lv3: return "≥ 500 OKB 或 30 日交易量 ≥ 100K USD"
        case .lv4: return "≥ 1,000 OKB 或 30 日交易量 ≥ 500K USD"
        case .lv5: return "≥ 2,000 OKB 或 30 日交易量 ≥ 2M USD"
        case .vip1: return "资产 ≥ 500K USD 或 30 日交易量 ≥ 10M USD"
        case .vip2: return "资产 ≥ 1M USD 或 30 日交易量 ≥ 20M USD"
        case .vip3: return "资产 ≥ 2M USD 或 30 日交易量 ≥ 50M USD"
        case .vip4: return "资产 ≥ 5M USD 或 30 日交易量 ≥ 100M USD"
        case .vip5: return "资产 ≥ 10M USD 或 30 日交易量 ≥ 200M USD"
        case .vip6: return "资产 ≥ 20M USD 或 30 日交易量 ≥ 500M USD"
        case .vip7: return "资产 ≥ 50M USD 或 30 日交易量 ≥ 1B USD"
        case .vip8: return "资产 ≥ 100M USD 或 30 日交易量 ≥ 2B USD"
        case .vip9: return "资产 ≥ 200M USD 或 30 日交易量 ≥ 4B USD"
        }
    }

    /// Spot maker fee in basis points. Negative means a rebate.
    public var spotMakerBps: Double {
        switch self {
        case .lv1: return 8
        case .lv2: return 7.5
        case .lv3: return 7
        case .lv4: return 6.5
        case .lv5: return 6
        case .vip1: return 5
        case .vip2: return 4
        case .vip3: return 2
        case .vip4: return 1
        case .vip5: return 0
        case .vip6: return -0.5
        case .vip7: return -1
        case .vip8: return -1.5
        case .vip9: return -2
        }
    }

    /// Spot taker fee in basis points.
    public var spotTakerBps: Double {
        switch self {
        case .lv1: return 10
        case .lv2: return 9.5
        case .lv3: return 9
        case .lv4: return 8.5
        case .lv5: return 8
        case .vip1: return 7
        case .vip2: return 6
        case .vip3: return 5
        case .vip4: return 4
        case .vip5: return 3
        case .vip6: return 2.5
        case .vip7: return 2
        case .vip8: return 1.8
        case .vip9: return 1.5
        }
    }

    /// Perpetual maker fee in basis points.
    public var swapMakerBps: Double {
        switch self {
        case .lv1: return 2
        case .lv2: return 1.8
        case .lv3: return 1.6
        case .lv4: return 1.4
        case .lv5: return 1.2
        case .vip1: return 1
        case .vip2: return 0.8
        case .vip3: return 0.6
        case .vip4: return 0.4
        case .vip5: return 0.2
        case .vip6: return 0
        case .vip7: return -0.5
        case .vip8: return -0.8
        case .vip9: return -1
        }
    }

    /// Perpetual taker fee in basis points.
    public var swapTakerBps: Double {
        switch self {
        case .lv1: return 5
        case .lv2: return 4.8
        case .lv3: return 4.6
        case .lv4: return 4.4
        case .lv5: return 4.2
        case .vip1: return 4
        case .vip2: return 3.5
        case .vip3: return 3
        case .vip4: return 2.5
        case .vip5: return 2.2
        case .vip6: return 2
        case .vip7: return 1.8
        case .vip8: return 1.6
        case .vip9: return 1.5
        }
    }
}

/// Which side of the book an order is expected to land on.
public enum FeeExecutionStyle: String, Codable, Sendable, CaseIterable {
    /// Market orders and marketable limits — what the strategy runner sends.
    case taker
    /// Resting limit orders. Cheaper, but a backtest that assumes maker fills
    /// is assuming its orders always got filled, which is its own fiction.
    case maker

    public var displayName: String {
        self == .taker ? "吃单 taker" : "挂单 maker"
    }
}

/// The cost model a backtest runs under.
///
/// Published tiers are a starting point, not gospel: promotions, OKB discounts
/// and sub-account arrangements all move the real number. `syncedFromAccount`
/// records that these rates came back from `okx account fees` for this specific
/// account, which is the only fully authoritative source.
public struct OKXFeeSchedule: Codable, Sendable, Equatable {
    public var tier: OKXFeeTier
    public var executionStyle: FeeExecutionStyle
    /// Assumed adverse fill offset, in basis points, on top of the fee.
    public var slippageBps: Double
    /// Overrides fetched from the live account, in basis points.
    public var spotMakerOverrideBps: Double?
    public var spotTakerOverrideBps: Double?
    public var swapMakerOverrideBps: Double?
    public var swapTakerOverrideBps: Double?
    public var syncedAt: Date?

    public init(
        tier: OKXFeeTier = .lv1,
        executionStyle: FeeExecutionStyle = .taker,
        slippageBps: Double = 5,
        spotMakerOverrideBps: Double? = nil,
        spotTakerOverrideBps: Double? = nil,
        swapMakerOverrideBps: Double? = nil,
        swapTakerOverrideBps: Double? = nil,
        syncedAt: Date? = nil
    ) {
        self.tier = tier
        self.executionStyle = executionStyle
        self.slippageBps = slippageBps
        self.spotMakerOverrideBps = spotMakerOverrideBps
        self.spotTakerOverrideBps = spotTakerOverrideBps
        self.swapMakerOverrideBps = swapMakerOverrideBps
        self.swapTakerOverrideBps = swapTakerOverrideBps
        self.syncedAt = syncedAt
    }

    public var syncedFromAccount: Bool { syncedAt != nil }

    public func feeBps(for instType: InstrumentType, style: FeeExecutionStyle? = nil) -> Double {
        let resolved = style ?? executionStyle
        switch (instType, resolved) {
        case (.spot, .maker): return spotMakerOverrideBps ?? tier.spotMakerBps
        case (.spot, .taker): return spotTakerOverrideBps ?? tier.spotTakerBps
        case (.swap, .maker): return swapMakerOverrideBps ?? tier.swapMakerBps
        case (.swap, .taker): return swapTakerOverrideBps ?? tier.swapTakerBps
        }
    }

    public func costs(for instType: InstrumentType, style: FeeExecutionStyle? = nil) -> StrategyCosts {
        StrategyCosts(feeBps: feeBps(for: instType, style: style), slippageBps: slippageBps)
    }

    /// Round-trip cost of one trade, in percent — the hurdle every signal must
    /// clear before it has made a cent.
    public func roundTripCostPct(for instType: InstrumentType) -> Double {
        (feeBps(for: instType) + slippageBps) * 2 / 100
    }

    public var summary: String {
        let source = syncedFromAccount ? "账户实时费率" : tier.displayName
        return "\(source) · 现货 \(PriceFormatter.decimals(feeBps(for: .spot), 3)) bps"
            + " · 永续 \(PriceFormatter.decimals(feeBps(for: .swap), 3)) bps"
            + " · 滑点 \(PriceFormatter.plain(slippageBps)) bps"
    }

    /// Apply rates returned by `okx account fees`.
    public mutating func apply(_ rates: AccountFeeRates) {
        switch rates.instType {
        case .spot:
            spotMakerOverrideBps = rates.makerBps
            spotTakerOverrideBps = rates.takerBps
        case .swap:
            swapMakerOverrideBps = rates.makerBps
            swapTakerOverrideBps = rates.takerBps
        }
        syncedAt = Date()
    }

    /// Drop synced values and fall back to the published table.
    public mutating func clearSync() {
        spotMakerOverrideBps = nil
        spotTakerOverrideBps = nil
        swapMakerOverrideBps = nil
        swapTakerOverrideBps = nil
        syncedAt = nil
    }
}

/// Fee rates for one instrument type, as reported by the exchange.
public struct AccountFeeRates: Sendable, Equatable {
    public let instType: InstrumentType
    /// Basis points. OKX reports fees as negative fractions (a cost), so
    /// `-0.001` becomes `10` bps here; a genuine rebate stays negative.
    public let makerBps: Double
    public let takerBps: Double

    public init(instType: InstrumentType, makerBps: Double, takerBps: Double) {
        self.instType = instType
        self.makerBps = makerBps
        self.takerBps = takerBps
    }
}
