import Foundation
@testable import MayStockKit

/// Markets the tests reach for by name, so a fixture's calendar and venue are
/// stated once rather than re-spelled in every call.
extension StrategyMarket {
    /// The default OKX fixture: hourly spot, a continuous calendar.
    static let hourlySpot = StrategyMarket(instId: "BTC-USDT", instType: .spot, bar: .h1)
    static let dailySpot = StrategyMarket(instId: "BTC-USDT", instType: .spot, bar: .d1)
    static let hourlySwap = StrategyMarket(instId: "BTC-USDT-SWAP", instType: .swap, bar: .h1)
    /// A US stock on Schwab: NYSE sessions, dollars.
    static let hourlyStock = StrategyMarket(instId: "SPY", instType: .stock, bar: .h1, venue: .schwab)
    static let dailyStock = StrategyMarket(instId: "SPY", instType: .stock, bar: .d1, venue: .schwab)
}

extension StrategyMarket {
    /// An id spelled the way `venue` spells a `type` instrument — for tests
    /// that walk every family a venue declares. An option manifest names the
    /// underlying it reads signals from. Every family a venue trades has one
    /// (`ManifestVenueTests.everyFamilyHasASampleSpelledAsItsOwn`).
    static func sampleId(for type: InstrumentType, on venue: Venue) -> String? {
        switch (venue, type) {
        case (.okx, .spot), (.okx, .option): return "BTC-USDT"
        case (.okx, .swap): return "BTC-USDT-SWAP"
        case (.schwab, .stock): return "SPY"
        default: return nil
        }
    }

    /// An hourly market of `type` on `venue`, spelled as that venue spells it.
    static func sample(_ type: InstrumentType, on venue: Venue) -> StrategyMarket {
        StrategyMarket(instId: sampleId(for: type, on: venue) ?? "X", instType: type, bar: .h1, venue: venue)
    }
}

