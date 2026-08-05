//! Performance statistics for one backtest run.
//!
//! The metric set follows what Freqtrade and Jesse report — the vocabulary
//! traders already read — plus a buy-and-hold benchmark, so a strategy is
//! judged against simply owning the asset rather than against zero.

use serde::{Deserialize, Serialize};

use super::{EquityPoint, Trade};

/// `f64::INFINITY` is not representable in JSON. Profit factor and payoff ratio
/// are legitimately infinite when there are no losing trades, so they serialise
/// as `null` and the Swift side shows "∞" rather than a fabricated number.
fn finite_or_null<S: serde::Serializer>(value: &f64, s: S) -> Result<S::Ok, S::Error> {
    if value.is_finite() {
        s.serialize_f64(*value)
    } else {
        s.serialize_none()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Metrics {
    // Returns
    #[serde(rename = "totalReturnPct")]
    pub total_return_pct: f64,
    #[serde(rename = "absolutePnL")]
    pub absolute_pnl: f64,
    pub cagr: f64,
    #[serde(rename = "spanDays")]
    pub span_days: f64,

    // Risk
    #[serde(rename = "maxDrawdownPct")]
    pub max_drawdown_pct: f64,
    #[serde(rename = "maxDrawdownAbsolute")]
    pub max_drawdown_absolute: f64,
    #[serde(rename = "maxDrawdownBars")]
    pub max_drawdown_bars: usize,
    #[serde(rename = "annualisedVolatilityPct")]
    pub annualised_volatility_pct: f64,
    pub sharpe: f64,
    pub sortino: f64,
    pub calmar: f64,

    // Trades
    #[serde(rename = "tradeCount")]
    pub trade_count: usize,
    #[serde(rename = "winRate")]
    pub win_rate: f64,
    #[serde(rename = "profitFactor", serialize_with = "finite_or_null")]
    pub profit_factor: f64,
    #[serde(rename = "expectancyPct")]
    pub expectancy_pct: f64,
    #[serde(rename = "payoffRatio", serialize_with = "finite_or_null")]
    pub payoff_ratio: f64,
    #[serde(rename = "averageHoldBars")]
    pub average_hold_bars: f64,
    #[serde(rename = "maxConsecutiveLosses")]
    pub max_consecutive_losses: usize,
    #[serde(rename = "largestWinPct")]
    pub largest_win_pct: f64,
    #[serde(rename = "largestLossPct")]
    pub largest_loss_pct: f64,

    // Costs & exposure
    #[serde(rename = "feesPaid")]
    pub fees_paid: f64,
    #[serde(rename = "fundingPaid")]
    pub funding_paid: f64,
    #[serde(rename = "exposurePct")]
    pub exposure_pct: f64,

    // Benchmark
    #[serde(rename = "buyHoldReturnPct")]
    pub buy_hold_return_pct: f64,

    #[serde(rename = "freeParameterCount")]
    pub free_parameter_count: usize,
}

impl Metrics {
    pub fn compute(
        trades: &[Trade],
        equity_curve: &[EquityPoint],
        initial_capital: f64,
        bar: &str,
        free_parameter_count: usize,
    ) -> Self {
        let final_equity = equity_curve
            .last()
            .map(|p| p.equity)
            .unwrap_or(initial_capital);
        let absolute_pnl = final_equity - initial_capital;
        let total_return_pct = if initial_capital > 0.0 {
            absolute_pnl / initial_capital * 100.0
        } else {
            0.0
        };

        let span_ms = match (equity_curve.first(), equity_curve.last()) {
            (Some(first), Some(last)) => (last.ts - first.ts) as f64,
            _ => 0.0,
        };
        let span_days = span_ms / 86_400_000.0;
        let years = span_days / 365.25;
        let cagr = if years > 0.0 && initial_capital > 0.0 && final_equity > 0.0 {
            ((final_equity / initial_capital).powf(1.0 / years) - 1.0) * 100.0
        } else {
            0.0
        };

        // --- Drawdown over the equity curve.
        let mut peak = initial_capital;
        let mut peak_index = 0usize;
        let mut worst_pct = 0.0;
        let mut worst_absolute = 0.0;
        let mut worst_bars = 0usize;
        for (index, point) in equity_curve.iter().enumerate() {
            if point.equity > peak {
                peak = point.equity;
                peak_index = index;
            }
            let drop = peak - point.equity;
            if peak > 0.0 && drop / peak * 100.0 > worst_pct {
                worst_pct = drop / peak * 100.0;
                worst_absolute = drop;
                worst_bars = index - peak_index;
            }
        }

        // --- Risk-adjusted returns from per-bar equity changes.
        let mut bar_returns: Vec<f64> = Vec::with_capacity(equity_curve.len().saturating_sub(1));
        for index in 1..equity_curve.len() {
            let previous = equity_curve[index - 1].equity;
            if previous > 0.0 {
                bar_returns.push(equity_curve[index].equity / previous - 1.0);
            }
        }
        let bars_per_year = 365.25 * 86_400.0 / crate::strategy::bar_seconds(bar);
        let mean = mean(&bar_returns);
        let deviation = standard_deviation(&bar_returns, mean);
        let downside = downside_deviation(&bar_returns);
        let annualised_volatility_pct = deviation * bars_per_year.sqrt() * 100.0;
        let sharpe = if deviation > 0.0 {
            mean / deviation * bars_per_year.sqrt()
        } else {
            0.0
        };
        let sortino = if downside > 0.0 {
            mean / downside * bars_per_year.sqrt()
        } else {
            0.0
        };
        let calmar = if worst_pct > 0.0 { cagr / worst_pct } else { 0.0 };

        // --- Trade statistics.
        let wins: Vec<&Trade> = trades.iter().filter(|t| t.net_pnl > 0.0).collect();
        let losses: Vec<&Trade> = trades.iter().filter(|t| t.net_pnl <= 0.0).collect();
        let win_rate = if trades.is_empty() {
            0.0
        } else {
            wins.len() as f64 / trades.len() as f64 * 100.0
        };

        let gross_profit: f64 = wins.iter().map(|t| t.net_pnl).sum();
        let gross_loss: f64 = losses.iter().map(|t| t.net_pnl).sum::<f64>().abs();
        let profit_factor = if gross_loss > 0.0 {
            gross_profit / gross_loss
        } else if gross_profit > 0.0 {
            f64::INFINITY
        } else {
            0.0
        };

        let expectancy_pct = if trades.is_empty() {
            0.0
        } else {
            trades.iter().map(|t| t.return_pct).sum::<f64>() / trades.len() as f64
        };
        let average_win = if wins.is_empty() {
            0.0
        } else {
            gross_profit / wins.len() as f64
        };
        let average_loss = if losses.is_empty() {
            0.0
        } else {
            gross_loss / losses.len() as f64
        };
        let payoff_ratio = if average_loss > 0.0 {
            average_win / average_loss
        } else if average_win > 0.0 {
            f64::INFINITY
        } else {
            0.0
        };

        let average_hold_bars = if trades.is_empty() {
            0.0
        } else {
            trades.iter().map(|t| t.bars).sum::<usize>() as f64 / trades.len() as f64
        };
        let largest_win_pct = trades.iter().map(|t| t.return_pct).fold(f64::NEG_INFINITY, f64::max);
        let largest_loss_pct = trades.iter().map(|t| t.return_pct).fold(f64::INFINITY, f64::min);

        let mut streak = 0usize;
        let mut worst_streak = 0usize;
        for trade in trades {
            streak = if trade.net_pnl <= 0.0 { streak + 1 } else { 0 };
            worst_streak = worst_streak.max(streak);
        }

        let fees_paid: f64 = trades.iter().map(|t| t.fees).sum();
        let funding_paid: f64 = trades.iter().map(|t| t.funding).sum();
        let bars_in_market: usize = trades.iter().map(|t| t.bars.max(1)).sum();
        let exposure_pct = if equity_curve.len() > 1 {
            (bars_in_market as f64 / equity_curve.len() as f64 * 100.0).min(100.0)
        } else {
            0.0
        };

        // --- Benchmark: hold the instrument for the same window.
        let buy_hold_return_pct = match (equity_curve.first(), equity_curve.last()) {
            (Some(first), Some(last)) if first.price > 0.0 => {
                (last.price / first.price - 1.0) * 100.0
            }
            _ => 0.0,
        };

        Self {
            total_return_pct,
            absolute_pnl,
            cagr,
            span_days,
            max_drawdown_pct: worst_pct,
            max_drawdown_absolute: worst_absolute,
            max_drawdown_bars: worst_bars,
            annualised_volatility_pct,
            sharpe,
            sortino,
            calmar,
            trade_count: trades.len(),
            win_rate,
            profit_factor,
            expectancy_pct,
            payoff_ratio,
            average_hold_bars,
            max_consecutive_losses: worst_streak,
            // An empty trade list has no largest win or loss; report zero
            // rather than the ±infinity the folds start from.
            largest_win_pct: if trades.is_empty() { 0.0 } else { largest_win_pct },
            largest_loss_pct: if trades.is_empty() { 0.0 } else { largest_loss_pct },
            fees_paid,
            funding_paid,
            exposure_pct,
            buy_hold_return_pct,
            free_parameter_count: free_parameter_count.max(1),
        }
    }

    /// Geometric average daily return in percent — the number to compare
    /// against a "0.5% a day" target. Compounding matters: 0.5% daily is
    /// +16.1% over 30 days, not +15%.
    pub fn daily_return_pct(&self) -> f64 {
        if self.span_days <= 0.0 || self.total_return_pct <= -100.0 {
            return 0.0;
        }
        ((1.0 + self.total_return_pct / 100.0).powf(1.0 / self.span_days) - 1.0) * 100.0
    }

    pub fn excess_return_pct(&self) -> f64 {
        self.total_return_pct - self.buy_hold_return_pct
    }

    /// Annualising a handful of days produces absurd numbers; below a month the
    /// CAGR figure should not drive any decision.
    pub fn annualisation_reliable(&self) -> bool {
        self.span_days >= 30.0
    }
}

fn mean(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.iter().sum::<f64>() / values.len() as f64
}

/// Sample standard deviation (n−1), the convention for return series.
fn standard_deviation(values: &[f64], m: f64) -> f64 {
    if values.len() <= 1 {
        return 0.0;
    }
    let sum_squares: f64 = values.iter().map(|v| (v - m) * (v - m)).sum();
    (sum_squares / (values.len() - 1) as f64).sqrt()
}

/// Root-mean-square of the negative returns only — the denominator of Sortino.
fn downside_deviation(values: &[f64]) -> f64 {
    if values.len() <= 1 {
        return 0.0;
    }
    let sum_squares: f64 = values.iter().map(|v| v.min(0.0) * v.min(0.0)).sum();
    (sum_squares / (values.len() - 1) as f64).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::decide::Direction;

    fn curve(equities: &[f64]) -> Vec<EquityPoint> {
        equities
            .iter()
            .enumerate()
            .map(|(i, e)| EquityPoint {
                ts: i as i64 * 86_400_000,
                equity: *e,
                price: 100.0 + i as f64,
            })
            .collect()
    }

    fn trade(net: f64, return_pct: f64, bars: usize) -> Trade {
        Trade {
            id: 1,
            direction: Direction::Long,
            entry_ts: 0,
            exit_ts: 1,
            entry_price: 100.0,
            exit_price: 100.0 + net,
            quantity: 1.0,
            notional: 100.0,
            gross_pnl: net,
            fees: 0.1,
            funding: 0.0,
            net_pnl: net,
            return_pct,
            bars,
            exit_reason: super::super::ExitReason::Signal,
        }
    }

    #[test]
    fn an_empty_run_is_all_zeroes_not_infinities() {
        let m = Metrics::compute(&[], &[], 10_000.0, "1H", 1);
        assert_eq!(m.total_return_pct, 0.0);
        assert_eq!(m.trade_count, 0);
        assert_eq!(m.largest_win_pct, 0.0);
        assert_eq!(m.largest_loss_pct, 0.0);
        assert!(m.sharpe.is_finite());
        assert_eq!(m.free_parameter_count, 1, "never divide by zero later");
    }

    #[test]
    fn drawdown_measures_peak_to_trough() {
        // 100 → 120 → 90 → 110: worst drawdown is 120 → 90 = 25%.
        let m = Metrics::compute(&[], &curve(&[100.0, 120.0, 90.0, 110.0]), 100.0, "1D", 1);
        assert!((m.max_drawdown_pct - 25.0).abs() < 1e-9);
        assert!((m.max_drawdown_absolute - 30.0).abs() < 1e-9);
        assert_eq!(m.max_drawdown_bars, 1);
    }

    #[test]
    fn a_monotonic_curve_has_no_drawdown() {
        let m = Metrics::compute(&[], &curve(&[100.0, 110.0, 120.0]), 100.0, "1D", 1);
        assert_eq!(m.max_drawdown_pct, 0.0);
    }

    #[test]
    fn profit_factor_is_infinite_without_losses_and_serialises_as_null() {
        let m = Metrics::compute(&[trade(10.0, 1.0, 3)], &curve(&[100.0, 110.0]), 100.0, "1D", 1);
        assert!(m.profit_factor.is_infinite());
        let json = serde_json::to_string(&m).unwrap();
        assert!(json.contains("\"profitFactor\":null"), "{json}");
    }

    #[test]
    fn win_rate_and_streaks_count_correctly() {
        let trades = vec![
            trade(10.0, 1.0, 1),
            trade(-5.0, -0.5, 1),
            trade(-5.0, -0.5, 1),
            trade(20.0, 2.0, 1),
            trade(-1.0, -0.1, 1),
        ];
        let m = Metrics::compute(&trades, &curve(&[100.0, 119.0]), 100.0, "1D", 1);
        assert_eq!(m.trade_count, 5);
        assert!((m.win_rate - 40.0).abs() < 1e-9);
        assert_eq!(m.max_consecutive_losses, 2);
        assert!((m.largest_win_pct - 2.0).abs() < 1e-9);
        assert!((m.largest_loss_pct - (-0.5)).abs() < 1e-9);
    }

    #[test]
    fn daily_return_compounds() {
        // +16.1% over 30 days is 0.5% a day, not 0.537%.
        let m = Metrics::compute(
            &[],
            &(0..=30)
                .map(|i| EquityPoint {
                    ts: i as i64 * 86_400_000,
                    equity: 100.0 * 1.005f64.powi(i),
                    price: 100.0,
                })
                .collect::<Vec<_>>(),
            100.0,
            "1D",
            1,
        );
        assert!((m.daily_return_pct() - 0.5).abs() < 1e-6, "{}", m.daily_return_pct());
    }

    #[test]
    fn the_benchmark_is_buy_and_hold_over_the_same_window() {
        // curve() prices run 100, 101, 102 → +2%.
        let m = Metrics::compute(&[], &curve(&[100.0, 100.0, 100.0]), 100.0, "1D", 1);
        assert!((m.buy_hold_return_pct - 2.0).abs() < 1e-9);
        assert!((m.excess_return_pct() - (-2.0)).abs() < 1e-9);
    }

    #[test]
    fn short_windows_are_flagged_as_unreliable_to_annualise() {
        let short = Metrics::compute(&[], &curve(&[100.0, 101.0]), 100.0, "1D", 1);
        assert!(!short.annualisation_reliable());
        let long: Vec<EquityPoint> = (0..40)
            .map(|i| EquityPoint {
                ts: i as i64 * 86_400_000,
                equity: 100.0,
                price: 100.0,
            })
            .collect();
        assert!(Metrics::compute(&[], &long, 100.0, "1D", 1).annualisation_reliable());
    }

    #[test]
    fn a_flat_curve_has_zero_sharpe_not_a_nan() {
        let m = Metrics::compute(&[], &curve(&[100.0; 20]), 100.0, "1D", 1);
        assert_eq!(m.sharpe, 0.0);
        assert_eq!(m.sortino, 0.0);
        assert_eq!(m.calmar, 0.0);
    }
}
