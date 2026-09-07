//! Bar-by-bar simulation for strategies that express a directional view
//! through long options: a call on a long signal, a put on a short one.
//!
//! Same execution discipline as the binary path — signals on the close of bar
//! *i*, fills at the open of bar *i+1* — but the traded instrument is priced
//! by the model in [`crate::options`] rather than read off a candle: OKX keeps
//! no history for a contract once it has expired, so there is no candle to
//! read. The result is a *model-priced* backtest, and the honest thing it
//! measures is whether the direction signal earns back the premium it spends
//! under a stated volatility assumption.
//!
//! Three things follow from pricing at the close only:
//!
//! * a stop or target on the premium is judged once per bar, at the close,
//!   and fills there — the model has no intrabar path to hit a level on;
//! * a contract whose settlement instant falls inside a bar is settled at
//!   that bar's *open*, at intrinsic value, with no exit fee;
//! * there is no liquidation and no funding: a long option cannot lose more
//!   than its premium and is not charged carry.

use super::{
    empty_result, utc_day, BacktestConfig, BacktestResult, EquityPoint, ExitReason, Metrics,
    Trade,
};
use crate::candle::Candle;
use crate::decide::{can_enter, desired_direction, realised_volatility, Direction};
use crate::expr::eval::Evaluator;
use crate::expr::ExprResult;
use crate::options::{self, OptionKind, OptionsSpec, SelectionRequest};
use crate::strategy::{bar_seconds, CompiledStrategy};

#[derive(Debug, Clone)]
struct OpenOption {
    kind: OptionKind,
    strike: f64,
    expiry_ms: i64,
    /// Units of underlying the contracts cover: contracts × multiplier.
    units: f64,
    /// Premium paid per unit, slippage included.
    entry_premium: f64,
    entry_ts: i64,
    entry_index: usize,
    equity_at_entry: f64,
    fees: f64,
    stop_premium: Option<f64>,
    target_premium: Option<f64>,
}

/// The model's premium for a held contract at a spot price and instant.
///
/// Falls back to intrinsic value when the volatility is unknown, so a held
/// position is never marked to NaN: the floor is the one number that needs
/// no model.
fn premium(position: &OpenOption, spot: f64, ts_ms: i64, sigma: f64) -> f64 {
    let years = options::years_between(ts_ms, position.expiry_ms);
    let modelled = options::black_scholes(position.kind, spot, position.strike, years, sigma);
    if modelled.is_finite() {
        modelled
    } else {
        options::intrinsic(position.kind, spot, position.strike)
    }
}

fn marked(position: Option<&OpenOption>, spot: f64, ts_ms: i64, sigma: f64) -> f64 {
    position
        .map(|p| premium(p, spot, ts_ms, sigma) * p.units)
        .unwrap_or(0.0)
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
    let spec = strategy.options_spec();
    let costs = strategy.costs(config.fee_bps, config.slippage_bps);
    let slippage = costs.slippage_bps / 10_000.0;
    // The same pre-trade caps the runner applies; see the binary engine.
    let limits = crate::guard::OrderLimits::default();

    if candles.len() <= 1 {
        return Ok(empty_result(strategy, &candles, config));
    }

    let mut evaluator = Evaluator::new(&candles, &strategy.params, &config.external_series);
    let long_entry = strategy
        .long_entry
        .as_ref()
        .map(|e| evaluator.evaluate(e))
        .transpose()?;
    let long_exit = strategy
        .long_exit
        .as_ref()
        .map(|e| evaluator.evaluate(e))
        .transpose()?;
    let short_entry = strategy
        .short_entry
        .as_ref()
        .map(|e| evaluator.evaluate(e))
        .transpose()?;
    let short_exit = strategy
        .short_exit
        .as_ref()
        .map(|e| evaluator.evaluate(e))
        .transpose()?;

    // Implied volatility, as the model sees it: realised volatility over the
    // manifest's window, scaled by the declared premium over realised.
    let closes: Vec<f64> = candles.iter().map(|c| c.close).collect();
    let realised = realised_volatility(&closes, manifest.risk.vol_lookback_bars, &manifest.market.bar);
    let sigma_at = |index: usize| -> f64 {
        realised.get(index).copied().unwrap_or(f64::NAN) / 100.0 * spec.implied_vol_multiplier
    };

    let mut cash = config.initial_capital;
    let mut position: Option<OpenOption> = None;
    let mut trades: Vec<Trade> = Vec::new();
    let mut equity_curve: Vec<EquityPoint> = Vec::with_capacity(candles.len());

    let mut pending_target: Option<Option<Direction>> = None;
    let mut last_exit_index: Option<usize> = None;
    let mut halted_day: Option<i64> = None;
    let mut day_start_equity = config.initial_capital;
    let mut current_day = utc_day(candles[0].ts_ms);
    let first_tradable = strategy.warmup_bars.min(candles.len() - 1);

    for index in 0..candles.len() {
        let candle = candles[index];
        // Volatility as known when this bar's orders were decided — the
        // previous close — and as known at this close, for marking.
        let sigma_prev = sigma_at(index.saturating_sub(1));
        let sigma_now = sigma_at(index);

        let day = utc_day(candle.ts_ms);
        if day != current_day {
            current_day = day;
            day_start_equity = cash + marked(position.as_ref(), candle.open, candle.ts_ms, sigma_prev);
            halted_day = None;
        }

        // --- 1. Settlement. A contract whose expiry has arrived pays its
        //        intrinsic value at this open and is gone.
        if let Some(open) = position.as_ref() {
            if candle.ts_ms >= open.expiry_ms {
                let settle = options::intrinsic(open.kind, candle.open, open.strike);
                close_position(
                    &mut position, settle, 0.0, candle.ts_ms, index,
                    ExitReason::Expiry, &mut cash, &mut trades,
                );
                last_exit_index = Some(index);
            }
        }

        // --- 2. Orders decided at the previous close fill at this open.
        if let Some(target) = pending_target.take() {
            let cooldown_reference = last_exit_index;
            if let Some(open) = position.as_ref() {
                if Some(open.kind.direction()) != target {
                    let exit = premium(open, candle.open, candle.ts_ms, sigma_prev) * (1.0 - slippage);
                    let fee = options::option_fee(
                        costs.fee_bps, candle.open, exit, open.units, spec.fee_cap_pct_of_premium);
                    close_position(
                        &mut position, exit, fee, candle.ts_ms, index,
                        ExitReason::Signal, &mut cash, &mut trades,
                    );
                    last_exit_index = Some(index);
                }
            }
            if position.is_none() && halted_day.is_none() {
                if let Some(direction) = target {
                    let since_exit = cooldown_reference.map(|exit| index - exit);
                    if can_enter(since_exit, manifest.risk.cooldown_bars) {
                        open_position(
                            strategy, &spec, &mut position, direction, candle.open,
                            candle.ts_ms, index, sigma_prev, slippage, costs.fee_bps,
                            &limits, &mut cash,
                        );
                    }
                }
            }
        }

        // --- 3. Protective exits on the premium, judged at this close.
        if let Some(open) = position.as_ref() {
            let mark = premium(open, candle.close, candle.ts_ms, sigma_now);
            let hit = if open.stop_premium.is_some_and(|stop| mark <= stop) {
                Some(ExitReason::StopLoss)
            } else if open.target_premium.is_some_and(|target| mark >= target) {
                Some(ExitReason::TakeProfit)
            } else {
                None
            };
            if let Some(reason) = hit {
                let exit = mark * (1.0 - slippage);
                let fee = options::option_fee(
                    costs.fee_bps, candle.close, exit, open.units, spec.fee_cap_pct_of_premium);
                close_position(
                    &mut position, exit, fee, candle.ts_ms, index, reason, &mut cash, &mut trades,
                );
                last_exit_index = Some(index);
            }
        }

        // --- 4. Daily-loss circuit breaker on marked equity.
        let marked_now = cash + marked(position.as_ref(), candle.close, candle.ts_ms, sigma_now);
        if let Some(limit) = manifest.risk.max_daily_loss_pct {
            if halted_day.is_none()
                && day_start_equity > 0.0
                && (day_start_equity - marked_now) / day_start_equity * 100.0 >= limit
            {
                if let Some(open) = position.as_ref() {
                    let exit = premium(open, candle.close, candle.ts_ms, sigma_now) * (1.0 - slippage);
                    let fee = options::option_fee(
                        costs.fee_bps, candle.close, exit, open.units, spec.fee_cap_pct_of_premium);
                    close_position(
                        &mut position, exit, fee, candle.ts_ms, index,
                        ExitReason::DailyLossHalt, &mut cash, &mut trades,
                    );
                    last_exit_index = Some(index);
                }
                halted_day = Some(day);
                pending_target = None;
            }
        }

        // --- 5. Signals on this close; the order fills next bar.
        if index >= first_tradable && index + 1 < candles.len() && halted_day.is_none() {
            let current = position.as_ref().map(|p| p.kind.direction());
            let held = position.as_ref().map(|p| index - p.entry_index).unwrap_or(0);
            let target = desired_direction(
                index,
                current,
                held,
                manifest.risk.min_hold_bars,
                manifest.risk.max_hold_bars,
                long_entry.as_deref(),
                long_exit.as_deref(),
                short_entry.as_deref(),
                short_exit.as_deref(),
                config.script_targets.as_deref(),
            );
            if target != current {
                pending_target = Some(target);
            }
        }

        if index >= first_tradable {
            equity_curve.push(EquityPoint {
                ts: candle.ts_ms,
                equity: cash + marked(position.as_ref(), candle.close, candle.ts_ms, sigma_now),
                price: candle.close,
            });
        }
    }

    // Anything still open is sold at the last close, so the metrics see
    // realised P&L.
    if let Some(open) = position.as_ref() {
        let last = candles[candles.len() - 1];
        let sigma = sigma_at(candles.len() - 1);
        let exit = premium(open, last.close, last.ts_ms, sigma) * (1.0 - slippage);
        let fee = options::option_fee(
            costs.fee_bps, last.close, exit, open.units, spec.fee_cap_pct_of_premium);
        close_position(
            &mut position, exit, fee, last.ts_ms, candles.len() - 1,
            ExitReason::EndOfData, &mut cash, &mut trades,
        );
        if let Some(point) = equity_curve.last_mut() {
            *point = EquityPoint { ts: last.ts_ms, equity: cash, price: last.close };
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
        final_equity: cash,
        trades,
        equity_curve,
        liquidations: 0,
        warmup_bars: strategy.warmup_bars,
        data_quality: crate::quality::inspect(&candles, bar_seconds(&manifest.market.bar), None),
        // A long option is not charged carry. Not "unmodelled": there is
        // nothing to model.
        funding_unmodelled: false,
        metrics,
    })
}

#[allow(clippy::too_many_arguments)]
fn open_position(
    strategy: &CompiledStrategy,
    spec: &OptionsSpec,
    position: &mut Option<OpenOption>,
    direction: Direction,
    spot: f64,
    ts_ms: i64,
    index: usize,
    sigma: f64,
    slippage: f64,
    fee_bps: f64,
    limits: &crate::guard::OrderLimits,
    cash: &mut f64,
) {
    if !(spot > 0.0) || !(*cash > 0.0) {
        return;
    }
    let kind = OptionKind::for_direction(direction);
    // The model's chain, chosen by the rule live trading uses on the real one.
    let request = SelectionRequest {
        kind,
        spot,
        now_ms: ts_ms,
        min_days_to_expiry: spec.min_days_to_expiry,
        moneyness_pct: spec.moneyness_pct,
        strike_step: spec.strike_step,
        candidates: options::synthetic_chain(kind, spot, ts_ms, spec),
    };
    let Some(contract) = options::select_contract(&request) else { return };

    let years = options::years_between(ts_ms, contract.expiry_ms);
    let fair = options::black_scholes(kind, spot, contract.strike, years, sigma);
    // Unknown volatility is an unknown price. The simulation stands aside,
    // exactly as the runner does when it cannot get a quote.
    if !fair.is_finite() || !(fair > 0.0) {
        return;
    }
    let paid = fair * (1.0 + slippage);

    let Some(budget) = options::premium_budget(strategy, *cash) else { return };
    // The premium is the order's whole exposure, and the same pre-trade caps
    // the runner applies judge it here.
    if crate::guard::check_order(budget / spot * direction.sign(), 0.0, spot, *cash, limits)
        .is_some()
    {
        return;
    }
    let contracts = options::contracts_for(budget, paid, spec.contract_multiplier, 1.0);
    if contracts < 1.0 {
        return;
    }
    let units = contracts * spec.contract_multiplier;
    let fee = options::option_fee(fee_bps, spot, paid, units, spec.fee_cap_pct_of_premium);

    let risk = &strategy.manifest.risk;
    let equity_at_entry = *cash;
    *cash -= paid * units + fee;
    *position = Some(OpenOption {
        kind,
        strike: contract.strike,
        expiry_ms: contract.expiry_ms,
        units,
        entry_premium: paid,
        entry_ts: ts_ms,
        entry_index: index,
        equity_at_entry,
        fees: fee,
        // Both levels are on the premium itself: an option's own price is the
        // thing a stop on it is about.
        stop_premium: risk.stop_loss_pct.map(|pct| paid * (1.0 - pct / 100.0)),
        target_premium: risk.take_profit_pct.map(|pct| paid * (1.0 + pct / 100.0)),
    });
}

#[allow(clippy::too_many_arguments)]
fn close_position(
    position: &mut Option<OpenOption>,
    exit_premium: f64,
    exit_fee: f64,
    ts: i64,
    index: usize,
    reason: ExitReason,
    cash: &mut f64,
    trades: &mut Vec<Trade>,
) {
    let Some(open) = position.take() else { return };
    let gross = (exit_premium - open.entry_premium) * open.units;
    let fees = open.fees + exit_fee;
    let net = gross - fees;
    *cash += exit_premium * open.units - exit_fee;
    trades.push(Trade {
        id: trades.len() + 1,
        direction: open.kind.direction(),
        entry_ts: open.entry_ts,
        exit_ts: ts,
        entry_price: open.entry_premium,
        exit_price: exit_premium,
        quantity: open.units,
        notional: open.entry_premium * open.units,
        gross_pnl: gross,
        fees,
        funding: 0.0,
        net_pnl: net,
        return_pct: if open.equity_at_entry > 0.0 {
            net / open.equity_at_entry * 100.0
        } else {
            0.0
        },
        bars: index - open.entry_index,
        exit_reason: reason,
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::strategy::Manifest;

    fn strategy(signals: &str, risk: &str, options: &str) -> CompiledStrategy {
        let json = format!(
            r#"{{"id":"o","name":"o",
                 "market":{{"instId":"BTC-USDT","instType":"OPTION","bar":"1H"}},
                 "signals":{signals},
                 "sizing":{{"mode":"equityPct","value":10}},
                 "risk":{{"volLookbackBars":24{risk}}},
                 "options":{options}}}"#
        );
        let manifest: Manifest = serde_json::from_str(&json).unwrap();
        CompiledStrategy::compile(manifest, &[]).unwrap()
    }

    /// Hourly bars drifting `per_bar` per bar with a little wobble, so the
    /// realised volatility is finite and the direction is unambiguous.
    fn drifting(count: i64, per_bar: f64) -> Vec<Candle> {
        (0..count)
            .map(|i| {
                let wobble = 1.0 + 0.004 * ((i as f64) * 0.9).sin();
                let close = 50_000.0 * (1.0 + per_bar).powi(i as i32) * wobble;
                Candle {
                    ts_ms: 1_788_768_000_000 + i * 3_600_000, // a Monday 08:00 UTC
                    open: close / (1.0 + per_bar),
                    high: close.max(close / (1.0 + per_bar)) * 1.001,
                    low: close.min(close / (1.0 + per_bar)) * 0.999,
                    close,
                    volume: 1.0,
                    confirmed: 1,
                }
            })
            .collect()
    }

    const ALWAYS_LONG: &str = r#"{"longEntry":"close > 0"}"#;
    const ALWAYS_SHORT: &str = r#"{"shortEntry":"close > 0"}"#;

    #[test]
    fn a_call_earns_in_a_rally_and_a_put_in_a_slide() {
        let config = BacktestConfig::default();
        let rally = drifting(400, 0.002);
        let up = run(&strategy(ALWAYS_LONG, "", "{}"), &rally, &config).unwrap();
        assert!(up.final_equity > config.initial_capital, "{}", up.final_equity);
        assert!(up.trades.iter().all(|t| t.direction == Direction::Long));

        let slide = drifting(400, -0.002);
        let down = run(&strategy(ALWAYS_SHORT, "", "{}"), &slide, &config).unwrap();
        assert!(down.final_equity > config.initial_capital, "{}", down.final_equity);
        assert!(down.trades.iter().all(|t| t.direction == Direction::Short));
    }

    #[test]
    fn the_loss_is_bounded_by_the_premium() {
        // A call held through a relentless slide loses the premium and no more.
        // Ten percent of the budget per entry, so the book can never be down
        // more than that per contract cycle plus fees.
        let config = BacktestConfig::default();
        let slide = drifting(300, -0.003);
        let result = run(&strategy(ALWAYS_LONG, "", r#"{"minDaysToExpiry": 30}"#), &slide, &config).unwrap();
        for trade in &result.trades {
            assert!(trade.net_pnl >= -(trade.notional + trade.fees) - 1e-9,
                    "a long option cannot lose more than it paid: {trade:?}");
        }
        assert_eq!(result.liquidations, 0);
        assert!(!result.funding_unmodelled);
    }

    #[test]
    fn a_contract_held_to_its_expiry_settles_at_intrinsic() {
        // One-day contracts, signal never exits: every trade ends at expiry.
        let config = BacktestConfig::default();
        let bars = drifting(200, 0.001);
        let result = run(&strategy(ALWAYS_LONG, "", r#"{"minDaysToExpiry": 1}"#), &bars, &config).unwrap();
        assert!(result.trades.len() >= 3, "{}", result.trades.len());
        assert!(result.trades.iter().take(result.trades.len() - 1)
            .all(|t| t.exit_reason == ExitReason::Expiry), "{:?}",
            result.trades.iter().map(|t| t.exit_reason).collect::<Vec<_>>());
        // Settlement is at intrinsic: never negative, and never above the spot.
        for trade in &result.trades {
            assert!(trade.exit_price >= 0.0);
        }
    }

    #[test]
    fn a_stop_on_the_premium_fires() {
        let config = BacktestConfig::default();
        let slide = drifting(300, -0.003);
        let result = run(
            &strategy(ALWAYS_LONG, r#","stopLossPct":40"#, r#"{"minDaysToExpiry": 30}"#),
            &slide, &config,
        ).unwrap();
        assert!(result.trades.iter().any(|t| t.exit_reason == ExitReason::StopLoss),
                "{:?}", result.trades.iter().map(|t| t.exit_reason).collect::<Vec<_>>());
        for trade in result.trades.iter().filter(|t| t.exit_reason == ExitReason::StopLoss) {
            // Judged at the close, so the fill can overshoot the level, but
            // the level was a 40% loss and the fill must be at or past it.
            assert!(trade.exit_price <= trade.entry_price * 0.6 + 1e-9);
        }
    }

    #[test]
    fn nothing_trades_before_the_volatility_window_is_primed() {
        let config = BacktestConfig::default();
        let bars = drifting(60, 0.002);
        let strategy = strategy(ALWAYS_LONG, "", "{}");
        assert!(strategy.warmup_bars >= 25);
        let result = run(&strategy, &bars, &config).unwrap();
        for trade in &result.trades {
            let entry_index = bars.iter().position(|c| c.ts_ms == trade.entry_ts).unwrap();
            assert!(entry_index > strategy.warmup_bars);
        }
    }

    #[test]
    fn a_reversal_swaps_the_contract() {
        // Long above the average, short below: a rally then a slide must hold
        // a call, then a put.
        let config = BacktestConfig::default();
        let mut bars = drifting(300, 0.002);
        let tail = drifting(300, -0.002);
        let last = bars.last().unwrap().close;
        let scale = last / tail[0].open;
        let resume_ts = bars[299].ts_ms;
        bars.extend(tail.iter().enumerate().map(|(i, c)| Candle {
            ts_ms: resume_ts + (i as i64 + 1) * 3_600_000,
            open: c.open * scale, high: c.high * scale, low: c.low * scale,
            close: c.close * scale, volume: 1.0, confirmed: 1,
        }));
        let strategy = strategy(
            r#"{"longEntry":"close > sma(close, 20)","longExit":"close < sma(close, 20)",
                "shortEntry":"close < sma(close, 20)","shortExit":"close > sma(close, 20)"}"#,
            "", r#"{"minDaysToExpiry": 14}"#);
        let result = run(&strategy, &bars, &config).unwrap();
        let directions: Vec<Direction> = result.trades.iter().map(|t| t.direction).collect();
        assert!(directions.contains(&Direction::Long) && directions.contains(&Direction::Short),
                "{directions:?}");
    }
}
