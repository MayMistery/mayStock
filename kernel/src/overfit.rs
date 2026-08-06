//! How much of a backtest result is skill, and how much is having looked a lot.
//!
//! Search a thousand parameter combinations and the best one will have a
//! flattering Sharpe ratio whether or not any of them has an edge. This module
//! implements the two standard corrections for that, both from Bailey and
//! López de Prado:
//!
//! - the **Deflated Sharpe Ratio**, which asks how likely the observed Sharpe
//!   is under the null that the strategy has no skill, given how many were
//!   tried and how non-normal the returns are;
//! - the **Probability of Backtest Overfitting** via combinatorially symmetric
//!   cross-validation, which asks how often the in-sample winner turns out to
//!   be a below-median performer out of sample.
//!
//! They answer different questions and both are worth having. DSR can pass a
//! strategy whose edge is real but tiny; PBO catches the selection procedure
//! itself being broken, even when every individual backtest looks fine.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DeflatedSharpe {
    /// The Sharpe actually observed, annualised.
    pub observed: f64,
    /// The Sharpe the *best of N* coin-flips would be expected to show. The bar
    /// a grid-search winner has to clear before it deserves the name.
    #[serde(rename = "expectedMaxUnderNull")]
    pub expected_max_under_null: f64,
    /// Probability that the observed Sharpe exceeds the benchmark given the
    /// sample size, skew and kurtosis. Above ~0.95 is the usual bar.
    #[serde(rename = "probability")]
    pub probability: f64,
    /// True when the result survives the correction.
    pub significant: bool,
    pub trials: usize,
    pub observations: usize,
}

/// Expected highest Sharpe among `trials` strategies that have no skill at all.
///
/// The standard error of a Sharpe estimate is roughly `1/√years`, and the
/// maximum of N draws from that distribution grows with log N — so testing more
/// things raises the bar rather than improving the odds.
pub fn expected_max_sharpe_under_null(trials: usize, years: f64) -> f64 {
    if trials <= 1 || years <= 0.0 {
        return 0.0;
    }
    let n = trials as f64;
    const EULER: f64 = 0.577_215_664_901_532_9;
    let term = (1.0 - EULER) * inverse_normal_cdf(1.0 - 1.0 / n)
        + EULER * inverse_normal_cdf(1.0 - 1.0 / (n * std::f64::consts::E));
    term / years.sqrt()
}

/// Deflate an observed Sharpe for selection bias and non-normal returns.
///
/// `returns` are per-period (whatever period the Sharpe was annualised from);
/// `periods_per_year` converts between the two. Skew and kurtosis matter
/// because the Sharpe's own standard error depends on them: a strategy that
/// makes small gains and occasional large losses has a *less* reliable Sharpe
/// than its point estimate suggests, and that is precisely the return shape a
/// naive optimiser gravitates towards.
pub fn deflated_sharpe(
    returns: &[f64],
    observed_sharpe: f64,
    trials: usize,
    periods_per_year: f64,
) -> Option<DeflatedSharpe> {
    let clean: Vec<f64> = returns.iter().copied().filter(|v| v.is_finite()).collect();
    let n = clean.len();
    if n < 8 || periods_per_year <= 0.0 || !observed_sharpe.is_finite() {
        return None;
    }

    let years = n as f64 / periods_per_year;
    let benchmark = expected_max_sharpe_under_null(trials, years);

    let mean = clean.iter().sum::<f64>() / n as f64;
    let variance = clean.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / n as f64;
    let deviation = variance.sqrt();
    if deviation <= 0.0 {
        return None;
    }
    let skew = clean.iter().map(|v| ((v - mean) / deviation).powi(3)).sum::<f64>() / n as f64;
    let kurtosis = clean.iter().map(|v| ((v - mean) / deviation).powi(4)).sum::<f64>() / n as f64;

    // Both Sharpes are expressed per period here; annualising one side only
    // would compare two different quantities.
    let per_period = observed_sharpe / periods_per_year.sqrt();
    let benchmark_per_period = benchmark / periods_per_year.sqrt();

    // Standard error of the Sharpe estimator under non-normality
    // (Bailey & López de Prado, eq. 1).
    let variance_of_estimate = (1.0 - skew * per_period
        + (kurtosis - 1.0) / 4.0 * per_period * per_period)
        / (n as f64 - 1.0);
    if !(variance_of_estimate > 0.0) {
        return None;
    }
    let statistic = (per_period - benchmark_per_period) / variance_of_estimate.sqrt();
    let probability = normal_cdf(statistic);

    Some(DeflatedSharpe {
        observed: observed_sharpe,
        expected_max_under_null: benchmark,
        probability,
        significant: probability >= 0.95,
        trials,
        observations: n,
    })
}

// MARK: - Probability of backtest overfitting

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct OverfitProbability {
    /// Share of splits where the in-sample winner ranked below the out-of-sample
    /// median. 0 is ideal; anything approaching 0.5 means the selection carries
    /// no information at all.
    pub pbo: f64,
    /// Splits actually evaluated.
    pub splits: usize,
    /// Candidate strategies compared.
    pub candidates: usize,
}

/// Combinatorially symmetric cross-validation.
///
/// `returns_by_candidate[i]` is one candidate's per-period return series; every
/// series must be the same length, since the whole method rests on ranking the
/// same periods across candidates. The series is cut into `blocks` contiguous
/// chunks, every half-and-half split of those chunks is tried, and for each
/// split the in-sample winner's out-of-sample rank is recorded.
///
/// Contiguous blocks rather than shuffled observations: shuffling would break
/// the serial correlation that makes a trading strategy's returns what they
/// are, and would flatter every candidate equally.
pub fn probability_of_backtest_overfitting(
    returns_by_candidate: &[Vec<f64>],
    blocks: usize,
) -> Option<OverfitProbability> {
    let candidates = returns_by_candidate.len();
    if candidates < 2 || blocks < 4 || blocks % 2 != 0 {
        return None;
    }
    let length = returns_by_candidate[0].len();
    if length < blocks * 2 || returns_by_candidate.iter().any(|r| r.len() != length) {
        return None;
    }

    let block_size = length / blocks;
    let mut logits: Vec<f64> = Vec::new();

    // Every way of choosing `blocks / 2` of the blocks as the in-sample half.
    for mask in 0u32..(1u32 << blocks) {
        if mask.count_ones() as usize != blocks / 2 {
            continue;
        }
        let mut in_sample = vec![0.0; candidates];
        let mut out_sample = vec![0.0; candidates];
        for block in 0..blocks {
            let start = block * block_size;
            let end = if block == blocks - 1 { length } else { start + block_size };
            let target = if mask & (1 << block) != 0 {
                &mut in_sample
            } else {
                &mut out_sample
            };
            for (index, series) in returns_by_candidate.iter().enumerate() {
                target[index] += sharpe(&series[start..end]).unwrap_or(f64::NEG_INFINITY);
            }
        }

        let Some(winner) = argmax(&in_sample) else { continue };
        // Where the in-sample winner ranks out of sample.
        //
        // Ties take the mid-rank. Awarding the top of a tied group instead
        // would say the winner beat candidates it merely matched, and with
        // near-identical candidates — which is exactly what an over-fitted
        // grid search produces — that alone would drive the answer to zero.
        let better = out_sample.iter().filter(|v| **v > out_sample[winner]).count() as f64;
        let equal = out_sample.iter().filter(|v| **v == out_sample[winner]).count() as f64;
        let rank_from_top = better + (equal - 1.0) / 2.0;
        // Mapped into (0, 1) by dividing by n+1 rather than n, so neither end
        // is ever reached and the logit stays finite without a clamp.
        let omega = (candidates as f64 - rank_from_top) / (candidates as f64 + 1.0);
        logits.push((omega / (1.0 - omega)).ln());
    }

    if logits.is_empty() {
        return None;
    }
    // PBO is the share of splits whose winner landed below the median.
    let below = logits.iter().filter(|v| **v <= 0.0).count() as f64;
    Some(OverfitProbability {
        pbo: below / logits.len() as f64,
        splits: logits.len(),
        candidates,
    })
}

fn sharpe(returns: &[f64]) -> Option<f64> {
    if returns.len() < 2 {
        return None;
    }
    let n = returns.len() as f64;
    let mean = returns.iter().sum::<f64>() / n;
    let variance = returns.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / (n - 1.0);
    let deviation = variance.sqrt();
    (deviation > 0.0).then(|| mean / deviation)
}

fn argmax(values: &[f64]) -> Option<usize> {
    values
        .iter()
        .enumerate()
        .filter(|(_, v)| v.is_finite())
        .max_by(|a, b| a.1.partial_cmp(b.1).unwrap_or(std::cmp::Ordering::Equal))
        .map(|(index, _)| index)
}

// MARK: - Normal distribution

/// Φ(x), via the error function.
pub fn normal_cdf(x: f64) -> f64 {
    0.5 * (1.0 + erf(x / std::f64::consts::SQRT_2))
}

/// Abramowitz & Stegun 7.1.26 — max error 1.5e-7, far below anything that
/// changes a decision here.
fn erf(x: f64) -> f64 {
    let sign = if x < 0.0 { -1.0 } else { 1.0 };
    let x = x.abs();
    let t = 1.0 / (1.0 + 0.327_591_1 * x);
    let y = 1.0
        - (((((1.061_405_429 * t - 1.453_152_027) * t) + 1.421_413_741) * t - 0.284_496_736) * t
            + 0.254_829_592)
            * t
            * (-x * x).exp();
    sign * y
}

/// Φ⁻¹(p) — Acklam's rational approximation, accurate to ~1e-9.
pub fn inverse_normal_cdf(p: f64) -> f64 {
    if p <= 0.0 || p >= 1.0 {
        return 0.0;
    }
    const A: [f64; 6] = [
        -3.969_683_028_665_376e01, 2.209_460_984_245_205e02, -2.759_285_104_469_687e02,
        1.383_577_518_672_690e02, -3.066_479_806_614_716e01, 2.506_628_277_459_239e00,
    ];
    const B: [f64; 5] = [
        -5.447_609_879_822_406e01, 1.615_858_368_580_409e02, -1.556_989_798_598_866e02,
        6.680_131_188_771_972e01, -1.328_068_155_288_572e01,
    ];
    const C: [f64; 6] = [
        -7.784_894_002_430_293e-03, -3.223_964_580_411_365e-01, -2.400_758_277_161_838e00,
        -2.549_732_539_343_734e00, 4.374_664_141_464_968e00, 2.938_163_982_698_783e00,
    ];
    const D: [f64; 4] = [
        7.784_695_709_041_462e-03, 3.224_671_290_700_398e-01, 2.445_134_137_142_996e00,
        3.754_408_661_907_416e00,
    ];
    const LOW: f64 = 0.024_25;

    if p < LOW {
        let q = (-2.0 * p.ln()).sqrt();
        (((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0)
    } else if p <= 1.0 - LOW {
        let q = p - 0.5;
        let r = q * q;
        (((((A[0] * r + A[1]) * r + A[2]) * r + A[3]) * r + A[4]) * r + A[5]) * q
            / (((((B[0] * r + B[1]) * r + B[2]) * r + B[3]) * r + B[4]) * r + 1.0)
    } else {
        let q = (-2.0 * (1.0 - p).ln()).sqrt();
        -(((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A deterministic pseudo-random walk, so the tests do not depend on a
    /// random seed but still exercise a realistic return shape.
    fn returns(count: usize, drift: f64, seed: u64) -> Vec<f64> {
        let mut state = seed;
        (0..count)
            .map(|_| {
                state = state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
                let uniform = ((state >> 33) as f64) / ((1u64 << 31) as f64);
                drift + (uniform - 0.5) * 0.02
            })
            .collect()
    }

    #[test]
    fn testing_more_things_raises_the_bar() {
        let one = expected_max_sharpe_under_null(10, 3.0);
        let many = expected_max_sharpe_under_null(10_000, 3.0);
        assert!(many > one, "the best of 10 000 coin flips looks better");
    }

    #[test]
    fn more_data_lowers_the_bar() {
        assert!(
            expected_max_sharpe_under_null(1_000, 10.0)
                < expected_max_sharpe_under_null(1_000, 1.0)
        );
    }

    #[test]
    fn a_single_trial_needs_no_deflation() {
        assert_eq!(expected_max_sharpe_under_null(1, 3.0), 0.0);
    }

    #[test]
    fn a_strong_result_from_few_trials_survives() {
        let series = returns(2_000, 0.0006, 42);
        let observed = sharpe(&series).unwrap() * (365.0_f64).sqrt();
        let result = deflated_sharpe(&series, observed, 5, 365.0).unwrap();
        assert!(result.significant, "probability {}", result.probability);
    }

    #[test]
    fn the_same_result_from_ten_thousand_trials_does_not() {
        // The whole point: an identical backtest means less when it was picked
        // out of a grid search.
        let series = returns(2_000, 0.0006, 42);
        let observed = sharpe(&series).unwrap() * (365.0_f64).sqrt();
        let few = deflated_sharpe(&series, observed, 5, 365.0).unwrap();
        let many = deflated_sharpe(&series, observed, 100_000, 365.0).unwrap();
        assert!(many.probability < few.probability);
        assert!(many.expected_max_under_null > few.expected_max_under_null);
    }

    #[test]
    fn a_flat_series_cannot_be_deflated() {
        assert!(deflated_sharpe(&vec![0.0; 100], 1.0, 10, 365.0).is_none());
        assert!(deflated_sharpe(&[0.01, 0.02], 1.0, 10, 365.0).is_none(), "too few points");
    }

    #[test]
    fn a_fat_left_tail_costs_a_promising_result_its_confidence() {
        // Steady gains with one large loss: the shape a naive optimiser walks
        // straight into. Its Sharpe is a less reliable estimate than the point
        // value suggests, so a result that clears the bar clears it by less.
        let mut fat_tail = returns(500, 0.001, 11);
        fat_tail[250] = -0.25;
        let symmetric = returns(500, 0.001, 11);

        let a = deflated_sharpe(&fat_tail, 4.0, 100, 365.0).unwrap();
        let b = deflated_sharpe(&symmetric, 4.0, 100, 365.0).unwrap();
        assert!(a.probability < b.probability,
                "a fat left tail should deflate harder: {} vs {}", a.probability, b.probability);
        assert!(b.significant && !a.significant, "and it should change the verdict");
    }

    #[test]
    fn below_the_bar_a_noisy_estimate_cuts_the_other_way() {
        // Not a bug, and worth pinning down so nobody "fixes" it: the standard
        // error widens the interval in *both* directions. When the observed
        // Sharpe is already under the benchmark, a less reliable estimate makes
        // us less sure of that too, and the probability moves towards 0.5
        // rather than towards 0.
        let mut fat_tail = returns(500, 0.001, 11);
        fat_tail[250] = -0.25;
        let symmetric = returns(500, 0.001, 11);

        let a = deflated_sharpe(&fat_tail, 1.0, 100, 365.0).unwrap();
        let b = deflated_sharpe(&symmetric, 1.0, 100, 365.0).unwrap();
        assert!(a.probability > b.probability);
        // Either way the verdict is the same, which is what actually matters.
        assert!(!a.significant && !b.significant);
    }

    #[test]
    fn candidates_that_are_all_noise_are_a_coin_flip() {
        // Independent series with no edge: whichever wins in sample won by
        // luck, so its out-of-sample rank is a toss-up. Anything much below
        // 0.5 here would mean the method is finding signal in noise.
        let candidates: Vec<Vec<f64>> = (0..6).map(|seed| returns(400, 0.0, seed + 1)).collect();
        let result = probability_of_backtest_overfitting(&candidates, 6).unwrap();
        assert!(result.pbo > 0.25, "pbo {}", result.pbo);
    }

    #[test]
    fn identical_candidates_rank_in_the_middle() {
        // Every candidate is the same, so the "winner" beat nobody. Awarding
        // it the top rank would report a selection procedure with no
        // information as perfectly reliable.
        let series = returns(400, 0.0005, 7);
        let candidates = vec![series.clone(), series.clone(), series.clone(), series];
        let result = probability_of_backtest_overfitting(&candidates, 6).unwrap();
        assert!(result.pbo >= 0.99, "a tie is not a win: pbo {}", result.pbo);
    }

    #[test]
    fn a_genuinely_better_candidate_is_found_out_of_sample() {
        // One candidate really does have the edge, consistently. Selecting it
        // in sample should keep working out of sample.
        let mut candidates = vec![returns(600, 0.004, 1)];
        for seed in 2..6 {
            candidates.push(returns(600, -0.0005, seed));
        }
        let result = probability_of_backtest_overfitting(&candidates, 6).unwrap();
        assert!(result.pbo < 0.2, "pbo {}", result.pbo);
    }

    #[test]
    fn mismatched_series_are_refused() {
        // The method ranks the same periods across candidates; series of
        // different lengths cannot be ranked against each other at all.
        let a = returns(400, 0.0, 1);
        let b = returns(300, 0.0, 2);
        assert!(probability_of_backtest_overfitting(&[a, b], 6).is_none());
        // And an odd number of blocks cannot be split in half.
        let c = returns(400, 0.0, 3);
        let d = returns(400, 0.0, 4);
        assert!(probability_of_backtest_overfitting(&[c, d], 5).is_none());
    }

    #[test]
    fn the_normal_functions_agree_with_each_other() {
        for p in [0.01, 0.1, 0.5, 0.9, 0.975, 0.999] {
            let x = inverse_normal_cdf(p);
            assert!((normal_cdf(x) - p).abs() < 1e-6, "p={p} round-tripped to {}", normal_cdf(x));
        }
        assert!((normal_cdf(0.0) - 0.5).abs() < 1e-9);
        assert!((inverse_normal_cdf(0.975) - 1.959_963_98).abs() < 1e-6);
    }
}
