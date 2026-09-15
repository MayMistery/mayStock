import Foundation
import Testing
@testable import MayStockKit

@Suite("Intelligence archive library")
struct IntelligenceLibraryTests {
    private let now = Date(timeIntervalSince1970: 1_788_868_800)

    @Test func quietPollAndUnknownOnlyReportDoNotReplaceResearch() {
        let research = report("research", .hourly, at: now.addingTimeInterval(-3_600),
                              findings: [finding("price")])
        let quiet = report("quiet", .hourly, at: now.addingTimeInterval(-1_800),
                           predictions: [IntelligencePrediction(instId: "BTC-USDT", generatedAt: now)])
        let unknown = report("unknown", .hourly, at: now.addingTimeInterval(-600),
                             findings: [finding("gap", kind: .unknown, sources: [])])
        let emptyFlash = report("flash", .flash, at: now)
        let library = library([quiet, unknown, emptyFlash, research])
        #expect(library.currentReport?.id == "research")
        #expect(library.historyDays.flatMap(\.editions).map(\.report.id) == ["research"])
        #expect(!IntelligenceLibrary.hasContent(quiet))
        #expect(!IntelligenceLibrary.hasContent(unknown))
        #expect(!IntelligenceLibrary.hasContent(emptyFlash))
    }

    @Test func substantiveContentRequiresEvidenceAndResolvablePredictionReferences() {
        let unsupported = report("unsupported", .hourly, at: now,
                                 findings: [finding("claim", sources: [])])
        let dangling = report("dangling", .hourly, at: now, predictions: [
            IntelligencePrediction(instId: "BTC-USDT", direction: .down,
                                   generatedAt: now, eventIds: ["absent"], findingIds: ["absent"])
        ])
        let blank = report("blank", .hourly, at: now,
                           findings: [IntelligenceFinding(id: "blank", title: "blank", body: " \n ",
                                                          kind: .observation, sources: [source()])])
        #expect(!IntelligenceLibrary.hasContent(unsupported))
        #expect(!IntelligenceLibrary.hasContent(dangling))
        #expect(!IntelligenceLibrary.hasContent(blank))
        #expect(!IntelligenceLibrary.hasContent(report("empty-flash-with-analysis", .flash, at: now,
                                                      findings: [finding("fact")])))
        #expect(!IntelligenceLibrary.hasContent(report("unknown-direction", .hourly, at: now,
            predictions: [IntelligencePrediction(instId: "BTC-USDT", direction: .down,
                                                   generatedAt: now, findingIds: ["gap"])],
            findings: [finding("gap", kind: .unknown)])))
        #expect(IntelligenceLibrary.hasContent(report("daily", .daily, at: now)))
        #expect(IntelligenceLibrary.hasContent(report("event", .hourly, at: now,
                                                     events: [event("event", at: now)])))
        #expect(IntelligenceLibrary.hasContent(report("finding", .hourly, at: now,
                                                     findings: [finding("fact")])))
    }

    @Test func failedModernDailyDoesNotReplaceResearchWhileLegacySummaryRemainsVisible() {
        let research = report("research", .hourly, at: now.addingTimeInterval(-300),
                              findings: [finding("fact")])
        var failed = report("failed-daily", .daily, at: now,
                            predictions: [IntelligencePrediction(instId: "BTC-USDT", generatedAt: now)],
                            findings: [])
        failed.title = "研究证据未通过校验"
        failed.summary = "本次研究没有通过证据校验。"
        var emptyLegacy = report("empty-legacy", .daily, at: now)
        emptyLegacy.summary = " \n "
        let legacy = report("legacy", .daily, at: now.addingTimeInterval(-600))
        let library = library([failed, emptyLegacy, research, legacy])
        #expect(!IntelligenceLibrary.hasContent(failed))
        #expect(!IntelligenceLibrary.hasContent(emptyLegacy))
        #expect(IntelligenceLibrary.hasContent(legacy))
        #expect(library.currentReport?.id == "research")
        #expect(library.todayDaily?.id == "legacy")
        #expect(library.historyDays.flatMap(\.editions).map(\.report.id) == ["research", "legacy"])
    }

    @Test func dailyVersionsUseLocalIssuedDateAcrossSpringDST() throws {
        let morning = report("morning", .daily, at: date("2026-03-08T05:30:00Z"))
        let evening = report("evening", .daily, at: date("2026-03-09T03:30:00Z"))
        let following = report("following", .daily, at: date("2026-03-09T04:30:00Z"))
        let library = IntelligenceLibrary(reports: [morning, following, evening], events: [],
                                          now: date("2026-03-09T12:00:00Z"), timezone: "America/New_York")
        #expect(library.historyDays.map(\.id) == ["2026-03-09", "2026-03-08"])
        let prior = try #require(library.historyDays.last)
        #expect(prior.date == date("2026-03-08T05:00:00Z"))
        #expect(library.historyDays[0].date.timeIntervalSince(prior.date) == 23 * 3_600)
        #expect(prior.editions.count == 1)
        #expect(prior.editions[0].id == "daily:2026-03-08")
        #expect(prior.editions[0].versions.map(\.id) == ["evening", "morning"])
        #expect(prior.editions[0].report.id == "evening")
        #expect(library.todayDaily?.id == "following")
    }

    @Test func repeatedHourDuringAutumnDSTKeepsOneDailyEdition() throws {
        let before = report("before", .daily, at: date("2026-11-01T05:30:00Z"))
        let after = report("after", .daily, at: date("2026-11-01T06:30:00Z"))
        let next = report("next", .daily, at: date("2026-11-02T06:00:00Z"))
        let library = IntelligenceLibrary(reports: [before, next, after], events: [],
                                          now: date("2026-11-02T12:00:00Z"), timezone: "America/New_York")
        #expect(library.historyDays.count == 2)
        let prior = try #require(library.historyDays.last)
        #expect(library.historyDays[0].date.timeIntervalSince(prior.date) == 25 * 3_600)
        #expect(prior.editions[0].versions.map(\.id) == ["after", "before"])
    }

    @Test func editionUsesDailyIssueDateRatherThanFutureCalendarEnd() throws {
        var daily = report("daily", .daily, at: date("2026-09-08T01:00:00Z"))
        daily.windowStart = date("2026-09-01T00:00:00Z")
        daily.windowEnd = date("2026-10-09T00:00:00Z")
        let library = library([daily])
        #expect(library.historyDays.map(\.id) == ["2026-09-08"])
        #expect(library.todayDaily?.id == "daily")
        #expect(try #require(library.historyDays.first).editions[0].versions == [daily])
    }

    @Test func hourlyVersionsMergeOnlyIdenticalWindowEndAndKind() throws {
        let window = date("2026-09-08T15:55:00Z")
        let first = report("first", .hourly, at: date("2026-09-08T15:56:00Z"),
                           windowEnd: window, findings: [finding("first")])
        let rerun = report("rerun", .hourly, at: date("2026-09-08T16:03:00Z"),
                           windowEnd: window, findings: [finding("rerun")])
        let nextHour = report("next", .hourly, at: date("2026-09-08T17:01:00Z"),
                              windowEnd: date("2026-09-08T17:00:00Z"), findings: [finding("next")])
        let flash = report("flash", .flash, at: date("2026-09-08T15:57:00Z"),
                           windowEnd: window, events: [event("news", at: window)])
        let library = library([nextHour, rerun, flash, first])
        #expect(library.historyDays.map(\.id) == ["2026-09-09", "2026-09-08"])
        let prior = try #require(library.historyDays.last)
        #expect(prior.editions.count == 2)
        let hourly = try #require(prior.editions.first { $0.kind == .hourly })
        #expect(hourly.versions.map(\.id) == ["rerun", "first"])
        #expect(hourly.report.id == "rerun")
        #expect(library.historyDays[0].editions[0].versions.map(\.id) == ["next"])
    }

    @Test func reportCanonicalizationIsIndependentOfInputOrderAndKeepsNewestDuplicateID() {
        let old = report("same", .daily, at: now.addingTimeInterval(-100))
        var replacement = report("same", .daily, at: now)
        replacement.summary = "latest"
        var collision = replacement
        collision.summary = "another saved value"
        let different = report("a-first", .daily, at: now)
        let inputs = [old, replacement, different, collision, replacement]
        let canonical = IntelligenceLibrary.canonicalReports(inputs)
        #expect(canonical == IntelligenceLibrary.canonicalReports(Array(inputs.reversed())))
        #expect(canonical.map(\.id) == ["a-first", "same"])
        #expect(canonical[1].generatedAt == now)
        #expect(library(inputs).historyDays == library(Array(inputs.reversed())).historyDays)
    }

    @Test func allDailyVersionsSurviveWithoutTitleSimilarityDeduplication() {
        let reports = (0..<4).map { index in
            report("v\(index)", .daily, at: now.addingTimeInterval(Double(index) * 10))
        }
        let editions = library(reports).historyDays.flatMap(\.editions)
        #expect(editions.count == 1)
        #expect(editions[0].versions.map(\.id) == ["v3", "v2", "v1", "v0"])
    }

    @Test func currentWatchlistOutlookAndEvidenceBelongToOneReport() throws {
        let old = report("old", .hourly, at: now.addingTimeInterval(-100), predictions: [
            IntelligencePrediction(instId: "ETH-USDT", direction: .up, generatedAt: now,
                                   findingIds: ["shared"])
        ], findings: [finding("shared", body: "older report")])
        let current = report("current", .hourly, at: now, predictions: [
            IntelligencePrediction(instId: "BTC-USDT", direction: .down,
                                   generatedAt: now.addingTimeInterval(-7_200), findingIds: ["shared"])
        ], findings: [finding("shared", body: "current report")])
        let flash = report("flash", .flash, at: now.addingTimeInterval(1), predictions: [
            IntelligencePrediction(instId: "BTC-USDT", direction: .up, generatedAt: now,
                                   eventIds: ["news"])
        ], events: [event("news", at: now)])
        let library = library([flash, old, current])
        let context = try #require(library.currentPrediction(for: "BTC-USDT"))
        #expect(context.reportId == "current")
        #expect(context.findings.map(\.body) == ["current report"])
        #expect(context.prediction.direction == .down)
        #expect(context.prediction.generatedAt == now.addingTimeInterval(-7_200))
        #expect(context.prediction.expiresAt < now)
        #expect(library.currentPrediction(for: "ETH-USDT") == nil)
    }

    @Test func rereadingExpiredResearchDoesNotMoveItToTodayOrRefreshPrediction() throws {
        let issued = now.addingTimeInterval(-3 * 86_400)
        let prediction = IntelligencePrediction(instId: "BTC-USDT", direction: .neutral,
                                                 generatedAt: issued, findingIds: ["price"])
        let report = report("expired", .daily, at: issued, predictions: [prediction],
                            findings: [finding("price")])
        let earlier = library([report])
        let later = IntelligenceLibrary(reports: [report], events: [], now: now.addingTimeInterval(86_400),
                                         timezone: "Asia/Taipei")
        #expect(earlier.historyDays == later.historyDays)
        #expect(later.todayDaily == nil)
        #expect(later.currentReport?.generatedAt == issued)
        #expect(try #require(later.currentPrediction(for: "BTC-USDT")).prediction == prediction)
    }

    @Test func eventsPreferLatestReportAndFallbackDuplicatesAreDeterministic() throws {
        let timestamp = now.addingTimeInterval(-300)
        var original = event("same", at: timestamp)
        original.title = "original"
        var corrected = original
        corrected.title = "corrected"
        var standalone = original
        standalone.title = "standalone does not override a report"
        standalone.sources = [source(retrieved: now.addingTimeInterval(100))]
        var fallbackOld = event("fallback", at: now.addingTimeInterval(300))
        fallbackOld.title = "older evidence"
        var fallbackNew = fallbackOld
        fallbackNew.title = "newer evidence"
        fallbackNew.sources = [source(retrieved: now.addingTimeInterval(100))]
        let reports = [report("new", .daily, at: now, events: [corrected]),
                       report("old", .daily, at: now.addingTimeInterval(-1), events: [original])]
        let first = library(reports, events: [standalone, fallbackOld, fallbackNew])
        let reversed = library(Array(reports.reversed()), events: [fallbackNew, fallbackOld, standalone])
        #expect(first.events == reversed.events)
        #expect(try #require(first.events.first { $0.id == "same" }).title == "corrected")
        #expect(try #require(first.events.first { $0.id == "fallback" }).title == "newer evidence")
    }

    @Test func recentFlashesUseOccurrenceTimeStatusAndFlashProvenance() {
        let recent = event("recent", at: now.addingTimeInterval(-30))
        let sameTime = event("independent", at: recent.occurredAt)
        let old = event("old", at: now.addingTimeInterval(-86_401))
        let future = event("future", at: now.addingTimeInterval(1))
        let unverified = event("unverified", at: recent.occurredAt, status: .unverified)
        let scheduled = event("scheduled", at: recent.occurredAt, status: .scheduled)
        var dayOnly = event("day-only", at: recent.occurredAt)
        dayOnly.timePrecision = .day
        var sourceless = event("sourceless", at: recent.occurredAt)
        sourceless.sources = []
        let dailyOnly = event("daily-only", at: now)
        let reports = [report("flash1", .flash, at: now.addingTimeInterval(-10),
                              events: [recent, sameTime, old, future, unverified, scheduled, dayOnly, sourceless]),
                       report("flash2", .flash, at: now, events: [recent]),
                       report("daily", .daily, at: now, events: [dailyOnly])]
        let library = library(reports)
        #expect(library.recentFlashes.map(\.id) == ["independent", "recent"])
        #expect(library.recentFlashes[0].occurredAt == recent.occurredAt)
    }

    @Test func upcomingEventsContainOnlyFutureScheduledItemsInTimeOrder() {
        var uncertainDate = event("uncertain-date", at: now.addingTimeInterval(200), status: .scheduled)
        uncertainDate.timePrecision = .unknown
        let items = [uncertainDate, event("late", at: now.addingTimeInterval(600), status: .scheduled),
                     event("early", at: now.addingTimeInterval(300), status: .scheduled),
                     event("unknown", at: now.addingTimeInterval(100), status: .unverified),
                     event("past", at: now.addingTimeInterval(-10), status: .scheduled),
                     event("now", at: now, status: .scheduled)]
        #expect(library([], events: items).upcomingEvents.map(\.id) == ["early", "late"])
    }

    @Test func dayPrecisionScheduleStaysUpcomingForItsWholeLocalDay() {
        let calendar = IntelligenceCalendar.calendar(timezone: "Asia/Taipei")
        let today = calendar.startOfDay(for: now)
        var todayEvent = event("today", at: today, status: .scheduled)
        todayEvent.timePrecision = .day
        var yesterday = event("yesterday", at: calendar.date(byAdding: .day, value: -1, to: today)!,
                              status: .scheduled)
        yesterday.timePrecision = .day
        var outsideWindow = event("outside", at: calendar.date(byAdding: .day, value: 31, to: today)!,
                                  status: .scheduled)
        outsideWindow.timePrecision = .day
        let library = library([], events: [todayEvent, yesterday, outsideWindow])
        #expect(library.upcomingEvents.map(\.id) == ["today"])
        #expect(library.upcomingEvents[0].occurredAt == today)
    }

    @Test func calendarUsesInclusiveLocalDatesAcrossDSTAndKeepsUnverifiedItems() {
        let start = date("2026-03-01T05:00:00Z")
        let end = date("2026-04-08T04:00:00Z")
        let items = [event("before", at: start.addingTimeInterval(-1)),
                     event("first", at: start, status: .unverified),
                     event("last", at: end.addingTimeInterval(-1), status: .scheduled),
                     event("after", at: end)]
        let library = IntelligenceLibrary(reports: [], events: items, now: date("2026-03-08T17:00:00Z"),
                                          timezone: "America/New_York")
        #expect(library.calendarEvents.map(\.id) == ["first", "last"])
        #expect(library.calendarEvents[0].status == .unverified)
        #expect(library.events.count == 4)
    }

    @Test func legacyArchiveWithoutAnalysisStillDecodesAndAppearsAsDailyEdition() throws {
        let json = #"{"id":"legacy","kind":"daily","generatedAt":1788868800,"windowStart":1788264000,"windowEnd":1791547200,"title":"旧日报","summary":"保留旧摘要","coverage":"旧版本","events":[],"predictions":[]}"#
        let legacy = try IntelligenceJSON.decoder().decode(IntelligenceReport.self, from: Data(json.utf8))
        let library = library([legacy])
        #expect(legacy.analysis == nil)
        #expect(library.currentReport?.summary == "保留旧摘要")
        #expect(library.todayDaily?.id == "legacy")
        #expect(library.historyDays[0].editions[0].versions == [legacy])
    }

    private func library(_ reports: [IntelligenceReport], events: [IntelligenceEvent] = []) -> IntelligenceLibrary {
        IntelligenceLibrary(reports: reports, events: events, now: now, timezone: "Asia/Taipei")
    }

    private func report(_ id: String, _ kind: IntelligenceKind, at generated: Date,
                        windowEnd: Date? = nil, predictions: [IntelligencePrediction] = [],
                        events: [IntelligenceEvent] = [], findings: [IntelligenceFinding]? = nil) -> IntelligenceReport {
        IntelligenceReport(id: id, kind: kind, generatedAt: generated,
                           windowStart: (windowEnd ?? generated).addingTimeInterval(-3_600),
                           windowEnd: windowEnd ?? generated, title: "Same headline",
                           summary: kind == .daily ? "Legacy daily summary" : "",
                           events: events, predictions: predictions, analysis: findings)
    }

    private func finding(_ id: String, body: String = "Observed market evidence", kind: IntelligenceFindingKind = .observation,
                         sources: [IntelligenceSource]? = nil) -> IntelligenceFinding {
        IntelligenceFinding(id: id, title: id, body: body, kind: kind, sources: sources ?? [source()])
    }

    private func event(_ id: String, at occurred: Date,
                       status: IntelligenceEventStatus = .occurred) -> IntelligenceEvent {
        IntelligenceEvent(id: id, title: id, status: status, occurredAt: occurred,
                          timePrecision: .minute, sources: [source()])
    }

    private func source(retrieved: Date? = nil) -> IntelligenceSource {
        IntelligenceSource(title: "Provider", url: "https://example.org/data", retrievedAt: retrieved ?? now,
                           evidence: "Timestamped provider evidence")
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}
