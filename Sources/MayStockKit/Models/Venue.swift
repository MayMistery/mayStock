import Foundation

/// Where an instrument trades.
///
/// The venue decides three things nothing else may guess: the calendar its
/// bars follow (the kernel owns that, see `KernelCalendar`), the currency its
/// book settles in, and how an instrument id is spelled. OKX writes the
/// instrument family into the id — `BTC-USDT-SWAP` — and quotes everything in
/// USDT; Schwab names a stock by its ticker and quotes in dollars. Every
/// place that used to split an id on `-` and read the second piece as the
/// quote currency was assuming OKX, and would have read `AAPL` as a coin
/// quoted in USDT.
public enum Venue: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case okx
    case schwab

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .okx: return "OKX"
        case .schwab: return "嘉信"
        }
    }

    /// What the book on this venue settles in — budgets, P&L and equity are
    /// all denominated in it.
    public var quoteCurrency: String {
        switch self {
        case .okx: return "USDT"
        case .schwab: return "USD"
        }
    }

    /// The instrument types this venue trades.
    public var instrumentTypes: [InstrumentType] {
        switch self {
        case .okx: return [.spot, .swap]
        case .schwab: return [.stock]
        }
    }

    public func trades(_ instType: InstrumentType) -> Bool {
        instrumentTypes.contains(instType)
    }

    /// The instrument family an id names on this venue.
    ///
    /// OKX encodes it in the id itself, and this is the only place allowed to
    /// know how. The spelling `instId.hasSuffix("-SWAP")` used to be copied
    /// into a dozen call sites, which is fine right up until one of them needs
    /// to grow a case and eleven others quietly keep the old answer.
    public func instrumentType(of instId: String) -> InstrumentType {
        switch self {
        case .okx:
            return instId.hasSuffix("-" + InstrumentType.swap.rawValue) ? .swap : .spot
        case .schwab:
            return .stock
        }
    }

    /// "BTC-USDT-SWAP" → ("BTC", "USDT") on OKX; "AAPL" → ("AAPL", "USD") on
    /// Schwab, where the quote is the venue's currency rather than part of
    /// the id.
    public func currencies(of instId: String) -> (base: String, quote: String) {
        switch self {
        case .okx:
            let parts = instId.split(separator: "-").map(String.init)
            return (parts.first ?? instId, parts.count > 1 ? parts[1] : quoteCurrency)
        case .schwab:
            return (instId, quoteCurrency)
        }
    }

    /// The id that prices `base` in the venue's quote currency — what a
    /// balance in `base` is marked against.
    public func spotInstId(base: String) -> String {
        switch self {
        case .okx: return "\(base)-\(quoteCurrency)"
        case .schwab: return base
        }
    }

    /// The perpetual that shares an underlying with `instId`. Only OKX has
    /// perpetuals; on any other venue the id passes through unchanged so a
    /// caller asking for funding on a stock gets a name the venue will refuse
    /// rather than an invented one.
    public func perpetual(for instId: String) -> String {
        switch self {
        case .okx:
            return instrumentType(of: instId) == .swap
                ? instId : instId + "-" + InstrumentType.swap.rawValue
        case .schwab:
            return instId
        }
    }

    /// How a bar interval annualises on this venue — the kernel's calendar,
    /// asked through one market so the number cannot be derived twice.
    public func barsPerYear(bar: BarInterval) -> Double {
        KernelCalendar(market: StrategyMarket(
            instId: "", instType: instrumentTypes[0], bar: bar, venue: self)).barsPerYear
    }
}
