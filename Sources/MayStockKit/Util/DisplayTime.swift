import Foundation
import Observation
import CMayStockKernel

/// The one clock every time the app shows is read in.
///
/// May, 2026-10-09: 「都要用新加坡时间」, then 「支持配置时区吧，默认sg」 — a
/// setting (`GeneralPrefs.displayTimeZone`), Singapore unless changed. A
/// rule a venue keeps on its own clock stays on it: a US trading day is New
/// York's, OKX's daily bar opens at 00:00 UTC+8 (`Venue.dayZone`),
/// Polymarket names a deadline by its New York day. Only how an instant is
/// written for May to read moves.
///
/// The Mac's own zone is never read: `TimeZone.current`, `Date.formatted`
/// and a `DateFormatter` left on its default all mean the system setting,
/// which is not this one. `DisplayTimeTests` keeps them out of the sources.
///
/// Reading the zone is observed: a view that writes a time while it draws
/// redraws when the setting changes, without asking for it.
public enum DisplayTime {
    /// The zone a fresh install reads times in. The kernel declares it
    /// (`display::DEFAULT_ZONE`) and writes its own texts in the same zone,
    /// so it is written once.
    public static let defaultIdentifier: String = {
        guard let pointer = ms_display_zone_default() else {
            preconditionFailure("the kernel names no default display zone")
        }
        defer { ms_string_free(pointer) }
        return String(cString: pointer)
    }()

    /// Offered in the settings without typing; any other IANA identifier
    /// can be typed in.
    public static let choices: [String] = [defaultIdentifier] + [
        "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Tokyo",
        "Europe/London", "America/New_York", "America/Chicago", "America/Los_Angeles", "UTC",
    ].filter { $0 != defaultIdentifier }

    /// The process's clock. Tests build their own: this one is shared by
    /// every test running alongside.
    static let shared = Clock()

    /// The zone times are read in now.
    public static var zone: TimeZone { shared.zone }

    public static var identifier: String { zone.identifier }

    /// What the display zone is called next to a time: `新加坡时间`.
    public static var name: String { name(of: zone) }

    /// Read times in the zone the settings name. Every process that shows
    /// times comes here with its config — the app on every change, the
    /// command-line tools once. One the system does not know keeps the
    /// default, and the log says so once per setting.
    public static func adopt(_ prefs: GeneralPrefs) {
        adopt(prefs.displayTimeZone, on: shared)
    }

    static func adopt(_ identifier: String, on clock: Clock) {
        guard clock.request(identifier) else { return }
        if !apply(identifier, on: clock) {
            Log.warn("display: 系统不认识时区「\(identifier)」，时间按 \(defaultIdentifier) 显示")
        }
    }

    /// Read times in `identifier` from now on. One the system does not know
    /// keeps the default and answers false.
    @discardableResult
    static func apply(_ identifier: String, on clock: Clock) -> Bool {
        let named = TimeZone(identifier: identifier)
        clock.set(named ?? defaultZone)
        return named != nil
    }

    /// Whether the system knows `identifier` as a zone.
    public static func isKnown(_ identifier: String) -> Bool {
        TimeZone(identifier: identifier) != nil
    }

    /// What a zone is called next to a time: `新加坡时间`, `纽约时间`.
    public static func name(of zone: TimeZone) -> String {
        zone.localizedName(for: .shortGeneric, locale: chinese) ?? zone.identifier
    }

    /// An instant as `format` writes it in the display zone. Digits are
    /// ASCII; `EEE` reads `周五`.
    public static func string(_ date: Date, _ format: String) -> String {
        shared.string(date, format)
    }

    /// `21:30–04:00`: a stretch of time by its two clock times.
    public static func span(_ interval: DateInterval) -> String {
        string(interval.start, "HH:mm") + "–" + string(interval.end, "HH:mm")
    }

    private static let chinese = Locale(identifier: "zh_CN")
    static var defaultZone: TimeZone {
        guard let zone = TimeZone(identifier: defaultIdentifier) else {
            preconditionFailure("the system does not know the default display zone \(defaultIdentifier)")
        }
        return zone
    }

    /// The zone and the formatters built for it, behind a lock: charts write
    /// times off the main thread's drawing pass, the settings change them on
    /// it. Observed by hand, because the storage is not the macro's.
    final class Clock: Observable, @unchecked Sendable {
        private let registrar = ObservationRegistrar()
        private let lock = NSLock()
        private var current: TimeZone
        private var formatters: [String: DateFormatter] = [:]
        private var requested: String?

        init(zone: TimeZone = DisplayTime.defaultZone) {
            current = zone
        }

        /// Whether `identifier` is a new request, remembering it.
        func request(_ identifier: String) -> Bool {
            lock.withLock {
                defer { requested = identifier }
                return requested != identifier
            }
        }

        var zone: TimeZone {
            registrar.access(self, keyPath: \.zone)
            return lock.withLock { current }
        }

        func set(_ zone: TimeZone) {
            guard lock.withLock({ current }) != zone else { return }
            registrar.withMutation(of: self, keyPath: \.zone) {
                lock.withLock {
                    current = zone
                    formatters = [:]
                }
            }
        }

        func string(_ date: Date, _ format: String) -> String {
            registrar.access(self, keyPath: \.zone)
            return lock.withLock {
                if let formatter = formatters[format] { return formatter.string(from: date) }
                let formatter = DateFormatter()
                formatter.locale = DisplayTime.chinese
                formatter.timeZone = current
                formatter.dateFormat = format
                formatters[format] = formatter
                return formatter.string(from: date)
            }
        }
    }
}
