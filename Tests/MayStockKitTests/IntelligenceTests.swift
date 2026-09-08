import Foundation
import Testing
@testable import MayStockKit

@Suite("Intelligence time and bridge contracts")
struct IntelligenceTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func quotePreservesRollingChangeAndOmitsPreviousCloseChange() throws {
        let marketTime = date("2026-09-04T20:00:00Z")
        let crypto = Ticker(instId: "BTC-USDT", last: 110, bid: nil, ask: nil,
                            reference: 100, high: 112, low: 98, volume: 1_000,
                            basis: .rolling24h, ts: marketTime)
        let stock = Ticker(instId: "TSLA", last: 110, bid: nil, ask: nil,
                           reference: 100, high: 112, low: 98, volume: 1_000,
                           basis: .previousClose, phase: .afterHours, ts: marketTime)
        let cryptoQuote = IntelligenceQuote(ticker: crypto)
        let stockQuote = IntelligenceQuote(ticker: stock)
        #expect(cryptoQuote.change24h == 10)
        #expect(stockQuote.change24h == nil)
        #expect(stockQuote.price == 110 && stockQuote.asOf == marketTime)
        let stockJSON = try #require(JSONSerialization.jsonObject(
            with: IntelligenceJSON.encoder().encode(stockQuote)) as? [String: Any])
        let cryptoJSON = try #require(JSONSerialization.jsonObject(
            with: IntelligenceJSON.encoder().encode(cryptoQuote)) as? [String: Any])
        #expect(stockJSON["change24h"] == nil, "previous-close change must not reach the model as 24h change")
        #expect(cryptoJSON["change24h"] as? Double == 10)
    }

    @Test func calendarIncludes38LocalDaysAcrossDST() {
        let days = IntelligenceSchedule.days(now: date("2026-03-08T16:00:00Z"), timezone: "America/New_York")
        #expect(days.count == 38)
        let calendar = IntelligenceSchedule.calendar(timezone: "America/New_York")
        #expect(days.allSatisfy { calendar.component(.hour, from: $0) == 0 })
        #expect(calendar.component(.day, from: days[7]) == 8)
        #expect(zip(days, days.dropFirst()).contains { $1.timeIntervalSince($0) == 23 * 3_600 })
    }

    @Test func dailyUsesSelectedZoneAndBootstraps() {
        let now = date("2026-09-08T00:05:00Z") // 08:05 Taipei
        let settings = IntelligenceSettings()
        #expect(IntelligenceSchedule.nextRun(kind: .daily, now: now, lastSuccess: nil, settings: settings) == now)
        #expect(IntelligenceSchedule.nextRun(kind: .daily, now: now,
            lastSuccess: date("2026-09-07T00:01:00Z"), settings: settings) == date("2026-09-08T00:00:00Z"))
        #expect(IntelligenceSchedule.nextRun(kind: .daily, now: now,
            lastSuccess: now, settings: settings) == date("2026-09-09T00:00:00Z"))
        #expect(IntelligenceSchedule.nextRun(kind: .daily, now: now,
            lastSuccess: date("2026-09-07T23:59:00Z"), settings: settings) == date("2026-09-08T00:00:00Z"))
    }

    @Test func intradayCadenceSurvivesRestartAndDoesNotStretchWindows() {
        let old = date("2026-09-08T00:00:00Z")
        let now = old.addingTimeInterval(5 * 3_600)
        let settings = IntelligenceSettings()
        #expect(IntelligenceSchedule.nextRun(kind: .flash, now: now, lastSuccess: old, settings: settings)
                == old.addingTimeInterval(1_800))
        #expect(IntelligenceSchedule.nextRun(kind: .hourly, now: now, lastSuccess: old, settings: settings)
                == old.addingTimeInterval(3_600))
        // Request.now is always now, not the missed scheduled time.
        let request = IntelligenceRequest(kind: .flash, now: now, settings: settings,
            watchlist: ["BTC-USDT", "ETH-USDT"], quotes: [], knownEvents: [])
        #expect(request.now == now)
        #expect(request.watchlist.count == 2)
    }

    @Test func pythonNumericDatesRoundTripWithoutAppleEpochShift() throws {
        let json = #"{"id":"r1","kind":"hourly","generatedAt":1788825600,"windowStart":1788822000,"windowEnd":1788825600,"title":"局势更新","summary":"","coverage":"partial","events":[{"id":"e1","title":"已发生事件","category":"geopolitics","importance":"high","status":"occurred","occurredAt":1788825540,"timePrecision":"minute","publishedAt":null,"summary":"","impact":"","sources":[{"title":"来源","url":"https://example.org/event","publisher":"Example","retrievedAt":1788825600,"evidence":"发生时间证据"}]}],"predictions":[{"instId":"ETH-USDT","direction":"insufficient","confidence":"low","horizonHours":24,"generatedAt":1788825600,"referencePrice":null,"drivers":[],"invalidation":"无行情","eventIds":[]}]}"#
        let decoded = try IntelligenceJSON.decoder().decode(IntelligenceReport.self, from: Data(json.utf8))
        #expect(decoded.generatedAt.timeIntervalSince1970 == 1_788_825_600)
        #expect(decoded.events[0].publishedAt == nil)
        #expect(decoded.predictions[0].referencePrice == nil)
        #expect(decoded.coverageComplete == nil) // Existing archives stay readable.
        #expect(decoded.analysis == nil && decoded.findings.isEmpty)
        #expect(decoded.predictions[0].findingIds == nil)
        let data = try IntelligenceJSON.encoder().encode(decoded)
        #expect(try IntelligenceJSON.decoder().decode(IntelligenceReport.self, from: data) == decoded)
        var partial = decoded
        partial.coverageComplete = false
        let updated = try IntelligenceJSON.encoder().encode(partial)
        #expect(try IntelligenceJSON.decoder().decode(IntelligenceReport.self, from: updated).coverageComplete == false)
    }
}
