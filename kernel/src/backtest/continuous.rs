//! Bar-by-bar simulation for strategies that hold a *scaled* position rather
//! than switching in and out.
//!
//! Same execution discipline as the binary path: exposure is computed on the
//! close of bar i from data up to i, and the resulting trade fills at the open
//! of bar i+1 with slippage and fees on the traded notional only. Positions are
//! adjusted incrementally, so holding through a flat signal costs nothing —
//! which is what makes a turnover comparison meaningful.

use super::liquidation::{Holding, Lender};
use super::{
    bucket_funding, empty_result, market_price, resolve_costs, BacktestConfig, BacktestResult, EquityPoint,
    ExitFill, ExitReason, Metrics, Trade,
};
use crate::candle::Candle;
use crate::decide::{realised_volatility, volatility_scale, Direction};
use crate::expr::eval::Evaluator;
use crate::expr::ExprResult;
use crate::fees::OrderSide;
use crate::sizing::{exposure_of, Footing};
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
    let costs = resolve_costs(strategy, config)?;
    let lender = Lender::for_run(strategy, config, &costs)?;
    let calendar = manifest.market.calendar();
    let slippage = costs.slippage_bps / 10_000.0;
    let allows_short = manifest.market.inst_type.allows_short();
    let leverage = strategy.leverage();
    let regime = manifest.market.inst_type.margin_regime();
    // The pre-trade check live applies to every rebalance (`decide_live`), so
    // the simulation never trades an order the runner would refuse.
    let limits = crate::guard::OrderLimits::default();
    let mut refusals = super::GuardRefusals::default();
    let position_limit = lender.position_limit();
    let mut limited = 0usize;

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
        realised_volatility(&closes, manifest.risk.vol_lookback_bars, manifest.market.bars_per_year())
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
    // Whether the pending order is the daily-loss breaker standing the
    // position down, so its close says so rather than "signal".
    let mut pending_halt = false;

    let funding_by_bar = bucket_funding(&candles, &manifest.market.bar, &config.funding_rates);
    let first_tradable = strategy.warmup_bars.min(candles.len() - 1);
    let threshold = manifest.risk.rebalance_threshold.max(0.0);

    // The daily-loss breaker and the liquidation check apply here exactly as
    // they do on the binary path. `decide_live` tests the breaker *before* it
    // branches on exposure, so live already halts a continuous strategy that
    // has bled through its limit; a simulation that did not would report
    // returns from days the runner would have sat out.
    let mut halted_day: Option<i64> = None;
    let mut day = calendar.session_key(candles[0].ts_ms);
    let mut day_start_equity = config.initial_capital;
    let mut liquidations = 0usize;

    for index in 0..candles.len() {
        let candle = candles[index];

        if calendar.session_key(candle.ts_ms) != day {
            day = calendar.session_key(candle.ts_ms);
            day_start_equity =
                equity + unrealised_for(quantity, average_price, candle.close, accrued_funding);
            // Latched for the day only. Leaving it set would make the backtest
            // decline trades the runner takes tomorrow.
            halted_day = None;
        }

        // --- 1. Execute the adjustment decided at the previous close.
        let halting = std::mem::take(&mut pending_halt);
        if let Some(decided) = pending_target_quantity.take() {
            let buying = decided > quantity;
            let fill = market_price(candle.open, buying, slippage);
            // What the order adds is judged again where it fills, against the
            // capital marked there: a gap since the decision moves both, and a
            // position may not grow on a price its capital cannot back. Only
            // what it adds can be cut; a close or a trim goes whole.
            let at_fill = Footing {
                costs: &costs, capital: equity + unrealised_for(quantity, average_price, fill, accrued_funding),
                price: fill, leverage, regime, held_base: quantity, held_basis: average_price,
                max_base: position_limit,
            };
            let target = at_fill.affordable(decided);
            let delta = target - quantity;
            if delta.abs() > 1e-12 {
                let fee = costs.fee(
                    if buying { OrderSide::Buy } else { OrderSide::Sell },
                    delta.abs(),
                    delta.abs() * fill,
                );
                equity -= fee;

                if quantity == 0.0 {
                    // Opening a fresh position.
                    entry_ts = candle.ts_ms;
                    entry_index = index;
                    entry_equity = equity + fee;
                    average_price = fill;
                    quantity = delta;
                    accrued_fees += fee;
                } else if (quantity > 0.0) == (delta > 0.0) {
                    // Adding: weighted-average the basis.
                    let total = quantity.abs() + delta.abs();
                    average_price =
                        (average_price * quantity.abs() + fill * delta.abs()) / total;
                    quantity += delta;
                    accrued_fees += fee;
                } else {
                    // Reducing, closing or flipping: realise on the overlap.
                    let was_long = quantity > 0.0;
                    let held_before = quantity.abs();
                    let after = quantity + delta;
                    let closed_out = after.abs() < 1e-12;
                    let flipped = !closed_out && (after > 0.0) != was_long;
                    // Exactly the whole position when it closes out, so not a
                    // rounding residue of its costs is left behind unbooked.
                    let closing = if closed_out || flipped { held_before } else { delta.abs() };
                    let share = closing / held_before;
                    // One order can close one side and open the other. Its fee
                    // is split by the quantity each part traded, so the trade
                    // it closes is not charged for the position it opens.
                    let opening_fee = if flipped { fee * after.abs() / delta.abs() } else { 0.0 };
                    let realised = (fill - average_price) * closing * if was_long { 1.0 } else { -1.0 };
                    let fees_share = accrued_fees * share + (fee - opening_fee);
                    let funding_share = accrued_funding * share;
                    // Funding accrues as a liability while the position is
                    // open — the mark subtracts it — and is *paid* when its
                    // share of the position is realised. It used to be
                    // reported on the trade and never paid: the mark dropped
                    // by the bill, the close reset the accrual, and equity
                    // jumped back up, so final equity had paid no funding.
                    equity += realised - funding_share;
                    let net = realised - fees_share - funding_share;

                    // **Every** reduction is booked, not only the ones that
                    // close the position outright.
                    //
                    // Volatility targeting realises its gains precisely by
                    // trimming — it sells into strength and buys back into
                    // weakness — so booking a trade only on a full close kept
                    // every loser and discarded every winner. One search
                    // candidate reported an 11% win rate, a 0.24 payoff ratio
                    // and −0.4% expectancy per trade while its equity curve
                    // was up 614%. Both numbers came from the same run; only
                    // the ledger was wrong.
                    //
                    // It is not a cosmetic error: win rate, payoff, expectancy
                    // and the Monte-Carlo resample are all computed from this
                    // ledger, and the resample compounds it — so every
                    // trimming strategy was pinned near a 100% probability of
                    // loss regardless of what it actually did.
                    trades.push(Trade {
                        id: trades.len() + 1,
                        direction: if was_long { Direction::Long } else { Direction::Short },
                        entry_ts,
                        exit_ts: candle.ts_ms,
                        entry_price: average_price,
                        exit_price: fill,
                        quantity: closing,
                        notional: closing * average_price,
                        gross_pnl: realised,
                        fees: fees_share,
                        funding: funding_share,
                        net_pnl: net,
                        return_pct: if entry_equity > 0.0 {
                            net / entry_equity * 100.0
                        } else {
                            0.0
                        },
                        bars: index - entry_index,
                        exit_reason: if halting {
                            ExitReason::DailyLossHalt
                        } else if flipped {
                            ExitReason::Reversal
                        } else {
                            ExitReason::Signal
                        },
                    });
                    // Only the closed share's costs are consumed; the rest
                    // stays with the position that is still open.
                    accrued_fees -= accrued_fees * share;
                    accrued_funding -= funding_share;

                    if closed_out || flipped {
                        // A new position starts here, if any: the clock, the
                        // cost basis and the costs restart.
                        quantity = if closed_out { 0.0 } else { after };
                        average_price = if flipped { fill } else { 0.0 };
                        accrued_fees = opening_fee;
                        accrued_funding = 0.0;
                        entry_ts = candle.ts_ms;
                        entry_index = index;
                        entry_equity = equity + opening_fee;
                    } else {
                        // A partial trim leaves entry_ts, entry_index and
                        // average_price alone: what remains is the same
                        // position, opened when it was opened, at the basis it
                        // was opened at.
                        quantity = after;
                    }
                }
            }
        }

        // --- 2. Liquidation, where the binary engine's lender puts it: a
        //        scaled position changes size every rebalance, so its level is
        //        the position's as it stands now — what is held, at what basis,
        //        with the funding it has settled — never fixed at entry.
        let liquidation = (quantity != 0.0)
            .then(|| Holding {
                direction: if quantity > 0.0 { Direction::Long } else { Direction::Short },
                quantity: quantity.abs(),
                basis: average_price,
                funding: accrued_funding,
                capital: equity,
            })
            .and_then(|held| Some((held, lender.liquidation_level(&held)?)));
        if let Some((held, level)) = liquidation {
            let direction = held.direction;
            let sign = direction.sign();
            let adverse_extreme = if quantity > 0.0 { candle.low } else { candle.high };
            if sign * (level - adverse_extreme) >= 0.0 {
                // Opened past the level, or reached it inside the bar.
                let trigger = if sign * (level - candle.open) >= 0.0 { candle.open } else { level };
                let size = held.quantity;
                let fill = lender.liquidation_fill(&held, trigger, slippage);
                let gross = sign * (fill.price - average_price) * size;
                equity += gross - fill.fee - accrued_funding;
                let fees = accrued_fees + fill.fee;
                let net = gross - fees - accrued_funding;
                trades.push(Trade {
                    id: trades.len() + 1,
                    direction,
                    entry_ts,
                    exit_ts: candle.ts_ms,
                    entry_price: average_price,
                    exit_price: fill.price,
                    quantity: size,
                    notional: size * average_price,
                    gross_pnl: gross,
                    fees,
                    funding: accrued_funding,
                    net_pnl: net,
                    return_pct: if entry_equity > 0.0 { net / entry_equity * 100.0 } else { 0.0 },
                    bars: index - entry_index,
                    exit_reason: ExitReason::Liquidation,
                });
                liquidations += 1;
                quantity = 0.0;
                average_price = 0.0;
                accrued_fees = 0.0;
                accrued_funding = 0.0;
                entry_equity = equity;
                pending_target_quantity = None;
                pending_halt = false;
            }
        }

        // --- 2b. Funding on the held position, settled at this bar's close
        //         after its range was checked — the binary engine's order, so
        //         a settlement moves both engines' levels from the next bar.
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

        // --- 2c. Daily-loss breaker.
        let marked = equity
            + unrealised_for(quantity, average_price, candle.close, accrued_funding);
        if let Some(limit) = manifest.risk.max_daily_loss_pct {
            if halted_day.is_none()
                && day_start_equity > 0.0
                && (day_start_equity - marked) / day_start_equity * 100.0 >= limit
            {
                halted_day = Some(day);
                // Stand the position down at this close, and take nothing else
                // today. The runner does the same thing.
                if quantity != 0.0 {
                    pending_target_quantity = Some(0.0);
                    pending_halt = true;
                }
            }
        }

        // --- 3. Decide next bar's target exposure.
        if index >= first_tradable && index + 1 < candles.len() && halted_day.is_none() {
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
            let close = candle.close;
            if marked_equity > 0.0 && close > 0.0 {
                // Sized as the runner sizes it (`decide_live`): at this close,
                // against the capital marked at it, no further than that
                // capital can commit to — the margin of the position after the
                // order and the order's fee (`sizing::Footing`). It used to be
                // sized at the next open against capital marked at this close;
                // across a gap the two prices disagree, and an isolated
                // position read its own loss as room to add.
                let footing = Footing {
                    costs: &costs, capital: marked_equity, price: close, leverage, regime,
                    held_base: quantity, held_basis: average_price, max_base: position_limit,
                };
                let current_exposure = exposure_of(quantity, marked_equity, close, leverage);
                // Only trade when the drift is worth the fee. The ceiling only
                // ever brings a target nearer what is held, so a drift too
                // small to trade before it is too small after it, and the
                // ceiling — a search — is only worked out for an order that may
                // go: a position held at full size meets it on every bar.
                let target_quantity = if (effective - current_exposure).abs() >= threshold {
                    footing.exposure_target(effective)
                } else {
                    quantity
                };
                let target_exposure = exposure_of(target_quantity, marked_equity, close, leverage);
                if (target_exposure - current_exposure).abs() >= threshold {
                    // What the runner would send (`guard::admit`): the order,
                    // the close alone when only a flip's opening half is
                    // refused, or nothing.
                    let admission = crate::guard::admit(
                        target_quantity - quantity, quantity, close, marked_equity,
                        strategy.max_notional_multiple(), &limits);
                    if let Some(denied) = admission.denied {
                        refusals.note(denied);
                    }
                    if admission.base_delta != 0.0 {
                        pending_target_quantity = Some(quantity + admission.base_delta);
                        let wanted = crate::sizing::exposure_base(effective, marked_equity, close, leverage);
                        if footing.limited_by_venue(wanted).is_some() {
                            limited += 1;
                        }
                    }
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
        let direction = if quantity > 0.0 { Direction::Long } else { Direction::Short };
        let size = quantity.abs();
        let fill = ExitFill::market(&costs, direction, size, last.close, slippage);
        let gross = direction.sign() * (fill.price - average_price) * size;
        equity += gross - fill.fee - accrued_funding;
        let fees = accrued_fees + fill.fee;
        let net = gross - fees - accrued_funding;
        trades.push(Trade {
            id: trades.len() + 1,
            direction,
            entry_ts,
            exit_ts: last.ts_ms,
            entry_price: average_price,
            exit_price: fill.price,
            quantity: size,
            notional: size * average_price,
            gross_pnl: gross,
            fees,
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
        manifest.market.bars_per_year(),
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
        liquidations,
        warmup_bars: strategy.warmup_bars,
        data_quality: crate::quality::inspect(
            &candles, calendar, manifest.market.bar_seconds(), None),
        funding_unmodelled: manifest.market.inst_type == InstrumentType::Swap
            && config.funding_rates.is_empty(),
        guard_refusals: refusals.count,
        guard_refusal: refusals.first,
        position_tiers_unmodelled: super::liquidation::tiers_unmodelled(strategy, config),
        position_limit,
        position_limited: limited,
        metrics,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::strategy::Manifest;

    fn strategy(risk: &str, leverage: f64) -> CompiledStrategy {
        let json = format!(
            r#"{{"id":"c","name":"c","market":{{"instId":"BTC-USDT-SWAP","instType":"SWAP","bar":"1H"}},
                 "signals":{{"exposure":"1"}},
                 "sizing":{{"mode":"equityPct","value":100}},
                 "risk":{{"leverage":{leverage},"rebalanceThreshold":0.001{risk}}}}}"#
        );
        let manifest: Manifest = serde_json::from_str(&json).unwrap();
        CompiledStrategy::compile(manifest, &[]).unwrap()
    }

    /// A steady slide: enough to trip a daily-loss limit and, with leverage,
    /// enough to liquidate.
    fn falling(count: i64, per_bar: f64) -> Vec<Candle> {
        (0..count)
            .map(|i| {
                let close = 100.0 * (1.0 - per_bar).powi(i as i32);
                Candle {
                    ts_ms: i * 3_600_000,
                    open: close / (1.0 - per_bar),
                    high: close / (1.0 - per_bar),
                    low: close,
                    close,
                    volume: 1.0,
                    confirmed: 1,
                }
            })
            .collect()
    }

    /// A full-size position at 20× is what sizing produces for this manifest,
    /// and the live runner sends it. Under the old single 1 000% cap the
    /// backtest refused every rebalance and reported nothing at all.
    #[test]
    fn a_full_size_position_at_high_leverage_trades_and_nothing_is_refused() {
        let bars: Vec<Candle> = (0..48)
            .map(|i| Candle { ts_ms: i * 3_600_000, open: 100.0, high: 100.5, low: 99.5, close: 100.0, volume: 1.0, confirmed: 1 })
            .collect();
        let result = run(&strategy("", 20.0), &bars, &BacktestConfig::default()).unwrap();
        assert_eq!(result.guard_refusals, 0, "{:?}", result.guard_refusal);
        assert!(result.final_equity != BacktestConfig::default().initial_capital, "the position was opened and paid its fees");
    }

    /// A position already at its target is left alone, at every leverage a
    /// perpetual allows: the drift a rebalance is judged on is measured on
    /// the same scale the target is sized on — and the live runner's. The
    /// market wobbles too little to move even a 50× position's exposure by
    /// the threshold (equity moves by leverage times the price).
    #[test]
    fn a_position_on_its_target_is_not_rebalanced_at_any_leverage() {
        let bars: Vec<Candle> = (0..200)
            .map(|i| {
                let close = 100.0 * (1.0 + 0.000_2 * ((i as f64) * 0.7).sin());
                Candle { ts_ms: i * 3_600_000, open: close, high: close * 1.001, low: close * 0.999,
                         close, volume: 1.0, confirmed: 1 }
            })
            .collect();
        let max = InstrumentType::Swap.max_leverage() as i64;
        for leverage in 1..=max {
            let json = format!(
                r#"{{"id":"on","name":"on","market":{{"instId":"BTC-USDT-SWAP","instType":"SWAP","bar":"1H"}},
                     "signals":{{"exposure":"1"}},"sizing":{{"mode":"equityPct","value":100}},
                     "risk":{{"leverage":{leverage},"rebalanceThreshold":0.05}}}}"#);
            let held = CompiledStrategy::compile(serde_json::from_str::<Manifest>(&json).unwrap(), &[]).unwrap();
            let result = run(&held, &bars, &BacktestConfig::default()).unwrap();
            assert_eq!(result.trades.len(), 1, "{leverage}x: {:?}",
                       result.trades.iter().map(|t| t.exit_reason).collect::<Vec<_>>());
        }
    }

    /// The binary engine's walk, for a scaled position: every family this
    /// engine trades, at every whole leverage it allows — 1× included — at
    /// full exposure either way it can face, through the worst bar its lender
    /// defines: a gap far past an isolated level, a Reg T call met inside its
    /// bar, all but the whole price where there is no level. What the position
    /// committed was its margin and its fee, so the run ends at or above zero,
    /// and an isolated liquidation takes what was committed: all of it, but
    /// for the slippage between the close it was sized at and the open it
    /// filled at — which leaves a short a little, and is cut from a long where
    /// it fills. A 1× short used to have no level and rode the gap.
    #[test]
    fn a_full_exposure_position_never_commits_more_than_the_equity_behind_it() {
        use crate::strategy::MarginRegime;
        let config = BacktestConfig { fees: Some(vec![crate::fees::FeeComponent::flat_bps(5.0)]),
                                      slippage_bps: Some(3.0), ..BacktestConfig::default() };
        let at = |i: i64, open: f64, high: f64, low: f64, close: f64| {
            Candle { ts_ms: i * 3_600_000, open, high, low, close, volume: 1.0, confirmed: 1 }
        };
        let quiet = |count: i64, price: f64| -> Vec<Candle> { (0..count).map(|i| at(i, price, price, price, price)).collect() };
        let mut walked = 0;
        for family in InstrumentType::ALL.into_iter().filter(|f| !f.is_option()) {
            let mut leverage = 1.0;
            while leverage <= family.max_leverage() {
                let exposures: &[f64] = if family.allows_short() { &[1.0, -1.0] } else { &[1.0] };
                for &exposure in exposures {
                    let json = format!(
                        r#"{{"id":"x","name":"x","market":{{"instId":"X","instType":{},"bar":"1H"}},
                             "signals":{{"exposure":"{exposure}"}},"sizing":{{"mode":"equityPct","value":100}},
                             "risk":{{"leverage":{leverage},"rebalanceThreshold":0.05}}}}"#,
                        serde_json::to_value(family).unwrap());
                    let strategy = CompiledStrategy::compile(serde_json::from_str::<Manifest>(&json).unwrap(), &[]).unwrap();
                    // The position it holds on quiet bars, as its lender sees it.
                    let costs = resolve_costs(&strategy, &config).unwrap();
                    let lender = Lender::for_run(&strategy, &config, &costs).unwrap();
                    let entry = run(&strategy, &quiet(10, 100.0), &config).unwrap().trades[0].clone();
                    let side = if entry.direction == Direction::Long { OrderSide::Buy } else { OrderSide::Sell };
                    let held = Holding {
                        direction: entry.direction, quantity: entry.quantity, basis: entry.entry_price, funding: 0.0,
                        capital: config.initial_capital - costs.fee(side, entry.quantity, entry.notional),
                    };
                    let level = lender.liquidation_level(&held);
                    let mut bars = quiet(6, 100.0);
                    let worst = match (level, family.margin_regime()) {
                        // Opened far past the liquidation level.
                        (Some(level), MarginRegime::Isolated) => {
                            let gap = level * (1.0 - exposure * 0.5);
                            at(6, gap, gap, gap, gap)
                        }
                        // The call met inside the bar.
                        (Some(level), _) => at(6, 100.0, level.max(100.0), level.min(100.0), level),
                        // No level: all but the whole price, either way.
                        (None, _) => {
                            let moved = 100.0 * (1.0 - exposure * 0.99);
                            at(6, moved, moved, moved, moved)
                        }
                    };
                    bars.push(worst);
                    bars.extend((7..10).map(|i| at(i, worst.close, worst.close, worst.close, worst.close)));

                    let result = run(&strategy, &bars, &config).unwrap();
                    let label = format!("{family:?} {leverage}x exposure {exposure}");
                    assert!(result.final_equity >= -1e-9 * config.initial_capital,
                            "{label}: ends at {} after {:?}", result.final_equity,
                            result.trades.iter().map(|t| t.exit_reason).collect::<Vec<_>>());
                    match level {
                        Some(_) => {
                            assert_eq!(result.liquidations, 1, "{label}");
                            if family.margin_regime() == MarginRegime::Isolated {
                                let slipped = config.initial_capital * 3.0 / 10_000.0;
                                assert!(result.final_equity <= slipped * 1.01, "{label}: {}", result.final_equity);
                            }
                        }
                        None => assert!(exposure > 0.0 || family.margin_regime() == MarginRegime::None,
                                        "{label}: lent against with no level"),
                    }
                    walked += 1;
                }
                leverage += 1.0;
            }
        }
        assert!(walked > 100, "walked {walked}");
    }

    /// A scaled position on isolated margin that rallies cannot add on the
    /// rally: its profit is not cash, and a liquidation takes the margin at the
    /// average price out of what was realised. At every leverage a perpetual
    /// allows, a rally the rebalancer would follow and then a gap far past the
    /// liquidation level end the run at or above zero. Counting the profit as
    /// capital, a 10× run of 10 000 ended at −18 606.
    #[test]
    fn a_rally_is_not_capital_an_isolated_position_can_add_on() {
        let max = InstrumentType::Swap.max_leverage() as i64;
        let mut liquidated = 0;
        for leverage in 2..=max {
            let leverage = leverage as f64;
            let json = format!(
                r#"{{"id":"r","name":"r","market":{{"instId":"BTC-USDT-SWAP","instType":"SWAP","bar":"1H"}},
                     "signals":{{"exposure":"1"}},"sizing":{{"mode":"equityPct","value":100}},
                     "risk":{{"leverage":{leverage},"rebalanceThreshold":0.05}}}}"#);
            let strategy = CompiledStrategy::compile(serde_json::from_str::<Manifest>(&json).unwrap(), &[]).unwrap();
            // Each bar adds a fifth of the margin in profit, for sixty bars.
            let mut price = 100.0;
            let mut bars = Vec::new();
            for i in 0..62i64 {
                let open = price;
                if i >= 2 {
                    price *= 1.0 + 0.2 / leverage;
                }
                bars.push(Candle { ts_ms: i * 3_600_000, open, high: open.max(price), low: open.min(price),
                                   close: price, volume: 1.0, confirmed: 1 });
            }
            let gap = price * 0.3;
            bars.extend((62..66).map(|i| Candle { ts_ms: i * 3_600_000, open: gap, high: gap, low: gap,
                                                  close: gap, volume: 1.0, confirmed: 1 }));
            let result = run(&strategy, &bars, &BacktestConfig::default()).unwrap();
            assert!(result.final_equity >= -1e-9 * result.initial_capital,
                    "{leverage}x: ends at {} after {:?}", result.final_equity,
                    result.trades.iter().map(|t| t.exit_reason).collect::<Vec<_>>());
            liquidated += result.liquidations;
        }
        assert!(liquidated > 0, "the gap no longer reaches a liquidation");
    }

    /// Not a correctness test — a stopwatch for the ceiling's cost where it
    /// bites hardest: a 10× position held at full exposure through 200 000
    /// minute bars, which wants to add on nearly every one. Run explicitly:
    /// `cargo test --release -- --ignored --nocapture full_exposure_throughput`
    /// (2026-10-09: 9.4 ms a run; 111 ms when the ceiling was halved for on
    /// every bar, 5.5 ms with no ceiling at all).
    #[test]
    #[ignore]
    fn full_exposure_throughput() {
        let json = r#"{"id":"s","name":"s","market":{"instId":"BTC-USDT-SWAP","instType":"SWAP","bar":"1m"},
             "signals":{"exposure":"1"},"sizing":{"mode":"equityPct","value":100},
             "risk":{"leverage":10,"rebalanceThreshold":0.05}}"#;
        let strategy = CompiledStrategy::compile(serde_json::from_str::<Manifest>(json).unwrap(), &[]).unwrap();
        let mut state = 7u64;
        let mut price = 30_000.0;
        let bars: Vec<Candle> = (0..200_000i64)
            .map(|i| {
                state = state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
                let open = price;
                price *= 1.0 + ((state >> 11) as f64 / (1u64 << 53) as f64 - 0.5) * 0.0004;
                Candle { ts_ms: i * 60_000, open, high: open.max(price), low: open.min(price), close: price,
                         volume: 1.0, confirmed: 1 }
            })
            .collect();
        let best = (0..5)
            .map(|_| {
                let started = std::time::Instant::now();
                run(&strategy, &bars, &BacktestConfig::default()).unwrap();
                started.elapsed().as_secs_f64() * 1000.0
            })
            .fold(f64::MAX, f64::min);
        println!("200 000 bars at full exposure, 10x: best of 5 = {best:.1} ms");
    }

    #[test]
    fn the_daily_breaker_applies_to_a_scaled_position_too() {
        // `decide_live` checks the limit before it branches on exposure, so
        // live halts a continuous strategy that bleeds through it. A backtest
        // that kept trading would report returns from days the runner sat out.
        let bars = falling(60, 0.01);
        let config = BacktestConfig::default();

        let unguarded = run(&strategy("", 1.0), &bars, &config).unwrap();
        let guarded = run(&strategy(r#","maxDailyLossPct":3"#, 1.0), &bars, &config).unwrap();

        assert!(
            guarded.final_equity > unguarded.final_equity,
            "guarded {} vs unguarded {}",
            guarded.final_equity,
            unguarded.final_equity
        );
    }

    /// One order that closes one side and opens the other books its closing
    /// leg as a reversal, and the breaker's stand-down as the breaker — both
    /// used to read "signal".
    #[test]
    fn a_flip_is_a_reversal_and_the_breakers_close_says_so() {
        let json = r#"{"id":"flip","name":"flip",
             "market":{"instId":"BTC-USDT-SWAP","instType":"SWAP","bar":"1H"},
             "signals":{"exposure":"sign(19.5 - bar_index)"},
             "sizing":{"mode":"equityPct","value":100},
             "risk":{"leverage":1,"rebalanceThreshold":0.01}}"#;
        let flips = CompiledStrategy::compile(serde_json::from_str::<Manifest>(json).unwrap(), &[]).unwrap();
        let bars: Vec<Candle> = (0..40)
            .map(|i| Candle { ts_ms: i * 3_600_000, open: 100.0, high: 100.5, low: 99.5, close: 100.0, volume: 1.0, confirmed: 1 })
            .collect();
        let result = run(&flips, &bars, &BacktestConfig::default()).unwrap();
        assert_eq!(result.trades.iter().filter(|t| t.exit_reason == ExitReason::Reversal).count(), 1,
                   "{:?}", result.trades.iter().map(|t| t.exit_reason).collect::<Vec<_>>());

        let halted = run(&strategy(r#","maxDailyLossPct":3"#, 1.0), &falling(60, 0.01), &BacktestConfig::default()).unwrap();
        assert!(halted.trades.iter().any(|t| t.exit_reason == ExitReason::DailyLossHalt),
                "{:?}", halted.trades.iter().map(|t| t.exit_reason).collect::<Vec<_>>());
    }

    #[test]
    fn the_breaker_clears_at_the_day_boundary() {
        // Latched for the day only. A permanently halted backtest would refuse
        // trades the runner takes tomorrow.
        let bars = falling(200, 0.004);
        let guarded = run(
            &strategy(r#","maxDailyLossPct":2"#, 1.0),
            &bars,
            &BacktestConfig::default(),
        )
        .unwrap();
        // More than one trade means it resumed after halting.
        assert!(guarded.trades.len() > 1, "trades {}", guarded.trades.len());
    }

    #[test]
    fn a_levered_scaled_position_can_be_liquidated() {
        // Previously hard-coded to zero: a 5x continuous position could ride a
        // 40% fall to the end of the backtest, which the exchange would never
        // have permitted.
        let bars = falling(80, 0.02);
        let result = run(&strategy("", 5.0), &bars, &BacktestConfig::default()).unwrap();
        assert!(result.liquidations > 0, "expected a liquidation");
        assert!(result
            .trades
            .iter()
            .any(|t| t.exit_reason == ExitReason::Liquidation));
    }

    #[test]
    fn trimming_a_position_books_a_trade() {
        // A scaled position that is reduced without being closed used to
        // realise its P&L into equity and book nothing. Volatility targeting
        // takes profit exactly that way — selling into strength — so the
        // ledger kept every loser and dropped every winner, and every metric
        // derived from it (win rate, payoff, expectancy, and the Monte-Carlo
        // resample that compounds them) was wrong in the same direction.
        let json = r#"{"id":"trim","name":"trim",
             "market":{"instId":"BTC-USDT-SWAP","instType":"SWAP","bar":"1H"},
             "signals":{"exposure":"clamp(1 - bar_index / 60, 0, 1)"},
             "sizing":{"mode":"equityPct","value":100},
             "risk":{"leverage":1,"rebalanceThreshold":0.01}}"#;
        let manifest: Manifest = serde_json::from_str(json).unwrap();
        let strategy = CompiledStrategy::compile(manifest, &[]).unwrap();

        // A steadily rising market, so every trim realises a gain.
        let bars: Vec<Candle> = (0..80)
            .map(|i| {
                let close = 100.0 * (1.0 + 0.004 * i as f64);
                Candle {
                    ts_ms: i * 3_600_000,
                    open: close,
                    high: close * 1.001,
                    low: close * 0.999,
                    close,
                    volume: 1.0,
                    confirmed: 1,
                }
            })
            .collect();

        let result = run(&strategy, &bars, &BacktestConfig::default()).unwrap();
        assert!(result.trades.len() > 5, "trims must appear in the ledger, got {}", result.trades.len());
        // And they must be the winners they actually were.
        let winners = result.trades.iter().filter(|t| t.net_pnl > 0.0).count();
        assert!(
            winners * 2 > result.trades.len(),
            "{winners} winners out of {} on a monotonically rising market",
            result.trades.len()
        );
    }

    #[test]
    fn a_trimmed_position_keeps_its_cost_basis_and_clock() {
        // A partial reduction leaves the same position open. Restarting its
        // entry price would re-mark the remainder at the trim price and erase
        // the unrealised gain that has not been taken yet.
        let json = r#"{"id":"trim2","name":"trim2",
             "market":{"instId":"BTC-USDT-SWAP","instType":"SWAP","bar":"1H"},
             "signals":{"exposure":"clamp(1 - bar_index / 200, 0, 1)"},
             "sizing":{"mode":"equityPct","value":100},
             "risk":{"leverage":1,"rebalanceThreshold":0.01}}"#;
        let manifest: Manifest = serde_json::from_str(json).unwrap();
        let strategy = CompiledStrategy::compile(manifest, &[]).unwrap();
        let bars: Vec<Candle> = (0..60)
            .map(|i| {
                let close = 100.0 * (1.0 + 0.004 * i as f64);
                Candle { ts_ms: i * 3_600_000, open: close, high: close * 1.001,
                         low: close * 0.999, close, volume: 1.0, confirmed: 1 }
            })
            .collect();
        let result = run(&strategy, &bars, &BacktestConfig::default()).unwrap();
        // Every trim is of the same original position, so they all share one
        // entry price — and each is held longer than the last.
        let entries: Vec<f64> = result.trades.iter().map(|t| t.entry_price).collect();
        assert!(entries.windows(2).all(|w| (w[0] - w[1]).abs() < 1e-9),
                "a trim must not re-mark the remainder: {entries:?}");
        let bars_held: Vec<usize> = result.trades.iter().map(|t| t.bars).collect();
        assert!(bars_held.windows(2).all(|w| w[1] >= w[0]),
                "the surviving position keeps ageing: {bars_held:?}");
    }

    #[test]
    fn an_unlevered_position_is_never_liquidated() {
        let bars = falling(80, 0.02);
        let result = run(&strategy("", 1.0), &bars, &BacktestConfig::default()).unwrap();
        assert_eq!(result.liquidations, 0);
    }
}
