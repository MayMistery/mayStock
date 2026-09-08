import Foundation

/// Which stretch of a sparkline buffer a line chart or menu bar draws.
///
/// On a market that never closes, a window is a trailing number of minutes
/// and nothing else makes sense. On a market with sessions, "the last hour"
/// of a closed market is an empty picture; what a stock app draws is the
/// session — the current one while it runs, the last one after the bell —
/// or the last few of them.
public enum SparkWindow: Equatable, Sendable {
    case trailing(minutes: Int)
    /// The current or most recent trading day, extended hours included.
    case session
    /// The last `days` calendar days — seven cover a trading week.
    case days(Int)

    /// The points to draw, ascending by time.
    public func points(from spark: SparklineBuffer, venue: Venue, now: Date = Date()) -> [SparkPoint] {
        switch self {
        case .trailing(let minutes):
            return spark.window(minutes: minutes, now: now)
        case .days(let days):
            return spark.window(seconds: TimeInterval(days) * 86_400, now: now)
        case .session:
            // The day, in the venue's own clock, of the latest sample: after
            // the bell that is the session just finished, which is the one a
            // closed market should still show.
            guard let anchor = spark.last?.ts ?? Optional(now) else { return [] }
            let start = Self.dayStart(of: anchor, in: venue.timeZone)
            return spark.window(seconds: now.timeIntervalSince(start), now: now)
        }
    }

    /// Midnight before `date` in `zone`.
    public static func dayStart(of date: Date, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.startOfDay(for: date)
    }
}
