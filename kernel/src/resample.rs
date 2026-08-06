//! What else could have happened.
//!
//! A backtest reports one maximum drawdown. That number is a single draw from
//! a distribution: the same trades in a different order produce a different
//! worst stretch, and the order they happened to arrive in carries no
//! information about the order they will arrive in next.
//!
//! The practical consequence is direct. If the observed drawdown is 12% and
//! the 95th percentile of the resampled distribution is 22%, then 22% is the
//! number position sizing and the portfolio breaker should be built on. The
//! observed figure is the optimistic tail of what this strategy can do to an
//! account.
//!
//! Two methods, because they answer different questions:
//!
//! - **Shuffle** keeps every trade exactly as it happened and only reorders
//!   them. It asks: how much of the drawdown was the sequence?
//! - **Block bootstrap** samples contiguous runs with replacement. It asks the
//!   same thing while preserving the clustering — losing streaks are not
//!   independent draws, and a method that breaks them up understates the tail
//!   it exists to measure.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ResampleReport {
    /// Trades the simulation ran on.
    pub trades: usize,
    pub iterations: usize,
    /// The drawdown the backtest actually reported, for comparison.
    #[serde(rename = "observedDrawdownPct")]
    pub observed_drawdown_pct: f64,
    /// Percentiles of the resampled maximum-drawdown distribution.
    #[serde(rename = "drawdownMedianPct")]
    pub drawdown_median_pct: f64,
    #[serde(rename = "drawdownP95Pct")]
    pub drawdown_p95_pct: f64,
    #[serde(rename = "drawdownWorstPct")]
    pub drawdown_worst_pct: f64,
    /// Share of runs that finished below the starting capital. A strategy that
    /// loses money in a third of plausible orderings is not a strategy with a
    /// good backtest; it is a coin flip with a good backtest.
    #[serde(rename = "lossProbability")]
    pub loss_probability: f64,
    /// 5th and 95th percentile of the final return.
    #[serde(rename = "returnP5Pct")]
    pub return_p5_pct: f64,
    #[serde(rename = "returnP95Pct")]
    pub return_p95_pct: f64,
}

/// How trades are resampled.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ResampleMethod {
    /// Reorder the observed trades. Every trade appears exactly once.
    Shuffle,
    /// Draw contiguous blocks with replacement, preserving streaks.
    #[default]
    Block,
}

/// Run the resampling.
///
/// `returns` are per-trade fractional returns on the equity at the time — the
/// same quantity a trade's `returnPct` reports, expressed as a fraction.
///
/// `seed` makes the answer reproducible. A risk figure that changed every time
/// it was computed could not be argued with, and one that cannot be argued
/// with cannot be trusted.
pub fn resample_trades(
    returns: &[f64],
    iterations: usize,
    method: ResampleMethod,
    block_size: usize,
    seed: u64,
) -> Option<ResampleReport> {
    let clean: Vec<f64> = returns.iter().copied().filter(|v| v.is_finite()).collect();
    let count = clean.len();
    // Below this the distribution is describing the sample, not the strategy.
    if count < 10 || iterations == 0 {
        return None;
    }
    let block = block_size.clamp(1, count);

    let mut rng = Lcg::new(seed);
    let mut drawdowns = Vec::with_capacity(iterations);
    let mut finals = Vec::with_capacity(iterations);
    let mut order: Vec<usize> = (0..count).collect();

    for _ in 0..iterations {
        let sequence: Vec<f64> = match method {
            ResampleMethod::Shuffle => {
                // Fisher–Yates over a reused buffer.
                for i in (1..count).rev() {
                    order.swap(i, rng.below(i + 1));
                }
                order.iter().map(|i| clean[*i]).collect()
            }
            ResampleMethod::Block => {
                let mut out = Vec::with_capacity(count);
                while out.len() < count {
                    let start = rng.below(count);
                    for offset in 0..block {
                        if out.len() >= count {
                            break;
                        }
                        // Wrapped rather than truncated, so the last trades are
                        // not systematically under-represented.
                        out.push(clean[(start + offset) % count]);
                    }
                }
                out
            }
        };

        let (drawdown, final_equity) = walk(&sequence);
        drawdowns.push(drawdown);
        finals.push(final_equity);
    }

    let (observed_dd, _) = walk(&clean);
    drawdowns.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mut sorted_finals = finals.clone();
    sorted_finals.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

    Some(ResampleReport {
        trades: count,
        iterations,
        observed_drawdown_pct: observed_dd * 100.0,
        drawdown_median_pct: percentile(&drawdowns, 0.5) * 100.0,
        drawdown_p95_pct: percentile(&drawdowns, 0.95) * 100.0,
        drawdown_worst_pct: drawdowns.last().copied().unwrap_or(0.0) * 100.0,
        loss_probability: finals.iter().filter(|v| **v < 1.0).count() as f64
            / finals.len() as f64,
        return_p5_pct: (percentile(&sorted_finals, 0.05) - 1.0) * 100.0,
        return_p95_pct: (percentile(&sorted_finals, 0.95) - 1.0) * 100.0,
    })
}

/// Compound a sequence of per-trade returns; report peak-to-trough drawdown as
/// a fraction, and the final equity multiple.
///
/// Compounded rather than summed, because that is how an account actually
/// behaves: a 50% loss after a 50% gain does not return you to where you were.
fn walk(returns: &[f64]) -> (f64, f64) {
    let mut equity = 1.0_f64;
    let mut peak = 1.0_f64;
    let mut worst = 0.0_f64;
    for r in returns {
        equity *= 1.0 + r;
        // A wiped-out account cannot recover, and compounding through zero
        // into negative equity would model a debt the exchange would have
        // liquidated long before.
        if equity <= 0.0 {
            return (1.0, 0.0);
        }
        peak = peak.max(equity);
        worst = worst.max((peak - equity) / peak);
    }
    (worst, equity)
}

fn percentile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    if sorted.len() == 1 {
        return sorted[0];
    }
    let position = q * (sorted.len() - 1) as f64;
    let lower = position.floor() as usize;
    let upper = position.ceil() as usize;
    let weight = position - lower as f64;
    sorted[lower] * (1.0 - weight) + sorted[upper] * weight
}

/// A small deterministic generator.
///
/// Deliberately not a cryptographic one and deliberately not the system RNG:
/// the whole point is that the same trades and the same seed give the same
/// risk figure on every machine and every run.
struct Lcg(u64);

impl Lcg {
    fn new(seed: u64) -> Self {
        // Any non-zero state; a zero seed would otherwise stick.
        Self(seed ^ 0x9E37_79B9_7F4A_7C15)
    }

    fn next_u64(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        // Return the high bits: the low bits of an LCG have short periods.
        self.0 >> 16
    }

    /// Uniform in `0..bound`, rejecting the biased tail rather than taking a
    /// plain modulo — the bias is small but it is free to avoid.
    fn below(&mut self, bound: usize) -> usize {
        if bound <= 1 {
            return 0;
        }
        let bound = bound as u64;
        let limit = u64::MAX - (u64::MAX % bound);
        loop {
            let value = self.next_u64();
            if value < limit {
                return (value % bound) as usize;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Wins and losses alternating. The observed drawdown is about one losing
    /// trade deep — a benign ordering, and the kind a backtest is quietly
    /// lucky to have drawn.
    fn alternating() -> Vec<f64> {
        (0..40)
            .map(|i| if i % 2 == 0 { 0.05 } else { -0.04 })
            .collect()
    }

    /// Runs of five wins then five losses. Shuffling destroys the runs; block
    /// sampling keeps them, which is the whole difference between the methods.
    fn streaky() -> Vec<f64> {
        (0..60)
            .map(|i| if (i / 5) % 2 == 0 { 0.05 } else { -0.04 })
            .collect()
    }

    #[test]
    fn the_same_seed_gives_the_same_answer() {
        // A risk figure that changed every time it was computed could not be
        // argued with, and one that cannot be argued with cannot be trusted.
        let a = resample_trades(&streaky(), 500, ResampleMethod::Block, 5, 42).unwrap();
        let b = resample_trades(&streaky(), 500, ResampleMethod::Block, 5, 42).unwrap();
        assert_eq!(a, b);
        let c = resample_trades(&streaky(), 500, ResampleMethod::Block, 5, 43).unwrap();
        assert_ne!(a.drawdown_p95_pct, c.drawdown_p95_pct);
    }

    #[test]
    fn reordering_finds_a_worse_drawdown_than_the_one_observed() {
        // The point of the exercise. The observed sequence is one draw, and
        // usually a flattering one.
        let report = resample_trades(&alternating(), 2_000, ResampleMethod::Shuffle, 1, 7).unwrap();
        assert!(
            report.drawdown_p95_pct > report.observed_drawdown_pct,
            "observed {:.2}%, p95 {:.2}%",
            report.observed_drawdown_pct,
            report.drawdown_p95_pct
        );
    }

    #[test]
    fn shuffling_preserves_the_final_return() {
        // Every trade appears exactly once, so compounding is commutative and
        // the endpoint cannot move. Only the path does.
        let report = resample_trades(&streaky(), 200, ResampleMethod::Shuffle, 1, 3).unwrap();
        assert!(
            (report.return_p5_pct - report.return_p95_pct).abs() < 1e-6,
            "p5 {:.4} p95 {:.4}",
            report.return_p5_pct,
            report.return_p95_pct
        );
    }

    #[test]
    fn the_bootstrap_spreads_the_final_return() {
        // Sampling with replacement genuinely varies the outcome, which is what
        // gives a confidence interval to report.
        let report = resample_trades(&streaky(), 2_000, ResampleMethod::Block, 5, 3).unwrap();
        assert!(report.return_p95_pct > report.return_p5_pct + 1.0);
    }

    #[test]
    fn blocks_preserve_streaks_and_so_find_a_fatter_tail() {
        // Losing streaks are not independent draws. A method that breaks them
        // up understates exactly the tail it exists to measure: on data whose
        // losses come in runs of five, sampling five at a time can stack them
        // in ways free shuffling cannot.
        let shuffled = resample_trades(&streaky(), 3_000, ResampleMethod::Shuffle, 1, 11).unwrap();
        let blocked = resample_trades(&streaky(), 3_000, ResampleMethod::Block, 5, 11).unwrap();
        assert!(
            blocked.drawdown_p95_pct > shuffled.drawdown_p95_pct,
            "blocked {:.2}% vs shuffled {:.2}%",
            blocked.drawdown_p95_pct,
            shuffled.drawdown_p95_pct
        );
    }

    #[test]
    fn a_block_matching_the_data_s_own_period_washes_the_effect_out() {
        // Worth knowing before choosing a block length. This data alternates
        // in runs of five, so blocks of ten always contain five wins and five
        // losses whatever the offset — every draw is balanced by construction
        // and the tail collapses. A block length is a modelling choice, not a
        // free parameter.
        let period_aligned =
            resample_trades(&streaky(), 3_000, ResampleMethod::Block, 10, 11).unwrap();
        let shorter = resample_trades(&streaky(), 3_000, ResampleMethod::Block, 5, 11).unwrap();
        assert!(period_aligned.drawdown_p95_pct < shorter.drawdown_p95_pct);
    }

    #[test]
    fn a_block_as_long_as_the_sample_reproduces_the_observed_path() {
        // Each draw is then a rotation of the original sequence, so the
        // drawdown distribution collapses onto the observed figure. Not a
        // useful setting — a demonstration that the mechanism is what it says.
        let report = resample_trades(&streaky(), 200, ResampleMethod::Block, 60, 11).unwrap();
        assert!((report.drawdown_median_pct - report.observed_drawdown_pct).abs() < 1e-9);
        assert!((report.drawdown_worst_pct - report.observed_drawdown_pct).abs() < 1e-9);
    }

    #[test]
    fn a_ruinous_sequence_stops_at_zero() {
        // Compounding through zero would model a debt the exchange would have
        // liquidated long before.
        let wipeout = vec![-1.5_f64; 12];
        let report = resample_trades(&wipeout, 50, ResampleMethod::Shuffle, 1, 1).unwrap();
        assert_eq!(report.loss_probability, 1.0);
        assert!(report.return_p5_pct <= -100.0 + 1e-9);
    }

    #[test]
    fn too_few_trades_is_not_a_distribution() {
        // Below ten, the resampling describes the sample rather than the
        // strategy, and reporting a confident percentile from it would be
        // worse than reporting nothing.
        assert!(resample_trades(&[0.01; 9], 100, ResampleMethod::Block, 3, 1).is_none());
        assert!(resample_trades(&[0.01; 40], 0, ResampleMethod::Block, 3, 1).is_none());
    }

    #[test]
    fn a_steadily_profitable_strategy_rarely_loses() {
        let steady = vec![0.01_f64; 60];
        let report = resample_trades(&steady, 500, ResampleMethod::Block, 5, 5).unwrap();
        assert_eq!(report.loss_probability, 0.0);
        assert!(report.drawdown_p95_pct < 1e-9, "no losing trade, no drawdown");
    }

    #[test]
    fn the_generator_is_uniform_enough_to_shuffle_with() {
        // A biased modulo would quietly favour the low indices, and a shuffle
        // that favours the front is not a shuffle.
        let mut rng = Lcg::new(99);
        let mut buckets = [0usize; 10];
        for _ in 0..100_000 {
            buckets[rng.below(10)] += 1;
        }
        for count in buckets {
            assert!((count as f64 - 10_000.0).abs() < 600.0, "buckets {buckets:?}");
        }
    }
}
