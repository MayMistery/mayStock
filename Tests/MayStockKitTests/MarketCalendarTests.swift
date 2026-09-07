import Foundation
import Testing
@testable import MayStockKit

/// The Swift side never does bar arithmetic of its own; it asks the kernel's
/// calendar through `KernelCalendar`. These tests walk every declared venue
/// and bar so a new venue whose calendar the kernel does not know fails here,
/// and pin the NYSE facts the runner and the backtest both depend on.
@Suite("Market calendar")
struct MarketCalendarTests {
    /// 2024-07-05 (Friday) 15:30 New York: the last hourly-grid bar of the
    /// session. 16:00 that day is the close; 2024-07-08 09:30 is Monday's open.
    private static let fridayLastBar = Date(timeIntervalSince1970: 1_720_207_800)
    private static let fridayClose = Date(timeIntervalSince1970: 1_720_209_600)
    private static let mondayOpen = Date(timeIntervalSince1970: 1_720_445_400)

    @Test func everyVenueAnnualisesEveryBar() {
        for venue in Venue.allCases {
            for bar in BarInterval.allCases {
                let perYear = venue.barsPerYear(bar: bar)
                #expect(perYear > 0 && perYear.isFinite, "\(venue) \(bar)")
            }
        }
    }

    @Test func aContinuousMarketCountsCalendarTime() {
        // A calendar year averages 365.25 days, and a market that never closes
        // trades every one of them.
        #expect(Venue.okx.barsPerYear(bar: .d1) == 365.25)
        #expect(Venue.okx.barsPerYear(bar: .h1) == 365.25 * 24)
    }

    @Test func aStockMarketCountsSessions() {
        #expect(Venue.schwab.barsPerYear(bar: .d1) == 252)
        // A 6.5-hour session holds seven hourly bars, the last a short one.
        #expect(Venue.schwab.barsPerYear(bar: .h1) == 252 * 7)
    }

    @Test func theWeekendHoldsNoStockBars() {
        let stock = StrategyMarket.hourlyStock.calendar
        #expect(stock.expectedBars(from: Self.fridayLastBar, to: Self.mondayOpen) == 1,
                "Friday's last bar to Monday's open is one bar apart: Monday's first")
        #expect(stock.expectedBars(from: Self.fridayClose,
                                   to: Self.mondayOpen.addingTimeInterval(-1)) == 0)
        // The same span on a continuous market is every hour of it: from
        // Friday 20:00 UTC up to the Monday 14:00 UTC bar is 66 hourly opens.
        let crypto = StrategyMarket.hourlySpot.calendar
        let mondayFourteen = Self.mondayOpen.addingTimeInterval(1_800)
        #expect(crypto.expectedBars(from: Self.fridayClose, to: mondayFourteen) == 66)
        // And an entry part-way through a bar has seen every open since.
        #expect(crypto.expectedBars(from: Self.fridayClose.addingTimeInterval(300),
                                    to: mondayFourteen) == 66)
    }

    @Test func theNextOpenAfterFridaysLastBarIsMonday() {
        let stock = StrategyMarket.hourlyStock.calendar
        #expect(stock.nextOpen(after: Self.fridayLastBar) == Self.mondayOpen)
        #expect(stock.barClose(Self.fridayLastBar) == Self.fridayClose,
                "the last bar of a session closes with the session, not an hour later")
        #expect(!stock.isOpen(at: Self.fridayClose))
        #expect(stock.isOpen(at: Self.mondayOpen))

        let crypto = StrategyMarket.hourlySpot.calendar
        #expect(crypto.nextOpen(after: Self.fridayLastBar)
                == Self.fridayLastBar.addingTimeInterval(3_600))
        #expect(crypto.isOpen(at: Self.fridayClose))
    }

    @Test func aStockTradingDayIsANewYorkDay() {
        // 03:00 UTC on Monday 2024-07-08 is still Sunday evening in New York;
        // 13:30 UTC is Monday's open. A breaker keyed on UTC days would reset
        // between the two; the stock calendar keeps them apart and Monday's
        // whole session together. The continuous market keys on UTC.
        let sundayEveningNY = Date(timeIntervalSince1970: 1_720_407_600)
        let stock = StrategyMarket.dailyStock.calendar
        #expect(stock.sessionKey(sundayEveningNY) != stock.sessionKey(Self.mondayOpen))
        #expect(stock.sessionKey(Self.mondayOpen)
                == stock.sessionKey(Self.mondayOpen.addingTimeInterval(6 * 3_600)))
        let crypto = StrategyMarket.dailySpot.calendar
        #expect(crypto.sessionKey(sundayEveningNY) == crypto.sessionKey(Self.mondayOpen))
    }

    @Test func barCountsForAWindowFollowTheCalendar() {
        // Thirty days back from Monday 2024-07-08 09:30 New York. Continuous:
        // 720 hourly opens. NYSE: seventeen full sessions × 7 bars, Juneteenth
        // and Independence Day closed, 3 July's early close holding 4 bars,
        // plus Monday's own first bar = 124.
        let crypto = StrategyMarket.hourlySpot.calendar
            .barCount(days: 30, endingAt: Self.mondayOpen)
        let stock = StrategyMarket.hourlyStock.calendar
            .barCount(days: 30, endingAt: Self.mondayOpen)
        #expect(crypto == 30 * 24)
        #expect(stock == 124)
    }
}
