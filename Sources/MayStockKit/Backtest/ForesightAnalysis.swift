import Foundation

/// One completed price swing: trough → peak, or peak → trough.
public struct PriceSwing: Sendable, Equatable {
    public let startIndex: Int
    public let endIndex: Int
    public let startPrice: Double
    public let endPrice: Double
    public let startTime: Date
    public let endTime: Date

    public var isUp: Bool { endPrice > startPrice }
    public var amplitudePct: Double { (endPrice / startPrice - 1) * 100 }
    public var bars: Int { endIndex - startIndex }
}

public struct ForesightResult: Sendable {
    public let swings: [PriceSwing]
    public let minimumSwingPct: Double
    /// Return from trading every swing perfectly, in percent, after costs.
    public let perfectReturnPct: Double
    /// Same, long-only (what a spot account could do).
    public let perfectLongOnlyReturnPct: Double
    public let buyHoldReturnPct: Double
    public let roundTripCostPct: Double
    public let barCount: Int
    public let spanDays: Double

    public var upSwings: Int { swings.filter(\.isUp).count }
    public var downSwings: Int { swings.count - upSwings }

    public var perfectDailyPct: Double {
        guard spanDays > 0, perfectReturnPct > -100 else { return 0 }
        return (pow(1 + perfectReturnPct / 100, 1 / spanDays) - 1) * 100
    }

    public var perfectLongOnlyDailyPct: Double {
        guard spanDays > 0, perfectLongOnlyReturnPct > -100 else { return 0 }
        return (pow(1 + perfectLongOnlyReturnPct / 100, 1 / spanDays) - 1) * 100
    }
}

/// How reliably a prior high or low actually stops price.
public struct LevelReliability: Sendable, Equatable {
    public let tests: Int
    public let held: Int
    public let broken: Int
    /// Share of touches that reversed rather than broke through.
    public var holdRate: Double { tests > 0 ? Double(held) / Double(tests) : 0 }
    /// Average move away from the level when it held, in percent.
    public let averageBouncePct: Double
    /// Average move through the level when it broke, in percent.
    public let averageBreakPct: Double
    /// Expected value of betting on the level holding, net of the round trip.
    public let expectancyPct: Double

    /// z-statistic of the hold rate against a coin flip.
    ///
    /// A 60% hold rate means nothing without knowing how many touches produced
    /// it: 6-out-of-10 is noise, 92-out-of-154 is not. |z| > 2 is the usual bar.
    public var zStatistic: Double {
        guard tests > 1 else { return 0 }
        let standardError = (0.25 / Double(tests)).squareRoot()
        guard standardError > 0 else { return 0 }
        return (holdRate - 0.5) / standardError
    }

    public var isSignificant: Bool { abs(zStatistic) > 2 }

    /// Annualised edge if every opportunity is taken, given how often they appear.
    public func annualEdgePct(overDays days: Double) -> Double {
        guard days > 0, tests > 0 else { return 0 }
        let perYear = Double(tests) / days * 365.25
        return perYear * expectancyPct
    }
}

/// What a strategy could earn **if it knew the future**, and how much of the
/// "obvious" structure on a chart is actually tradeable in advance.
///
/// This exists because the most expensive intuition in trading is that support
/// and resistance are visible in real time. On a finished chart every swing is
/// obvious; the question is what remains once you can only see the left-hand
/// side. `perfectReturnPct` is a hard ceiling nobody can reach — it is computed
/// **with look-ahead on purpose**, and is the only place in this codebase that
/// does so.
public enum ForesightAnalysis {

    /// Swing detection (zigzag): alternating extremes at least `minimumSwingPct`
    /// apart. Uses the whole series, so it is hindsight by construction.
    public static func swings(candles: [Candle], minimumSwingPct: Double) -> [PriceSwing] {
        guard candles.count > 2, minimumSwingPct > 0 else { return [] }
        let threshold = minimumSwingPct / 100

        var result: [PriceSwing] = []
        var anchorIndex = 0
        var anchorPrice = candles[0].close
        var extremeIndex = 0
        var extremePrice = candles[0].close
        var direction = 0        // 0 unknown, +1 rising, −1 falling

        for index in 1..<candles.count {
            let price = candles[index].close

            if direction >= 0, price > extremePrice {
                extremePrice = price
                extremeIndex = index
            }
            if direction <= 0, price < extremePrice {
                extremePrice = price
                extremeIndex = index
            }

            switch direction {
            case 0:
                if price / anchorPrice - 1 >= threshold {
                    direction = 1
                    extremePrice = price
                    extremeIndex = index
                } else if 1 - price / anchorPrice >= threshold {
                    direction = -1
                    extremePrice = price
                    extremeIndex = index
                }
            case 1:
                // Rising: a fall of `threshold` from the peak ends the swing.
                if 1 - price / extremePrice >= threshold {
                    result.append(PriceSwing(
                        startIndex: anchorIndex, endIndex: extremeIndex,
                        startPrice: anchorPrice, endPrice: extremePrice,
                        startTime: candles[anchorIndex].ts, endTime: candles[extremeIndex].ts))
                    anchorIndex = extremeIndex
                    anchorPrice = extremePrice
                    direction = -1
                    extremePrice = price
                    extremeIndex = index
                }
            default:
                if price / extremePrice - 1 >= threshold {
                    result.append(PriceSwing(
                        startIndex: anchorIndex, endIndex: extremeIndex,
                        startPrice: anchorPrice, endPrice: extremePrice,
                        startTime: candles[anchorIndex].ts, endTime: candles[extremeIndex].ts))
                    anchorIndex = extremeIndex
                    anchorPrice = extremePrice
                    direction = 1
                    extremePrice = price
                    extremeIndex = index
                }
            }
        }

        // The series ends mid-swing. A live zigzag would leave it unconfirmed,
        // but this is explicitly a hindsight tool: the final leg happened and a
        // perfect trader would have taken it, so it counts toward the ceiling.
        if extremeIndex > anchorIndex,
           abs(extremePrice / anchorPrice - 1) >= threshold {
            result.append(PriceSwing(
                startIndex: anchorIndex, endIndex: extremeIndex,
                startPrice: anchorPrice, endPrice: extremePrice,
                startTime: candles[anchorIndex].ts, endTime: candles[extremeIndex].ts))
        }
        return result
    }

    /// The ceiling: trade every swing perfectly, paying real costs.
    public static func perfectForesight(
        candles: [Candle], minimumSwingPct: Double, roundTripCostPct: Double
    ) -> ForesightResult {
        let detected = swings(candles: candles, minimumSwingPct: minimumSwingPct)
        let cost = roundTripCostPct / 100

        // Long and short every swing.
        var equity = 1.0
        for swing in detected {
            let gross = abs(swing.endPrice / swing.startPrice - 1)
            equity *= (1 + gross) * (1 - cost)
        }
        // Long-only: sit out the down swings (what spot can do).
        var longOnly = 1.0
        for swing in detected where swing.isUp {
            let gross = swing.endPrice / swing.startPrice - 1
            longOnly *= (1 + gross) * (1 - cost)
        }

        let first = candles.first?.close ?? 0
        let last = candles.last?.close ?? 0
        let span = zipSpan(candles)

        return ForesightResult(
            swings: detected,
            minimumSwingPct: minimumSwingPct,
            perfectReturnPct: (equity - 1) * 100,
            perfectLongOnlyReturnPct: (longOnly - 1) * 100,
            buyHoldReturnPct: first > 0 ? (last / first - 1) * 100 : 0,
            roundTripCostPct: roundTripCostPct,
            barCount: candles.count,
            spanDays: span)
    }

    private static func zipSpan(_ candles: [Candle]) -> Double {
        guard let first = candles.first, let last = candles.last else { return 0 }
        return last.ts.timeIntervalSince(first.ts) / 86_400
    }

    /// Does a prior swing extreme actually stop price?
    ///
    /// Walks forward in time using only past extremes — no look-ahead. Each time
    /// price comes within `tolerancePct` of a level established earlier, it
    /// records whether price then moved *away* by `targetPct` (held) or *through*
    /// by `targetPct` (broke), whichever happened first.
    public static func levelReliability(
        candles: [Candle],
        minimumSwingPct: Double,
        tolerancePct: Double = 0.5,
        targetPct: Double = 2,
        roundTripCostPct: Double = 0.3
    ) -> LevelReliability {
        let detected = swings(candles: candles, minimumSwingPct: minimumSwingPct)
        guard !detected.isEmpty else {
            return LevelReliability(tests: 0, held: 0, broken: 0,
                                    averageBouncePct: 0, averageBreakPct: 0, expectancyPct: 0)
        }

        // A level becomes usable only once the swing that formed it has ended.
        let levels: [(index: Int, price: Double, isResistance: Bool)] = detected.map {
            ($0.endIndex, $0.endPrice, $0.isUp)
        }

        var tests = 0, held = 0, broken = 0
        var bounceTotal = 0.0, breakTotal = 0.0
        let tolerance = tolerancePct / 100
        let target = targetPct / 100

        for level in levels {
            // Look for the first touch strictly after the level formed.
            var touchIndex: Int?
            var index = level.index + 1
            while index < candles.count {
                if abs(candles[index].close / level.price - 1) <= tolerance {
                    touchIndex = index
                    break
                }
                index += 1
            }
            guard let touch = touchIndex, touch + 1 < candles.count else { continue }

            // From the touch, which came first: away by target, or through by target?
            var outcome: Bool?
            var move = 0.0
            for forward in (touch + 1)..<candles.count {
                let change = candles[forward].close / level.price - 1
                if level.isResistance {
                    if -change >= target { outcome = true; move = -change * 100; break }
                    if change >= target { outcome = false; move = change * 100; break }
                } else {
                    if change >= target { outcome = true; move = change * 100; break }
                    if -change >= target { outcome = false; move = -change * 100; break }
                }
            }
            guard let resolved = outcome else { continue }
            tests += 1
            if resolved {
                held += 1
                bounceTotal += move
            } else {
                broken += 1
                breakTotal += move
            }
        }

        let holdRate = tests > 0 ? Double(held) / Double(tests) : 0
        let averageBounce = held > 0 ? bounceTotal / Double(held) : 0
        let averageBreak = broken > 0 ? breakTotal / Double(broken) : 0
        // Betting the level holds: win `target`, lose `target`, pay the round trip.
        let expectancy = holdRate * targetPct - (1 - holdRate) * targetPct - roundTripCostPct

        return LevelReliability(
            tests: tests, held: held, broken: broken,
            averageBouncePct: averageBounce, averageBreakPct: averageBreak,
            expectancyPct: expectancy)
    }
}
