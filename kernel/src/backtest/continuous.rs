//! Bar-by-bar simulation for strategies that hold a *scaled* position rather
//! than switching in and out.
//!
//! Same execution discipline as the binary path: exposure is computed on the
//! close of bar i from data up to i, and the resulting trade fills at the open
//! of bar i+1 with slippage and fees on the traded notional only. Positions are
//! adjusted incrementally, so holding through a flat signal costs nothing —
//! which is what makes a turnover comparison meaningful.

use super::{
    bucket_funding, empty_result, BacktestConfig, BacktestResult, EquityPoint, ExitReason, Metrics,
    Trade,
};
use crate::candle::Candle;
use crate::decide::{realised_volatility, volatility_scale, Direction};
use crate::expr::eval::Evaluator;
use crate::expr::ExprResult;
use crate::strategy::{CompiledStrategy, InstrumentType, SizingMode};

fn unrealised_for(quantity: f64, average_price: f64, price: f64, funding: f64) -> f64 {
    if quantity == 0.0 {
        return 0.0;
    }
    (price - average_price) * quantity - funding
}

pub fn run(
    strategy: &CompiledStrategy,
    raw_candles: &[Candle],
    config: &BacktestConfig,
) -> ExprResult<BacktestResult> {
    let mut candles: Vec<Candle> = raw_candles
        .iter()
        .copied()
        .filter(|c| c.is_confirmed())
        .collect();
    candles.sort_by_key(|c| c.ts_ms);

    let manifest = &strategy.manifest;
    let costs = strategy.costs(config.fee_bps, config.slippage_bps);
    let fee_rate = costs.fee_bps / 10_000.0;
    let slippage = costs.slippage_bps / 10_000.0;
    let allows_short = manifest.market.inst_type.allows_short();
    let leverage = strategy.leverage();

    let Some(exposure_expression) = strategy.exposure.as_ref() else {
        return Ok(empty_result(strategy, &candles, config));
    };
    if candles.len() <= 1 {
        return Ok(empty_result(strategy, &candles, config));
    }

    let mut evaluator = Evaluator::new(&candles, &strategy.params, &config.external_series);
    let raw_exposure = evaluator.evaluate(exposure_expression)?;

    // Volatility scaling, when the manifest asks for it.
    let closes: Vec<f64> = candles.iter().map(|c| c.close).collect();
    let volatility = if manifest.sizing.mode == SizingMode::VolatilityTarget {
        realised_volatility(&closes, manifest.risk.vol_lookback_bars, &manifest.market.bar)
    } else {
        vec![f64::NAN; candles.len()]
    };

    let mut equity = config.initial_capital;
    let mut quantity = 0.0f64; // signed base units held
    let mut average_price = 0.0f64;
    let mut entry_ts = candles[0].ts_ms;
    let mut entry_index = 0usize;
    let mut entry_equity = config.initial_capital;
    let mut accrued_fees = 0.0f64;
    let mut accrued_funding = 0.0f64;

    let mut trades: Vec<Trade> = Vec::new();
    let mut equity_curve: Vec<EquityPoint> = Vec::with_capacity(candles.len());
    let mut pending_target_quantity: Option<f64> = None;

    let funding_by_bar = bucket_funding(&candles, &manifest.market.bar, &config.funding_rates);
    let first_tradable = strategy.warmup_bars.min(candles.len() - 1);
    let threshold = manifest.risk.rebalance_threshold.max(0.0);

    for index in 0..candles.len() {
        let candle = candles[index];

        // --- 1. Execute the adjustment decided at the previous close.
        if let Some(target) = pending_target_quantity.take() {
            let delta = target - quantity;
            if delta.abs() > 1e-12 {
                let buying = delta > 0.0;
                let fill = candle.open * if buying { 1.0 + slippage } else { 1.0 - slippage };
                let traded_notional = delta.abs() * fill;
                let fee = traded_notional * fee_rate;
                equity -= fee;
                accrued_fees += fee;

                if quantity == 0.0 {
                    // Opening a fresh position.
                    entry_ts = candle.ts_ms;
                    entry_index = index;
                    entry_equity = equity + fee;
                    average_price = fill;
                    quantity = delta;
                } else if (quantity > 0.0) == (delta > 0.0) {
                    // Adding: weighted-average the basis.
                    let total = quantity.abs() + delta.abs();
                    average_price =
                        (average_price * quantity.abs() + fill * delta.abs()) / total;
                    quantity += delta;
                } else {
                    // Reducing or flipping: realise on the overlap.
                    let closing = quantity.abs().min(delta.abs());
                    let realised = (fill - average_price)
                        * closing
                        * if quantity > 0.0 { 1.0 } else { -1.0 };
                    equity += realised;
                    let remainder = delta.abs() - closing;
                    let was_long = quantity > 0.0;
                    quantity += delta;

                    if quantity.abs() < 1e-12 || remainder > 1e-12 {
                        // The position closed (possibly reopening the other
                        // way) — book it as a completed trade.
                        let net = realised - accrued_fees - accrued_funding;
                        trades.push(Trade {
                            id: trades.len() + 1,
                            direction: if was_long {
                                Direction::Long
                            } else {
                                Direction::Short
                            },
                            entry_ts,
                            exit_ts: candle.ts_ms,
                            entry_price: average_price,
                            exit_price: fill,
                            quantity: closing,
                            notional: closing * average_price,
                            gross_pnl: realised,
                            fees: accrued_fees,
                            funding: accrued_funding,
                            net_pnl: net,
                            return_pct: if entry_equity > 0.0 {
                                net / entry_equity * 100.0
                            } else {
                                0.0
                            },
                            bars: index - entry_index,
                            exit_reason: ExitReason::Signal,
                        });
                        accrued_fees = 0.0;
                        accrued_funding = 0.0;
                        entry_ts = candle.ts_ms;
                        entry_index = index;
                        entry_equity = equity;
                        average_price = if remainder > 1e-12 { fill } else { 0.0 };
                        if quantity.abs() < 1e-12 {
                            quantity = 0.0;
                        }
                    }
                }
            }
        }

        // --- 2. Funding on the held position.
        if quantity != 0.0 {
            if let Some(rates) = funding_by_bar.get(&index) {
                for rate in rates {
                    accrued_funding += rate
                        * quantity.abs()
                        * candle.close
                        * if quantity > 0.0 { 1.0 } else { -1.0 };
                }
            }
        }

        // --- 3. Decide next bar's target exposure.
        if index >= first_tradable && index + 1 < candles.len() {
            let raw = raw_exposure[index];
            // Unknown means flat, never a guess.
            let target = if raw.is_nan() { 0.0 } else { raw };
            let target = target.clamp(if allows_short { -1.0 } else { 0.0 }, 1.0);

            let scale = match manifest.sizing.mode {
                SizingMode::VolatilityTarget => volatility_scale(
                    manifest.sizing.value,
                    volatility[index],
                    manifest.risk.max_exposure,
                ),
                SizingMode::EquityPct => manifest.sizing.value / 100.0,
                _ => 1.0,
            };
            let cap = manifest.risk.max_exposure;
            let effective =
                (target * scale).clamp(if allows_short { -cap } else { 0.0 }, cap);

            let marked_equity = equity
                + unrealised_for(quantity, average_price, candle.close, accrued_funding);
            let price = candles[index + 1].open;
            if marked_equity > 0.0 && price > 0.0 {
                let target_quantity = marked_equity * effective * leverage / price;
                let current_exposure = quantity * candle.close / marked_equity;
                // Only trade when the drift is worth the fee.
                if (effective - current_exposure).abs() >= threshold {
                    pending_target_quantity = Some(target_quantity);
                }
            }
        }

        if index >= first_tradable {
            equity_curve.push(EquityPoint {
                ts: candle.ts_ms,
                equity: equity
                    + unrealised_for(quantity, average_price, candle.close, accrued_funding),
                price: candle.close,
            });
        }
    }

    // Close whatever is left so the metrics see realised P&L.
    if quantity != 0.0 {
        let last = candles[candles.len() - 1];
        let buying = quantity < 0.0;
        let fill = last.close * if buying { 1.0 + slippage } else { 1.0 - slippage };
        let fee = quantity.abs() * fill * fee_rate;
        let realised =
            (fill - average_price) * quantity.abs() * if quantity > 0.0 { 1.0 } else { -1.0 };
        equity += realised - fee;
        accrued_fees += fee;
        let net = realised - accrued_fees - accrued_funding;
        trades.push(Trade {
            id: trades.len() + 1,
            direction: if quantity > 0.0 {
                Direction::Long
            } else {
                Direction::Short
            },
            entry_ts,
            exit_ts: last.ts_ms,
            entry_price: average_price,
            exit_price: fill,
            quantity: quantity.abs(),
            notional: quantity.abs() * average_price,
            gross_pnl: realised,
            fees: accrued_fees,
            funding: accrued_funding,
            net_pnl: net,
            return_pct: if entry_equity > 0.0 {
                net / entry_equity * 100.0
            } else {
                0.0
            },
            bars: candles.len() - 1 - entry_index,
            exit_reason: ExitReason::EndOfData,
        });
        if let Some(point) = equity_curve.last_mut() {
            *point = EquityPoint {
                ts: last.ts_ms,
                equity,
                price: last.close,
            };
        }
    }

    let metrics = Metrics::compute(
        &trades,
        &equity_curve,
        config.initial_capital,
        &manifest.market.bar,
        strategy.free_parameter_count,
    );

    Ok(BacktestResult {
        strategy_id: manifest.id.clone(),
        inst_id: manifest.market.inst_id.clone(),
        bar: manifest.market.bar.clone(),
        start: equity_curve.first().map(|p| p.ts).unwrap_or(candles[0].ts_ms),
        end: candles[candles.len() - 1].ts_ms,
        bar_count: equity_curve.len(),
        initial_capital: config.initial_capital,
        final_equity: equity,
        trades,
        equity_curve,
        liquidations: 0,
        warmup_bars: strategy.warmup_bars,
        funding_unmodelled: manifest.market.inst_type == InstrumentType::Swap
            && config.funding_rates.is_empty(),
        metrics,
    })
}
