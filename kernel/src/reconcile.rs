//! Measuring live trading against the backtest that justified it.
//!
//! Two questions, both answered from data rather than from assumption:
//!
//! 1. **What slippage are we actually paying?** The backtest charges a flat
//!    `slippageBps` that somebody typed in. Real fills know better.
//! 2. **Is live tracking the simulation?** A strategy that backtested at +67%
//!    and is running at −3% has something wrong with it, and the earlier that
//!    shows up as a number the better.
//!
//! Both live here rather than in Swift for the same reason everything else
//! does: they are deterministic calculations over market data, and the answer
//! must not depend on which side of the FFI asked.

use serde::{Deserialize, Serialize};

use crate::candle::Candle;

// MARK: - Slippage

/// One execution, as the ledger recorded it.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct ExecutedFill {
    /// Milliseconds since the Unix epoch.
    pub ts_ms: i64,
    pub price: f64,
    /// 1 for a buy, −1 for a sell.
    pub side: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SlippageReport {
    /// Fills that could be matched to a bar. Fills whose bar is not in the
    /// candle window are not counted, rather than being scored against a
    /// neighbouring bar's open.
    pub samples: usize,
    /// Median adverse slippage in basis points. The median rather than the
    /// mean, because one fill during a listing spike would otherwise set the
    /// assumption for every future backtest.
    #[serde(rename = "medianBps")]
    pub median_bps: Option<f64>,
    #[serde(rename = "meanBps")]
    pub mean_bps: Option<f64>,
    /// The bad tail. A cost model built on the median alone will under-reserve
    /// exactly when it matters.
    #[serde(rename = "p90Bps")]
    pub p90_bps: Option<f64>,
    /// What the manifest currently assumes, echoed back so a caller can show
    /// the comparison without re-reading the manifest.
    #[serde(rename = "assumedBps")]
    pub assumed_bps: f64,
}

/// Compare each fill against the open of the bar it landed in.
///
/// That is the like-for-like comparison, because it is exactly what the
/// backtester models: a signal on bar *i*'s close fills at bar *i+1*'s open,
/// plus slippage. Measuring against the current mark instead would fold in
/// however long the tick took to notice the bar, which is a different quantity
/// and not one the simulation ever claimed to model.
///
/// Slippage is signed *adversely*: positive means the fill was worse than the
/// open. Negative values are kept — sometimes a market order gets price
/// improvement, and discarding those would bias the estimate upward.
pub fn calibrate_slippage(
    fills: &[ExecutedFill],
    candles: &[Candle],
    assumed_bps: f64,
) -> SlippageReport {
    let mut sorted: Vec<Candle> = candles.iter().copied().filter(|c| c.is_sane()).collect();
    sorted.sort_by_key(|c| c.ts_ms);

    let mut deviations: Vec<f64> = Vec::new();
    for fill in fills {
        if !(fill.price > 0.0) || fill.side == 0 {
            continue;
        }
        let Some(bar) = bar_containing(&sorted, fill.ts_ms) else {
            continue;
        };
        if !(bar.open > 0.0) {
            continue;
        }
        let signed = (fill.price - bar.open) / bar.open * fill.side as f64;
        deviations.push(signed * 10_000.0);
    }

    deviations.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let samples = deviations.len();
    SlippageReport {
        samples,
        median_bps: percentile(&deviations, 0.5),
        mean_bps: (samples > 0).then(|| deviations.iter().sum::<f64>() / samples as f64),
        p90_bps: percentile(&deviations, 0.9),
        assumed_bps,
    }
}

/// The bar whose interval contains `ts_ms`, using the gap to the next bar as
/// the interval. The last bar is treated as open-ended, which is right: a fill
/// that just happened belongs to the bar still forming.
fn bar_containing(sorted: &[Candle], ts_ms: i64) -> Option<Candle> {
    if sorted.is_empty() || ts_ms < sorted[0].ts_ms {
        return None;
    }
    let index = match sorted.binary_search_by_key(&ts_ms, |c| c.ts_ms) {
        Ok(exact) => exact,
        Err(insertion) => insertion.checked_sub(1)?,
    };
    Some(sorted[index])
}

/// Linear-interpolation percentile of an already-sorted slice.
fn percentile(sorted: &[f64], q: f64) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    if sorted.len() == 1 {
        return Some(sorted[0]);
    }
    let position = q * (sorted.len() - 1) as f64;
    let lower = position.floor() as usize;
    let upper = position.ceil() as usize;
    let weight = position - lower as f64;
    Some(sorted[lower] * (1.0 - weight) + sorted[upper] * weight)
}

// MARK: - Live versus backtest

/// One point on an equity curve.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct EquitySample {
    pub ts_ms: i64,
    pub equity: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EquityComparison {
    /// Paired observations. Everything below is null until there are at least
    /// two, because a single point describes no return at all.
    pub samples: usize,
    /// Milliseconds actually covered by the overlap.
    #[serde(rename = "coveredMs")]
    pub covered_ms: i64,
    #[serde(rename = "liveReturnPct")]
    pub live_return_pct: Option<f64>,
    #[serde(rename = "backtestReturnPct")]
    pub backtest_return_pct: Option<f64>,
    /// Live minus backtest, in percentage points. The headline number.
    #[serde(rename = "differencePct")]
    pub difference_pct: Option<f64>,
    /// Standard deviation of the per-interval return difference, in basis
    /// points. Small means live is following the simulation's *shape* even if
    /// the level has drifted; large means they are different strategies.
    #[serde(rename = "trackingErrorBps")]
    pub tracking_error_bps: Option<f64>,
    /// Correlation of the two return series. Distinguishes "same strategy,
    /// worse costs" from "not doing the same thing at all".
    pub correlation: Option<f64>,
}

/// Align a backtest curve onto the live curve's sample times and compare.
///
/// Alignment is step-wise: each live sample is paired with the most recent
/// backtest point at or before it. Interpolating between backtest points would
/// invent equity the simulation never reported, and the gap between two bars is
/// precisely where a backtest has no opinion.
pub fn compare_equity(live: &[EquitySample], backtest: &[EquitySample]) -> EquityComparison {
    let mut live: Vec<EquitySample> = live.iter().copied().filter(|s| s.equity > 0.0).collect();
    let mut sim: Vec<EquitySample> = backtest
        .iter()
        .copied()
        .filter(|s| s.equity > 0.0)
        .collect();
    live.sort_by_key(|s| s.ts_ms);
    sim.sort_by_key(|s| s.ts_ms);

    // The simulation has no opinion outside its own window. Live samples past
    // the last backtest point would otherwise all pair with that final value
    // and be scored against a return of zero — reporting the backtest as flat
    // during a period it never covered.
    let sim_end = sim.last().map(|s| s.ts_ms);

    let mut paired: Vec<(f64, f64)> = Vec::new();
    let mut paired_times: Vec<i64> = Vec::new();
    let mut cursor = 0usize;
    for point in &live {
        if sim_end.is_none_or(|end| point.ts_ms > end) {
            continue;
        }
        while cursor + 1 < sim.len() && sim[cursor + 1].ts_ms <= point.ts_ms {
            cursor += 1;
        }
        // Nothing to pair with until the backtest has started.
        if sim[cursor].ts_ms > point.ts_ms {
            continue;
        }
        paired.push((point.equity, sim[cursor].equity));
        paired_times.push(point.ts_ms);
    }

    let samples = paired.len();
    let covered_ms = match (paired_times.first(), paired_times.last()) {
        (Some(first), Some(last)) if samples >= 2 => last - first,
        _ => 0,
    };
    if samples < 2 {
        return EquityComparison {
            samples,
            covered_ms,
            live_return_pct: None,
            backtest_return_pct: None,
            difference_pct: None,
            tracking_error_bps: None,
            correlation: None,
        };
    }

    let live_return = (paired[samples - 1].0 / paired[0].0 - 1.0) * 100.0;
    let sim_return = (paired[samples - 1].1 / paired[0].1 - 1.0) * 100.0;

    let mut live_steps: Vec<f64> = Vec::with_capacity(samples - 1);
    let mut sim_steps: Vec<f64> = Vec::with_capacity(samples - 1);
    for window in paired.windows(2) {
        live_steps.push(window[1].0 / window[0].0 - 1.0);
        sim_steps.push(window[1].1 / window[0].1 - 1.0);
    }

    let differences: Vec<f64> = live_steps
        .iter()
        .zip(&sim_steps)
        .map(|(a, b)| a - b)
        .collect();

    EquityComparison {
        samples,
        covered_ms,
        live_return_pct: Some(live_return),
        backtest_return_pct: Some(sim_return),
        difference_pct: Some(live_return - sim_return),
        tracking_error_bps: stdev(&differences).map(|v| v * 10_000.0),
        correlation: correlation(&live_steps, &sim_steps),
    }
}

fn mean(values: &[f64]) -> Option<f64> {
    (!values.is_empty()).then(|| values.iter().sum::<f64>() / values.len() as f64)
}

fn stdev(values: &[f64]) -> Option<f64> {
    if values.len() < 2 {
        return None;
    }
    let mu = mean(values)?;
    let variance: f64 = values.iter().map(|v| (v - mu) * (v - mu)).sum::<f64>()
        / (values.len() - 1) as f64;
    Some(variance.sqrt())
}

fn correlation(a: &[f64], b: &[f64]) -> Option<f64> {
    if a.len() != b.len() || a.len() < 2 {
        return None;
    }
    let (mu_a, mu_b) = (mean(a)?, mean(b)?);
    let mut covariance = 0.0;
    let mut var_a = 0.0;
    let mut var_b = 0.0;
    for (x, y) in a.iter().zip(b) {
        covariance += (x - mu_a) * (y - mu_b);
        var_a += (x - mu_a) * (x - mu_a);
        var_b += (y - mu_b) * (y - mu_b);
    }
    // A series that does not vary has no correlation to report — not a
    // correlation of zero, which would read as "unrelated" rather than
    // "undefined".
    //
    // Tested against a relative floor rather than against zero: a curve
    // compounding at a fixed rate has a return variance of ~1e-33 rather than
    // exactly 0, and dividing by that produces a confident-looking number made
    // entirely of rounding error.
    if !varies(var_a, mu_a, a.len()) || !varies(var_b, mu_b, b.len()) {
        return None;
    }
    Some(covariance / (var_a.sqrt() * var_b.sqrt()))
}

/// Does this series vary enough for a ratio against its spread to mean anything?
fn varies(sum_squares: f64, mean: f64, count: usize) -> bool {
    if count < 2 || !(sum_squares > 0.0) {
        return false;
    }
    let deviation = (sum_squares / (count - 1) as f64).sqrt();
    deviation > mean.abs().max(1e-12) * 1e-9
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bar(ts_ms: i64, open: f64) -> Candle {
        Candle {
            ts_ms,
            open,
            high: open + 5.0,
            low: open - 5.0,
            close: open,
            volume: 1.0,
            confirmed: 1,
        }
    }

    fn fill(ts_ms: i64, price: f64, side: i32) -> ExecutedFill {
        ExecutedFill { ts_ms, price, side }
    }

    #[test]
    fn a_buy_above_the_open_pays_slippage() {
        // Bought at 100.10 against an open of 100 → 10 bps adverse.
        let report = calibrate_slippage(&[fill(500, 100.10, 1)], &[bar(0, 100.0)], 5.0);
        assert_eq!(report.samples, 1);
        assert!((report.median_bps.unwrap() - 10.0).abs() < 1e-6);
    }

    #[test]
    fn a_sell_below_the_open_also_pays_slippage() {
        // Adverse is direction-aware: a seller is hurt by a *lower* price.
        let report = calibrate_slippage(&[fill(500, 99.90, -1)], &[bar(0, 100.0)], 5.0);
        assert!((report.median_bps.unwrap() - 10.0).abs() < 1e-6);
    }

    #[test]
    fn price_improvement_is_kept_not_discarded() {
        // Throwing away the favourable fills would bias the estimate upward and
        // make every future backtest too pessimistic.
        let report = calibrate_slippage(&[fill(500, 99.90, 1)], &[bar(0, 100.0)], 5.0);
        assert!(report.median_bps.unwrap() < 0.0);
    }

    #[test]
    fn the_median_ignores_one_freak_fill() {
        let fills = [
            fill(100, 100.01, 1),
            fill(200, 100.01, 1),
            fill(300, 100.01, 1),
            fill(400, 130.0, 1), // a listing spike
        ];
        let report = calibrate_slippage(&fills, &[bar(0, 100.0)], 5.0);
        assert!(report.median_bps.unwrap() < 20.0, "the median holds");
        assert!(report.mean_bps.unwrap() > 500.0, "the mean does not");
        // And the tail is still reported, so nobody plans off the median alone.
        assert!(report.p90_bps.unwrap() > 100.0);
    }

    #[test]
    fn a_fill_before_the_candle_window_is_not_scored() {
        // Better to report fewer samples than to price a fill against a bar
        // that has nothing to do with it.
        let report = calibrate_slippage(&[fill(-5_000, 100.0, 1)], &[bar(0, 100.0)], 5.0);
        assert_eq!(report.samples, 0);
        assert!(report.median_bps.is_none());
    }

    #[test]
    fn a_fill_lands_in_the_bar_that_contains_it() {
        let candles = [bar(0, 100.0), bar(1_000, 200.0), bar(2_000, 300.0)];
        let report = calibrate_slippage(&[fill(1_500, 202.0, 1)], &candles, 5.0);
        // Scored against 200, not 100 or 300.
        assert!((report.median_bps.unwrap() - 100.0).abs() < 1e-6);
    }

    #[test]
    fn two_identical_curves_have_no_gap() {
        let curve: Vec<EquitySample> = (0..10)
            .map(|i| EquitySample { ts_ms: i * 1_000, equity: 1_000.0 + i as f64 })
            .collect();
        let result = compare_equity(&curve, &curve);
        assert!(result.difference_pct.unwrap().abs() < 1e-9);
        assert!(result.tracking_error_bps.unwrap().abs() < 1e-9);
        assert!((result.correlation.unwrap() - 1.0).abs() < 1e-9);
    }

    #[test]
    fn a_live_curve_that_lags_shows_a_negative_gap() {
        // Returns have to actually vary, or there is no shape to correlate.
        let steps = [0.02, -0.01, 0.03, 0.005, -0.02, 0.01, 0.015, -0.005, 0.02];
        let mut sim = vec![EquitySample { ts_ms: 0, equity: 1_000.0 }];
        let mut live = vec![EquitySample { ts_ms: 0, equity: 1_000.0 }];
        for (i, step) in steps.iter().enumerate() {
            let ts = (i as i64 + 1) * 1_000;
            sim.push(EquitySample {
                ts_ms: ts,
                equity: sim[i].equity * (1.0 + step),
            });
            // The same shape, consistently costing a little more.
            live.push(EquitySample {
                ts_ms: ts,
                equity: live[i].equity * (1.0 + step - 0.004),
            });
        }
        let result = compare_equity(&live, &sim);
        assert!(result.difference_pct.unwrap() < 0.0);
        // Same shape, lower level: strongly correlated despite the gap. That is
        // the distinction the correlation exists to draw.
        assert!(result.correlation.unwrap() > 0.99);
    }

    #[test]
    fn one_observation_reports_nothing_rather_than_zero() {
        let point = [EquitySample { ts_ms: 0, equity: 1_000.0 }];
        let result = compare_equity(&point, &point);
        assert_eq!(result.samples, 1);
        assert!(result.live_return_pct.is_none());
        assert!(result.difference_pct.is_none());
    }

    #[test]
    fn live_samples_before_the_backtest_starts_are_dropped() {
        let live = [
            EquitySample { ts_ms: 0, equity: 1_000.0 },
            EquitySample { ts_ms: 5_000, equity: 1_100.0 },
            EquitySample { ts_ms: 6_000, equity: 1_200.0 },
        ];
        let sim = [
            EquitySample { ts_ms: 4_000, equity: 2_000.0 },
            EquitySample { ts_ms: 6_000, equity: 2_200.0 },
        ];
        let result = compare_equity(&live, &sim);
        // Only the two live points at or after 4_000 can be paired.
        assert_eq!(result.samples, 2);
    }

    #[test]
    fn a_curve_compounding_at_a_fixed_rate_reports_no_correlation() {
        // Its return variance is ~1e-33, not 0. Dividing by that yields a
        // confident number made entirely of rounding error.
        let sim: Vec<EquitySample> = (0..10)
            .map(|i| EquitySample { ts_ms: i * 1_000, equity: 1_000.0 * 1.01_f64.powi(i as i32) })
            .collect();
        let live: Vec<EquitySample> = (0..10)
            .map(|i| EquitySample { ts_ms: i * 1_000, equity: 1_000.0 * 1.005_f64.powi(i as i32) })
            .collect();
        let result = compare_equity(&live, &sim);
        assert!(result.correlation.is_none());
        // The level gap is still perfectly well defined, and still reported.
        assert!(result.difference_pct.unwrap() < 0.0);
    }

    #[test]
    fn live_samples_past_the_backtest_window_are_dropped() {
        // Otherwise every sample after the simulation ended pairs with its last
        // value, and the backtest is reported as flat over a period it never
        // covered — which would read as live outperforming.
        let live: Vec<EquitySample> = (0..10)
            .map(|i| EquitySample { ts_ms: i * 1_000, equity: 1_000.0 + i as f64 })
            .collect();
        let sim: Vec<EquitySample> = (0..4)
            .map(|i| EquitySample { ts_ms: i * 1_000, equity: 1_000.0 + i as f64 })
            .collect();
        let result = compare_equity(&live, &sim);
        assert_eq!(result.samples, 4);
        assert_eq!(result.covered_ms, 3_000, "only the overlap is reported");
        assert!(result.difference_pct.unwrap().abs() < 1e-9);
    }

    #[test]
    fn a_flat_curve_reports_no_correlation_rather_than_zero() {
        let flat: Vec<EquitySample> = (0..5)
            .map(|i| EquitySample { ts_ms: i * 1_000, equity: 1_000.0 })
            .collect();
        let rising: Vec<EquitySample> = (0..5)
            .map(|i| EquitySample { ts_ms: i * 1_000, equity: 1_000.0 + i as f64 })
            .collect();
        // Undefined, not "unrelated".
        assert!(compare_equity(&flat, &rising).correlation.is_none());
    }
}
