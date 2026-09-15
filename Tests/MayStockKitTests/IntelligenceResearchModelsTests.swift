import Foundation
import Testing
@testable import MayStockKit

@Suite("Intelligence research and forecast provenance")
struct IntelligenceResearchModelsTests {
    @Test func pythonAnalysisSchemaPreservesParagraphsAndEvidence() throws {
        let json = #"{"id":"r-new","kind":"hourly","generatedAt":1788825600,"windowStart":1788822000,"windowEnd":1788825600,"title":"今早的转折","summary":"先核对价格，再检验解释。","coverage":"部分分钟数据不可用","events":[],"analysis":[{"id":"price","title":"10:20 后卖压增强","body":"第一段：价格和成交量是直接观测。\n\n第二段：精确记录市场、时区和对照窗口。","kind":"observation","instIds":["BTC-USDT"],"sources":[{"title":"交易所行情","url":"https://example.org/candles","publisher":"Exchange","retrievedAt":1788825600,"evidence":"10:20 UTC+8; close 100; taker sell 65%"}]},{"id":"cause","title":"跨市场同步可能解释回落","body":"同步性支持该假说，但不能单独证明因果。","kind":"inference","instIds":["BTC-USDT","ETH-USDT"],"sources":[]},{"id":"gap","title":"分钟级汇率仍待核实","body":"当前代理数据只能支持更宽的时间窗口。","kind":"unknown","instIds":[],"sources":[]}],"predictions":[{"instId":"BTC-USDT","direction":"down","confidence":"low","horizonHours":1,"generatedAt":1788825600,"referencePrice":100,"drivers":["主动卖出占比升高"],"invalidation":"价格收复前高","eventIds":[],"findingIds":["price","cause"]}]}"#
        let report = try IntelligenceJSON.decoder().decode(IntelligenceReport.self, from: Data(json.utf8))
        #expect(report.findings.count == 3)
        #expect(report.findings.map(\.kind) == [.observation, .inference, .unknown])
        #expect(report.findings[0].body.contains("\n\n第二段"))
        #expect(report.findings[0].sources[0].evidence.contains("taker sell 65%"))
        #expect(report.predictions[0].findingIds == ["price", "cause"])
        let encoded = try IntelligenceJSON.encoder().encode(report)
        #expect(try IntelligenceJSON.decoder().decode(IntelligenceReport.self, from: encoded) == report)
        let wire = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(wire["analysis"] != nil)
        #expect(wire["findings"] == nil, "The convenience property must not alter the Python wire schema")
    }

    @Test func latestForecastResolvesOnlyItsOwnReportDespiteRepeatedIds() throws {
        let first = makeReport(id: "old", time: 100, evidence: "older evidence")
        let latest = makeReport(id: "new", time: 200, evidence: "current evidence")
        let context = try #require(IntelligencePredictionContext.latest(for: "BTC-USDT", in: [latest, first]))
        #expect(context.reportId == "new")
        #expect(context.prediction.generatedAt == Date(timeIntervalSince1970: 200))
        #expect(context.findings.count == 1 && context.events.count == 1)
        #expect(context.findings[0].sources[0].evidence == "current evidence")
        #expect(context.events[0].sources[0].evidence == "current evidence")
        #expect(IntelligencePredictionContext.latest(for: "MISSING", in: [latest, first]) == nil)
    }

    @Test func forecastFromAnotherArchiveCannotBorrowItsEvidence() {
        let first = makeReport(id: "old", time: 100, evidence: "older evidence")
        let other = makeReport(id: "new", time: 200, evidence: "different evidence")
        let context = IntelligencePredictionContext(prediction: first.predictions[0], report: other)
        #expect(context.findings.isEmpty)
        #expect(context.events.isEmpty)
    }

    private func makeReport(id: String, time: TimeInterval, evidence: String) -> IntelligenceReport {
        let source = IntelligenceSource(title: id, url: "https://example.org/" + id, evidence: evidence)
        let event = IntelligenceEvent(id: "event-1", title: id, sources: [source])
        let finding = IntelligenceFinding(id: "finding-1", title: id, body: evidence,
                                          kind: .observation, instIds: ["BTC-USDT"], sources: [source])
        let unrelated = IntelligenceFinding(id: "finding-2", title: "unrelated", body: "other instrument",
                                            kind: .unknown, instIds: ["ETH-USDT"])
        let prediction = IntelligencePrediction(instId: "BTC-USDT", generatedAt: Date(timeIntervalSince1970: time),
                                                eventIds: ["event-1"], findingIds: ["finding-1"])
        return IntelligenceReport(id: id, kind: .hourly, events: [event], predictions: [prediction],
                                  analysis: [finding, unrelated])
    }
}
