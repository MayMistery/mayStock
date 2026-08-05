import Foundation
@testable import MayStockKit

/// Shared synthetic candles for tests that care about a price path rather than
/// about realistic market microstructure.
enum CandleFixture {
    /// One candle per close, with open/high/low all equal to it — a series with
    /// no intrabar range, so stops and targets can only trigger on the close.
    static func flat(_ closes: [Double], bar: TimeInterval = 3_600) -> [Candle] {
        closes.enumerated().map { index, close in
            Candle(ts: Date(timeIntervalSince1970: Double(index) * bar),
                   open: close, high: close, low: close, close: close,
                   volume: 1, confirmed: true)
        }
    }

    /// Explicit OHLC bars, for tests that care about where inside a bar a
    /// protective level sits.
    static func make(
        _ bars: [(open: Double, high: Double, low: Double, close: Double)],
        bar: TimeInterval = 3_600
    ) -> [Candle] {
        bars.enumerated().map { index, b in
            Candle(ts: Date(timeIntervalSince1970: Double(index) * bar),
                   open: b.open, high: b.high, low: b.low, close: b.close,
                   volume: 1, confirmed: true)
        }
    }

    /// Closes with an explicit intrabar range, for exercising protective exits.
    static func ranged(
        _ closes: [Double], spreadPct: Double = 1, bar: TimeInterval = 3_600
    ) -> [Candle] {
        closes.enumerated().map { index, close in
            let spread = close * spreadPct / 100
            return Candle(ts: Date(timeIntervalSince1970: Double(index) * bar),
                          open: close, high: close + spread, low: close - spread,
                          close: close, volume: 1, confirmed: true)
        }
    }
}
