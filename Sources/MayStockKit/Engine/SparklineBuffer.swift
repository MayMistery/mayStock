import Foundation

public struct SparkPoint: Sendable, Equatable {
    public let ts: Date
    public let price: Double
    public init(ts: Date, price: Double) {
        self.ts = ts
        self.price = price
    }
}

/// Ring buffer of price samples powering the menu bar sparkline and the
/// "% move within N minutes" alert condition.
///
/// Sampling: at most one point per `minInterval` seconds (default 1s),
/// capacity default 1 day of minute-grade coverage.
public struct SparklineBuffer: Sendable, Equatable {
    public private(set) var points: [SparkPoint] = []
    public let capacity: Int
    public let minInterval: TimeInterval

    public init(capacity: Int = 1_800, minInterval: TimeInterval = 1.0) {
        self.capacity = capacity
        self.minInterval = minInterval
    }

    public mutating func sample(price: Double, at ts: Date = Date()) {
        if let last = points.last, ts.timeIntervalSince(last.ts) < minInterval {
            return
        }
        points.append(SparkPoint(ts: ts, price: price))
        if points.count > capacity {
            points.removeFirst(points.count - capacity)
        }
    }

    /// Seed from candle closes so the sparkline is meaningful immediately
    /// after launch instead of growing from a single dot. Live ticks may have
    /// arrived before the REST backfill lands, so history is *prepended* in
    /// front of any existing samples (idempotent: only strictly-older bars).
    public mutating func seed(candles: [Candle]) {
        let cutoff = points.first?.ts ?? Date.distantFuture
        let history = candles
            .filter { $0.ts < cutoff }
            .map { SparkPoint(ts: $0.ts, price: $0.close) }
        guard !history.isEmpty else { return }
        points = Array((history + points).suffix(capacity))
    }

    /// Points inside the trailing window.
    public func window(minutes: Int, now: Date = Date()) -> [SparkPoint] {
        let cutoff = now.addingTimeInterval(-TimeInterval(minutes) * 60)
        guard let start = points.firstIndex(where: { $0.ts >= cutoff }) else { return [] }
        return Array(points[start...])
    }

    /// Percent move from the start of the trailing window to the latest point.
    public func movePct(minutes: Int, now: Date = Date()) -> Double? {
        let w = window(minutes: minutes, now: now)
        guard let first = w.first, let last = w.last, first.price > 0, w.count >= 2 else { return nil }
        return (last.price - first.price) / first.price * 100
    }
}
