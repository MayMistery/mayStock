import Foundation
import Testing
@testable import MayStockKit

/// Schwab charges nothing to buy and passes two regulatory levies through on
/// sales. A fee model built from percentages alone could not say that, which
/// is why fees are components with a side and a cap.
@Suite("Schwab fee schedule")
struct SchwabFeeScheduleTests {
    @Test func buyingIsFreeAndSellingPaysTheRegulators() throws {
        let model = try #require(SchwabFeeSchedule().feeModel(for: .stock))
        #expect(model.charge(side: .buy, units: 100, notional: 10_000) == 0)
        // SEC §31: 0.278 bps of $10 000 = $0.278. TAF: 100 × $0.000166 = $0.0166.
        let sale = model.charge(side: .sell, units: 100, notional: 10_000)
        #expect(abs(sale - 0.2946) < 1e-9)
    }

    @Test func theTradingActivityFeeIsCapped() throws {
        let model = try #require(SchwabFeeSchedule().feeModel(for: .stock))
        // 100 000 shares would owe $16.60 of TAF; the cap is $8.30.
        let sale = model.charge(side: .sell, units: 100_000, notional: 1_000_000)
        let sec = 1_000_000 * 0.278 / 10_000
        #expect(abs(sale - (sec + 8.30)) < 1e-9)
    }

    /// Every schedule prices exactly the types its venue trades — no schedule
    /// quietly answers zero for an instrument it has never seen.
    @Test func everyScheduleAnswersForExactlyItsVenuesTypes() {
        let schedules = FeeSchedules()
        for venue in Venue.allCases {
            let schedule = schedules.schedule(for: venue)
            #expect(schedule.venue == venue)
            for type in InstrumentType.allCases {
                #expect((schedule.feeModel(for: type) != nil) == venue.trades(type),
                        "\(venue) \(type)")
                #expect((schedule.roundTripCostPct(for: type) != nil) == venue.trades(type))
            }
        }
    }

    @Test func aStockRoundTripIsCheaperThanACryptoOne() throws {
        let stock = try #require(SchwabFeeSchedule().roundTripCostPct(for: .stock))
        let crypto = try #require(OKXFeeSchedule().roundTripCostPct(for: .spot))
        #expect(stock > 0)
        #expect(stock < crypto)
    }

    @Test func feeModelsSurviveAJSONRoundTrip() throws {
        let model = try #require(SchwabFeeSchedule().feeModel(for: .stock))
        let decoded = try JSONDecoder().decode(FeeModel.self, from: JSONEncoder().encode(model))
        #expect(decoded == model)
        #expect(model.flatBps == nil, "a per-share, sell-only model has no bps shorthand")
        #expect(FeeModel.flatBps(10).flatBps == 10)
    }

    @Test func theSchedulesRoundTripAsOneBlock() throws {
        var schedules = FeeSchedules()
        schedules.okx.tier = .vip2
        schedules.schwab.secFeeBpsOfSale = 0.3
        let decoded = try JSONDecoder().decode(FeeSchedules.self, from: JSONEncoder().encode(schedules))
        #expect(decoded == schedules)
    }

    /// The fee protocol, end to end: a stock backtest pays nothing on entry
    /// and the two levies on exit, and the weekend between two sessions is
    /// not a gap.
    @Test func aStockBacktestChargesOnlyTheSale() throws {
        let strategy = try StrategyManifest(
            id: "stock", name: "stock",
            market: .hourlyStock,
            signals: StrategySignals(longEntry: "bar_index > 0", longExit: "bar_index > 2"),
            sizing: StrategySizing(mode: .equityPct, value: 100)
        ).compile()
        // Friday 2024-07-05 and Monday 2024-07-08, seven hourly bars each,
        // on the NYSE grid, with the weekend absent as a real feed leaves it.
        let sessions: [TimeInterval] = [1_720_186_200, 1_720_445_400]
        let candles = sessions.flatMap { open in
            (0..<7).map { index in
                Candle(ts: Date(timeIntervalSince1970: open + Double(index) * 3_600),
                       open: 100, high: 100, low: 100, close: 100, volume: 1, confirmed: true)
            }
        }
        let config = BacktestConfig(
            initialCapital: 10_000,
            feeSchedules: FeeSchedules(schwab: SchwabFeeSchedule(slippageBps: 0)))
        let result = try BacktestEngine(strategy: strategy, config: config).run(candles: candles)

        // The signals re-enter after every exit, so several trades: each one
        // must pay exactly its own sale and nothing on its purchase.
        #expect(result.trades.count > 1)
        let model = try #require(SchwabFeeSchedule().feeModel(for: .stock))
        var expectedTotal = 0.0
        for trade in result.trades {
            let sale = model.charge(side: .sell, units: trade.quantity,
                                    notional: trade.quantity * trade.exitPrice)
            #expect(sale > 0)
            #expect(abs(trade.fees - sale) < 1e-9, "only the sale is charged")
            expectedTotal += sale
        }
        #expect(abs(result.metrics.feesPaid - expectedTotal) < 1e-9)

        let quality = try #require(result.dataQuality)
        #expect(quality.usable)
        #expect(quality.gaps == 0, "a weekend is not a gap on a stock calendar")
        #expect(quality.offGrid == 0)
    }

    @Test func theSameBarsAreAGapOnAContinuousCalendar() throws {
        let strategy = try StrategyManifest(
            id: "crypto", name: "crypto",
            market: .hourlySpot,
            signals: StrategySignals(longEntry: "bar_index > 0", longExit: "bar_index > 2")
        ).compile()
        let sessions: [TimeInterval] = [1_720_186_200, 1_720_445_400]
        let candles = sessions.flatMap { open in
            (0..<7).map { index in
                Candle(ts: Date(timeIntervalSince1970: open + Double(index) * 3_600),
                       open: 100, high: 100, low: 100, close: 100, volume: 1, confirmed: true)
            }
        }
        let result = try BacktestEngine(strategy: strategy, config: BacktestConfig(initialCapital: 10_000))
            .run(candles: candles)
        let quality = try #require(result.dataQuality)
        #expect(quality.gaps > 0, "the weekend is missing hours on a market that never closes")
    }
}
