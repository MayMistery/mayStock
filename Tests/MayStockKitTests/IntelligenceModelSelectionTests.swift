import Foundation
import Testing
@testable import MayStockKit

@Suite("Intelligence model selection contracts")
struct IntelligenceModelSelectionTests {
    private let expertModel = "model_hub/es1_orange_o48_for_bench_expert[1m]"

    @Test func legacyArchiveKeepsDefaultSettingsAndUnknownReportModel() throws {
        struct Archive: Codable {
            var settings: IntelligenceSettings
            var reports: [IntelligenceReport]
        }
        let json = #"{"settings":{"enabled":false,"dailyHour":9,"timezone":"America/New_York","horizonHours":1},"reports":[{"id":"old-report","kind":"daily","generatedAt":1788825600,"windowStart":1788822000,"windowEnd":1788825600,"title":"旧日报","summary":"已有摘要","coverage":"","events":[],"predictions":[]}]}"#
        var archive = try IntelligenceJSON.decoder().decode(Archive.self, from: Data(json.utf8))
        #expect(archive.settings.model == "model_hub/es1_orange_o50[1m]")
        #expect(!archive.settings.enabled && archive.settings.dailyHour == 9)
        #expect(archive.settings.timezone == "America/New_York")
        #expect(archive.reports[0].model == nil)
        archive.settings.model = expertModel
        let migrated = try IntelligenceJSON.decoder().decode(Archive.self,
            from: IntelligenceJSON.encoder().encode(archive))
        #expect(migrated.settings.model == expertModel)
        #expect(migrated.reports[0].model == nil)
        #expect(migrated.reports[0].summary == "已有摘要")
    }

    @Test func settingsRoundTripKeepsSelectedModelAndMissingModelUsesLegacyDefault() throws {
        let settings = IntelligenceSettings(dailyHour: 7, horizonHours: 1, model: expertModel)
        let encoded = try IntelligenceJSON.encoder().encode(settings)
        #expect(try IntelligenceJSON.decoder().decode(IntelligenceSettings.self, from: encoded) == settings)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["model"] as? String == expertModel)
        for legacy in [#"{}"#, #"{"model":null}"#] {
            let decoded = try IntelligenceJSON.decoder().decode(IntelligenceSettings.self, from: Data(legacy.utf8))
            #expect(decoded.model == IntelligenceSettings.defaultModel)
        }
    }

    @Test func modelNormalizationSupportsRoutingPunctuationAndTrimsEdges() {
        for model in [expertModel, IntelligenceSettings.defaultModel, "claude-sonnet-4-5",
                      "provider/team.model:v2_alpha[1m]-2026", "3-preview", "A:/[]_.-",
                      String(repeating: "a", count: 200)] {
            #expect(IntelligenceSettings.normalizeModel(model) == model)
            #expect(IntelligenceSettings.normalizeModel(" \t" + model + "\r\n") == model)
        }
    }

    @Test func invalidModelNamesAreRejectedWithoutTruncation() {
        for model in ["", " \t\n", "-model", "/model", ".model", "_model", ":model", "[model]",
                      "provider/model name", "model\tname", "model\nname", "model\rname",
                      "model\u{0}", "\u{0}model", "model\u{7F}", "模型", "model-é", "model🚀",
                      "model?token=x", "model#fragment", "model;command", "$(model)", "model\\name",
                      String(repeating: "a", count: 201)] {
            #expect(IntelligenceSettings.normalizeModel(model) == nil)
        }
    }

    @Test func newRequestWritesSelectedModelAndOldRequestDecodesToLegacyDefault() throws {
        let request = makeRequest(model: expertModel)
        let data = try IntelligenceJSON.encoder().encode(request)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["model"] as? String == expertModel)
        let decoded = try IntelligenceJSON.decoder().decode(IntelligenceRequest.self, from: data)
        #expect(decoded.model == expertModel)
        #expect(decoded.horizonHours == 1 && decoded.watchlist == ["BTC-USDT"])
        object.removeValue(forKey: "model")
        let legacy = try IntelligenceJSON.decoder().decode(IntelligenceRequest.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.model == IntelligenceSettings.defaultModel)
    }

    @Test func reportModelProvenanceRoundTripsIndependentlyOfCurrentSettings() throws {
        let request = makeRequest(model: expertModel)
        let report = makeReport(for: request, model: expertModel)
        let encoded = try IntelligenceJSON.encoder().encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["model"] as? String == expertModel)
        let decoded = try IntelligenceJSON.decoder().decode(IntelligenceReport.self, from: encoded)
        #expect(decoded == report)
        #expect(decoded.model != IntelligenceSettings().model)
    }

    @Test func bridgeAcceptsMatchingWorkerModel() async throws {
        let request = makeRequest(model: expertModel)
        let report = makeReport(for: request, model: expertModel)
        let (bridge, directory) = try fixtureBridge(report: report)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await bridge.generate(request) == report)
    }

    @Test func bridgeRejectsWorkerThatReturnsAnotherModel() async throws {
        let request = makeRequest(model: expertModel)
        let report = makeReport(for: request, model: IntelligenceSettings.defaultModel)
        let (bridge, directory) = try fixtureBridge(report: report)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: IntelligenceBridgeError.self) { try await bridge.generate(request) }
    }

    @Test func bridgeRejectsMissingWorkerProvenanceWhileOldReportStillDecodes() async throws {
        let request = makeRequest(model: expertModel)
        let legacy = makeReport(for: request, model: nil)
        let data = try IntelligenceJSON.encoder().encode(legacy)
        #expect(try IntelligenceJSON.decoder().decode(IntelligenceReport.self, from: data).model == nil)
        let (bridge, directory) = try fixtureBridge(report: legacy)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: IntelligenceBridgeError.self) { try await bridge.generate(request) }
    }

    private func makeRequest(model: String) -> IntelligenceRequest {
        IntelligenceRequest(kind: .hourly, now: Date(timeIntervalSince1970: 1_788_825_600),
                            settings: IntelligenceSettings(model: model), watchlist: ["BTC-USDT"],
                            quotes: [], knownEvents: [])
    }

    private func makeReport(for request: IntelligenceRequest, model: String?) -> IntelligenceReport {
        IntelligenceReport(id: "fixture-report", kind: request.kind, generatedAt: request.now,
                           windowStart: request.now.addingTimeInterval(-3_600), windowEnd: request.now,
                           title: "模型来源测试", summary: "仅测试模型路由元数据", model: model)
    }

    /// A shell fixture stands in for the JSON worker without invoking an SDK,
    /// networking or depending on a developer's Python environment.
    private func fixtureBridge(report: IntelligenceReport) throws -> (IntelligenceBridge, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("worker.sh")
        let json = String(decoding: try IntelligenceJSON.encoder().encode(report), as: UTF8.self)
        try ("#!/bin/sh\ncat > /dev/null\ncat <<'REPORT_JSON'\n" + json + "\nREPORT_JSON\n")
            .write(to: script, atomically: true, encoding: .utf8)
        return (IntelligenceBridge(python: URL(fileURLWithPath: "/bin/sh"), script: script), directory)
    }
}
