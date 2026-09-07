//! Market calendars: when a bar is expected to exist.
//!
//! Everything in the kernel that converts between *bars* and *time* goes
//! through here — annualisation, the gap detector, the staleness check, the
//! day boundary of the daily-loss breaker, and the close an observation must
//! precede to be usable. A crypto exchange trades every hour of every day, so
//! for it all of those reduce to arithmetic on `bar_seconds`. A stock exchange
//! does not, and a kernel that assumed it did would refuse every stock series
//! as full of holes, annualise its Sharpe with √(365/252) of air in it, and
//! reset the daily breaker at midnight UTC — 20:00 in New York, in the middle
//! of nothing.
//!
//! There is exactly one definition per venue and nothing is inferred from the
//! data: a calendar read off which bars happen to be present would take every
//! outage for a holiday.

use chrono::{Datelike, Duration, LocalResult, NaiveDate, NaiveDateTime, TimeZone, Weekday};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};

pub const DAY_MS: i64 = 86_400_000;
const DAY_SECONDS: f64 = 86_400.0;
const WEEK_SECONDS: f64 = 7.0 * DAY_SECONDS;
/// Calendar days in a year, for bars that are measured in calendar time.
const CALENDAR_DAYS_PER_YEAR: f64 = 365.25;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MarketCalendar {
    /// Trades every hour of every day. Crypto.
    Continuous,
    /// The NYSE / Nasdaq regular session: 09:30–16:00 America/New_York, the
    /// exchange holiday rules, and 13:00 early closes.
    UsEquities,
}

impl MarketCalendar {
    /// Trading sessions in a year. The annualisation constant for daily bars.
    pub fn sessions_per_year(self) -> f64 {
        match self {
            Self::Continuous => CALENDAR_DAYS_PER_YEAR,
            Self::UsEquities => us::SESSIONS_PER_YEAR,
        }
    }

    /// Bars in a year, for annualising Sharpe, volatility and returns.
    ///
    /// Intraday bars are counted per session, daily bars per session, and
    /// anything a week or longer in calendar time — a weekly bar spans seven
    /// calendar days whatever the exchange does on five of them.
    pub fn bars_per_year(self, bar_seconds: f64) -> f64 {
        match self {
            Self::Continuous => CALENDAR_DAYS_PER_YEAR * DAY_SECONDS / bar_seconds,
            Self::UsEquities => {
                if bar_seconds >= WEEK_SECONDS {
                    CALENDAR_DAYS_PER_YEAR * DAY_SECONDS / bar_seconds
                } else if bar_seconds >= DAY_SECONDS {
                    us::SESSIONS_PER_YEAR
                } else {
                    us::SESSIONS_PER_YEAR * (us::SESSION_SECONDS / bar_seconds).ceil()
                }
            }
        }
    }

    /// The trading day a timestamp belongs to, as a day index.
    ///
    /// This is the boundary the daily-loss breaker resets on. For a continuous
    /// market it is the UTC day; for an exchange it is the local date of the
    /// session, so two bars of one New York session that straddle midnight UTC
    /// are the same day and not two.
    pub fn session_key(self, ts_ms: i64) -> i64 {
        match self {
            Self::Continuous => ts_ms.div_euclid(DAY_MS),
            Self::UsEquities => us::day_index(us::local(ts_ms).date()),
        }
    }

    /// Whether the market is trading at this instant.
    pub fn is_open(self, ts_ms: i64) -> bool {
        match self {
            Self::Continuous => true,
            Self::UsEquities => us::session(us::local(ts_ms).date())
                .is_some_and(|(open, close)| ts_ms >= open && ts_ms < close),
        }
    }

    /// Open time of the bar that follows the bar opening at `ts_ms`.
    pub fn next_open(self, ts_ms: i64, bar_seconds: f64) -> i64 {
        let bar_ms = bar_millis(bar_seconds);
        match self {
            Self::Continuous => ts_ms + bar_ms,
            Self::UsEquities => us::next_open(ts_ms, bar_ms, bar_seconds),
        }
    }

    /// Close of the bar opening at `ts_ms` — the instant a decision on that bar
    /// is taken, and therefore the instant an observation must precede to be
    /// known to it.
    pub fn bar_close(self, ts_ms: i64, bar_seconds: f64) -> i64 {
        let bar_ms = bar_millis(bar_seconds);
        match self {
            Self::Continuous => ts_ms + bar_ms,
            Self::UsEquities => us::bar_close(ts_ms, bar_ms, bar_seconds),
        }
    }

    /// Expected bar opens strictly after `from_ms` and up to `to_ms` inclusive.
    ///
    /// This is "bars between": how many bars a position opened at `from_ms`
    /// has been held by the bar opening at `to_ms`, or how many a cooldown
    /// has waited. `from_ms` is any instant — a fill time, a clock reading —
    /// while `to_ms` is a bar's own open, which every caller has in hand.
    ///
    /// On a continuous market the grid is wherever the venue anchors it (OKX
    /// aligns daily bars to UTC+8, not to the epoch), so the count is taken
    /// backwards from `to_ms`: the opens at `to_ms`, one bar earlier, and so
    /// on while still after `from_ms`. Dividing the raw interval instead
    /// would call a position entered at 10:05 and judged at the 15:00 bar
    /// four bars old — 4.9 rounded down — when it has seen five opens, and
    /// every bar-counted rule would then sit one bar off the backtest.
    pub fn opens_between(self, from_ms: i64, to_ms: i64, bar_seconds: f64) -> usize {
        if to_ms <= from_ms {
            return 0;
        }
        match self {
            Self::Continuous => {
                let bar_ms = bar_millis(bar_seconds);
                ((to_ms - from_ms + bar_ms - 1) / bar_ms) as usize
            }
            Self::UsEquities => {
                let mut count = 0;
                let mut t = self.next_open(from_ms, bar_seconds);
                while t <= to_ms {
                    count += 1;
                    t = self.next_open(t, bar_seconds);
                }
                count
            }
        }
    }

    /// Expected opens strictly between two observed bars — the bars that
    /// should be there and are not.
    pub fn opens_strictly_between(self, a_ms: i64, b_ms: i64, bar_seconds: f64) -> usize {
        if b_ms <= a_ms {
            return 0;
        }
        match self {
            Self::Continuous => {
                let bar_ms = bar_millis(bar_seconds);
                ((b_ms - a_ms) / bar_ms).saturating_sub(1) as usize
            }
            Self::UsEquities => {
                let mut count = 0;
                let mut t = self.next_open(a_ms, bar_seconds);
                while t < b_ms {
                    count += 1;
                    t = self.next_open(t, bar_seconds);
                }
                count
            }
        }
    }

    /// Whether a bar opening at `ts_ms` is one the calendar expects.
    ///
    /// Reported rather than acted on: a bar that is not where the calendar
    /// expects one is usually a feed serving extended hours, which is worth
    /// knowing and not worth refusing. On a continuous market the grid is
    /// wherever the venue anchors it — OKX aligns daily bars to UTC+8, not to
    /// the epoch — so a bar there is judged against its predecessor only.
    pub fn on_grid(self, previous_ms: Option<i64>, ts_ms: i64, bar_seconds: f64) -> bool {
        let bar_ms = bar_millis(bar_seconds);
        match self {
            Self::Continuous => previous_ms.map_or(true, |p| (ts_ms - p) % bar_ms == 0),
            Self::UsEquities => us::on_grid(ts_ms, bar_ms, bar_seconds),
        }
    }

    /// How many bars the newest confirmed bar trails the clock.
    ///
    /// Counted in bars the calendar expected, not in elapsed time: a stock
    /// series whose last bar is the 15:30 one is not "eighteen bars behind" at
    /// 09:00 the next morning, it is exactly where it should be. Inside a
    /// session the fraction of the current bar elapsed is added, which is what
    /// makes this reduce to `elapsed / bar` on a continuous market.
    pub fn bars_behind(self, newest_ms: i64, now_ms: i64, bar_seconds: f64) -> f64 {
        let bar_ms = bar_millis(bar_seconds);
        match self {
            Self::Continuous => (now_ms - newest_ms) as f64 / bar_ms as f64,
            Self::UsEquities => {
                let mut count = 0usize;
                let mut last = newest_ms;
                let mut t = self.next_open(newest_ms, bar_seconds);
                while t <= now_ms {
                    count += 1;
                    last = t;
                    t = self.next_open(t, bar_seconds);
                }
                let close = self.bar_close(last, bar_seconds);
                let fraction = if now_ms >= last && now_ms < close {
                    (now_ms - last) as f64 / bar_ms as f64
                } else {
                    0.0
                };
                count as f64 + fraction
            }
        }
    }
}

fn bar_millis(bar_seconds: f64) -> i64 {
    // A zero or negative bar would loop forever below; the strategy layer
    // never produces one, and a caller that does gets an hour rather than a
    // hang, matching `strategy::bar_seconds`' own fallback.
    if bar_seconds > 0.0 {
        (bar_seconds * 1_000.0) as i64
    } else {
        3_600_000
    }
}

/// The New York session and its holidays.
///
/// Rules, not a table: a table has to be extended every December and is
/// silently wrong the year somebody forgets. The only things listed by date are
/// the ad-hoc closures — hurricanes, funerals, September 2001 — which no rule
/// can produce.
mod us {
    use super::*;

    pub const SESSIONS_PER_YEAR: f64 = 252.0;
    /// 09:30–16:00.
    pub const SESSION_SECONDS: f64 = 23_400.0;
    const TZ: Tz = chrono_tz::America::New_York;

    /// Days the exchange closed outside any rule.
    const AD_HOC_CLOSURES: &[(i32, u32, u32)] = &[
        (1985, 9, 27),  // Hurricane Gloria
        (1994, 4, 27),  // Nixon funeral
        (2001, 9, 11),  // September 11 attacks, through the Friday
        (2001, 9, 12),
        (2001, 9, 13),
        (2001, 9, 14),
        (2004, 6, 11),  // Reagan funeral
        (2007, 1, 2),   // Ford funeral
        (2012, 10, 29), // Hurricane Sandy
        (2012, 10, 30),
        (2018, 12, 5),  // G. H. W. Bush funeral
        (2025, 1, 9),   // Carter funeral
    ];

    pub fn local(ts_ms: i64) -> NaiveDateTime {
        match TZ.timestamp_millis_opt(ts_ms) {
            LocalResult::Single(d) => d.naive_local(),
            // An instant always maps to exactly one local time; the other arms
            // are unreachable for a UTC timestamp, but a fallback beats a panic
            // inside a trading process.
            LocalResult::Ambiguous(d, _) => d.naive_local(),
            LocalResult::None => chrono::DateTime::from_timestamp_millis(ts_ms)
                .map(|d| d.naive_utc())
                .unwrap_or_default(),
        }
    }

    pub fn to_ms(local: NaiveDateTime) -> i64 {
        match TZ.from_local_datetime(&local) {
            LocalResult::Single(d) => d.timestamp_millis(),
            // The repeated hour when clocks fall back: take the first pass.
            LocalResult::Ambiguous(first, _) => first.timestamp_millis(),
            // The skipped hour when clocks spring forward. Neither ever
            // touches a market hour, so the exact choice is immaterial; move
            // forward an hour so the result is at least a real instant.
            LocalResult::None => TZ
                .from_local_datetime(&(local + Duration::hours(1)))
                .earliest()
                .map(|d| d.timestamp_millis())
                .unwrap_or_else(|| local.and_utc().timestamp_millis()),
        }
    }

    pub fn day_index(date: NaiveDate) -> i64 {
        let epoch = NaiveDate::from_ymd_opt(1970, 1, 1).expect("valid date");
        date.signed_duration_since(epoch).num_days()
    }

    /// Open and close of the session on `date`, or `None` when the market is
    /// closed that day.
    pub fn session(date: NaiveDate) -> Option<(i64, i64)> {
        if !is_trading_day(date) {
            return None;
        }
        let open = to_ms(date.and_hms_opt(9, 30, 0)?);
        let (hour, minute) = if early_close(date) { (13, 0) } else { (16, 0) };
        let close = to_ms(date.and_hms_opt(hour, minute, 0)?);
        Some((open, close))
    }

    /// The first trading day strictly after `date`.
    pub fn next_session_date(date: NaiveDate) -> NaiveDate {
        let mut candidate = date.succ_opt().expect("date within range");
        while !is_trading_day(candidate) {
            candidate = candidate.succ_opt().expect("date within range");
        }
        candidate
    }

    pub fn next_open(ts_ms: i64, bar_ms: i64, bar_seconds: f64) -> i64 {
        if bar_seconds >= WEEK_SECONDS {
            return ts_ms + bar_ms;
        }
        let local = local(ts_ms);
        let date = local.date();
        if bar_seconds >= DAY_SECONDS {
            // Daily bars carry whatever clock time the feed stamps them with;
            // the next one is the next session at that same clock time.
            return to_ms(next_session_date(date).and_time(local.time()));
        }
        match session(date) {
            Some((open, _)) if ts_ms < open => open,
            Some((_, close)) if ts_ms < close && ts_ms + bar_ms < close => ts_ms + bar_ms,
            _ => session(next_session_date(date))
                .map(|(open, _)| open)
                .expect("the next session date is a trading day by construction"),
        }
    }

    pub fn bar_close(ts_ms: i64, bar_ms: i64, bar_seconds: f64) -> i64 {
        if bar_seconds >= WEEK_SECONDS {
            return ts_ms + bar_ms;
        }
        let date = local(ts_ms).date();
        if bar_seconds >= DAY_SECONDS {
            return session(date).map(|(_, close)| close).unwrap_or(ts_ms + bar_ms);
        }
        match session(date) {
            Some((open, close)) if ts_ms >= open && ts_ms < close => (ts_ms + bar_ms).min(close),
            _ => ts_ms + bar_ms,
        }
    }

    pub fn is_trading_day(date: NaiveDate) -> bool {
        !matches!(date.weekday(), Weekday::Sat | Weekday::Sun) && !is_holiday(date)
    }

    /// A bar the session grid contains: inside a session and a whole number
    /// of bars from its open, or — for daily bars, which carry whatever
    /// clock time the feed stamps them with — simply on a trading day.
    pub fn on_grid(ts_ms: i64, bar_ms: i64, bar_seconds: f64) -> bool {
        if bar_seconds >= WEEK_SECONDS {
            return true;
        }
        let date = local(ts_ms).date();
        if bar_seconds >= DAY_SECONDS {
            return is_trading_day(date);
        }
        match session(date) {
            Some((open, close)) => ts_ms >= open && ts_ms < close && (ts_ms - open) % bar_ms == 0,
            None => false,
        }
    }

    /// 13:00 close: the day after Thanksgiving, and Christmas Eve or the eve of
    /// Independence Day when they fall on a weekday that is itself open.
    pub fn early_close(date: NaiveDate) -> bool {
        let year = date.year();
        let day_after_thanksgiving = nth_weekday(year, 11, Weekday::Thu, 4) + Duration::days(1);
        if date == day_after_thanksgiving {
            return true;
        }
        let eve = (date.month(), date.day()) == (7, 3) || (date.month(), date.day()) == (12, 24);
        eve && matches!(
            date.weekday(),
            Weekday::Mon | Weekday::Tue | Weekday::Wed | Weekday::Thu
        )
    }

    pub fn is_holiday(date: NaiveDate) -> bool {
        let year = date.year();
        let ymd = |month: u32, day: u32| NaiveDate::from_ymd_opt(year, month, day);
        let triple = (year, date.month(), date.day());
        if AD_HOC_CLOSURES.contains(&triple) {
            return true;
        }

        // New Year's Day. Observed on the Monday when it falls on a Sunday;
        // *not* observed at all when it falls on a Saturday — the market is
        // open on the preceding Friday.
        if let Some(new_year) = ymd(1, 1) {
            let observed = match new_year.weekday() {
                Weekday::Sun => new_year + Duration::days(1),
                _ => new_year,
            };
            if new_year.weekday() != Weekday::Sat && date == observed {
                return true;
            }
        }
        if year >= 1998 && date == nth_weekday(year, 1, Weekday::Mon, 3) {
            return true; // Martin Luther King Jr. Day
        }
        if date == nth_weekday(year, 2, Weekday::Mon, 3) {
            return true; // Washington's Birthday
        }
        if date == easter(year) - Duration::days(2) {
            return true; // Good Friday
        }
        if date == last_weekday(year, 5, Weekday::Mon) {
            return true; // Memorial Day
        }
        if year >= 2022 && ymd(6, 19).map(observed) == Some(date) {
            return true; // Juneteenth
        }
        if ymd(7, 4).map(observed) == Some(date) {
            return true; // Independence Day
        }
        if date == nth_weekday(year, 9, Weekday::Mon, 1) {
            return true; // Labor Day
        }
        if date == nth_weekday(year, 11, Weekday::Thu, 4) {
            return true; // Thanksgiving
        }
        if ymd(12, 25).map(observed) == Some(date) {
            return true; // Christmas
        }
        false
    }

    /// Saturday holidays are taken on the Friday, Sunday ones on the Monday.
    fn observed(date: NaiveDate) -> NaiveDate {
        match date.weekday() {
            Weekday::Sat => date - Duration::days(1),
            Weekday::Sun => date + Duration::days(1),
            _ => date,
        }
    }

    fn nth_weekday(year: i32, month: u32, weekday: Weekday, n: u32) -> NaiveDate {
        let first = NaiveDate::from_ymd_opt(year, month, 1).expect("valid month");
        let offset = (weekday.num_days_from_monday() + 7 - first.weekday().num_days_from_monday()) % 7;
        first + Duration::days(i64::from(offset) + 7 * i64::from(n - 1))
    }

    fn last_weekday(year: i32, month: u32, weekday: Weekday) -> NaiveDate {
        let next_month = if month == 12 {
            NaiveDate::from_ymd_opt(year + 1, 1, 1)
        } else {
            NaiveDate::from_ymd_opt(year, month + 1, 1)
        };
        let mut candidate = next_month.expect("valid month") - Duration::days(1);
        while candidate.weekday() != weekday {
            candidate -= Duration::days(1);
        }
        candidate
    }

    /// Gregorian Easter Sunday (Meeus / Jones / Butcher).
    fn easter(year: i32) -> NaiveDate {
        let a = year % 19;
        let b = year / 100;
        let c = year % 100;
        let d = b / 4;
        let e = b % 4;
        let f = (b + 8) / 25;
        let g = (b - f + 1) / 3;
        let h = (19 * a + b - d - g + 15) % 30;
        let i = c / 4;
        let k = c % 4;
        let l = (32 + 2 * e + 2 * i - h - k) % 7;
        let m = (a + 11 * h + 22 * l) / 451;
        let month = (h + l - 7 * m + 114) / 31;
        let day = (h + l - 7 * m + 114) % 31 + 1;
        NaiveDate::from_ymd_opt(year, month as u32, day as u32).expect("Easter is a real date")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOUR: f64 = 3_600.0;
    const HALF_HOUR: f64 = 1_800.0;
    const DAY: f64 = 86_400.0;

    fn date(y: i32, m: u32, d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, d).unwrap()
    }

    /// Milliseconds of a New York wall-clock time.
    fn ny(y: i32, m: u32, d: u32, hour: u32, minute: u32) -> i64 {
        us::to_ms(date(y, m, d).and_hms_opt(hour, minute, 0).unwrap())
    }

    fn utc(y: i32, m: u32, d: u32, hour: u32, minute: u32) -> i64 {
        date(y, m, d).and_hms_opt(hour, minute, 0).unwrap().and_utc().timestamp_millis()
    }

    // MARK: Holidays

    #[test]
    fn the_published_2024_calendar_is_reproduced_by_the_rules() {
        let closed = [
            (1, 1), (1, 15), (2, 19), (3, 29), (5, 27), (6, 19), (7, 4), (9, 2), (11, 28), (12, 25),
        ];
        for (m, d) in closed {
            assert!(!us::is_trading_day(date(2024, m, d)), "2024-{m:02}-{d:02} should be closed");
        }
        for (m, d) in [(7, 3), (11, 29), (12, 24)] {
            assert!(us::is_trading_day(date(2024, m, d)));
            assert!(us::early_close(date(2024, m, d)), "2024-{m:02}-{d:02} closes at 13:00");
        }
        // Ordinary days around them are open and full length.
        assert!(us::is_trading_day(date(2024, 7, 5)));
        assert!(!us::early_close(date(2024, 7, 5)));
    }

    #[test]
    fn the_published_2025_and_2026_calendars_are_reproduced() {
        for (m, d) in [(1, 1), (1, 9), (1, 20), (2, 17), (4, 18), (5, 26), (6, 19), (7, 4), (9, 1), (11, 27), (12, 25)] {
            assert!(!us::is_trading_day(date(2025, m, d)), "2025-{m:02}-{d:02}");
        }
        for (m, d) in [(7, 3), (11, 28), (12, 24)] {
            assert!(us::early_close(date(2025, m, d)), "2025-{m:02}-{d:02}");
        }
        for (m, d) in [(1, 1), (1, 19), (2, 16), (4, 3), (5, 25), (6, 19), (7, 3), (9, 7), (11, 26), (12, 25)] {
            assert!(!us::is_trading_day(date(2026, m, d)), "2026-{m:02}-{d:02}");
        }
        // Independence Day 2026 is a Saturday, taken on the Friday — so there
        // is no eve to close early on.
        assert!(us::is_trading_day(date(2026, 7, 2)));
        assert!(!us::early_close(date(2026, 7, 2)));
        for (m, d) in [(11, 27), (12, 24)] {
            assert!(us::early_close(date(2026, m, d)), "2026-{m:02}-{d:02}");
        }
    }

    #[test]
    fn weekend_observance_follows_the_exchange_not_the_federal_rule() {
        // 2022-01-01 was a Saturday: the exchange did not close on the Friday.
        assert!(us::is_trading_day(date(2021, 12, 31)));
        // 2023-01-01 was a Sunday: closed on the Monday.
        assert!(!us::is_trading_day(date(2023, 1, 2)));
        // Christmas 2021 was a Saturday: closed on the Friday.
        assert!(!us::is_trading_day(date(2021, 12, 24)));
        // Juneteenth 2022 was a Sunday: closed on the Monday.
        assert!(!us::is_trading_day(date(2022, 6, 20)));
    }

    #[test]
    fn holidays_that_did_not_yet_exist_are_not_backdated() {
        // Martin Luther King Jr. Day from 1998; Juneteenth from 2022.
        assert!(us::is_trading_day(date(1997, 1, 20)));
        assert!(!us::is_trading_day(date(1998, 1, 19)));
        assert!(us::is_trading_day(date(2021, 6, 18)));
        // And a closure no rule produces.
        assert!(!us::is_trading_day(date(2001, 9, 12)));
        assert!(us::is_trading_day(date(2001, 9, 17)));
    }

    // MARK: Time zone

    #[test]
    fn the_open_moves_with_daylight_saving() {
        // Clocks sprang forward on 2024-03-10 and fell back on 2024-11-03.
        assert_eq!(ny(2024, 3, 8, 9, 30), utc(2024, 3, 8, 14, 30));
        assert_eq!(ny(2024, 3, 11, 9, 30), utc(2024, 3, 11, 13, 30));
        assert_eq!(ny(2024, 11, 4, 9, 30), utc(2024, 11, 4, 14, 30));
        // 1990 used the old April rule: still standard time on the 4th of March.
        assert_eq!(ny(1990, 3, 5, 9, 30), utc(1990, 3, 5, 14, 30));
        assert_eq!(ny(1990, 4, 2, 9, 30), utc(1990, 4, 2, 13, 30));
    }

    #[test]
    fn the_session_key_is_the_local_date_not_the_utc_one() {
        // 23:30 New York on the 11th is 03:30 UTC on the 12th.
        let late = ny(2024, 3, 11, 23, 30);
        let morning = ny(2024, 3, 11, 9, 30);
        let cal = MarketCalendar::UsEquities;
        assert_eq!(cal.session_key(late), cal.session_key(morning));
        assert_ne!(MarketCalendar::Continuous.session_key(late),
                   MarketCalendar::Continuous.session_key(morning));
        assert_eq!(MarketCalendar::Continuous.session_key(utc(2024, 3, 12, 0, 0)),
                   MarketCalendar::Continuous.session_key(utc(2024, 3, 12, 23, 59)));
    }

    // MARK: Annualisation

    #[test]
    fn bars_per_year_counts_sessions_not_calendar_days() {
        let us = MarketCalendar::UsEquities;
        assert_eq!(us.bars_per_year(DAY), 252.0);
        assert_eq!(us.bars_per_year(HALF_HOUR), 252.0 * 13.0);
        assert_eq!(us.bars_per_year(HOUR), 252.0 * 7.0, "the 15:30 bar is a short seventh");
        assert_eq!(us.bars_per_year(60.0), 252.0 * 390.0);
        assert!((us.bars_per_year(7.0 * DAY) - 52.18).abs() < 0.01);

        let crypto = MarketCalendar::Continuous;
        assert_eq!(crypto.bars_per_year(DAY), 365.25);
        assert_eq!(crypto.bars_per_year(HOUR), 365.25 * 24.0);
    }

    // MARK: Expected bars

    #[test]
    fn hourly_bars_step_within_the_session_and_jump_the_night() {
        let cal = MarketCalendar::UsEquities;
        // Friday 2024-03-08.
        assert_eq!(cal.next_open(ny(2024, 3, 8, 9, 30), HOUR), ny(2024, 3, 8, 10, 30));
        assert_eq!(cal.next_open(ny(2024, 3, 8, 14, 30), HOUR), ny(2024, 3, 8, 15, 30));
        // The 15:30 bar is the last; the next is Monday's open, across the
        // weekend *and* the clock change.
        assert_eq!(cal.next_open(ny(2024, 3, 8, 15, 30), HOUR), ny(2024, 3, 11, 9, 30));
        // Pre-market and after-hours timestamps resolve to the next open.
        assert_eq!(cal.next_open(ny(2024, 3, 8, 8, 0), HOUR), ny(2024, 3, 8, 9, 30));
        assert_eq!(cal.next_open(ny(2024, 3, 8, 17, 0), HOUR), ny(2024, 3, 11, 9, 30));
    }

    #[test]
    fn an_early_close_ends_the_session_at_one() {
        let cal = MarketCalendar::UsEquities;
        // 2024-11-29, the day after Thanksgiving.
        assert_eq!(cal.next_open(ny(2024, 11, 29, 12, 30), HALF_HOUR), ny(2024, 12, 2, 9, 30));
        assert_eq!(cal.bar_close(ny(2024, 11, 29, 12, 30), HOUR), ny(2024, 11, 29, 13, 0));
        assert_eq!(cal.bar_close(ny(2024, 11, 27, 15, 30), HOUR), ny(2024, 11, 27, 16, 0));
    }

    #[test]
    fn daily_bars_step_to_the_next_session_at_the_same_clock_time() {
        let cal = MarketCalendar::UsEquities;
        // A feed stamping daily bars at midnight local; Friday → Monday.
        assert_eq!(cal.next_open(ny(2024, 7, 5, 0, 0), DAY), ny(2024, 7, 8, 0, 0));
        // Wednesday 2024-07-03 → Friday, skipping Independence Day.
        assert_eq!(cal.next_open(ny(2024, 7, 3, 0, 0), DAY), ny(2024, 7, 5, 0, 0));
        // And a daily bar's decision is taken at that day's close.
        assert_eq!(cal.bar_close(ny(2024, 7, 3, 0, 0), DAY), ny(2024, 7, 3, 13, 0));
        assert_eq!(cal.bar_close(ny(2024, 7, 5, 0, 0), DAY), ny(2024, 7, 5, 16, 0));
    }

    #[test]
    fn a_complete_stock_series_has_no_gaps() {
        let cal = MarketCalendar::UsEquities;
        // Thursday 2024-07-03 (early close) through Monday 2024-07-08, hourly.
        let opens = [
            ny(2024, 7, 3, 9, 30), ny(2024, 7, 3, 10, 30), ny(2024, 7, 3, 11, 30),
            ny(2024, 7, 3, 12, 30),
            ny(2024, 7, 5, 9, 30), ny(2024, 7, 5, 10, 30), ny(2024, 7, 5, 11, 30),
            ny(2024, 7, 5, 12, 30), ny(2024, 7, 5, 13, 30), ny(2024, 7, 5, 14, 30),
            ny(2024, 7, 5, 15, 30),
            ny(2024, 7, 8, 9, 30),
        ];
        for pair in opens.windows(2) {
            assert_eq!(cal.opens_strictly_between(pair[0], pair[1], HOUR), 0,
                       "{} → {}", pair[0], pair[1]);
        }
        for open in opens {
            assert!(cal.on_grid(None, open, HOUR));
        }
        // Skipping the whole of Friday is seven missing bars.
        assert_eq!(cal.opens_strictly_between(ny(2024, 7, 3, 12, 30), ny(2024, 7, 8, 9, 30), HOUR), 7);
        // A bar off the grid is flagged, and is not a hole.
        assert!(!cal.on_grid(None, ny(2024, 7, 5, 9, 45), HOUR));
        assert!(!cal.on_grid(None, ny(2024, 7, 5, 8, 30), HOUR), "pre-market");
        assert!(!cal.on_grid(None, ny(2024, 7, 6, 9, 30), HOUR), "Saturday");
        assert_eq!(cal.opens_strictly_between(ny(2024, 7, 5, 9, 30), ny(2024, 7, 5, 9, 45), HOUR), 0);
        // Daily bars are on the grid on any trading day, whatever their clock time.
        assert!(cal.on_grid(None, ny(2024, 7, 5, 0, 0), DAY));
        assert!(cal.on_grid(None, ny(2024, 7, 5, 6, 0), DAY));
        assert!(!cal.on_grid(None, ny(2024, 7, 4, 0, 0), DAY));
    }

    #[test]
    fn a_continuous_series_counts_gaps_arithmetically() {
        let cal = MarketCalendar::Continuous;
        let t0 = utc(2024, 1, 1, 0, 0);
        assert_eq!(cal.opens_strictly_between(t0, t0 + 3_600_000, HOUR), 0);
        assert_eq!(cal.opens_strictly_between(t0, t0 + 3 * 3_600_000, HOUR), 2);
        assert_eq!(cal.opens_strictly_between(t0, t0 + 5_400_000, HOUR), 0);
        assert_eq!(cal.opens_between(t0, t0 + 3 * 3_600_000, HOUR), 3);
        // An entry five minutes into a bar, judged at the bar five hours on,
        // has seen five opens; the raw interval divides to 4.9.
        assert_eq!(cal.opens_between(t0 + 5 * 60_000, t0 + 5 * 3_600_000, HOUR), 5);
        assert_eq!(cal.opens_between(t0 + 5 * 3_600_000, t0 + 5 * 3_600_000, HOUR), 0);
        assert_eq!(cal.opens_between(t0 + 5 * 3_600_000, t0, HOUR), 0);
        // Alignment is judged against the predecessor, never the epoch: OKX
        // anchors daily bars to UTC+8.
        assert!(cal.on_grid(None, t0 + 1234, HOUR));
        assert!(cal.on_grid(Some(t0), t0 + 3_600_000, HOUR));
        assert!(!cal.on_grid(Some(t0), t0 + 5_400_000, HOUR));
    }

    // MARK: Staleness

    #[test]
    fn a_feed_is_not_stale_overnight() {
        let cal = MarketCalendar::UsEquities;
        let newest = ny(2024, 7, 5, 15, 30);
        // Friday evening, Saturday, Sunday, Monday before the open: no bar was
        // due, so nothing is behind.
        for now in [ny(2024, 7, 5, 18, 0), ny(2024, 7, 6, 12, 0), ny(2024, 7, 8, 9, 0)] {
            assert_eq!(cal.bars_behind(newest, now, HOUR), 0.0);
        }
        // One minute into Monday's first bar: one bar behind and a sliver.
        let behind = cal.bars_behind(newest, ny(2024, 7, 8, 9, 31), HOUR);
        assert!((behind - (1.0 + 1.0 / 60.0)).abs() < 1e-9, "{behind}");
        // Two hours into Monday with nothing arrived: dead feed.
        assert!(cal.bars_behind(newest, ny(2024, 7, 8, 11, 31), HOUR) > 2.5);
    }

    #[test]
    fn continuous_staleness_is_elapsed_over_bar() {
        let cal = MarketCalendar::Continuous;
        let t0 = utc(2024, 1, 1, 0, 0);
        assert!((cal.bars_behind(t0, t0 + 5_400_000, HOUR) - 1.5).abs() < 1e-9);
    }

    #[test]
    fn is_open_respects_the_session() {
        let cal = MarketCalendar::UsEquities;
        assert!(cal.is_open(ny(2024, 7, 5, 9, 30)));
        assert!(cal.is_open(ny(2024, 7, 5, 15, 59)));
        assert!(!cal.is_open(ny(2024, 7, 5, 16, 0)));
        assert!(!cal.is_open(ny(2024, 7, 4, 12, 0)));
        assert!(!cal.is_open(ny(2024, 7, 6, 12, 0)));
        assert!(MarketCalendar::Continuous.is_open(ny(2024, 7, 6, 12, 0)));
    }

    #[test]
    fn the_calendar_names_round_trip_through_json() {
        let json = serde_json::to_string(&MarketCalendar::UsEquities).unwrap();
        assert_eq!(json, "\"usEquities\"");
        let back: MarketCalendar = serde_json::from_str("\"continuous\"").unwrap();
        assert_eq!(back, MarketCalendar::Continuous);
    }
}
