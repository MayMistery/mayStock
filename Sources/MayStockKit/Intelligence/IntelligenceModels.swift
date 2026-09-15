import Foundation

public enum IntelligenceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case daily, hourly, flash
}

public enum IntelligenceCategory: String, Codable, CaseIterable, Sendable {
    case macro, policy, geopolitics, crypto, earnings
}

public enum IntelligenceImportance: String, Codable, CaseIterable, Sendable {
    case high, medium, low
}

public enum IntelligenceEventStatus: String, Codable, CaseIterable, Sendable {
    case scheduled, occurred, unverified
}

public enum IntelligenceTimePrecision: String, Codable, CaseIterable, Sendable {
    case minute, day, unknown
}

public enum IntelligenceDirection: String, Codable, CaseIterable, Sendable {
    case up, down, neutral, insufficient
}

public enum IntelligenceConfidence: String, Codable, CaseIterable, Sendable {
    case low, medium, high
}

public enum IntelligenceFindingKind: String, Codable, CaseIterable, Sendable {
    case observation, inference, unknown
}

/// Dates in the bridge use Unix seconds; callers configure their JSON coder's
/// date strategy to secondsSince1970. Day boundaries belong to the display zone.
public struct IntelligenceSource: Codable, Equatable, Sendable {
    public var title: String
    public var url: String
    public var publisher: String
    public var retrievedAt: Date
    public var evidence: String

    public init(title: String, url: String, publisher: String = "", retrievedAt: Date = Date(),
                evidence: String = "") {
        self.title = title
        self.url = url
        self.publisher = publisher
        self.retrievedAt = retrievedAt
        self.evidence = evidence
    }
}

public struct IntelligenceEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var category: IntelligenceCategory
    public var importance: IntelligenceImportance
    public var status: IntelligenceEventStatus
    public var occurredAt: Date
    public var timePrecision: IntelligenceTimePrecision
    public var publishedAt: Date?
    public var summary: String
    public var impact: String
    public var sources: [IntelligenceSource]

    public init(id: String = UUID().uuidString, title: String,
                category: IntelligenceCategory = .macro, importance: IntelligenceImportance = .medium,
                status: IntelligenceEventStatus = .unverified, occurredAt: Date = Date(),
                timePrecision: IntelligenceTimePrecision = .unknown, publishedAt: Date? = nil,
                summary: String = "", impact: String = "", sources: [IntelligenceSource] = []) {
        self.id = id
        self.title = title
        self.category = category
        self.importance = importance
        self.status = status
        self.occurredAt = occurredAt
        self.timePrecision = timePrecision
        self.publishedAt = publishedAt
        self.summary = summary
        self.impact = impact
        self.sources = sources
    }
}

/// An agent-chosen section of the market analysis. Observations, causal
/// interpretations and unresolved questions retain their own evidence.
public struct IntelligenceFinding: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var kind: IntelligenceFindingKind
    public var instIds: [String]
    public var sources: [IntelligenceSource]

    public init(id: String = UUID().uuidString, title: String, body: String,
                kind: IntelligenceFindingKind, instIds: [String] = [],
                sources: [IntelligenceSource] = []) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.instIds = instIds
        self.sources = sources
    }
}

/// Direction and confidence are uncalibrated model judgments, never trade
/// instructions or an empirically measured probability of a price move.
public struct IntelligencePrediction: Codable, Identifiable, Equatable, Sendable {
    public var id: String { instId }
    public var instId: String
    public var direction: IntelligenceDirection
    public var confidence: IntelligenceConfidence
    public var horizonHours: Int
    public var generatedAt: Date
    public var referencePrice: Double?
    public var drivers: [String]
    public var invalidation: String
    public var eventIds: [String]
    /// Absent in reports generated before research findings were supported.
    public var findingIds: [String]?

    public init(instId: String, direction: IntelligenceDirection = .insufficient,
                confidence: IntelligenceConfidence = .low, horizonHours: Int = 1,
                generatedAt: Date = Date(), referencePrice: Double? = nil,
                drivers: [String] = [], invalidation: String = "", eventIds: [String] = [],
                findingIds: [String]? = nil) {
        self.instId = instId
        self.direction = direction
        self.confidence = confidence
        self.horizonHours = horizonHours
        self.generatedAt = generatedAt
        self.referencePrice = referencePrice
        self.drivers = drivers
        self.invalidation = invalidation
        self.eventIds = eventIds
        self.findingIds = findingIds
    }

    public var expiresAt: Date { generatedAt.addingTimeInterval(Double(horizonHours) * 3_600) }
}

public struct IntelligenceReport: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: IntelligenceKind
    public var generatedAt: Date
    public var windowStart: Date
    public var windowEnd: Date
    public var title: String
    public var summary: String
    public var coverage: String
    /// Host-computed source coverage; absent in archives created before this field.
    public var coverageComplete: Bool?
    public var events: [IntelligenceEvent]
    public var predictions: [IntelligencePrediction]
    /// Optional so pre-analysis report archives continue to decode unchanged.
    public var analysis: [IntelligenceFinding]?
    /// The worker's actual selected model. Earlier archives leave it unknown.
    public var model: String?

    public var findings: [IntelligenceFinding] { analysis ?? [] }

    public init(id: String = UUID().uuidString, kind: IntelligenceKind,
                generatedAt: Date = Date(), windowStart: Date = Date(), windowEnd: Date = Date(),
                title: String = "", summary: String = "", coverage: String = "",
                events: [IntelligenceEvent] = [], predictions: [IntelligencePrediction] = [],
                coverageComplete: Bool? = nil, analysis: [IntelligenceFinding]? = nil,
                model: String? = nil) {
        self.id = id
        self.kind = kind
        self.generatedAt = generatedAt
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.title = title
        self.summary = summary
        self.coverage = coverage
        self.coverageComplete = coverageComplete
        self.events = events
        self.predictions = predictions
        self.analysis = analysis
        self.model = model
    }
}

/// The forecast and evidence are resolved from the same report, even when
/// several archives reuse a short event or finding identifier.
public struct IntelligencePredictionContext: Equatable, Sendable {
    public let reportId: String
    public let prediction: IntelligencePrediction
    public let events: [IntelligenceEvent]
    public let findings: [IntelligenceFinding]

    public init(prediction: IntelligencePrediction, report: IntelligenceReport) {
        self.reportId = report.id
        self.prediction = prediction
        let belongsToReport = report.predictions.contains(prediction)
        self.events = belongsToReport ? report.events.filter { prediction.eventIds.contains($0.id) } : []
        self.findings = belongsToReport ? report.findings.filter { (prediction.findingIds ?? []).contains($0.id) } : []
    }

    public static func latest(for instId: String, in reports: [IntelligenceReport]) -> Self? {
        reports.flatMap { report in
            report.predictions.filter { $0.instId == instId }.map { Self(prediction: $0, report: report) }
        }.max { $0.prediction.generatedAt < $1.prediction.generatedAt }
    }
}

public struct IntelligenceSettings: Codable, Equatable, Sendable {
    public static let defaultModel = "model_hub/es1_orange_o50[1m]"

    public var enabled: Bool
    public var dailyHour: Int
    public var timezone: String
    public var horizonHours: Int
    public var model: String

    public init(enabled: Bool = true, dailyHour: Int = 8, timezone: String = "Asia/Taipei",
                horizonHours: Int = 1, model: String = IntelligenceSettings.defaultModel) {
        self.enabled = enabled
        self.dailyHour = dailyHour
        self.timezone = timezone
        self.horizonHours = horizonHours
        self.model = model
    }

    /// Accept model identifiers, including routed names, without embedded
    /// whitespace, controls or command-like leading punctuation.
    public static func normalizeModel(_ value: String) -> String? {
        let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.utf8.count <= 200,
              model.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:/\[\]-]*\z"#,
                          options: .regularExpression) != nil else { return nil }
        return model
    }

    private enum CodingKeys: String, CodingKey { case enabled, dailyHour, timezone, horizonHours, model }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        dailyHour = try c.decodeIfPresent(Int.self, forKey: .dailyHour) ?? 8
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? "Asia/Taipei"
        horizonHours = try c.decodeIfPresent(Int.self, forKey: .horizonHours) ?? 1
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultModel
    }
}

public struct IntelligenceJobStatus: Codable, Equatable, Sendable {
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var nextRunAt: Date?
    public var error: String?
    public var note: String?
    public var coverageComplete: Bool?

    public init(lastAttemptAt: Date? = nil, lastSuccessAt: Date? = nil, nextRunAt: Date? = nil,
                error: String? = nil, note: String? = nil, coverageComplete: Bool? = nil) {
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.nextRunAt = nextRunAt
        self.error = error
        self.note = note
        self.coverageComplete = coverageComplete
    }
}

public enum IntelligenceCalendar {
    public static func calendar(timezone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    /// Exactly 38 local dates, preserving DST day boundaries.
    public static func days(around now: Date, timezone: String) -> [Date] {
        let calendar = calendar(timezone: timezone)
        let today = calendar.startOfDay(for: now)
        return (-7...30).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    /// Number of leading blanks needed for a Monday-first calendar grid.
    public static func leadingDays(for day: Date, timezone: String) -> Int {
        (calendar(timezone: timezone).component(.weekday, from: day) + 5) % 7
    }
}
