import Foundation
import Observation

// MARK: - Records

/// One observation of total account equity, in the quote currency.
public struct AccountEquityPoint: Codable, Sendable, Equatable {
    public let ts: Date
    public let equity: Double

    public init(ts: Date, equity: Double) {
        self.ts = ts
        self.equity = equity
    }
}

/// The windows the panel reports.
///
/// One rolling, two calendar. The distinction is not cosmetic: "the last 24
/// hours" and "today" answer different questions, and only the second one is
/// the question a trader actually asks at 09:00. A calendar window is also
/// answerable *immediately* — 00:00 today is a real instant, so a curve that
/// has been recording since yesterday can price it exactly one second after
/// launch, where a trailing window would still be waiting to fill up.
public enum EquityWindow: String, CaseIterable, Sendable, Identifiable {
    /// Rolling: the last hour, continuously. The interactive one — it moves
    /// under you while you watch it.
    case hour1
    /// Since 00:00 today.
    case day1
    /// Since 00:00 Monday.
    case day7

    public var id: String { rawValue }

    /// The book's trading day. Everything the workbench touches settles
    /// against a Singapore-hours desk, and a "today" that rolled over at some
    /// other midnight would put two different days' P&L under one label.
    public static let timeZone = TimeZone(identifier: "Asia/Singapore") ?? .gmt

    /// Monday-first, in the book's own time zone.
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2      // Monday
        return calendar
    }

    /// The instant this window measures from.
    public func anchor(now: Date = Date()) -> Date {
        let calendar = Self.calendar
        switch self {
        case .hour1:
            return now.addingTimeInterval(-3_600)
        case .day1:
            return calendar.startOfDay(for: now)
        case .day7:
            let components = calendar.dateComponents(
                [.yearForWeekOfYear, .weekOfYear], from: now)
            // Falling back to "seven days ago" rather than to nothing: a
            // calendar that cannot resolve its own week is not a reason to
            // stop reporting a number.
            return calendar.date(from: components)
                ?? calendar.startOfDay(for: now.addingTimeInterval(-7 * 86_400))
        }
    }

    public var label: String {
        switch self {
        case .hour1: return "1h"
        case .day1: return "今日"
        case .day7: return "本周"
        }
    }

    /// What the label is short for, spelled out in a tooltip.
    public var longLabel: String {
        switch self {
        case .hour1: return "最近 1 小时（滚动）"
        case .day1: return "今日 00:00 起（新加坡时间）"
        case .day7: return "本周一 00:00 起（新加坡时间）"
        }
    }
}

/// Equity change since a window's anchor, carrying an explicit account of what
/// the number is really measured from.
///
/// **The number is always shown.** An earlier version suppressed it whenever
/// coverage fell short, which for a calendar window is the wrong trade: "since
/// 00:00 today" is exact the moment there is a sample at or before midnight,
/// and when there isn't, "+0.4% since 10:23" is strictly more use than a dash.
/// What must never happen is the number being printed as if it meant something
/// it doesn't — so the caveats travel with it rather than replacing it.
public struct EquityChange: Sendable, Equatable {
    public let window: EquityWindow
    public let startEquity: Double
    public let endEquity: Double
    /// The instant the window asked to measure from.
    public let anchor: Date
    /// The sample actually used. Later than `anchor` when history does not
    /// reach back that far.
    public let referenceTs: Date
    /// Seconds of the window actually backed by samples, holes excluded.
    public let coveredSeconds: TimeInterval
    /// Seconds between the reference sample and the endpoint.
    ///
    /// Kept apart from `coveredSeconds` because the two answer different
    /// questions and were once the same number: a curve whose first and last
    /// samples sit a day apart *spans* a day however much of the middle is
    /// missing. Only the second question protects the reader.
    public let spannedSeconds: TimeInterval
    /// Anchor to endpoint — how long this window currently is. Variable for
    /// the calendar windows: "today" is 30 seconds long at 00:00:30.
    public let windowSeconds: TimeInterval

    public init(
        window: EquityWindow, startEquity: Double, endEquity: Double,
        anchor: Date, referenceTs: Date,
        coveredSeconds: TimeInterval, spannedSeconds: TimeInterval,
        windowSeconds: TimeInterval
    ) {
        self.window = window
        self.startEquity = startEquity
        self.endEquity = endEquity
        self.anchor = anchor
        self.referenceTs = referenceTs
        self.coveredSeconds = coveredSeconds
        self.spannedSeconds = spannedSeconds
        self.windowSeconds = windowSeconds
    }

    public var changeQuote: Double { endEquity - startEquity }

    public var changePct: Double? {
        guard startEquity > 0 else { return nil }
        return changeQuote / startEquity * 100
    }

    /// True when the reference sample predates the anchor, so this really is
    /// "since 00:00" and not "since whenever we happened to start looking".
    public var isAnchored: Bool { referenceTs <= anchor }

    /// Fraction of the window backed by recorded history.
    public var coverage: Double {
        guard windowSeconds > 0 else { return 1 }
        return Swift.min(Swift.max(coveredSeconds, 0) / windowSeconds, 1)
    }

    /// Nothing to disclose: measured from the anchor, with no holes since.
    public var isComplete: Bool { isAnchored && coverage >= 0.9 }

    /// Anchored, but with stretches nobody observed — the engine was down for
    /// part of the window rather than the app being new.
    ///
    /// Worth telling apart, and the more alarming of the two: "we only started
    /// recording at 10:23" is a fact about the app's age, while "6 of these 12
    /// hours were never observed" is a fact about an outage.
    public var hasGaps: Bool { isAnchored && coverage < 0.9 }

    /// Seconds of the window with no samples behind them at all.
    public var missingSeconds: TimeInterval {
        Swift.max(Swift.min(windowSeconds, spannedSeconds) - coveredSeconds, 0)
    }

    /// Human description of the caveat, empty when there is none.
    public var coverageNote: String {
        if !isAnchored {
            return "记录从 \(EquityChange.clock(referenceTs)) 才开始，"
                + "这不是完整的\(window.label)"
        }
        if hasGaps {
            return "\(window.longLabel)里有 \(AccountEquityCurve.describe(missingSeconds))"
                + "没有记录 —— 引擎当时没在跑"
        }
        return ""
    }

    /// Wall-clock time in the book's own zone.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = EquityWindow.timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Curve

/// Rolling record of total account equity, one series per trading mode.
///
/// Windowed returns cannot be derived from the ledger: the ledger knows fills,
/// and a strategy that has been flat all week has no fills to speak of while its
/// equity still moved. Only a time series of the account's own value answers
/// "how did the last 24 hours go", so this records one.
///
/// Demo and live keep separate curves for the same reason their ledgers do —
/// splicing a simulated equity jump into a live curve would ruin both.
@Observable
@MainActor
public final class AccountEquityCurve {
    public private(set) var points: [AccountEquityPoint] = []
    public let mode: TradingMode

    /// Called whenever the series changes, so the app can persist it.
    public var onChanged: (() -> Void)?

    /// Samples closer together than this are dropped. The runner ticks every
    /// 20s; an equity curve does not need that resolution and the file would
    /// grow without bound if it kept it.
    public static let minimumSampleInterval: TimeInterval = 60
    /// Full-resolution horizon. Older points are thinned to `coarseInterval`,
    /// which keeps 30 days of history in a few thousand rows.
    public static let fineHorizon: TimeInterval = 25 * 3_600
    public static let coarseInterval: TimeInterval = 900
    public static let retention: TimeInterval = 30 * 86_400

    public init(mode: TradingMode) {
        self.mode = mode
    }

    // MARK: Queries

    public var latest: AccountEquityPoint? { points.last }
    public var oldest: AccountEquityPoint? { points.first }

    /// How much history this curve holds.
    public var recordedSpan: TimeInterval {
        guard let first = points.first, let last = points.last else { return 0 }
        return last.ts.timeIntervalSince(first.ts)
    }

    /// Change over a trailing window.
    ///
    /// `latest` lets the caller supply a fresher equity reading than the last
    /// stored sample — the panel marks continuously while the curve only
    /// records once a minute, and the number on screen should be the live one.
    public func change(
        over window: EquityWindow, now: Date = Date(), latest liveEquity: Double? = nil
    ) -> EquityChange? {
        let endTs: Date
        let endEquity: Double
        if let liveEquity, liveEquity > 0 {
            endTs = now
            endEquity = liveEquity
        } else if let last = points.last {
            endTs = last.ts
            endEquity = last.equity
        } else {
            return nil
        }

        // The reference is the last sample at or before the cutoff. With less
        // history than the window, fall back to the oldest sample — and let
        // `coveredSeconds` disclose that it is not a full window.
        // The anchor is a real instant, not a length: `now` decides which
        // midnight or which Monday, and the reference is the last sample at or
        // before it. Falling back to the oldest sample keeps a number on screen
        // from the first second — flagged, via `isAnchored`, as measured from
        // later than it claims.
        let anchor = window.anchor(now: endTs)
        let start = points.last(where: { $0.ts <= anchor }) ?? points.first
        guard let start, start.equity > 0 else { return nil }

        return EquityChange(
            window: window,
            startEquity: start.equity,
            endEquity: endEquity,
            anchor: anchor,
            referenceTs: start.ts,
            // Counted from the anchor when history reaches it and from the
            // oldest sample when it does not — in both cases counting only the
            // stretches a sample actually stands behind.
            coveredSeconds: coveredSeconds(
                from: Swift.max(anchor, start.ts), to: endTs, now: endTs),
            spannedSeconds: Swift.max(endTs.timeIntervalSince(start.ts), 0),
            windowSeconds: Swift.max(endTs.timeIntervalSince(anchor), 0))
    }

    /// Seconds between `from` and `to` that recorded samples actually back.
    ///
    /// This is deliberately not `to - from`, which is what the coverage figure
    /// used to be computed from. Endpoint distance says nothing about the
    /// middle: on 2026-08-06 the trading loop was dead for 402 minutes of a
    /// 544-minute stretch, and because the curve still had a sample at each
    /// end, the panel reported that day as fully covered and printed a
    /// confident return across it. Only intervals short enough to be sampling
    /// jitter count; everything longer is a hole, and holes are the thing the
    /// reader needs told about.
    public func coveredSeconds(from: Date, to: Date, now: Date = Date()) -> TimeInterval {
        guard to > from else { return 0 }
        var covered: TimeInterval = 0
        var cursor = from
        for point in points where point.ts > from {
            guard point.ts <= to else { break }
            covered += Swift.min(point.ts.timeIntervalSince(cursor),
                                 Self.continuityLimit(after: cursor, now: now))
            cursor = point.ts
        }
        // The stretch since the newest sample. Fresh is covered; stale means
        // the figure on screen is older than its label admits.
        covered += Swift.min(to.timeIntervalSince(cursor),
                             Self.continuityLimit(after: cursor, now: now))
        return Swift.min(Swift.max(covered, 0), to.timeIntervalSince(from))
    }

    /// Longest silence still read as sampling jitter rather than downtime.
    ///
    /// The fine figure is deliberately the same 300s the heartbeat uses to
    /// declare the engine not trading: the banner and the coverage figure must
    /// not disagree about whether a stretch of time was covered. Past
    /// `fineHorizon` the curve is thinned to `coarseInterval` on purpose, so
    /// judging that region by the fine threshold would report our own
    /// compaction as an outage.
    public static let continuityTolerance: TimeInterval = 300

    private static func continuityLimit(after ts: Date, now: Date) -> TimeInterval {
        ts < now.addingTimeInterval(-fineHorizon) ? coarseInterval * 2 : continuityTolerance
    }

    /// Every window at once, in display order.
    public func changes(now: Date = Date(), latest liveEquity: Double? = nil) -> [EquityChange] {
        EquityWindow.allCases.compactMap { change(over: $0, now: now, latest: liveEquity) }
    }

    /// Points since a window's anchor, for a sparkline.
    public func window(_ window: EquityWindow, now: Date = Date()) -> [AccountEquityPoint] {
        let anchor = window.anchor(now: now)
        return points.filter { $0.ts >= anchor }
    }

    // MARK: Mutation

    /// Append a sample. Returns false when the sample was rejected — too soon
    /// after the previous one, non-finite, or timestamped in the past.
    @discardableResult
    public func record(equity: Double, at ts: Date = Date()) -> Bool {
        guard equity.isFinite, equity > 0 else { return false }
        if let last = points.last {
            // A clock that jumps backwards (NTP correction, sleep/wake) must
            // not be able to corrupt the ordering the window lookup relies on.
            guard ts > last.ts,
                  ts.timeIntervalSince(last.ts) >= Self.minimumSampleInterval else { return false }
        }
        points.append(AccountEquityPoint(ts: ts, equity: equity))
        compact(now: ts)
        onChanged?()
        return true
    }

    public func replace(points newPoints: [AccountEquityPoint]) {
        points = Self.normalise(newPoints)
    }

    public func clear() {
        points = []
        onChanged?()
    }

    /// Drop expired points and thin the coarse region. Idempotent.
    private func compact(now: Date) {
        let expiry = now.addingTimeInterval(-Self.retention)
        if let first = points.first, first.ts < expiry {
            points.removeAll { $0.ts < expiry }
        }

        let fineStart = now.addingTimeInterval(-Self.fineHorizon)
        guard points.contains(where: { $0.ts < fineStart }) else { return }
        var thinned: [AccountEquityPoint] = []
        var lastBucket: Int?
        for point in points {
            guard point.ts < fineStart else {
                thinned.append(point)
                continue
            }
            let bucket = Int(point.ts.timeIntervalSince1970 / Self.coarseInterval)
            guard bucket != lastBucket else { continue }
            thinned.append(point)
            lastBucket = bucket
        }
        points = thinned
    }

    /// Sort ascending and drop duplicate timestamps — a stored file may have
    /// been written by an older build or merged by hand.
    nonisolated static func normalise(_ points: [AccountEquityPoint]) -> [AccountEquityPoint] {
        var seen = Set<Date>()
        return points
            .filter { $0.equity.isFinite && $0.equity > 0 }
            .sorted { $0.ts < $1.ts }
            .filter { seen.insert($0.ts).inserted }
    }

    /// "3 小时" / "12 分钟" — used in the coverage tooltip.
    public nonisolated static func describe(_ seconds: TimeInterval) -> String {
        let value = Swift.max(seconds, 0)
        if value < 90 { return "\(Int(value.rounded())) 秒" }
        if value < 5_400 { return "\(Int((value / 60).rounded())) 分钟" }
        if value < 172_800 { return "\(Int((value / 3_600).rounded())) 小时" }
        return "\(Int((value / 86_400).rounded())) 天"
    }
}

// MARK: - Persistence

/// JSON-backed storage for one mode's equity curve.
public struct AccountEquityStore: Sendable {
    public let fileURL: URL

    public init(directory: URL, mode: TradingMode) {
        self.fileURL = directory.appendingPathComponent("equity-\(mode.rawValue).json")
    }

    /// Per-strategy curves live in their own file, keyed by strategy id.
    public init(directory: URL, mode: TradingMode, perStrategy: Bool) {
        let name = perStrategy
            ? "strategy-equity-\(mode.rawValue).json"
            : "equity-\(mode.rawValue).json"
        self.fileURL = directory.appendingPathComponent(name)
    }

    private struct Payload: Codable {
        var points: [AccountEquityPoint]
    }

    public func load() -> [AccountEquityPoint] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return [] }
        return AccountEquityCurve.normalise(payload.points)
    }

    /// Load every per-strategy curve from one file.
    public func loadByStrategy() -> [String: [AccountEquityPoint]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? decoder.decode([String: [AccountEquityPoint]].self, from: data)
        else { return [:] }
        return raw.mapValues(AccountEquityCurve.normalise)
    }

    public func save(byStrategy curves: [String: [AccountEquityPoint]]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(curves).write(to: fileURL, options: .atomic)
    }

    public func save(_ points: [AccountEquityPoint]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Payload(points: points))
        try data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Heartbeat

/// When the trading loop last completed a pass.
///
/// A dead man's switch rather than a health check: the engine says "I am still
/// doing useful work", and the *absence* of that signal is what raises the
/// alarm. An external probe asking "is the process up?" cannot distinguish a
/// running app from a running app whose loop has stopped — which is precisely
/// the failure that goes unnoticed, because nothing errors and the panel keeps
/// showing the last numbers it had.
///
/// On disk because the question is "was this trading while I was not
/// watching", and an in-memory value cannot answer that after a restart.
public struct HeartbeatStore: Sendable {
    public let fileURL: URL
    /// Writes closer together than this are skipped; the tick is far more
    /// frequent than the resolution this needs, and every write is disk I/O in
    /// the trading loop.
    public static let minimumInterval: TimeInterval = 30

    private final class Gate: @unchecked Sendable {
        var lastWrite: Date?
    }
    private let gate = Gate()

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("heartbeat.json")
    }

    private struct Payload: Codable { var lastTickAt: Date }

    public func record(_ ts: Date) {
        if let last = gate.lastWrite, ts.timeIntervalSince(last) < Self.minimumInterval { return }
        gate.lastWrite = ts
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(Payload(lastTickAt: ts)).write(to: fileURL, options: .atomic)
    }

    public func load() -> Date? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Payload.self, from: data))?.lastTickAt
    }
}
