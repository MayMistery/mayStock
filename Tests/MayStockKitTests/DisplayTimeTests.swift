import Foundation
import Observation
import Testing
@testable import MayStockKit

/// The display clock (`DisplayTime`). No test here changes the process's
/// zone — every other suite runs alongside and reads it — so each builds
/// its own `DisplayTime.Clock`, and the shared one stays on the default.
@Suite("Display time")
struct DisplayTimeTests {
    private func at(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    @Test("默认新加坡时间，默认值只在内核写一处")
    func theDefaultIsTheKernelsSingapore() {
        #expect(DisplayTime.defaultIdentifier == "Asia/Singapore")
        #expect(GeneralPrefs().displayTimeZone == DisplayTime.defaultIdentifier)
        #expect(DisplayTime.choices.first == DisplayTime.defaultIdentifier)
        #expect(DisplayTime.choices.allSatisfy(DisplayTime.isKnown), "every offered zone is one the system knows")
        #expect(Set(DisplayTime.choices).count == DisplayTime.choices.count)
    }

    @Test("旧配置没有这一项读成默认；写错类型不连累其他设置")
    func aConfigWithoutTheSettingReadsTheDefault() throws {
        let decode = { (json: String) in try JSONDecoder().decode(GeneralPrefs.self, from: Data(json.utf8)) }
        #expect(try decode("{}").displayTimeZone == DisplayTime.defaultIdentifier)
        #expect(try decode(#"{"displayTimeZone":"America/New_York"}"#).displayTimeZone == "America/New_York")
        let mistyped = try decode(#"{"displayTimeZone":8,"hoverDelayMs":300}"#)
        #expect((mistyped.displayTimeZone, mistyped.hoverDelayMs) == (DisplayTime.defaultIdentifier, 300))
        // Kept as written, unknown or not: the app shows the default and says so.
        #expect(try decode(#"{"displayTimeZone":"Mars/Olympus"}"#).displayTimeZone == "Mars/Olympus")
        let written = try JSONEncoder().encode(GeneralPrefs(displayTimeZone: "Europe/London"))
        #expect(try JSONDecoder().decode(GeneralPrefs.self, from: written).displayTimeZone == "Europe/London")
    }

    @Test("换时区，写出来的时刻跟着换；不认识的时区按默认")
    func aClockWritesInTheZoneItWasGiven() {
        let clock = DisplayTime.Clock()
        let open = at("2026-10-09T13:30:00Z")
        #expect(clock.string(open, "MM-dd HH:mm") == "10-09 21:30")
        #expect(DisplayTime.apply("America/New_York", on: clock))
        #expect(clock.string(open, "MM-dd HH:mm") == "10-09 09:30")
        #expect(clock.string(open, "EEE") == "周五")
        #expect(!DisplayTime.apply("Mars/Olympus", on: clock), "an unknown zone is refused")
        #expect(clock.zone.identifier == DisplayTime.defaultIdentifier, "and the default read instead")
    }

    @Test("同一个设置只套用一次（日志只说一次）")
    func aSettingIsTakenUpOnce() {
        let clock = DisplayTime.Clock()
        #expect(clock.request("Mars/Olympus"))
        #expect(!clock.request("Mars/Olympus"), "the same setting again is no news")
        #expect(clock.request("Asia/Tokyo"))
    }

    /// A view that writes a time while it draws depends on the zone without
    /// asking: SwiftUI redraws it when the setting changes.
    @Test("读过时间的视图在时区改动时被通知")
    func writingATimeObservesTheZone() {
        final class Flag: @unchecked Sendable { var raised = false }
        let clock = DisplayTime.Clock()
        let flag = Flag()
        withObservationTracking {
            _ = clock.string(Date(), "HH:mm")
        } onChange: {
            flag.raised = true
        }
        DisplayTime.apply(DisplayTime.defaultIdentifier, on: clock)
        #expect(!flag.raised, "the same zone again changes nothing")
        DisplayTime.apply("Europe/London", on: clock)
        #expect(flag.raised)
    }

    @Test("日线以上按交易所的日命名，日内按显示时区")
    func aBarIsLabelledOnItsVenuesDayOrTheDisplayClock() {
        for venue in Venue.allCases {
            #expect(ChartMath.labelZone(barSeconds: 86_400, venue: venue) == venue.dayZone)
            #expect(ChartMath.labelZone(barSeconds: 7 * 86_400, venue: venue) == venue.dayZone)
            #expect(ChartMath.labelZone(barSeconds: 3_600, venue: venue) == DisplayTime.zone)
        }
        // OKX's 1D bar opens at 00:00 UTC+8; a US day is New York's.
        #expect(Venue.okx.dayZone.secondsFromGMT(for: Date()) == 8 * 3_600)
        #expect(Venue.schwab.dayZone.identifier == "America/New_York")
    }

    @Test("美股时段写成新加坡时间，随纽约夏令时移动")
    func usHoursAreWrittenOnTheDisplayClock() {
        #expect(USSessionHours.displayedHours(\.regular, on: at("2026-10-09T15:00:00Z")) == "新加坡时间 21:30–04:00")
        #expect(USSessionHours.displayedHours(\.preMarket, on: at("2026-10-09T15:00:00Z")) == "新加坡时间 16:00–21:30")
        #expect(USSessionHours.displayedHours(\.regular, on: at("2026-12-09T15:00:00Z")) == "新加坡时间 22:30–05:00")
    }

    @Test("涨跌基准按谁的 0 点命名，不同于显示时区时注出换算")
    func aChangeBasisNamesWhoseMidnight() {
        #expect(ChangeBasis.sinceUtc8Midnight.changeLabel == "较新加坡时间 0 点")
        #expect(ChangeBasis.sinceUtc8Midnight.settingName == "新加坡时间 0 点起")
        #expect(ChangeBasis.sinceUtcMidnight.changeLabel == "较UTC 0 点（新加坡时间 08:00）")
        #expect(ChangeBasis.sinceUtcMidnight.settingName == "UTC 0 点起（新加坡时间 08:00）")
    }

    // MARK: - Guard

    /// What reads the Mac's own zone, or formats without saying which: each
    /// would write a time on the system clock instead of the display one.
    private static let systemClockReads = [
        "TimeZone.current", "TimeZone.autoupdatingCurrent", "Calendar.current", "Calendar.autoupdatingCurrent",
        "NSTimeZone.default", "NSTimeZone.local", "timeZone: .current", "TimeZone = .current",
        ".formatted(date:", ".formatted(.dateTime", ".formatted(.iso8601", "Date.FormatStyle",
        "style: .time", "style: .date", "style: .relative", "style: .offset", "style: .timer", "Text(timerInterval",
    ]

    /// Every source file, every target: a time written anywhere goes through
    /// the display clock or names its zone. A `DateFormatter` is let through
    /// only with its zone set within the lines that build it.
    @Test("源码里没有读系统时区的写法；每个 DateFormatter 都写明时区")
    func noSourceReadsTheSystemClock() throws {
        let fileManager = FileManager.default
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1,
              !fileManager.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            root.deleteLastPathComponent()
        }
        let sources = root.appendingPathComponent("Sources")
        let walker = try #require(fileManager.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files = 0
        var offences: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files += 1
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            let name = url.path.replacingOccurrences(of: root.path + "/", with: "")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                for read in Self.systemClockReads where code.contains(read) {
                    offences.append("\(name):\(index + 1) \(read)")
                }
                if code.contains("DateFormatter()"), !code.contains("ISO8601DateFormatter()") {
                    let building = lines[index..<min(lines.count, index + 8)]
                    if !building.contains(where: { $0.contains(".timeZone =") }) {
                        offences.append("\(name):\(index + 1) DateFormatter without a zone")
                    }
                }
            }
        }
        #expect(files > 100, "the walk found the sources")
        #expect(offences.isEmpty, "写时间请用 DisplayTime（或写明时区）：\n\(offences.joined(separator: "\n"))")
    }
}
