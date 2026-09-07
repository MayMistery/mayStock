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
