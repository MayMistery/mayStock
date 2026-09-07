//! Is this candle series fit to trade on?
//!
//! Every indicator downstream will compute a plausible-looking number from a
//! series with a hole in it, a duplicate bar, or a bar whose high is below its
//! low. None of them can tell. So the series is judged *before* any of them
//! see it, and a series that fails is a refusal to decide — not a flat target,
//! which would liquidate a position because the feed hiccupped.
//!
//! "A hole" is judged against the market's calendar, not against the clock.
//! An hourly stock series is missing nothing between Friday's 15:30 bar and
//! Monday's 09:30 one; an hourly crypto series missing the same stretch has
//! lost sixty-five bars. The calendar is the only thing that can tell those
//! apart, which is why it is an input here rather than something inferred
//! from the data.

use serde::{Deserialize, Serialize};

use crate::calendar::MarketCalendar;
use crate::candle::Candle;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DataQuality {
    /// False when the series must not be traded on. `reason` says why.
    pub usable: bool,
    pub reason: String,
    /// Bars the calendar expected that are not there.
    pub gaps: usize,
    pub duplicates: usize,
    /// Bars whose OHLC does not bracket itself.
    pub malformed: usize,
    /// Bars that are present but not where the calendar expects one — a feed
    /// serving extended hours, or a venue on a grid this calendar does not
    /// describe. Reported, never a refusal: nothing is missing, something is
    /// merely extra, and the reader should know which.
    #[serde(rename = "offGrid", default)]
    pub off_grid: usize,
    /// How far the newest confirmed bar trails `now`, in bars the calendar
    /// expected. `None` when no clock was supplied.
    #[serde(rename = "barsBehind")]
    pub bars_behind: Option<f64>,
}

impl DataQuality {
    pub fn good() -> Self {
        Self {
            usable: true,
            reason: String::new(),
            gaps: 0,
            duplicates: 0,
            malformed: 0,
            off_grid: 0,
            bars_behind: None,
        }
    }
}

/// Bars the newest confirmed bar may trail the clock before the feed is judged
/// dead rather than quiet. Not one: a bar is only confirmed once the next one
/// opens, so a healthy feed is routinely a whole interval behind. Anything past
/// two means a bar that should exist does not.
pub const MAX_BARS_BEHIND: f64 = 2.5;

/// How many bars may be missing before the series is refused outright.
///
/// Not zero. Exchanges genuinely drop the occasional bar in thin markets, and
/// refusing to trade for the rest of the day over one hole would be its own
/// kind of failure. What must never pass is a series with enough holes that a
/// lookback window no longer means what it says.
pub const MAX_GAP_RATIO: f64 = 0.02;

/// Judge a candle series.
///
/// `now_ms` is the caller's wall clock. The kernel has none by design — it is
/// pure computation — so staleness is only checked when the caller supplies
/// one. Passing `None` from a backtest is correct: historical data is stale
/// by definition and the property is meaningless there.
pub fn inspect(
    candles: &[Candle],
    calendar: MarketCalendar,
    bar_seconds: f64,
    now_ms: Option<i64>,
) -> DataQuality {
    let confirmed: Vec<Candle> = candles.iter().copied().filter(|c| c.is_confirmed()).collect();
    if confirmed.len() < 2 || bar_seconds <= 0.0 {
        return DataQuality::good();
    }

    let mut sorted = confirmed;
    sorted.sort_by_key(|c| c.ts_ms);

    let malformed = sorted.iter().filter(|c| !c.is_sane()).count();

    let mut duplicates = 0usize;
    let mut gaps = 0usize;
    for pair in sorted.windows(2) {
        if pair[1].ts_ms == pair[0].ts_ms {
            duplicates += 1;
            continue;
        }
        gaps += calendar.opens_strictly_between(pair[0].ts_ms, pair[1].ts_ms, bar_seconds);
    }
    // Every bar is judged, the first included: a pre-market bar at the head of
    // the series is exactly the kind of extra the reader should hear about.
    let off_grid = sorted
        .iter()
        .enumerate()
        .filter(|(index, candle)| {
            let previous = index.checked_sub(1).map(|i| sorted[i].ts_ms);
            !calendar.on_grid(previous, candle.ts_ms, bar_seconds)
        })
        .count();

    let bars_behind = now_ms.map(|now| {
        let newest = sorted[sorted.len() - 1].ts_ms;
        calendar.bars_behind(newest, now, bar_seconds)
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
        off_grid,
        bars_behind,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOUR: f64 = 3_600.0;
    const HOUR_MS: i64 = 3_600_000;
    const CRYPTO: MarketCalendar = MarketCalendar::Continuous;
    const STOCKS: MarketCalendar = MarketCalendar::UsEquities;

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

    /// Hourly New York session bars for `sessions` consecutive trading days
    /// starting Monday 2024-07-08, exactly as the calendar expects them.
    fn stock_hours(sessions: usize) -> Vec<Candle> {
        // 2024-07-08 09:30 New York is 13:30 UTC (daylight time).
        let mut ts = 1_720_445_400_000;
        let mut out = Vec::new();
        for _ in 0..sessions {
            let open = ts;
            for k in 0..7 {
                out.push(bar(open + k * HOUR_MS));
            }
            ts = STOCKS.next_open(open + 6 * HOUR_MS, HOUR);
        }
        out
    }

    #[test]
    fn a_clean_series_is_usable() {
        let result = inspect(&contiguous(100), CRYPTO, HOUR, None);
        assert!(result.usable, "{}", result.reason);
        assert_eq!(result.gaps, 0);
        assert_eq!(result.off_grid, 0);
    }

    #[test]
    fn one_missing_bar_in_a_hundred_is_tolerated() {
        // Exchanges do drop the occasional bar in a thin market. Standing down
        // for the rest of the day over one hole is its own kind of failure.
        let mut candles = contiguous(100);
        candles.remove(50);
        let result = inspect(&candles, CRYPTO, HOUR, None);
        assert_eq!(result.gaps, 1);
        assert!(result.usable);
    }

    #[test]
    fn a_series_full_of_holes_is_refused() {
        let candles: Vec<Candle> = (0..50).map(|i| bar(i * HOUR_MS * 3)).collect();
        let result = inspect(&candles, CRYPTO, HOUR, None);
        assert!(!result.usable);
        assert!(result.reason.contains("缺失"));
    }

    #[test]
    fn a_stock_series_with_nights_and_weekends_has_no_holes() {
        // Two weeks of hourly bars, Independence Day-free, clean.
        let candles = stock_hours(10);
        assert_eq!(candles.len(), 70);
        let result = inspect(&candles, STOCKS, HOUR, None);
        assert!(result.usable, "{}", result.reason);
        assert_eq!(result.gaps, 0, "nights and weekends are not gaps on a stock calendar");
        assert_eq!(result.off_grid, 0);

        // The same bars judged as if the market never closed: refused. This is
        // what every stock series looked like before the calendar existed.
        let as_crypto = inspect(&candles, CRYPTO, HOUR, None);
        assert!(!as_crypto.usable);
        assert!(as_crypto.gaps > 100);
    }

    #[test]
    fn a_missing_session_is_a_gap_on_a_stock_calendar_too() {
        let mut candles = stock_hours(10);
        // Drop Wednesday of the first week entirely: seven bars.
        candles.drain(14..21);
        let result = inspect(&candles, STOCKS, HOUR, None);
        assert_eq!(result.gaps, 7);
        assert!(!result.usable, "7 of 70 is far past the tolerance");
    }

    #[test]
    fn extended_hours_bars_are_reported_not_refused() {
        let mut candles = stock_hours(5);
        // A 08:30 pre-market bar on the first day, an hour before the open.
        let premarket = bar(candles[0].ts_ms - HOUR_MS);
        candles.insert(0, premarket);
        let result = inspect(&candles, STOCKS, HOUR, None);
        assert!(result.usable, "{}", result.reason);
        assert_eq!(result.gaps, 0);
        assert_eq!(result.off_grid, 1);
    }

    #[test]
    fn a_stale_feed_is_refused() {
        // The newest bar is 10 hours old on an hourly strategy: the feed is
        // not quiet, it is dead.
        let candles = contiguous(100);
        let now = 99 * HOUR_MS + 10 * HOUR_MS;
        let result = inspect(&candles, CRYPTO, HOUR, Some(now));
        assert!(!result.usable);
        assert!(result.reason.contains("落后"));
    }

    #[test]
    fn being_one_bar_behind_is_normal() {
        // A bar is only confirmed once the next one opens, so a healthy feed is
        // routinely a whole interval behind. Refusing that would refuse always.
        let candles = contiguous(100);
        let now = 99 * HOUR_MS + HOUR_MS + 60_000;
        assert!(inspect(&candles, CRYPTO, HOUR, Some(now)).usable);
    }

    #[test]
    fn a_stock_feed_is_not_stale_over_the_weekend() {
        let candles = stock_hours(5); // Monday to Friday, last bar Friday 15:30
        let friday_close = candles[candles.len() - 1].ts_ms + HOUR_MS / 2;
        // Saturday noon: no bar was due, so nothing is behind.
        let saturday = friday_close + 20 * HOUR_MS;
        let result = inspect(&candles, STOCKS, HOUR, Some(saturday));
        assert!(result.usable, "{}", result.reason);
        assert_eq!(result.bars_behind, Some(0.0));
        // Monday 12:00: three bars were due and none came.
        let monday_open = STOCKS.next_open(candles[candles.len() - 1].ts_ms, HOUR);
        let monday_noon = monday_open + 2 * HOUR_MS + HOUR_MS / 2;
        let dead = inspect(&candles, STOCKS, HOUR, Some(monday_noon));
        assert!(!dead.usable);
        assert!(dead.reason.contains("落后"));
    }

    #[test]
    fn a_duplicate_timestamp_is_refused() {
        let mut candles = contiguous(20);
        candles.push(bar(10 * HOUR_MS));
        let result = inspect(&candles, CRYPTO, HOUR, None);
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
        let result = inspect(&candles, CRYPTO, HOUR, None);
        assert!(!result.usable);
        assert!(result.reason.contains("不自洽"));
    }

    #[test]
    fn a_backtest_passing_no_clock_is_never_stale() {
        // Historical data is stale by definition; the property is meaningless
        // there and must not block a backtest.
        let candles = contiguous(100);
        let result = inspect(&candles, CRYPTO, HOUR, None);
        assert!(result.usable);
        assert!(result.bars_behind.is_none());
    }

    #[test]
    fn too_short_a_series_is_not_judged() {
        // Warm-up handles "not enough data"; this module only judges data it
        // actually has.
        assert!(inspect(&contiguous(1), CRYPTO, HOUR, None).usable);
        assert!(inspect(&[], CRYPTO, HOUR, None).usable);
    }

    #[test]
    fn unconfirmed_bars_do_not_count_as_gaps() {
        // The forming bar is filtered out everywhere else too; if it counted
        // here the newest data would always look like a hole.
        let mut candles = contiguous(20);
        candles.push(Candle { confirmed: 0, ..bar(50 * HOUR_MS) });
        assert!(inspect(&candles, CRYPTO, HOUR, None).usable);
    }

    #[test]
    fn the_report_carries_the_off_grid_count_on_the_wire() {
        let json = serde_json::to_string(&DataQuality::good()).unwrap();
        assert!(json.contains("\"offGrid\":0"), "{json}");
        // And a report written before the field existed still reads.
        let legacy = r#"{"usable":true,"reason":"","gaps":0,"duplicates":0,"malformed":0,"barsBehind":null}"#;
        let parsed: DataQuality = serde_json::from_str(legacy).unwrap();
        assert_eq!(parsed.off_grid, 0);
    }
}
