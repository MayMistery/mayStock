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

    public init(instId: String, direction: IntelligenceDirection = .insufficient,
                confidence: IntelligenceConfidence = .low, horizonHours: Int = 1,
                generatedAt: Date = Date(), referencePrice: Double? = nil,
                drivers: [String] = [], invalidation: String = "", eventIds: [String] = []) {
        self.instId = instId
        self.direction = direction
        self.confidence = confidence
        self.horizonHours = horizonHours
        self.generatedAt = generatedAt
        self.referencePrice = referencePrice
        self.drivers = drivers
        self.invalidation = invalidation
        self.eventIds = eventIds
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

    public init(id: String = UUID().uuidString, kind: IntelligenceKind,
                generatedAt: Date = Date(), windowStart: Date = Date(), windowEnd: Date = Date(),
                title: String = "", summary: String = "", coverage: String = "",
                events: [IntelligenceEvent] = [], predictions: [IntelligencePrediction] = [],
                coverageComplete: Bool? = nil) {
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
    }
}

public struct IntelligenceSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var dailyHour: Int
    public var timezone: String
    public var horizonHours: Int

    public init(enabled: Bool = true, dailyHour: Int = 8, timezone: String = "Asia/Taipei",
                horizonHours: Int = 1) {
        self.enabled = enabled
        self.dailyHour = dailyHour
        self.timezone = timezone
        self.horizonHours = horizonHours
    }

    private enum CodingKeys: String, CodingKey { case enabled, dailyHour, timezone, horizonHours }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        dailyHour = try c.decodeIfPresent(Int.self, forKey: .dailyHour) ?? 8
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? "Asia/Taipei"
        horizonHours = try c.decodeIfPresent(Int.self, forKey: .horizonHours) ?? 1
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
