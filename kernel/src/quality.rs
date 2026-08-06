//! Is this candle series fit to trade on?
//!
//! A backtest is handed a clean, contiguous array. Live trading is handed
//! whatever the exchange returned, which on a bad day means a stale bar, a
//! hole where a bar should be, or the same bar twice. Every indicator downstream
//! will happily compute a number from that, and the number will look exactly
//! like a real one.
//!
//! The research on production trading systems is blunt about this: the gap
//! check is the part most people skip, and without it a quiet feed is
//! indistinguishable from a dead one. So the series is inspected *before* the
//! signal is, and a strategy standing aside on bad data is the correct
//! behaviour rather than a failure.

use serde::{Deserialize, Serialize};

use crate::candle::Candle;

/// What is wrong with the series, if anything.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DataQuality {
    /// Safe to compute signals from.
    pub usable: bool,
    /// Human-readable summary, empty when usable.
    pub reason: String,
    /// Bars missing from the middle of the series.
    pub gaps: usize,
    /// Repeated timestamps.
    pub duplicates: usize,
    /// Bars failing the OHLC sanity check.
    pub malformed: usize,
    /// How far behind the latest confirmed bar is, in bar intervals. `None`
    /// when the caller supplied no wall clock.
    #[serde(rename = "barsBehind")]
    pub bars_behind: Option<f64>,
}

impl DataQuality {
    fn good() -> Self {
        Self {
            usable: true,
            reason: String::new(),
            gaps: 0,
            duplicates: 0,
            malformed: 0,
            bars_behind: None,
        }
    }
}

/// How stale the newest confirmed bar may be before the feed is presumed
/// broken, in bar intervals.
///
/// Two rather than one: a bar is only confirmed once the *next* one opens, so
/// a healthy feed is routinely a whole interval behind. Anything past two means
/// a bar that should exist does not.
pub const MAX_BARS_BEHIND: f64 = 2.5;

/// How many bars may be missing before the series is refused outright.
///
/// Not zero. Exchanges genuinely drop the occasional bar in thin markets, and
/// refusing to trade for the rest of the day over one hole would be its own
/// kind of failure. What must never pass is a series with enough holes that a
/// lookback window no longer means what it says.
pub const MAX_GAP_RATIO: f64 = 0.02;

/// Inspect the confirmed portion of a candle series.
///
/// `now_ms` is the caller's wall clock. The kernel has none by design — it is
/// pure computation — so staleness is only checked when the caller supplies
/// one. Passing `None` from a backtest is correct: historical data is stale
/// by definition and the property is meaningless there.
pub fn inspect(candles: &[Candle], bar_seconds: f64, now_ms: Option<i64>) -> DataQuality {
    let confirmed: Vec<Candle> = candles.iter().copied().filter(|c| c.is_confirmed()).collect();
    if confirmed.len() < 2 || bar_seconds <= 0.0 {
        return DataQuality::good();
    }

    let mut sorted = confirmed;
    sorted.sort_by_key(|c| c.ts_ms);

    let malformed = sorted.iter().filter(|c| !c.is_sane()).count();
    let interval_ms = (bar_seconds * 1000.0) as i64;

    let mut duplicates = 0usize;
    let mut gaps = 0usize;
    for pair in sorted.windows(2) {
        let step = pair[1].ts_ms - pair[0].ts_ms;
        if step == 0 {
            duplicates += 1;
        } else if step > interval_ms {
            // Every whole interval beyond the first is a bar that is not there.
            gaps += ((step / interval_ms) - 1).max(0) as usize;
        }
    }

    let bars_behind = now_ms.map(|now| {
        let newest = sorted[sorted.len() - 1].ts_ms;
        (now - newest) as f64 / (bar_seconds * 1000.0)
    });

    let expected = sorted.len() + gaps;
    let gap_ratio = gaps as f64 / expected as f64;

    // Ordered by how badly each one misleads a signal, worst first.
    let reason = if malformed > 0 {
        format!("{malformed} 根 K 线的高低价与开收盘不自洽，行情源有问题")
    } else if duplicates > 0 {
        format!("{duplicates} 根 K 线时间戳重复，序列不可信")
    } else if gap_ratio > MAX_GAP_RATIO {
        format!(
            "缺失 {gaps} 根 K 线（占 {:.1}%），回看窗口已经名不副实",
            gap_ratio * 100.0
        )
    } else if bars_behind.is_some_and(|behind| behind > MAX_BARS_BEHIND) {
        format!(
            "最新已确认 K 线落后 {:.1} 根，行情可能已经断了",
            bars_behind.unwrap_or_default()
        )
    } else {
        String::new()
    };

    DataQuality {
        usable: reason.is_empty(),
        reason,
        gaps,
        duplicates,
        malformed,
        bars_behind,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOUR: f64 = 3_600.0;
    const HOUR_MS: i64 = 3_600_000;

    fn bar(ts_ms: i64) -> Candle {
        Candle {
            ts_ms,
            open: 100.0,
            high: 101.0,
            low: 99.0,
            close: 100.5,
            volume: 1.0,
            confirmed: 1,
        }
    }

    fn contiguous(count: i64) -> Vec<Candle> {
        (0..count).map(|i| bar(i * HOUR_MS)).collect()
    }

    #[test]
    fn a_clean_series_is_usable() {
        let result = inspect(&contiguous(100), HOUR, None);
        assert!(result.usable, "{}", result.reason);
        assert_eq!(result.gaps, 0);
    }

    #[test]
    fn one_missing_bar_in_a_hundred_is_tolerated() {
        // Exchanges do drop the occasional bar in a thin market. Standing down
        // for the rest of the day over one hole is its own kind of failure.
        let mut candles = contiguous(100);
        candles.remove(50);
        let result = inspect(&candles, HOUR, None);
        assert_eq!(result.gaps, 1);
        assert!(result.usable);
    }

    #[test]
    fn a_series_full_of_holes_is_refused() {
        let candles: Vec<Candle> = (0..50).map(|i| bar(i * HOUR_MS * 3)).collect();
        let result = inspect(&candles, HOUR, None);
        assert!(!result.usable);
        assert!(result.reason.contains("缺失"));
    }

    #[test]
    fn a_stale_feed_is_refused() {
        // The newest bar is 10 hours old on an hourly strategy: the feed is
        // not quiet, it is dead.
        let candles = contiguous(100);
        let now = 99 * HOUR_MS + 10 * HOUR_MS;
        let result = inspect(&candles, HOUR, Some(now));
        assert!(!result.usable);
        assert!(result.reason.contains("落后"));
    }

    #[test]
    fn being_one_bar_behind_is_normal() {
        // A bar is only confirmed once the next one opens, so a healthy feed is
        // routinely a whole interval behind. Refusing that would refuse always.
        let candles = contiguous(100);
        let now = 99 * HOUR_MS + HOUR_MS + 60_000;
        assert!(inspect(&candles, HOUR, Some(now)).usable);
    }

    #[test]
    fn a_duplicate_timestamp_is_refused() {
        let mut candles = contiguous(20);
        candles.push(bar(10 * HOUR_MS));
        let result = inspect(&candles, HOUR, None);
        assert!(!result.usable);
        assert!(result.reason.contains("重复"));
    }

    #[test]
    fn a_malformed_bar_is_refused() {
        // A low above the high is not a quiet market, it is a broken feed —
        // and every indicator downstream would compute a real-looking number
        // from it.
        let mut candles = contiguous(20);
        candles[5].low = 500.0;
        let result = inspect(&candles, HOUR, None);
        assert!(!result.usable);
        assert!(result.reason.contains("不自洽"));
    }

    #[test]
    fn a_backtest_passing_no_clock_is_never_stale() {
        // Historical data is stale by definition; the property is meaningless
        // there and must not block a backtest.
        let candles = contiguous(100);
        let result = inspect(&candles, HOUR, None);
        assert!(result.usable);
        assert!(result.bars_behind.is_none());
    }

    #[test]
    fn too_short_a_series_is_not_judged() {
        // Warm-up handles "not enough data"; this module only judges data it
        // actually has.
        assert!(inspect(&contiguous(1), HOUR, None).usable);
        assert!(inspect(&[], HOUR, None).usable);
    }

    #[test]
    fn unconfirmed_bars_do_not_count_as_gaps() {
        // The forming bar is filtered out everywhere else too; if it counted
        // here the newest data would always look like a hole.
        let mut candles = contiguous(20);
        candles.push(Candle { confirmed: 0, ..bar(50 * HOUR_MS) });
        assert!(inspect(&candles, HOUR, None).usable);
    }
}
