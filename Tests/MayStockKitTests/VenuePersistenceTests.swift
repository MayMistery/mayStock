import Foundation
import Testing
@testable import MayStockKit

/// Records written before venues existed were all OKX, and must read back as
/// such; records written since carry their venue.
@Suite("Venue persistence")
struct VenuePersistenceTests {
    private func stripping(_ key: String, from data: Data) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: key)
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func fillsRememberTheirVenue() throws {
        let fill = StrategyFill(
            id: "1", strategyId: "s", instId: "AAPL", side: .buy, price: 100, quantity: 1,
            feeQuote: 0, ts: Date(timeIntervalSince1970: 0), clOrdId: nil, mode: .demo,
            venue: .schwab)
        let data = try JSONEncoder().encode(fill)
        #expect(try JSONDecoder().decode(StrategyFill.self, from: data).venue == .schwab)
        let legacy = try JSONDecoder().decode(StrategyFill.self, from: stripping("venue", from: data))
        #expect(legacy.venue == .okx)
    }

    @Test func positionsRememberTheirVenue() throws {
        let state = StrategyPositionState(strategyId: "s", instId: "AAPL", venue: .schwab)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(StrategyPositionState.self, from: data).venue == .schwab)
        let legacy = try JSONDecoder().decode(
            StrategyPositionState.self, from: stripping("venue", from: data))
        #expect(legacy.venue == .okx)
    }

    @Test func aV3PortfolioKeepsItsOKXScheduleAndGainsTheOthers() throws {
        // v3 carried one schedule under `feeSchedule`. Its tier and slippage
        // must survive; every other venue starts from its defaults.
        let old = OKXFeeSchedule(tier: .vip1, slippageBps: 3)
        let schedule = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: ["mode": "demo", "feeSchedule": schedule])

        let prefs = try JSONDecoder().decode(StrategyPortfolioPrefs.self, from: data)
        #expect(prefs.feeSchedules.okx == old)
        #expect(prefs.feeSchedules.schwab == SchwabFeeSchedule())

        let rewritten = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs)) as? [String: Any])
        #expect(rewritten["feeSchedules"] != nil)
        #expect(rewritten["feeSchedule"] == nil, "the legacy key is read, never written")
    }

    @Test func theWatchlistIsOKX() {
        // Every watch item prices on OKX; the venue is a fact of the list, not
        // of the item, until another venue's quotes are wired in.
        #expect(WatchItem.venue == .okx)
    }
}
