import Foundation

public struct SparkPoint: Sendable, Equatable {
    public let ts: Date
    public let price: Double
    public init(ts: Date, price: Double) {
        self.ts = ts
        self.price = price
    }
}

/// Price history powering the menu bar sparkline, the panel line chart and the
/// "% move within N minutes" alert condition.
///
/// Storage is **two-tiered** so a full day of history costs a few thousand
/// points instead of 86 400:
///
///   - `fine`   — recent samples at up to one per `fineInterval` (1s), covering
///                the last `fineWindow` (2h). This is what a 5m/15m/1H window
///                draws, so it stays tick-accurate.
///   - `coarse` — everything older, compacted to one point per `coarseInterval`
///                (1m) and trimmed to `retention` (25h). This is what a 4H/24H
///                window draws, where per-second detail is invisible anyway.
///
/// The old fixed 1 800-sample ring held only 30 minutes, which silently capped
/// every window longer than that — the reason the window filter appeared dead.
public struct SparklineBuffer: Sendable, Equatable {
    /// Minimum spacing between live samples.
    public let fineInterval: TimeInterval
    /// How long samples keep full resolution before compaction.
    public let fineWindow: TimeInterval
    /// Bucket size for compacted history.
    public let coarseInterval: TimeInterval
    /// Total history kept.
    public let retention: TimeInterval

    /// Compacted history, ascending by ts. Always strictly older than `fine`.
    public private(set) var coarse: [SparkPoint] = []
    /// Full-resolution recent samples, ascending by ts.
    public private(set) var fine: [SparkPoint] = []

    /// Timestamp of the first *live* sample. Seeded history may never overwrite
    /// anything at or after this instant.
    private var liveStart: Date?

    public init(
        fineInterval: TimeInterval = 1,
        fineWindow: TimeInterval = 2 * 3_600,
        coarseInterval: TimeInterval = 60,
        retention: TimeInterval = 25 * 3_600
    ) {
        self.fineInterval = max(fineInterval, 0.05)
        self.fineWindow = max(fineWindow, 60)
        self.coarseInterval = max(coarseInterval, 1)
        self.retention = max(retention, fineWindow)
    }

    /// Whole series, ascending by ts.
    public var points: [SparkPoint] { coarse + fine }

    public var isEmpty: Bool { coarse.isEmpty && fine.isEmpty }
    public var first: SparkPoint? { coarse.first ?? fine.first }
    public var last: SparkPoint? { fine.last ?? coarse.last }

    /// Oldest instant covered by the buffer, if any.
    public var coverageStart: Date? { first?.ts }

    // MARK: Ingest

    public mutating func sample(price: Double, at ts: Date = Date()) {
        guard price.isFinite else { return }
        // Reject out-of-order and over-frequent samples: exchange timestamps
        // can jitter, and tickers push ~10×/s.
        if let last {
            guard ts.timeIntervalSince(last.ts) >= fineInterval else { return }
        }
        if liveStart == nil { liveStart = ts }
        fine.append(SparkPoint(ts: ts, price: price))
        compact(now: ts)
    }

    /// Seed from candle closes so a window is meaningful immediately after
    /// launch instead of growing from a single dot.
    ///
    /// Safe to call repeatedly with different resolutions — a later, finer seed
    /// refines the buckets an earlier coarse seed filled, and neither can touch
    /// buckets that hold live samples.
    public mutating func seed(candles: [Candle]) {
        guard !candles.isEmpty else { return }
        let liveCutoff = liveStart ?? .distantFuture

        // Buckets already holding live-derived data are untouchable.
        var live: [Int: SparkPoint] = [:]
        var seeded: [Int: SparkPoint] = [:]
        for point in coarse {
            if point.ts >= liveCutoff { live[bucket(point.ts)] = point }
            else { seeded[bucket(point.ts)] = point }
        }
        for candle in candles where candle.ts < liveCutoff && candle.close.isFinite {
            seeded[bucket(candle.ts)] = SparkPoint(ts: candle.ts, price: candle.close)
        }

        coarse = seeded.merging(live) { _, liveValue in liveValue }
            .values.sorted { $0.ts < $1.ts }
        trim()
    }

    // MARK: Read

    /// Points inside the trailing window, ascending by ts.
    public func window(minutes: Int, now: Date = Date()) -> [SparkPoint] {
        window(seconds: TimeInterval(minutes) * 60, now: now)
    }

    public func window(seconds: TimeInterval, now: Date = Date()) -> [SparkPoint] {
        let cutoff = now.addingTimeInterval(-seconds)
        // `fine` alone answers most windows; only reach into history when needed.
        let head: [SparkPoint]
        if let start = coarse.firstIndex(where: { $0.ts >= cutoff }) {
            head = Array(coarse[start...])
        } else {
            head = []
        }
        guard let start = fine.firstIndex(where: { $0.ts >= cutoff }) else { return head }
        return head + fine[start...]
    }

    /// Percent move from the start of the trailing window to the latest point.
    public func movePct(minutes: Int, now: Date = Date()) -> Double? {
        let w = window(minutes: minutes, now: now)
        guard let first = w.first, let last = w.last, first.price > 0, w.count >= 2 else { return nil }
        return (last.price - first.price) / first.price * 100
    }

    // MARK: Internals

    private func bucket(_ ts: Date) -> Int {
        Int((ts.timeIntervalSince1970 / coarseInterval).rounded(.down))
    }

    /// Demote samples that aged out of the fine window into 1-minute buckets.
    private mutating func compact(now: Date) {
        let cutoff = now.addingTimeInterval(-fineWindow)
        let end = fine.firstIndex(where: { $0.ts >= cutoff }) ?? fine.count
        guard end > 0 else { trim(newest: now); return }
        let aged = Array(fine[..<end])
        fine.removeFirst(end)

        // One representative per bucket (the bucket's closing price), appended
        // in order — `coarse` stays sorted and stays older than `fine`.
        var lastKey = coarse.last.map { bucket($0.ts) }
        for point in aged {
            let key = bucket(point.ts)
            if key == lastKey, !coarse.isEmpty {
                coarse[coarse.count - 1] = point // a later sample closes the bucket
            } else {
                coarse.append(point)
                lastKey = key
            }
        }
        trim(newest: now)
    }

    private mutating func trim() { trim(newest: last?.ts) }

    private mutating func trim(newest: Date?) {
        guard let newest else { return }
        let cutoff = newest.addingTimeInterval(-retention)
        if let oldest = coarse.first?.ts, oldest < cutoff {
            if let start = coarse.firstIndex(where: { $0.ts >= cutoff }) {
                coarse.removeFirst(start)
            } else {
                coarse.removeAll()
            }
        }
        // Hard ceilings as a safety net against pathological clocks.
        let maxCoarse = Int(retention / coarseInterval) + 8
        if coarse.count > maxCoarse { coarse.removeFirst(coarse.count - maxCoarse) }
        let maxFine = Int(fineWindow / fineInterval) + 8
        if fine.count > maxFine { fine.removeFirst(fine.count - maxFine) }
    }
}
