//! Vectorised technical indicators over price series.
//!
//! **Warm-up is NaN, never zero.** A 20-period average has no value on bar 5;
//! returning 0 there would make `close > sma(close, 20)` fire on every early
//! bar. Every function below emits NaN until it has enough input, and every
//! consumer treats NaN as "unknown" (comparisons against it are false).
//!
//! All functions are total: they accept any length input, including empty, and
//! return a vector of exactly the same length.
//!
//! The only implementation. It began as a port of a Swift twin that has since
//! been deleted (`docs/KERNEL.md` §4.1); what pins it now is the unit tests
//! below, function by function, and `KernelGoldenTests` on the Swift side,
//! which freezes whole backtests built on it.

use std::collections::VecDeque;

pub type Series = Vec<f64>;

fn nans(n: usize) -> Series {
    vec![f64::NAN; n]
}

/// Index of the first non-NaN element.
fn first_valid(x: &[f64]) -> Option<usize> {
    x.iter().position(|v| !v.is_nan())
}

/// Elementwise map that propagates NaN.
pub fn zip2<F: Fn(f64, f64) -> f64>(a: &[f64], b: &[f64], f: F) -> Series {
    let n = a.len().min(b.len());
    let mut out = nans(n);
    for i in 0..n {
        if !a[i].is_nan() && !b[i].is_nan() {
            out[i] = f(a[i], b[i]);
        }
    }
    out
}

// MARK: Moving averages

/// Simple moving average. NaN until `period` consecutive valid samples exist.
pub fn sma(x: &[f64], period: usize) -> Series {
    if period == 0 || x.is_empty() {
        return nans(x.len());
    }
    let mut out = nans(x.len());
    let mut sum = 0.0;
    let mut count = 0usize; // valid samples currently inside the window
    for i in 0..x.len() {
        if !x[i].is_nan() {
            sum += x[i];
            count += 1;
        }
        if i >= period {
            let dropped = x[i - period];
            if !dropped.is_nan() {
                sum -= dropped;
                count -= 1;
            }
        }
        if i + 1 >= period && count == period {
            out[i] = sum / period as f64;
        }
    }
    out
}

/// Exponential moving average, seeded with the SMA of the first `period` valid
/// samples (the convention used by TA-Lib and TradingView).
pub fn ema(x: &[f64], period: usize) -> Series {
    if period == 0 || x.is_empty() {
        return nans(x.len());
    }
    let mut out = nans(x.len());
    let Some(start) = first_valid(x) else {
        return out;
    };
    if start + period > x.len() {
        return out;
    }

    let mut seed = 0.0;
    for i in start..(start + period) {
        if x[i].is_nan() {
            return out; // gap inside the seed window
        }
        seed += x[i];
    }
    let alpha = 2.0 / (period as f64 + 1.0);
    let mut prev = seed / period as f64;
    out[start + period - 1] = prev;
    for i in (start + period)..x.len() {
        if x[i].is_nan() {
            continue; // hold the last value across gaps
        }
        prev = alpha * x[i] + (1.0 - alpha) * prev;
        out[i] = prev;
    }
    out
}

/// Linearly weighted moving average — the most recent bar carries weight `period`.
///
/// Slid in O(1) a bar: dropping the oldest sample lowers every remaining
/// weight by one, which is subtracting the plain sum, and the new sample
/// enters at full weight. Both sums are recomputed exactly whenever a window
/// is entered clean and once per window length after that, so rounding cannot
/// build up over a long series.
pub fn wma(x: &[f64], period: usize) -> Series {
    if period == 0 || x.is_empty() {
        return nans(x.len());
    }
    let mut out = nans(x.len());
    let denominator = (period * (period + 1) / 2) as f64;
    let mut plain = 0.0; // Σ x over the window
    let mut weighted = 0.0; // Σ weight · x, oldest weight 1, newest `period`
    let mut nans_in_window = 0usize;
    // Bars slid since the sums were last exact; `None` when they describe no
    // window at all.
    let mut since_exact: Option<usize> = None;
    for i in 0..x.len() {
        if x[i].is_nan() {
            nans_in_window += 1;
        }
        if i >= period && x[i - period].is_nan() {
            nans_in_window -= 1;
        }
        if i + 1 < period || nans_in_window > 0 {
            since_exact = None;
            continue;
        }
        match since_exact {
            Some(slid) if slid + 1 < period => {
                weighted += period as f64 * x[i] - plain;
                plain += x[i] - x[i - period];
                since_exact = Some(slid + 1);
            }
            _ => {
                let window = &x[i + 1 - period..=i];
                plain = window.iter().sum();
                weighted = window.iter().enumerate().map(|(k, v)| (k + 1) as f64 * v).sum();
                since_exact = Some(0);
            }
        }
        out[i] = weighted / denominator;
    }
    out
}

/// The nested loop `wma` replaced, kept as its reference.
#[cfg(test)]
fn naive_wma(x: &[f64], period: usize) -> Series {
    if period == 0 || x.is_empty() {
        return nans(x.len());
    }
    let mut out = nans(x.len());
    let denominator = (period * (period + 1) / 2) as f64;
    for i in 0..x.len() {
        if i + 1 < period {
            continue;
        }
        let mut acc = 0.0;
        let mut complete = true;
        for k in 0..period {
            let value = x[i + 1 + k - period];
            if value.is_nan() {
                complete = false;
                break;
            }
            acc += value * (k + 1) as f64;
        }
        if complete {
            out[i] = acc / denominator;
        }
    }
    out
}

/// Wilder's smoothing (RMA) — the average used inside RSI and ATR. Equivalent
/// to an EMA with `alpha = 1/period`.
pub fn rma(x: &[f64], period: usize) -> Series {
    if period == 0 || x.is_empty() {
        return nans(x.len());
    }
    let mut out = nans(x.len());
    let Some(start) = first_valid(x) else {
        return out;
    };
    if start + period > x.len() {
        return out;
    }

    let mut seed = 0.0;
    for i in start..(start + period) {
        if x[i].is_nan() {
            return out;
        }
        seed += x[i];
    }
    let mut prev = seed / period as f64;
    out[start + period - 1] = prev;
    for i in (start + period)..x.len() {
        if x[i].is_nan() {
            continue;
        }
        prev = (prev * (period - 1) as f64 + x[i]) / period as f64;
        out[i] = prev;
    }
    out
}

// MARK: Oscillators

/// Relative Strength Index using Wilder's smoothing. Range 0…100.
pub fn rsi(x: &[f64], period: usize) -> Series {
    if period == 0 || x.len() < 2 {
        return nans(x.len());
    }
    let mut gains = nans(x.len());
    let mut losses = nans(x.len());
    for i in 1..x.len() {
        if x[i].is_nan() || x[i - 1].is_nan() {
            continue;
        }
        let delta = x[i] - x[i - 1];
        gains[i] = delta.max(0.0);
        losses[i] = (-delta).max(0.0);
    }
    let avg_gain = rma(&gains, period);
    let avg_loss = rma(&losses, period);
    let mut out = nans(x.len());
    for i in 0..x.len() {
        if avg_gain[i].is_nan() || avg_loss[i].is_nan() {
            continue;
        }
        // All-gain windows are RSI 100; all-loss windows are RSI 0.
        out[i] = if avg_loss[i] == 0.0 {
            if avg_gain[i] == 0.0 {
                50.0
            } else {
                100.0
            }
        } else {
            100.0 - 100.0 / (1.0 + avg_gain[i] / avg_loss[i])
        };
    }
    out
}

/// Rate of change in percent: `(x[i] / x[i-period] - 1) * 100`.
pub fn roc(x: &[f64], period: usize) -> Series {
    if period == 0 {
        return nans(x.len());
    }
    let mut out = nans(x.len());
    for i in period..x.len() {
        let base = x[i - period];
        if x[i].is_nan() || base.is_nan() || base == 0.0 {
            continue;
        }
        out[i] = (x[i] / base - 1.0) * 100.0;
    }
    out
}

// MARK: Volatility

/// Population standard deviation over a rolling window — the convention
/// Bollinger Bands are defined with. Unknown when the window holds a NaN.
pub fn stdev(x: &[f64], period: usize) -> Series {
    if period == 0 || x.is_empty() {
        return nans(x.len());
    }
    let mut out = nans(x.len());
    let mut window = WindowMoments::new(x, period);
    for i in 0..x.len() {
        window.advance(i);
        if i + 1 >= period && window.count == period {
            out[i] = window.variance(0).sqrt();
        }
    }
    out
}

/// The two-pass loop `stdev` replaced, kept as its reference.
#[cfg(test)]
fn naive_stdev(x: &[f64], period: usize) -> Series {
    if period == 0 || x.is_empty() {
        return nans(x.len());
    }
    let mean = sma(x, period);
    let mut out = nans(x.len());
    for i in 0..x.len() {
        if i + 1 < period || mean[i].is_nan() {
            continue;
        }
        let mut acc = 0.0;
        for j in (i + 1 - period)..=i {
            let d = x[j] - mean[i];
            acc += d * d;
        }
        out[i] = (acc / period as f64).sqrt();
    }
    out
}

/// Count, sum and sum of squares of the valid samples in a window sliding one
/// bar at a time — what a rolling deviation needs, in O(1) a bar where summing
/// each window afresh is O(period).
///
/// The sums are kept relative to an anchor at the window's mean, so squaring
/// prices in the tens of thousands does not cancel away the variance of a
/// quiet stretch, and they are recomputed exactly — anchor included — once per
/// window length, so rounding cannot accumulate over a long series. They are
/// also recomputed whenever the variance collapses against them (noise
/// sliding out, a flat stretch sliding in), where the subtraction would keep
/// only rounding: measured, a two-bar window on a flat run read 2.4e-7 where
/// the truth is 0. A recompute costs one window and resets the anchor to
/// where the values now are, so the pass stays O(n) in practice.
pub(crate) struct WindowMoments<'a> {
    x: &'a [f64],
    period: usize,
    anchor: f64,
    /// Valid samples in the window.
    pub count: usize,
    sum: f64,
    sum_sq: f64,
    since_exact: usize,
}

impl<'a> WindowMoments<'a> {
    pub fn new(x: &'a [f64], period: usize) -> Self {
        Self { x, period: period.max(1), anchor: 0.0, count: 0, sum: 0.0, sum_sq: 0.0, since_exact: usize::MAX }
    }

    /// Move the window to end at `i`. Called for `i` = 0, 1, 2, … in turn.
    pub fn advance(&mut self, i: usize) {
        if self.since_exact >= self.period {
            self.recompute(i);
            return;
        }
        self.add(self.x[i], 1.0);
        if i >= self.period {
            self.add(self.x[i - self.period], -1.0);
        }
        self.since_exact += 1;
        if self.count > 0 && self.numerator() < 1e-6 * self.sum_sq {
            self.recompute(i);
        }
    }

    /// Σ (x − mean)², from the anchored sums.
    fn numerator(&self) -> f64 {
        self.sum_sq - self.sum * self.sum / self.count as f64
    }

    fn add(&mut self, value: f64, sign: f64) {
        if value.is_nan() {
            return;
        }
        let d = value - self.anchor;
        self.sum += sign * d;
        self.sum_sq += sign * d * d;
        if sign > 0.0 {
            self.count += 1;
        } else {
            self.count -= 1;
        }
    }

    fn recompute(&mut self, i: usize) {
        let window = &self.x[(i + 1).saturating_sub(self.period)..=i];
        let valid = window.iter().filter(|v| !v.is_nan());
        let (count, total) = valid.clone().fold((0usize, 0.0), |(n, t), v| (n + 1, t + v));
        self.anchor = if count > 0 { total / count as f64 } else { 0.0 };
        self.count = count;
        self.sum = valid.clone().map(|v| v - self.anchor).sum();
        self.sum_sq = valid.map(|v| (v - self.anchor) * (v - self.anchor)).sum();
        self.since_exact = 0;
    }

    /// Variance of the valid samples, `ddof` 0 for the population and 1 for a
    /// sample. Never negative: rounding cannot be allowed to take a square
    /// root of one.
    pub fn variance(&self, ddof: usize) -> f64 {
        (self.numerator() / (self.count as f64 - ddof as f64)).max(0.0)
    }
}

/// True range: `max(h-l, |h-prevClose|, |l-prevClose|)`.
pub fn true_range(high: &[f64], low: &[f64], close: &[f64]) -> Series {
    let n = high.len().min(low.len()).min(close.len());
    let mut out = nans(n);
    for i in 0..n {
        if high[i].is_nan() || low[i].is_nan() {
            continue;
        }
        if i == 0 {
            out[i] = high[i] - low[i];
        } else if !close[i - 1].is_nan() {
            out[i] = (high[i] - low[i])
                .max((high[i] - close[i - 1]).abs())
                .max((low[i] - close[i - 1]).abs());
        }
    }
    out
}

/// Average true range (Wilder).
pub fn atr(high: &[f64], low: &[f64], close: &[f64], period: usize) -> Series {
    rma(&true_range(high, low, close), period)
}

// MARK: Rolling extremes

pub fn highest(x: &[f64], period: usize) -> Series {
    rolling_extreme(x, period, true)
}

pub fn lowest(x: &[f64], period: usize) -> Series {
    rolling_extreme(x, period, false)
}

/// Sliding extreme over a monotonic deque: O(n), where the nested loop it
/// replaced was O(n · period). That was nothing at `highest(high, 20)` on 1H
/// bars and quadratic at the windows 1m research uses — a seven-day channel on
/// minute bars is 10 080 bars a window, about 1.4e9 comparisons per series on
/// the 200 000-bar runs the runner allows (`BacktestRunner.maxBars`).
///
/// Same answer bar for bar, NaN included: a window holding any NaN is unknown.
/// `naive_rolling_extreme` is kept as the reference the test checks it against.
fn rolling_extreme(x: &[f64], period: usize, want_max: bool) -> Series {
    if period == 0 || x.is_empty() {
        return nans(x.len());
    }
    let mut out = nans(x.len());
    // Indices still able to be the extreme, oldest first; their values only
    // fall (for a max) from front to back, so the front is the answer.
    let mut candidates: VecDeque<usize> = VecDeque::new();
    let mut nans_in_window = 0usize;
    for i in 0..x.len() {
        if i >= period {
            let leaving = i - period;
            if x[leaving].is_nan() {
                nans_in_window -= 1;
            } else if candidates.front() == Some(&leaving) {
                candidates.pop_front();
            }
        }
        if x[i].is_nan() {
            nans_in_window += 1;
        } else {
            // A value at least as extreme makes every older one behind it
            // irrelevant for as long as it stays in the window.
            while candidates.back().is_some_and(|&back| {
                if want_max { x[back] <= x[i] } else { x[back] >= x[i] }
            }) {
                candidates.pop_back();
            }
            candidates.push_back(i);
        }
        if i + 1 >= period && nans_in_window == 0 {
            out[i] = candidates.front().map_or(f64::NAN, |&front| x[front]);
        }
    }
    out
}

/// The nested loop `rolling_extreme` replaced, kept as its reference.
#[cfg(test)]
fn naive_rolling_extreme(x: &[f64], period: usize, want_max: bool) -> Series {
    if period == 0 || x.is_empty() {
        return nans(x.len());
    }
    let mut out = nans(x.len());
    for i in 0..x.len() {
        if i + 1 < period {
            continue;
        }
        let mut best = f64::NAN;
        let mut complete = true;
        for j in (i + 1 - period)..=i {
            if x[j].is_nan() {
                complete = false;
                break;
            }
            let better = if want_max { x[j] > best } else { x[j] < best };
            if best.is_nan() || better {
                best = x[j];
            }
        }
        if complete {
            out[i] = best;
        }
    }
    out
}

// MARK: Composites

pub struct Macd {
    pub macd: Series,
    pub signal: Series,
    pub histogram: Series,
}

pub fn macd(x: &[f64], fast: usize, slow: usize, signal: usize) -> Macd {
    let line = zip2(&ema(x, fast), &ema(x, slow), |a, b| a - b);
    let sig = ema(&line, signal);
    let histogram = zip2(&line, &sig, |a, b| a - b);
    Macd {
        macd: line,
        signal: sig,
        histogram,
    }
}

pub struct Bollinger {
    pub upper: Series,
    pub middle: Series,
    pub lower: Series,
}

pub fn bollinger(x: &[f64], period: usize, mult: f64) -> Bollinger {
    let mid = sma(x, period);
    let sd = stdev(x, period);
    Bollinger {
        upper: zip2(&mid, &sd, |m, s| m + mult * s),
        lower: zip2(&mid, &sd, |m, s| m - mult * s),
        middle: mid,
    }
}

// MARK: Series utilities

/// Shift a series `n` bars into the past: `ref(x, 1)[i] == x[i-1]`.
/// A negative shift would be forward peeking, so it yields all NaN.
pub fn shift(x: &[f64], n: i64) -> Series {
    if n == 0 {
        return x.to_vec();
    }
    let mut out = nans(x.len());
    if n < 0 {
        return out; // forward peeking is never allowed
    }
    let n = n as usize;
    for i in n..x.len() {
        out[i] = x[i - n];
    }
    out
}

/// `a` crossing up through `b`: below-or-equal on the previous bar, above now.
/// NaN on either bar means "unknown" — never a cross.
pub fn crosses_above(a: &[f64], b: &[f64]) -> Series {
    cross(a, b, |pa, pb, ca, cb| pa <= pb && ca > cb)
}

pub fn crosses_below(a: &[f64], b: &[f64]) -> Series {
    cross(a, b, |pa, pb, ca, cb| pa >= pb && ca < cb)
}

fn cross<F: Fn(f64, f64, f64, f64) -> bool>(a: &[f64], b: &[f64], test: F) -> Series {
    let n = a.len().min(b.len());
    let mut out = vec![0.0; n];
    if n <= 1 {
        // Match the Swift original: a single bar has no previous bar, and the
        // zero-length case must stay empty rather than gain a NaN.
        if n == 1 {
            out[0] = f64::NAN;
        }
        return out;
    }
    for i in 1..n {
        if a[i].is_nan() || b[i].is_nan() || a[i - 1].is_nan() || b[i - 1].is_nan() {
            out[i] = f64::NAN;
            continue;
        }
        out[i] = if test(a[i - 1], b[i - 1], a[i], b[i]) {
            1.0
        } else {
            0.0
        };
    }
    out[0] = f64::NAN;
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    /// A series with what breaks sliding windows: NaN runs, a single NaN every
    /// so often, a plateau of equal values, and prices at BTC's magnitude
    /// moving by cents — where squaring before subtracting loses the variance.
    fn awkward_series() -> Vec<f64> {
        let mut seed = 12_345u64;
        (0..600)
            .map(|i| {
                seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
                if i % 97 == 0 || (201..210).contains(&i) {
                    f64::NAN
                } else if (300..340).contains(&i) {
                    42.0
                } else if (400..470).contains(&i) {
                    65_000.0 + ((seed >> 33) % 100) as f64 / 100.0
                } else {
                    ((seed >> 33) % 1000) as f64 / 10.0
                }
            })
            .collect()
    }

    fn agree(name: &str, period: usize, fast: &[f64], slow: &[f64]) {
        assert_eq!(fast.len(), slow.len());
        for (i, (f, s)) in fast.iter().zip(slow).enumerate() {
            assert_eq!(f.is_nan(), s.is_nan(), "{name}({period}) bar {i}: {f} vs {s}");
            if !f.is_nan() {
                assert!((f - s).abs() <= 1e-9 * s.abs().max(1.0), "{name}({period}) bar {i}: {f} vs {s}");
            }
        }
    }

    /// The sliding versions against the loops they replaced.
    #[test]
    fn the_sliding_averages_match_the_loops_they_replaced() {
        let x = awkward_series();
        for period in [0, 1, 2, 3, 7, 20, 121, 599, 600, 601] {
            agree("wma", period, &wma(&x, period), &naive_wma(&x, period));
            agree("stdev", period, &stdev(&x, period), &naive_stdev(&x, period));
        }
    }

    /// The deque against the loop it replaced, over windows from one bar to
    /// longer than the series, NaN runs, and a plateau of equal values — where
    /// a deque that pops on `<` instead of `<=` keeps stale indices.
    #[test]
    fn the_sliding_extreme_matches_the_nested_loop() {
        let mut seed = 12_345u64;
        let x: Vec<f64> = (0..600)
            .map(|i| {
                seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
                if i % 97 == 0 || (201..210).contains(&i) {
                    f64::NAN
                } else if (300..340).contains(&i) {
                    42.0
                } else {
                    ((seed >> 33) % 1000) as f64 / 10.0
                }
            })
            .collect();
        for period in [0, 1, 2, 3, 7, 20, 121, 599, 600, 601] {
            for want_max in [true, false] {
                let fast = rolling_extreme(&x, period, want_max);
                let slow = naive_rolling_extreme(&x, period, want_max);
                assert_eq!(fast.len(), slow.len());
                for (i, (f, s)) in fast.iter().zip(&slow).enumerate() {
                    assert!(f.to_bits() == s.to_bits() || (f.is_nan() && s.is_nan()),
                            "period {period} max {want_max} bar {i}: {f} vs {s}");
                }
            }
        }
    }

    #[test]
    fn sma_is_nan_until_the_window_fills() {
        let x = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let out = sma(&x, 3);
        assert!(out[0].is_nan());
        assert!(out[1].is_nan());
        assert!(approx(out[2], 2.0));
        assert!(approx(out[3], 3.0));
        assert!(approx(out[4], 4.0));
    }

    #[test]
    fn sma_window_reopens_after_a_gap() {
        // A NaN inside the window must suppress output until it has scrolled out.
        let x = vec![1.0, f64::NAN, 3.0, 4.0, 5.0];
        let out = sma(&x, 3);
        assert!(out[2].is_nan());
        assert!(out[3].is_nan());
        assert!(approx(out[4], 4.0));
    }

    #[test]
    fn ema_seeds_with_the_simple_average() {
        let x = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let out = ema(&x, 3);
        assert!(out[1].is_nan());
        assert!(approx(out[2], 2.0)); // (1+2+3)/3
        assert!(approx(out[3], 0.5 * 4.0 + 0.5 * 2.0));
    }

    #[test]
    fn rsi_pins_at_the_extremes() {
        let rising: Vec<f64> = (0..40).map(|i| 100.0 + i as f64).collect();
        let out = rsi(&rising, 14);
        assert!(approx(*out.last().unwrap(), 100.0));

        let falling: Vec<f64> = (0..40).map(|i| 100.0 - i as f64).collect();
        let out = rsi(&falling, 14);
        assert!(approx(*out.last().unwrap(), 0.0));
    }

    #[test]
    fn a_flat_series_has_no_deviation() {
        let x = vec![5.0; 20];
        let out = stdev(&x, 5);
        assert!(approx(out[19], 0.0));
    }

    #[test]
    fn crossing_needs_a_previous_bar() {
        let a = vec![1.0, 3.0];
        let b = vec![2.0, 2.0];
        let out = crosses_above(&a, &b);
        assert!(out[0].is_nan(), "bar zero has nothing to cross from");
        assert!(approx(out[1], 1.0));
    }

    #[test]
    fn crossing_is_unknown_not_false_across_a_gap() {
        let a = vec![1.0, f64::NAN, 3.0];
        let b = vec![2.0, 2.0, 2.0];
        let out = crosses_above(&a, &b);
        assert!(out[1].is_nan());
        assert!(out[2].is_nan(), "the previous bar is still unknown");
    }

    #[test]
    fn shift_never_looks_forward() {
        let x = vec![1.0, 2.0, 3.0];
        assert!(shift(&x, -1).iter().all(|v| v.is_nan()));
        let back = shift(&x, 1);
        assert!(back[0].is_nan());
        assert!(approx(back[1], 1.0));
    }

    #[test]
    fn every_function_preserves_length() {
        let x: Vec<f64> = (0..7).map(|i| i as f64).collect();
        for n in [0usize, 1, 3, 50] {
            assert_eq!(sma(&x, n).len(), x.len());
            assert_eq!(ema(&x, n).len(), x.len());
            assert_eq!(rma(&x, n).len(), x.len());
            assert_eq!(wma(&x, n).len(), x.len());
            assert_eq!(rsi(&x, n).len(), x.len());
            assert_eq!(roc(&x, n).len(), x.len());
            assert_eq!(stdev(&x, n).len(), x.len());
            assert_eq!(highest(&x, n).len(), x.len());
            assert_eq!(lowest(&x, n).len(), x.len());
        }
        assert!(sma(&[], 3).is_empty());
        assert!(ema(&[], 3).is_empty());
    }

    #[test]
    fn true_range_uses_the_previous_close() {
        let high = vec![10.0, 12.0];
        let low = vec![9.0, 11.0];
        let close = vec![9.5, 11.5];
        let out = true_range(&high, &low, &close);
        assert!(approx(out[0], 1.0)); // first bar: high - low
        assert!(approx(out[1], 2.5)); // |12 - 9.5|
    }
}
