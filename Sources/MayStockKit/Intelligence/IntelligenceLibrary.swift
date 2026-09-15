import Foundation

/// A logical edition keeps its earlier revisions without placing every rerun
/// beside genuinely different daily or hourly research.
public struct IntelligenceEdition: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: IntelligenceKind
    public let report: IntelligenceReport
    /// Newest first, with duplicate report identifiers removed.
    public let versions: [IntelligenceReport]
}

public struct IntelligenceHistoryDay: Identifiable, Equatable, Sendable {
    /// Gregorian local date, independent of the device's locale and timezone.
    public let id: String
    public let date: Date
    public let editions: [IntelligenceEdition]
}

/// A read-only projection of the archive. It never changes an observation,
/// forecast timestamp, or saved report when the user revisits the station.
public struct IntelligenceLibrary: Sendable {
    public let currentReport: IntelligenceReport?
    public let todayDaily: IntelligenceReport?
    public let historyDays: [IntelligenceHistoryDay]
    public let recentFlashes: [IntelligenceEvent]
    public let upcomingEvents: [IntelligenceEvent]
    /// All known events, one version per identifier, in occurrence-time order.
    public let events: [IntelligenceEvent]
    /// The inclusive -7/+30 local-date calendar window.
    public let calendarEvents: [IntelligenceEvent]

    public init(reports: [IntelligenceReport], events: [IntelligenceEvent],
                now: Date, timezone: String) {
        let calendar = IntelligenceCalendar.calendar(timezone: timezone)
        let canonical = Self.canonicalReports(reports)
        let visible = canonical.filter(Self.hasContent)
        self.currentReport = visible.first { $0.kind != .flash }
        self.todayDaily = visible.first {
            $0.kind == .daily && calendar.isDate($0.generatedAt, inSameDayAs: now)
        }

        var editions: [String: [IntelligenceReport]] = [:]
        for report in visible {
            let key = report.kind == .daily
                ? "daily:\(Self.dayID(report.generatedAt, calendar: calendar))"
                : "\(report.kind.rawValue):\(report.windowEnd.timeIntervalSince1970)"
            editions[key, default: []].append(report)
        }
        var days: [String: (date: Date, editions: [IntelligenceEdition])] = [:]
        for (id, versions) in editions {
            // Every bucket was populated above, in canonical newest-first order.
            guard let latest = versions.first else { continue }
            let issuedAt = latest.kind == .daily ? latest.generatedAt : latest.windowEnd
            let date = calendar.startOfDay(for: issuedAt)
            let dayID = Self.dayID(date, calendar: calendar)
            let edition = IntelligenceEdition(id: id, kind: latest.kind,
                                             report: latest, versions: versions)
            if days[dayID] == nil { days[dayID] = (date, []) }
            days[dayID]?.editions.append(edition)
        }
        self.historyDays = days.map { id, value in
            IntelligenceHistoryDay(id: id, date: value.date,
                                   editions: value.editions.sorted {
                if $0.report.generatedAt != $1.report.generatedAt {
                    return $0.report.generatedAt > $1.report.generatedAt
                }
                return $0.id < $1.id
            })
        }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }

        // The latest report owns corrections to an event. Standalone archive
        // events only fill gaps and cannot override an explicit newer report.
        var selected: [String: IntelligenceEvent] = [:]
        for report in canonical {
            for event in Self.canonicalEvents(report.events) where selected[event.id] == nil {
                selected[event.id] = event
            }
        }
        for event in Self.canonicalEvents(events) where selected[event.id] == nil {
            selected[event.id] = event
        }
        let ordered = selected.values.sorted(by: Self.eventOccursEarlier)
        self.events = ordered

        let flashIDs = Set(visible.filter { $0.kind == .flash }.flatMap { $0.events.map(\.id) })
        self.recentFlashes = ordered.filter {
            flashIDs.contains($0.id) && $0.status == .occurred
                && $0.timePrecision == .minute && Self.hasEvidence($0.sources)
                && $0.occurredAt <= now && $0.occurredAt >= now.addingTimeInterval(-86_400)
        }.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.id < $1.id
        }
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 31, to: today) ?? today
        self.upcomingEvents = ordered.filter {
            guard $0.status == .scheduled, $0.occurredAt < end else { return false }
            switch $0.timePrecision {
            case .minute: return $0.occurredAt > now
            case .day: return calendar.startOfDay(for: $0.occurredAt) >= today
            case .unknown: return false
            }
        }
        self.calendarEvents = ordered.filter { $0.occurredAt >= start && $0.occurredAt < end }
    }

    /// One briefing owns the complete watchlist outlook; an older report cannot
    /// silently supply a missing symbol or replace an expired forecast.
    public func currentPrediction(for instId: String) -> IntelligencePredictionContext? {
        guard let report = currentReport,
              let prediction = report.predictions.filter({ $0.instId == instId }).sorted(by: {
                  if $0.generatedAt != $1.generatedAt { return $0.generatedAt > $1.generatedAt }
                  return Self.stableKey($0) < Self.stableKey($1)
              }).first else { return nil }
        return IntelligencePredictionContext(prediction: prediction, report: report)
    }

    /// A quiet poll is operational state, not another research edition. Legacy
    /// daily summaries remain visible even when the newer findings field is absent.
    public static func hasContent(_ report: IntelligenceReport) -> Bool {
        if report.kind == .flash { return !report.events.isEmpty }
        if report.kind == .daily && report.analysis == nil
            && !report.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !report.events.isEmpty { return true }
        if report.findings.contains(where: {
            $0.kind != .unknown && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && hasEvidence($0.sources)
        }) { return true }
        return report.predictions.contains { prediction in
            guard prediction.direction != .insufficient else { return false }
            let eventEvidence = report.events.contains {
                prediction.eventIds.contains($0.id) && hasEvidence($0.sources)
            }
            let findingEvidence = report.findings.contains {
                $0.kind != .unknown && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (prediction.findingIds ?? []).contains($0.id) && hasEvidence($0.sources)
            }
            return eventEvidence || findingEvidence
        }
    }

    /// Stable for any input order, including damaged archives with duplicate IDs.
    /// Equal timestamps use the ID, then the entire encoded value as a final tie.
    public static func canonicalReports(_ reports: [IntelligenceReport]) -> [IntelligenceReport] {
        var selected: [String: IntelligenceReport] = [:]
        for report in reports {
            guard let current = selected[report.id] else {
                selected[report.id] = report
                continue
            }
            if report.generatedAt > current.generatedAt {
                selected[report.id] = report
            } else if report.generatedAt == current.generatedAt && report != current
                        && stableKey(report) < stableKey(current) {
                // Encoding is reserved for an actual equal-ID/equal-time conflict.
                selected[report.id] = report
            }
        }
        return selected.values.sorted {
            if $0.generatedAt != $1.generatedAt { return $0.generatedAt > $1.generatedAt }
            return $0.id < $1.id
        }
    }

    private static func hasEvidence(_ sources: [IntelligenceSource]) -> Bool {
        sources.contains {
            !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func dayID(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func eventOccursEarlier(_ lhs: IntelligenceEvent, _ rhs: IntelligenceEvent) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id < rhs.id
    }

    private static func canonicalEvents(_ events: [IntelligenceEvent]) -> [IntelligenceEvent] {
        var selected: [String: IntelligenceEvent] = [:]
        for event in events {
            guard let current = selected[event.id] else {
                selected[event.id] = event
                continue
            }
            let observed = event.sources.map(\.retrievedAt).max() ?? .distantPast
            let priorObserved = current.sources.map(\.retrievedAt).max() ?? .distantPast
            let published = event.publishedAt ?? .distantPast
            let priorPublished = current.publishedAt ?? .distantPast
            if observed > priorObserved || (observed == priorObserved && published > priorPublished) {
                selected[event.id] = event
            } else if observed == priorObserved && published == priorPublished && event != current
                        && stableKey(event) < stableKey(current) {
                selected[event.id] = event
            }
        }
        return selected.values.sorted { $0.id < $1.id }
    }

    private static func stableKey<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
