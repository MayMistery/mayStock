import Foundation

/// Pure chart mathematics shared by every MayStock chart: axis tick selection,
/// moving averages and shape-preserving downsampling.
///
/// Lives in the kit rather than the app so it is unit-testable without AppKit,
/// and so all three charts provably agree on what a "nice" axis looks like.
public enum ChartMath {

    // MARK: - Value axis

    /// A "nice" axis step (1/2/5 × 10ⁿ) so gridlines land on round numbers.
    public static func niceStep(range: Double, target: Int = 4) -> Double {
        guard range > 0, range.isFinite, target > 0 else { return 1 }
        let rough = range / Double(target)
        let magnitude = pow(10, floor(log10(rough)))
        guard magnitude > 0, magnitude.isFinite else { return 1 }
        let normalized = rough / magnitude
        let nice: Double = normalized < 1.5 ? 1 : normalized < 3.5 ? 2 : normalized < 7.5 ? 5 : 10
        return nice * magnitude
    }

    /// Round values inside `lo...hi`, spaced on a nice step.
    public static func valueTicks(lo: Double, hi: Double, target: Int = 4) -> [Double] {
        guard hi > lo, lo.isFinite, hi.isFinite else { return [] }
        let step = niceStep(range: hi - lo, target: target)
        guard step > 0, step.isFinite else { return [] }
        var ticks: [Double] = []
        var value = (lo / step).rounded(.up) * step
        while value <= hi, ticks.count < 64 {
            ticks.append(value)
            value += step
        }
        return ticks
    }

    // MARK: - Time axis (time-positioned series)

    /// Human-friendly time steps, ascending. Every entry below a day divides a
    /// day evenly, so ticks land on wall-clock boundaries.
    public static let timeStepLadder: [TimeInterval] = [
        1, 2, 5, 10, 15, 30,
        60, 120, 300, 600, 900, 1_800,
        3_600, 7_200, 10_800, 21_600, 43_200,
        86_400,
    ]

    /// Smallest ladder step that keeps the tick count within `maxLabels`.
    public static func niceTimeStep(span: TimeInterval, maxLabels: Int = 5) -> TimeInterval {
        guard span > 0, span.isFinite, maxLabels > 1 else { return 60 }
        let rough = span / Double(maxLabels - 1)
        return timeStepLadder.first { $0 >= rough } ?? 86_400
    }

    /// Wall-clock aligned ticks inside `start...end`, so labels read
    /// 10:00 / 10:15 / 10:30 rather than 10:03 / 10:18 / 10:33.
    public static func timeTicks(
        from start: Date, to end: Date,
        maxLabels: Int = 5, timeZone: TimeZone = .current
    ) -> [Date] {
        guard end > start else { return [] }
        let step = niceTimeStep(span: end.timeIntervalSince(start), maxLabels: maxLabels)
        // Align to local midnight rather than to the UTC epoch.
        let offset = TimeInterval(timeZone.secondsFromGMT(for: start))
        let startLocal = start.timeIntervalSince1970 + offset
        let endLocal = end.timeIntervalSince1970 + offset
        var local = (startLocal / step).rounded(.up) * step
        var ticks: [Date] = []
        while local <= endLocal, ticks.count < 64 {
            ticks.append(Date(timeIntervalSince1970: local - offset))
            local += step
        }
        return ticks
    }

    /// Label format for a time-positioned axis spanning `span`.
    ///
    /// A full day is still clock-only: every label would carry the same date.
    public static func timeAxisFormat(span: TimeInterval) -> String {
        switch span {
        case ..<180: return "HH:mm:ss"
        case ...86_400: return "HH:mm"
        case ..<(7 * 86_400): return "MM-dd HH:mm"
        default: return "MM-dd"
        }
    }

    // MARK: - Time axis (index-positioned series)

    /// Calendar granularity for axis labels.
    public enum AxisUnit: Sendable, Equatable {
        case seconds(Int)
        case minutes(Int)
        case hours(Int)
        case days
        case weeks
        case months
        case years

        /// Nominal length, used to skip units finer than the bar interval.
        public var approximateSeconds: TimeInterval {
            switch self {
            case .seconds(let n): return TimeInterval(n)
            case .minutes(let n): return TimeInterval(n) * 60
            case .hours(let n): return TimeInterval(n) * 3_600
            case .days: return 86_400
            case .weeks: return 604_800
            case .months: return 2_629_800
            case .years: return 31_557_600
            }
        }

        /// True once a boundary of this unit is also a calendar-day boundary.
        public var isDayOrLarger: Bool {
            switch self {
            case .days, .weeks, .months, .years: return true
            default: return false
            }
        }

        public var labelFormat: String {
            switch self {
            case .seconds: return "HH:mm:ss"
            case .minutes, .hours: return "HH:mm"
            case .days, .weeks: return "MM-dd"
            case .months: return "yyyy-MM"
            case .years: return "yyyy"
            }
        }
    }

    /// A label position on an index-positioned (candlestick) axis.
    public struct AxisTick: Sendable, Equatable {
        public let index: Int
        public let date: Date
        /// Crosses into a new calendar day (or larger) — worth emphasising.
        public let isMajor: Bool

        public init(index: Int, date: Date, isMajor: Bool) {
            self.index = index
            self.date = date
            self.isMajor = isMajor
        }
    }

    private static let unitLadder: [AxisUnit] = [
        .seconds(1), .seconds(5), .seconds(15), .seconds(30),
        .minutes(1), .minutes(5), .minutes(15), .minutes(30),
        .hours(1), .hours(3), .hours(6), .hours(12),
        .days, .weeks, .months, .years,
    ]

    /// Label positions for a series laid out by *index* (candlesticks), placed
    /// on the first bar of each wall-clock boundary.
    ///
    /// The unit is the finest one that still yields at most `maxLabels` labels,
    /// which is what gives professional charts their ...09:00 / 10:00 / 11:00
    /// axis instead of labels at whatever index happened to divide evenly.
    public static func axisTicks(
        timestamps: [Date], maxLabels: Int = 5,
        barSeconds: TimeInterval = 0, timeZone: TimeZone = .current
    ) -> [AxisTick] {
        guard timestamps.count > 1, maxLabels > 1 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Never label more often than one bar; never finer than needed.
        let candidates = unitLadder.filter { $0.approximateSeconds >= barSeconds }
        var denser: [AxisTick] = []
        for unit in candidates.isEmpty ? [AxisUnit.years] : candidates {
            let ticks = boundaries(timestamps: timestamps, unit: unit, calendar: calendar)
            guard ticks.count <= maxLabels else {
                denser = ticks
                continue
            }
            // Jumping a rung can overshoot — three months of daily bars go from
            // 11 weekly labels straight to 2 monthly ones. Thinning the denser
            // rung keeps the labels on real boundaries *and* fills the budget.
            //
            // Only rescue genuinely sparse axes: thinning a rung that already
            // half-fills the budget just shifts the labels off the rounder
            // phase (09:15/09:45 instead of 09:00/09:30) for no gain.
            if ticks.count * 2 <= maxLabels, !denser.isEmpty {
                let stride = Int((Double(denser.count) / Double(maxLabels)).rounded(.up))
                if stride > 1 {
                    let thinned = denser.enumerated()
                        .filter { $0.offset.isMultiple(of: stride) }
                        .map(\.element)
                    if thinned.count > ticks.count, thinned.count <= maxLabels { return thinned }
                }
            }
            return ticks
        }
        // Even years are too dense (absurdly long series): fall back to a stride.
        let stride = max(1, timestamps.count / max(maxLabels - 1, 1))
        return Swift.stride(from: 0, to: timestamps.count, by: stride).map {
            AxisTick(index: $0, date: timestamps[$0], isMajor: false)
        }
    }

    private static func boundaries(
        timestamps: [Date], unit: AxisUnit, calendar: Calendar
    ) -> [AxisTick] {
        var ticks: [AxisTick] = []
        var previousKey = bucketKey(timestamps[0], unit: unit, calendar: calendar)
        var previousDay = calendar.startOfDay(for: timestamps[0])
        for index in 1..<timestamps.count {
            let date = timestamps[index]
            let key = bucketKey(date, unit: unit, calendar: calendar)
            defer { previousKey = key }
            guard key != previousKey else { continue }
            let day = calendar.startOfDay(for: date)
            let isMajor = unit.isDayOrLarger || day != previousDay
            previousDay = day
            ticks.append(AxisTick(index: index, date: date, isMajor: isMajor))
            if ticks.count > 64 { return ticks } // bail out of pathological input
        }
        return ticks
    }

    private static func bucketKey(_ date: Date, unit: AxisUnit, calendar: Calendar) -> Int {
        switch unit {
        case .seconds, .minutes, .hours:
            let step = unit.approximateSeconds
            let offset = TimeInterval(calendar.timeZone.secondsFromGMT(for: date))
            return Int(((date.timeIntervalSince1970 + offset) / step).rounded(.down))
        case .days:
            return Int(calendar.startOfDay(for: date).timeIntervalSince1970 / 86_400)
        case .weeks:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return (components.yearForWeekOfYear ?? 0) * 60 + (components.weekOfYear ?? 0)
        case .months:
            let components = calendar.dateComponents([.year, .month], from: date)
            return (components.year ?? 0) * 12 + (components.month ?? 0)
        case .years:
            return calendar.component(.year, from: date)
        }
    }

    // MARK: - Series maths

    /// Simple moving average over the *whole* series; `nil` until `period`
    /// samples exist. Computing this over full history (not the visible slice)
    /// is what makes the overlay agree with every other charting package.
    public static func movingAverage(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0 else { return Array(repeating: nil, count: values.count) }
        var out = [Double?](repeating: nil, count: values.count)
        var sum = 0.0
        for index in values.indices {
            sum += values[index]
            if index >= period { sum -= values[index - period] }
            if index >= period - 1 { out[index] = sum / Double(period) }
        }
        return out
    }

    /// Shape-preserving downsample: within each equal-time bucket keep the
    /// extremes (in chronological order), so spikes survive but the point count
    /// stays proportional to the pixels available.
    public static func downsample(_ points: [SparkPoint], buckets: Int) -> [SparkPoint] {
        guard buckets > 1, points.count > buckets * 2 else { return points }
        guard let firstTs = points.first?.ts, let lastTs = points.last?.ts else { return points }
        let span = lastTs.timeIntervalSince(firstTs)
        guard span > 0 else { return points }
        let width = span / Double(buckets)

        var result: [SparkPoint] = []
        result.reserveCapacity(buckets * 2)
        var index = 0
        while index < points.count {
            let bucket = min(buckets - 1, Int(points[index].ts.timeIntervalSince(firstTs) / width))
            var end = index
            var low = points[index], high = points[index]
            while end < points.count,
                  min(buckets - 1, Int(points[end].ts.timeIntervalSince(firstTs) / width)) == bucket {
                if points[end].price < low.price { low = points[end] }
                if points[end].price > high.price { high = points[end] }
                end += 1
            }
            if low.ts <= high.ts {
                result.append(low)
                if high.ts != low.ts { result.append(high) }
            } else {
                result.append(high)
                result.append(low)
            }
            index = end
        }
        // Anchor the true endpoints so the last price is never smoothed away.
        if let first = points.first, result.first != first { result.insert(first, at: 0) }
        if let last = points.last, result.last != last { result.append(last) }
        return result
    }
}
