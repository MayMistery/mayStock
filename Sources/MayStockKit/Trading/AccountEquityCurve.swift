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

/// The trailing windows the panel reports.
public enum EquityWindow: String, CaseIterable, Sendable, Identifiable {
    case hour1, day1, day7

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .hour1: return 3_600
        case .day1: return 86_400
        case .day7: return 7 * 86_400
        }
    }

    public var label: String {
        switch self {
        case .hour1: return "1h"
        case .day1: return "1d"
        case .day7: return "7d"
        }
    }
}

/// Equity change over a trailing window, carrying an explicit statement of how
/// much of that window real samples actually cover.
///
/// The coverage field is the point of this type. A freshly-installed app has
/// minutes of history; rendering its 20-minute move under a "7d" label would be
/// a lie of exactly the kind this codebase refuses to tell elsewhere. Callers
/// are expected to check `isComplete` before presenting the number plainly.
public struct EquityChange: Sendable, Equatable {
    public let window: EquityWindow
    public let startEquity: Double
    public let endEquity: Double
    /// Seconds between the reference sample and the endpoint.
    public let coveredSeconds: TimeInterval

    public init(
        window: EquityWindow, startEquity: Double, endEquity: Double,
        coveredSeconds: TimeInterval
    ) {
        self.window = window
        self.startEquity = startEquity
        self.endEquity = endEquity
        self.coveredSeconds = coveredSeconds
    }

    public var changeQuote: Double { endEquity - startEquity }

    public var changePct: Double? {
        guard startEquity > 0 else { return nil }
        return changeQuote / startEquity * 100
    }

    /// Fraction of the requested window backed by recorded history.
    public var coverage: Double {
        guard window.seconds > 0 else { return 0 }
        return Swift.min(Swift.max(coveredSeconds, 0) / window.seconds, 1)
    }

    /// Below this the number is a shorter-window return wearing a longer
    /// window's label, and the UI must say so rather than print it straight.
    public var isComplete: Bool { coverage >= 0.9 }

    /// Human description of the shortfall, for a tooltip.
    public var coverageNote: String {
        guard !isComplete else { return "" }
        return "仅记录了 \(AccountEquityCurve.describe(coveredSeconds))，不足 \(window.label)"
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
        let cutoff = endTs.addingTimeInterval(-window.seconds)
        let start = points.last(where: { $0.ts <= cutoff }) ?? points.first
        guard let start, start.equity > 0 else { return nil }

        return EquityChange(
            window: window,
            startEquity: start.equity,
            endEquity: endEquity,
            coveredSeconds: Swift.max(endTs.timeIntervalSince(start.ts), 0))
    }

    /// Every window at once, in display order.
    public func changes(now: Date = Date(), latest liveEquity: Double? = nil) -> [EquityChange] {
        EquityWindow.allCases.compactMap { change(over: $0, now: now, latest: liveEquity) }
    }

    /// Points inside a trailing window, for a sparkline.
    public func window(_ window: EquityWindow, now: Date = Date()) -> [AccountEquityPoint] {
        let cutoff = now.addingTimeInterval(-window.seconds)
        return points.filter { $0.ts >= cutoff }
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
