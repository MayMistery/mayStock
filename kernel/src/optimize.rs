//! The parameter sweep, run entirely inside the kernel.
//!
//! It used to run from Swift: for every grid point, re-encode the manifest,
//! call `ms_strategy_compile` to parse every expression again, run the
//! backtest, then JSON-decode a full result — six thousand equity points and
//! every trade — only to read six numbers off it. Five thousand times, in
//! sequence, on one core.
//!
//! Three observations collapse that:
//!
//! 1. **A parameter value does not change the parsed expression.** The AST
//!    depends on the source text, and only `params` differs between grid
//!    points. So a candidate is a clone of the compiled strategy with a
//!    different map — no lexing, no parsing, no validation.
//! 2. **The sweep only needs metrics.** Curves and trade lists are what makes
//!    a result expensive to serialise, and the sweep reads neither.
//! 3. **Grid points are independent.** Nothing is shared but the candles, which
//!    are read-only.
//!
//! What remains is a parallel loop over a cloned struct, and one small JSON
//! document at the end.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde::{Deserialize, Serialize};

use crate::backtest::{self, BacktestConfig, Metrics};
use crate::candle::Candle;
use crate::overfit::{DeflatedSharpe, OverfitProbability};
use crate::strategy::CompiledStrategy;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CandidateSummary {
    /// Index into the grid as supplied, so the caller can match it back to the
    /// parameter set it sent.
    pub index: usize,
    pub params: HashMap<String, f64>,
    pub metrics: Metrics,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SweepOutcome {
    pub candidates: Vec<CandidateSummary>,
    /// Grid points the kernel refused — a period outside its legal range, say.
    /// Reported rather than silently dropped: a sweep that skipped most of its
    /// grid found nothing, whatever the winner looks like.
    pub skipped: usize,
    /// Does the winner survive having been chosen from this many tries?
    pub deflated: Option<DeflatedSharpe>,
    /// Does the *selection procedure* carry any information?
    pub overfit: Option<OverfitProbability>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SweepRequest {
    #[serde(default)]
    pub config: BacktestConfig,
    /// One map per grid point.
    #[serde(default)]
    pub grid: Vec<HashMap<String, f64>>,
    /// Worker threads. 0 means "decide from the machine".
    #[serde(default)]
    pub threads: usize,
    /// Candidates to cross-validate. CSCV is combinatorial in the blocks and
    /// linear in the candidates, so the sample is capped.
    #[serde(rename = "crossValidationSample", default = "default_sample")]
    pub cross_validation_sample: usize,
    #[serde(default = "default_blocks")]
    pub blocks: usize,
}

fn default_sample() -> usize {
    24
}
fn default_blocks() -> usize {
    8
}

/// Evaluate every grid point and assess the winner.
pub fn sweep(
    strategy: &CompiledStrategy,
    candles: &[Candle],
    request: &SweepRequest,
) -> SweepOutcome {
    let skipped = AtomicUsize::new(0);
    let mut candidates: Vec<CandidateSummary> = run_grid(
        strategy,
        candles,
        &request.config,
        &request.grid,
        request.threads,
        &skipped,
        |index, params, result| CandidateSummary {
            index,
            params,
            metrics: result.metrics,
        },
    );

    // Ranked by Sharpe here only to pick who gets cross-validated. The caller
    // applies its own objective and constraints to the full list; this ordering
    // does not leak into the result.
    candidates.sort_by(|a, b| {
        b.metrics
            .sharpe
            .partial_cmp(&a.metrics.sharpe)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // Second pass for return series, over a bounded sample.
    //
    // Re-running two dozen backtests costs less than holding five thousand
    // equity curves in memory — and holding them was a real regression, not a
    // hypothetical one: a 5 000-point sweep over 6 000 bars is a quarter of a
    // gigabyte of f64 that exists only to be thrown away.
    let sample = sample_indices(candidates.len(), request.cross_validation_sample);
    let sampled_grid: Vec<HashMap<String, f64>> = sample
        .iter()
        .map(|position| candidates[*position].params.clone())
        .collect();
    let series: Vec<Vec<f64>> = run_grid(
        strategy,
        candles,
        &request.config,
        &sampled_grid,
        request.threads,
        &AtomicUsize::new(0),
        |_, _, result| period_returns(&result.equity_curve),
    );

    let winner = candidates.first();
    let deflated = winner.and_then(|best| {
        // The winner is the first entry of the sample by construction, since
        // the sample always includes index 0.
        let returns = series.first()?;
        let periods = periods_per_year(returns.len(), best.metrics.span_days);
        crate::overfit::deflated_sharpe(
            returns,
            best.metrics.sharpe,
            request.grid.len().max(1),
            periods,
        )
    });

    let usable: Vec<Vec<f64>> = series.into_iter().filter(|s| s.len() >= 32).collect();
    let overfit = crate::overfit::probability_of_backtest_overfitting(&usable, request.blocks);

    SweepOutcome {
        candidates,
        skipped: skipped.load(Ordering::Relaxed),
        deflated,
        overfit,
    }
}

/// Run every grid point in parallel, mapping each result through `collect`.
fn run_grid<T: Send>(
    strategy: &CompiledStrategy,
    candles: &[Candle],
    config: &BacktestConfig,
    grid: &[HashMap<String, f64>],
    threads: usize,
    skipped: &AtomicUsize,
    collect: impl Fn(usize, HashMap<String, f64>, backtest::BacktestResult) -> T + Sync,
) -> Vec<T> {
    if grid.is_empty() {
        return Vec::new();
    }
    let workers = resolve_threads(threads, grid.len());
    let next = AtomicUsize::new(0);
    // One slot per grid point, so results land in grid order regardless of
    // which worker finished first. A sweep whose output depended on thread
    // scheduling would not be reproducible, and a backtest that is not
    // reproducible is not evidence.
    let slots: Vec<std::sync::Mutex<Option<T>>> =
        (0..grid.len()).map(|_| std::sync::Mutex::new(None)).collect();

    std::thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| loop {
                let index = next.fetch_add(1, Ordering::Relaxed);
                if index >= grid.len() {
                    break;
                }
                let params = &grid[index];
                let Some(variant) = strategy.with_params(params) else {
                    skipped.fetch_add(1, Ordering::Relaxed);
                    continue;
                };
                match backtest::run(&variant, candles, config) {
                    Ok(result) => {
                        let value = collect(index, params.clone(), result);
                        *slots[index].lock().unwrap() = Some(value);
                    }
                    Err(_) => {
                        skipped.fetch_add(1, Ordering::Relaxed);
                    }
                }
            });
        }
    });

    slots
        .into_iter()
        .filter_map(|slot| slot.into_inner().unwrap())
        .collect()
}

fn resolve_threads(requested: usize, work: usize) -> usize {
    let available = if requested > 0 {
        requested
    } else {
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1)
    };
    available.clamp(1, work.max(1))
}

/// Period-over-period returns from an equity curve.
pub fn period_returns(curve: &[backtest::EquityPoint]) -> Vec<f64> {
    curve
        .windows(2)
        .filter(|pair| pair[0].equity > 0.0)
        .map(|pair| pair[1].equity / pair[0].equity - 1.0)
        .collect()
}

/// Observations per year implied by the curve.
///
/// Derived from the curve rather than from the bar interval, because the curve
/// excludes warm-up bars — annualising by the nominal interval would treat a
/// series as longer than it is.
pub fn periods_per_year(observations: usize, span_days: f64) -> f64 {
    if span_days <= 0.0 || observations < 2 {
        return 365.0;
    }
    observations as f64 / (span_days / 365.25)
}

/// Positions to cross-validate, spread evenly across the ranking.
///
/// Always includes the winner, then samples down the list. Taking only the top
/// would compare winners against winners and understate exactly the problem the
/// statistic exists to detect.
fn sample_indices(count: usize, limit: usize) -> Vec<usize> {
    if count == 0 {
        return Vec::new();
    }
    if count <= limit {
        return (0..count).collect();
    }
    let stride = count as f64 / limit as f64;
    let mut out: Vec<usize> = (0..limit)
        .map(|i| ((i as f64 * stride) as usize).min(count - 1))
        .collect();
    out.dedup();
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::strategy::Manifest;

    fn strategy() -> CompiledStrategy {
        let json = r#"{"id":"t","name":"t","market":{"instId":"BTC-USDT","bar":"1H"},
             "params":[{"name":"fast","default":5,"min":2,"max":40},
                       {"name":"slow","default":20,"min":5,"max":80}],
             "signals":{"longEntry":"ema(close, fast) > ema(close, slow)",
                        "longExit":"ema(close, fast) < ema(close, slow)"},
             "sizing":{"mode":"equityPct","value":100}}"#;
        let manifest: Manifest = serde_json::from_str(json).unwrap();
        CompiledStrategy::compile(manifest, &[]).unwrap()
    }

    fn candles(count: i64) -> Vec<Candle> {
        (0..count)
            .map(|i| {
                let base = 100.0 + (i as f64 * 0.15).sin() * 12.0 + i as f64 * 0.02;
                Candle {
                    ts_ms: i * 3_600_000,
                    open: base,
                    high: base + 1.0,
                    low: base - 1.0,
                    close: base + 0.2,
                    volume: 10.0,
                    confirmed: 1,
                }
            })
            .collect()
    }

    fn grid(points: usize) -> Vec<HashMap<String, f64>> {
        (0..points)
            .map(|i| {
                HashMap::from([
                    ("fast".to_string(), 3.0 + (i % 8) as f64),
                    ("slow".to_string(), 20.0 + (i / 8) as f64 * 3.0),
                ])
            })
            .collect()
    }

    #[test]
    fn every_grid_point_is_evaluated() {
        let request = SweepRequest {
            config: BacktestConfig::default(),
            grid: grid(16),
            threads: 4,
            cross_validation_sample: 8,
            blocks: 8,
        };
        let outcome = sweep(&strategy(), &candles(900), &request);
        assert_eq!(outcome.candidates.len(), 16);
        assert_eq!(outcome.skipped, 0);
    }

    #[test]
    fn results_do_not_depend_on_thread_count() {
        // A sweep whose output changed with the machine it ran on would not be
        // reproducible, and a backtest that is not reproducible is not evidence.
        let bars = candles(900);
        let make = |threads| SweepRequest {
            config: BacktestConfig::default(),
            grid: grid(16),
            threads,
            cross_validation_sample: 8,
            blocks: 8,
        };
        let one = sweep(&strategy(), &bars, &make(1));
        let many = sweep(&strategy(), &bars, &make(8));
        assert_eq!(one.candidates.len(), many.candidates.len());
        for (a, b) in one.candidates.iter().zip(&many.candidates) {
            assert_eq!(a.index, b.index);
            assert_eq!(a.params, b.params);
            assert!((a.metrics.sharpe - b.metrics.sharpe).abs() < 1e-12);
            assert!((a.metrics.total_return_pct - b.metrics.total_return_pct).abs() < 1e-12);
        }
    }

    #[test]
    fn swapping_parameters_matches_a_full_recompile() {
        // The whole optimisation rests on this: cloning the compiled strategy
        // and swapping `params` must produce exactly what re-parsing the
        // manifest would.
        let bars = candles(900);
        let params = HashMap::from([("fast".to_string(), 9.0), ("slow".to_string(), 31.0)]);

        let swapped = strategy().with_params(&params).unwrap();

        let json = r#"{"id":"t","name":"t","market":{"instId":"BTC-USDT","bar":"1H"},
             "params":[{"name":"fast","default":9,"min":2,"max":40},
                       {"name":"slow","default":31,"min":5,"max":80}],
             "signals":{"longEntry":"ema(close, fast) > ema(close, slow)",
                        "longExit":"ema(close, fast) < ema(close, slow)"},
             "sizing":{"mode":"equityPct","value":100}}"#;
        let manifest: Manifest = serde_json::from_str(json).unwrap();
        let recompiled = CompiledStrategy::compile(manifest, &[]).unwrap();

        assert_eq!(swapped.warmup_bars, recompiled.warmup_bars);
        let a = backtest::run(&swapped, &bars, &BacktestConfig::default()).unwrap();
        let b = backtest::run(&recompiled, &bars, &BacktestConfig::default()).unwrap();
        assert!((a.metrics.total_return_pct - b.metrics.total_return_pct).abs() < 1e-12);
        assert_eq!(a.trades.len(), b.trades.len());
    }

    #[test]
    fn a_value_outside_the_declared_range_is_clamped_not_honoured() {
        // A caller cannot widen a parameter's domain by sending a number from
        // outside it — the manifest's own loader clamps, and a sweep that did
        // not would test settings the strategy never declared.
        let swapped = strategy()
            .with_params(&HashMap::from([
                ("fast".to_string(), 0.0),
                ("slow".to_string(), 9_999.0),
            ]))
            .unwrap();
        assert_eq!(swapped.params["fast"], 2.0, "clamped up to the declared min");
        assert_eq!(swapped.params["slow"], 80.0, "clamped down to the declared max");
    }

    #[test]
    fn an_unevaluable_grid_point_is_skipped_and_counted() {
        // A period of zero is not a strategy. The sweep carries on but says so,
        // because a sweep that skipped most of its grid found nothing whatever
        // the winner looks like.
        let json = r#"{"id":"t","name":"t","market":{"instId":"BTC-USDT","bar":"1H"},
             "params":[{"name":"period","default":10}],
             "signals":{"longEntry":"close > ema(close, period)"},
             "sizing":{"mode":"equityPct","value":100}}"#;
        let manifest: Manifest = serde_json::from_str(json).unwrap();
        let unbounded = CompiledStrategy::compile(manifest, &[]).unwrap();

        let request = SweepRequest {
            config: BacktestConfig::default(),
            grid: vec![
                HashMap::from([("period".to_string(), 10.0)]),
                HashMap::from([("period".to_string(), 0.0)]),
                HashMap::from([("period".to_string(), f64::NAN)]),
            ],
            threads: 2,
            cross_validation_sample: 4,
            blocks: 8,
        };
        let outcome = sweep(&unbounded, &candles(600), &request);
        assert_eq!(outcome.candidates.len(), 1);
        assert_eq!(outcome.skipped, 2);
    }

    #[test]
    fn the_sample_spans_the_ranking() {
        assert_eq!(sample_indices(5, 24), vec![0, 1, 2, 3, 4]);
        let spread = sample_indices(100, 5);
        assert_eq!(spread.first(), Some(&0), "the winner is always included");
        assert!(spread.last().unwrap() > &50, "and the weak end is represented");
        assert_eq!(spread.len(), 5);
        assert!(sample_indices(0, 8).is_empty());
    }

    #[test]
    fn an_empty_grid_is_not_an_error() {
        let request = SweepRequest {
            config: BacktestConfig::default(),
            grid: Vec::new(),
            threads: 0,
            cross_validation_sample: 8,
            blocks: 8,
        };
        let outcome = sweep(&strategy(), &candles(300), &request);
        assert!(outcome.candidates.is_empty());
        assert!(outcome.deflated.is_none());
        assert!(outcome.overfit.is_none());
    }
}

#[cfg(test)]
mod bench {
    use super::*;
    use super::tests_support::*;

    /// Not a correctness test — a stopwatch. Run explicitly:
    /// `cargo test --release -- --ignored --nocapture sweep_throughput`
    #[test]
    #[ignore]
    fn sweep_throughput() {
        let strategy = bench_strategy();
        let bars = bench_candles(6_000);
        let grid = bench_grid(1_000);

        for threads in [1usize, 0] {
            let request = SweepRequest {
                config: BacktestConfig::default(),
                grid: grid.clone(),
                threads,
                cross_validation_sample: 24,
                blocks: 8,
            };
            let started = std::time::Instant::now();
            let outcome = sweep(&strategy, &bars, &request);
            let elapsed = started.elapsed();
            println!(
                "threads={:<4} candidates={} elapsed={:?} ({:.3} ms/candidate)",
                if threads == 0 { "auto".to_string() } else { threads.to_string() },
                outcome.candidates.len(),
                elapsed,
                elapsed.as_secs_f64() * 1000.0 / outcome.candidates.len() as f64,
            );
        }

        // What the old per-candidate path cost on top of the backtest itself:
        // a full manifest re-parse, and serialising a result whose curve and
        // trade list nobody read.
        let json = r#"{"id":"b","name":"b","market":{"instId":"BTC-USDT","bar":"1H"},
             "params":[{"name":"fast","default":5,"min":2,"max":60},
                       {"name":"slow","default":20,"min":5,"max":200}],
             "signals":{"longEntry":"ema(close, fast) > ema(close, slow)",
                        "longExit":"ema(close, fast) < ema(close, slow)"},
             "sizing":{"mode":"equityPct","value":100}}"#;
        let started = std::time::Instant::now();
        for _ in 0..100 {
            let manifest: crate::strategy::Manifest = serde_json::from_str(json).unwrap();
            let compiled = CompiledStrategy::compile(manifest, &[]).unwrap();
            let result = backtest::run(&compiled, &bars, &BacktestConfig::default()).unwrap();
            let _ = serde_json::to_string(&result).unwrap();
        }
        let old = started.elapsed();
        println!(
            "old path (reparse + full-result JSON) = {:.3} ms/candidate",
            old.as_secs_f64() * 1000.0 / 100.0
        );
    }
}

#[cfg(test)]
mod tests_support {
    use super::*;
    use crate::strategy::Manifest;

    pub fn bench_strategy() -> CompiledStrategy {
        let json = r#"{"id":"b","name":"b","market":{"instId":"BTC-USDT","bar":"1H"},
             "params":[{"name":"fast","default":5,"min":2,"max":60},
                       {"name":"slow","default":20,"min":5,"max":200}],
             "signals":{"longEntry":"ema(close, fast) > ema(close, slow)",
                        "longExit":"ema(close, fast) < ema(close, slow)"},
             "sizing":{"mode":"equityPct","value":100}}"#;
        let manifest: Manifest = serde_json::from_str(json).unwrap();
        CompiledStrategy::compile(manifest, &[]).unwrap()
    }

    pub fn bench_candles(count: i64) -> Vec<Candle> {
        (0..count)
            .map(|i| {
                let base = 100.0 + (i as f64 * 0.05).sin() * 20.0 + i as f64 * 0.01;
                Candle {
                    ts_ms: i * 3_600_000,
                    open: base,
                    high: base + 1.5,
                    low: base - 1.5,
                    close: base + 0.3,
                    volume: 10.0,
                    confirmed: 1,
                }
            })
            .collect()
    }

    pub fn bench_grid(points: usize) -> Vec<HashMap<String, f64>> {
        (0..points)
            .map(|i| {
                HashMap::from([
                    ("fast".to_string(), 2.0 + (i % 40) as f64),
                    ("slow".to_string(), 20.0 + (i / 40) as f64 * 5.0),
                ])
            })
            .collect()
    }
}
