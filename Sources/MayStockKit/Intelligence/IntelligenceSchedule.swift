import Foundation

/// Calendar arithmetic stays in the selected timezone, including DST changes.
public enum IntelligenceSchedule {
    public static func calendar(timezone: String) -> Calendar {
        IntelligenceCalendar.calendar(timezone: timezone)
    }

    public static func days(now: Date, timezone: String) -> [Date] {
        IntelligenceCalendar.days(around: now, timezone: timezone)
    }

    public static func nextRun(kind: IntelligenceKind, now: Date,
                               lastSuccess: Date?, settings: IntelligenceSettings) -> Date {
        switch kind {
        case .flash: return (lastSuccess ?? now.addingTimeInterval(-1_800)).addingTimeInterval(1_800)
        case .hourly: return (lastSuccess ?? now.addingTimeInterval(-3_600)).addingTimeInterval(3_600)
        case .daily:
            guard let lastSuccess else { return now } // Bootstrap the calendar on first launch.
            let cal = calendar(timezone: settings.timezone)
            let start = cal.startOfDay(for: now)
            let today = cal.date(bySettingHour: settings.dailyHour, minute: 0, second: 0, of: start) ?? start
            // A manually generated pre-schedule report does not skip today's scheduled refresh.
            if lastSuccess < today { return today }
            let tomorrow = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return cal.date(bySettingHour: settings.dailyHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
    }
}
