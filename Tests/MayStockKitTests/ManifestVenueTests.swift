import Foundation
import Testing
@testable import MayStockKit

/// A manifest names its venue, and the venue decides what the manifest may
/// ask for. Every rule here walks the declarations — venues, instrument
/// types, data sources — rather than naming today's cases.
@Suite("Manifest venue")
struct ManifestVenueTests {
    private func decode(_ json: String) throws -> StrategyManifest {
        try JSONDecoder().decode(StrategyManifest.self, from: Data(json.utf8))
    }

    private func manifest(
        market: StrategyMarket, signals: StrategySignals = StrategySignals(longEntry: "close > 1"),
        data: [String: AlternativeSeriesSpec] = [:]
    ) -> StrategyManifest {
        StrategyManifest(id: "x", name: "x", market: market, signals: signals, data: data)
    }

    @Test func aManifestWithoutAVenueIsOKX() throws {
        let manifest = try decode("""
        { "name": "old", "market": { "instId": "BTC-USDT", "instType": "SPOT", "bar": "1H" },
          "signals": { "longEntry": "close > 1" } }
        """)
        #expect(manifest.market.venue == .okx)
        _ = try manifest.compile()
    }

    @Test func aStockManifestNamesItsVenue() throws {
        let manifest = try decode("""
        { "schema": 2, "name": "spy",
          "market": { "venue": "schwab", "instId": "SPY", "instType": "STOCK", "bar": "1D" },
          "signals": { "longEntry": "close > sma(close, 20)", "longExit": "close < sma(close, 20)" } }
        """)
        let compiled = try manifest.compile()
        #expect(compiled.market.venue == .schwab)
        #expect(compiled.market.instType == .stock)
        #expect(compiled.market.venue.quoteCurrency == "USD")
    }

    @Test func theVenueSurvivesEncoding() throws {
        let original = manifest(market: .dailyStock)
        let decoded = try JSONDecoder().decode(StrategyManifest.self, from: original.encoded())
        #expect(decoded.market.venue == .schwab)
        #expect(decoded.schema == StrategyManifest.currentSchema)
        #expect(decoded == original)
    }

    @Test func everyTypeIsRefusedOnAVenueThatDoesNotTradeIt() {
        for venue in Venue.allCases {
            for type in InstrumentType.allCases where !venue.trades(type) {
                let manifest = manifest(
                    market: StrategyMarket(instId: "X", instType: type, bar: .h1, venue: venue))
                #expect(throws: StrategyManifestError.instrumentNotOnVenue(type, venue)) {
                    _ = try manifest.compile()
                }
            }
        }
    }

    /// Every family a venue trades has a sample id, and the venue reads each
    /// back as the family it was written for — an option names its
    /// underlying, which is the one exception by design.
    @Test func everyFamilyHasASampleSpelledAsItsOwn() throws {
        for venue in Venue.allCases {
            for type in venue.instrumentTypes {
                let id = try #require(StrategyMarket.sampleId(for: type, on: venue), "\(venue) \(type)")
                if type != .option { #expect(venue.instrumentType(of: id) == type, "\(venue) \(id)") }
            }
        }
    }

    /// The candles a backtest reads are the instId's and the position is the
    /// instType's: a manifest whose id names another family is refused. A
    /// perpetual spelled as its spot pair used to backtest on spot candles
    /// and charge no funding — OKX refuses that spelling for funding.
    @Test func anIdNamingAnotherFamilyIsRefused() throws {
        for venue in Venue.allCases {
            for declared in venue.instrumentTypes where declared != .option {
                for named in venue.instrumentTypes where named != declared && named != .option {
                    let id = try #require(StrategyMarket.sampleId(for: named, on: venue))
                    let manifest = manifest(market: StrategyMarket(instId: id, instType: declared, bar: .h1, venue: venue))
                    #expect(throws: StrategyManifestError.instrumentMismatch(
                        instId: id, named: named, declared: declared, venue: venue)) {
                        _ = try manifest.compile()
                    }
                }
                #expect(throws: Never.self) { _ = try manifest(market: .sample(declared, on: venue)).compile() }
            }
        }
    }

    @Test func aDataSourceTheVenueLacksIsRefusedAtImport() throws {
        for venue in Venue.allCases {
            let type = try #require(venue.instrumentTypes.first)
            for source in AlternativeSeriesSource.allCases where !source.isAvailable(on: venue) {
                let manifest = manifest(
                    market: .sample(type, on: venue),
                    data: ["feed": AlternativeSeriesSpec(source: source)])
                #expect(throws: StrategyManifestError.dataSourceNotOnVenue(
                    name: "feed", source: source, venue: venue)) {
                    _ = try manifest.compile()
                }
            }
        }
    }

    @Test func leverageStopsAtTheTypesCeiling() throws {
        for venue in Venue.allCases {
            for type in venue.instrumentTypes where type.allowsLeverage {
                var manifest = manifest(market: .sample(type, on: venue))
                manifest.risk.leverage = type.maxLeverage
                #expect(throws: Never.self) { _ = try manifest.compile() }
                manifest.risk.leverage = type.maxLeverage + 1
                #expect(throws: StrategyManifestError.leverageOutOfRange(
                    type.maxLeverage + 1, max: type.maxLeverage)) {
                    _ = try manifest.compile()
                }
            }
        }
        // The ceilings themselves: a stock on Regulation T margin borrows at
        // most half its value.
        #expect(InstrumentType.stock.maxLeverage == 2)
        #expect(!InstrumentType.spot.allowsLeverage)
    }

    @Test func shortingFollowsTheTypesPolicy() {
        for venue in Venue.allCases {
            for type in venue.instrumentTypes {
                let manifest = manifest(
                    market: .sample(type, on: venue),
                    signals: StrategySignals(longEntry: "close > 1", shortEntry: "close < 1"))
                if type.allowsShorting {
                    #expect(throws: Never.self) { _ = try manifest.compile() }
                } else {
                    #expect(throws: StrategyManifestError.shortingNotAllowed(type)) {
                        _ = try manifest.compile()
                    }
                }
            }
        }
        #expect(InstrumentType.stock.allowsShorting, "a margin account may short a stock")
    }

    @Test func effectiveCostsComeFromTheVenuesSchedule() throws {
        let costs = try #require(manifest(market: .dailyStock).effectiveCosts(under: FeeSchedules()))
        #expect(costs.feeBps == nil, "a per-share, sell-only model has no single bps figure")
        #expect(costs.slippageBps == SchwabFeeSchedule().slippageBps)

        let crypto = try #require(manifest(market: .hourlySpot).effectiveCosts(under: FeeSchedules()))
        #expect(crypto.feeBps == OKXFeeSchedule().feeBps(for: .spot))
    }

    @Test func costsKeepTheirShorthandWhereItApplies() throws {
        let flat = StrategyCosts(feeBps: 7, slippageBps: 1)
        let data = try JSONEncoder().encode(flat)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"feeBps\""))
        #expect(try JSONDecoder().decode(StrategyCosts.self, from: data) == flat)

        let components = try #require(SchwabFeeSchedule().costs(for: .stock))
        let componentData = try JSONEncoder().encode(components)
        let componentText = try #require(String(data: componentData, encoding: .utf8))
        #expect(componentText.contains("\"fees\""))
        #expect(try JSONDecoder().decode(StrategyCosts.self, from: componentData) == components)
    }
}
