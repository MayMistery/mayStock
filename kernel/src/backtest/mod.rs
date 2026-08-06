//! Bar-by-bar simulator.
//!
//! Execution model (see `docs/STRATEGY.md`):
//! - signals are evaluated on the **close of bar i**, using data up to i only;
//! - the resulting order fills at the **open of bar i+1**, plus slippage;
//! - protective exits are checked against bar highs/lows, and when several
//!   could have triggered inside one bar the **worst** one is assumed.
//!
//! Look-ahead bias is structurally impossible here: the evaluation window ends
//! where the execution window begins.

pub mod continuous;
pub mod metrics;

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::candle::Candle;
use crate::decide::{desired_direction, Direction};
use crate::expr::eval::Evaluator;
use crate::expr::ExprResult;
use crate::series;
use crate::strategy::{bar_seconds, CompiledStrategy, SizingMode};

pub use metrics::Metrics;

// MARK: - Inputs

/// One funding settlement on a perpetual swap (OKX settles every 8h).
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct FundingRate {
    pub ts_ms: i64,
    /// Fraction of notional, e.g. `0.0001` = 0.01%. Longs pay when positive.
    pub rate: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BacktestConfig {
    #[serde(rename = "initialCapital", default = "default_capital")]
    pub initial_capital: f64,
    /// Maintenance margin rate used for the swap liquidation check.
    #[serde(rename = "maintenanceMarginRate", default = "default_mmr")]
    pub maintenance_margin_rate: f64,
    /// Real funding history; empty means funding is not modelled (flagged in
    /// the report rather than silently assumed to be zero).
    #[serde(rename = "fundingRates", default)]
    pub funding_rates: Vec<FundingRate>,
    /// Account-tier fallbacks used when the manifest states no costs.
    #[serde(rename = "feeBps")]
    pub fee_bps: Option<f64>,
    #[serde(rename = "slippageBps")]
    pub slippage_bps: Option<f64>,
    /// Named non-OHLCV series from the manifest's `data` block, **already
    /// aligned to the candle array**.
    #[serde(rename = "externalSeries", default)]
    pub external_series: HashMap<String, Vec<f64>>,
    /// Target position per candle from an external script engine. When set it
    /// replaces expression evaluation; risk rules still apply.
    #[serde(rename = "scriptTargets")]
    pub script_targets: Option<Vec<i32>>,
}

fn default_capital() -> f64 {
    10_000.0
}
fn default_mmr() -> f64 {
    0.005
}

impl Default for BacktestConfig {
    fn default() -> Self {
        Self {
            initial_capital: 10_000.0,
            maintenance_margin_rate: 0.005,
            funding_rates: Vec::new(),
            fee_bps: None,
            slippage_bps: None,
            external_series: HashMap::new(),
            script_targets: None,
        }
    }
}

// MARK: - Outputs

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ExitReason {
    Signal,
    StopLoss,
    TakeProfit,
    TrailingStop,
    Liquidation,
    DailyLossHalt,
    EndOfData,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Trade {
    pub id: usize,
    pub direction: Direction,
    #[serde(rename = "entryTs")]
    pub entry_ts: i64,
    #[serde(rename = "exitTs")]
    pub exit_ts: i64,
    #[serde(rename = "entryPrice")]
    pub entry_price: f64,
    #[serde(rename = "exitPrice")]
    pub exit_price: f64,
    pub quantity: f64,
    pub notional: f64,
    #[serde(rename = "grossPnL")]
    pub gross_pnl: f64,
    pub fees: f64,
    pub funding: f64,
    #[serde(rename = "netPnL")]
    pub net_pnl: f64,
    /// Net PnL as a fraction of the equity that existed when the trade opened.
    #[serde(rename = "returnPct")]
    pub return_pct: f64,
    pub bars: usize,
    #[serde(rename = "exitReason")]
    pub exit_reason: ExitReason,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct EquityPoint {
    pub ts: i64,
    pub equity: f64,
    pub price: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BacktestResult {
    #[serde(rename = "strategyId")]
    pub strategy_id: String,
    #[serde(rename = "instId")]
    pub inst_id: String,
    pub bar: String,
    pub start: i64,
    pub end: i64,
    #[serde(rename = "barCount")]
    pub bar_count: usize,
    #[serde(rename = "initialCapital")]
    pub initial_capital: f64,
    #[serde(rename = "finalEquity")]
    pub final_equity: f64,
    pub trades: Vec<Trade>,
    #[serde(rename = "equityCurve")]
    pub equity_curve: Vec<EquityPoint>,
    pub liquidations: usize,
    #[serde(rename = "warmupBars")]
    pub warmup_bars: usize,
    /// True when the strategy is a swap but no funding history was supplied.
    #[serde(rename = "fundingUnmodelled")]
    pub funding_unmodelled: bool,
    pub metrics: Metrics,
}

// MARK: - Engine internals

#[derive(Debug, Clone, Copy)]
struct OpenPosition {
    direction: Direction,
    quantity: f64,
    entry_price: f64,
    entry_ts: i64,
    entry_index: usize,
    equity_at_entry: f64,
    fees: f64,
    funding: f64,
    stop_price: Option<f64>,
    target_price: Option<f64>,
    trail_anchor: Option<f64>,
    liquidation_price: Option<f64>,
}

impl OpenPosition {
    fn notional(&self) -> f64 {
        self.quantity * self.entry_price
    }
}

#[derive(Debug, Clone, Copy)]
struct PendingExit {
    price: f64,
    reason: ExitReason,
}

fn utc_day(ts_ms: i64) -> i64 {
    (ts_ms as f64 / 86_400_000.0).floor() as i64
}

fn unrealised(position: Option<&OpenPosition>, price: f64) -> f64 {
    match position {
        None => 0.0,
        Some(p) => p.direction.sign() * (price - p.entry_price) * p.quantity - p.funding,
    }
}

/// Buying (entering long / exiting short) pays up; selling receives less.
fn fill_price(reference: f64, direction: Direction, is_exit: bool, slippage: f64) -> f64 {
    let buying = if is_exit {
        direction == Direction::Short
    } else {
        direction == Direction::Long
    };
    reference * if buying { 1.0 + slippage } else { 1.0 - slippage }
}

// MARK: - Engine

pub fn run(
    strategy: &CompiledStrategy,
    raw_candles: &[Candle],
    config: &BacktestConfig,
) -> ExprResult<BacktestResult> {
    if strategy.is_continuous() {
        return crate::backtest::continuous::run(strategy, raw_candles, config);
    }

    let mut candles: Vec<Candle> = raw_candles.iter().copied().filter(|c| c.is_confirmed()).collect();
    candles.sort_by_key(|c| c.ts_ms);

    let manifest = &strategy.manifest;
    let costs = strategy.costs(config.fee_bps, config.slippage_bps);
    let fee_rate = costs.fee_bps / 10_000.0;
    let slippage = costs.slippage_bps / 10_000.0;
    let leverage = strategy.leverage();

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

    let highs: Vec<f64> = candles.iter().map(|c| c.high).collect();
    let lows: Vec<f64> = candles.iter().map(|c| c.low).collect();
    let closes: Vec<f64> = candles.iter().map(|c| c.close).collect();
    let atr_series = manifest
        .risk
        .atr_stop
        .map(|s| series::atr(&highs, &lows, &closes, s.period.max(1)));

    let mut equity = config.initial_capital;
    let mut position: Option<OpenPosition> = None;
    let mut trades: Vec<Trade> = Vec::new();
    let mut equity_curve: Vec<EquityPoint> = Vec::with_capacity(candles.len());
    let mut liquidations = 0usize;

    // Outer None = no order pending; inner None = go flat.
    let mut pending_target: Option<Option<Direction>> = None;
    let mut last_exit_index: Option<usize> = None;
    let mut halted_day: Option<i64> = None;
    let mut day_start_equity = config.initial_capital;
    let mut current_day = utc_day(candles[0].ts_ms);

    let funding_by_bar = bucket_funding(&candles, &manifest.market.bar, &config.funding_rates);
    let first_tradable = strategy.warmup_bars.min(candles.len() - 1);

    for index in 0..candles.len() {
        let candle = candles[index];

        // --- New UTC day: reset the daily-loss circuit breaker.
        let day = utc_day(candle.ts_ms);
        if day != current_day {
            current_day = day;
            day_start_equity = equity + unrealised(position.as_ref(), candle.open);
            halted_day = None;
        }

        // --- 1. Execute the order decided at the previous bar's close.
        if let Some(target) = pending_target.take() {
            // Cooldown counts from the *previous* exit: reversing straight out
            // of a losing side is the signal working, not churn.
            let cooldown_reference = last_exit_index;
            if let Some(existing) = position {
                if Some(existing.direction) != target {
                    let fill = fill_price(candle.open, existing.direction, true, slippage);
                    close_position(
                        &mut position,
                        fill,
                        candle.ts_ms,
                        index,
                        ExitReason::Signal,
                        fee_rate,
                        &mut equity,
                        &mut trades,
                    );
                    last_exit_index = Some(index);
                }
            }
            if position.is_none() && halted_day.is_none() {
                if let Some(direction) = target {
                    if can_enter(index, cooldown_reference, manifest.risk.cooldown_bars) {
                        let fill = fill_price(candle.open, direction, false, slippage);
                        // ATR as known at the decision bar — never this bar's.
                        let atr = atr_series.as_ref().map(|s| {
                            if index > 0 {
                                s[index - 1]
                            } else {
                                f64::NAN
                            }
                        });
                        open_position(
                            strategy,
                            config,
                            &mut position,
                            direction,
                            fill,
                            candle.ts_ms,
                            index,
                            &mut equity,
                            leverage,
                            fee_rate,
                            atr,
                        );
                    }
                }
            }
        }

        // --- 2. Protective exits, checked against this bar's range.
        if let Some(existing) = position {
            if let Some(exit) = protective_exit(strategy, &existing, &candle, leverage) {
                if exit.reason == ExitReason::Liquidation {
                    liquidations += 1;
                }
                close_position(
                    &mut position,
                    exit.price,
                    candle.ts_ms,
                    index,
                    exit.reason,
                    fee_rate,
                    &mut equity,
                    &mut trades,
                );
                last_exit_index = Some(index);
            }
        }

        // --- 3. Funding settlements that fall inside this bar.
        if let Some(existing) = position.as_mut() {
            if let Some(rates) = funding_by_bar.get(&index) {
                for rate in rates {
                    existing.funding +=
                        rate * existing.quantity * candle.close * existing.direction.sign();
                }
            }
        }

        // --- 4. Trail the stop with this bar's extreme. Never intra-bar
        //        look-ahead: the level updated here only governs *later* bars.
        if let Some(existing) = position.as_mut() {
            if let Some(trail_pct) = manifest.risk.trailing_stop_pct {
                let anchor = existing.trail_anchor.unwrap_or(existing.entry_price);
                let updated = if existing.direction == Direction::Long {
                    anchor.max(candle.high)
                } else {
                    anchor.min(candle.low)
                };
                existing.trail_anchor = Some(updated);
                let trail_stop = if existing.direction == Direction::Long {
                    updated * (1.0 - trail_pct / 100.0)
                } else {
                    updated * (1.0 + trail_pct / 100.0)
                };
                existing.stop_price = Some(match existing.stop_price {
                    Some(current) => {
                        if existing.direction == Direction::Long {
                            current.max(trail_stop)
                        } else {
                            current.min(trail_stop)
                        }
                    }
                    None => trail_stop,
                });
            }
        }

        // --- 5. Daily-loss circuit breaker.
        let marked = equity + unrealised(position.as_ref(), candle.close);
        if let Some(limit) = manifest.risk.max_daily_loss_pct {
            if halted_day.is_none()
                && day_start_equity > 0.0
                && (day_start_equity - marked) / day_start_equity * 100.0 >= limit
            {
                if let Some(existing) = position {
                    let fill = fill_price(candle.close, existing.direction, true, slippage);
                    close_position(
                        &mut position,
                        fill,
                        candle.ts_ms,
                        index,
                        ExitReason::DailyLossHalt,
                        fee_rate,
                        &mut equity,
                        &mut trades,
                    );
                    last_exit_index = Some(index);
                }
                halted_day = Some(day);
                pending_target = None;
            }
        }

        // --- 6. Evaluate signals on this close; the order fills next bar.
        if index >= first_tradable && index + 1 < candles.len() && halted_day.is_none() {
            let current = position.map(|p| p.direction);
            let held = position.map(|p| index - p.entry_index).unwrap_or(0);
            let target = desired_direction(
                index,
                current,
                held,
                manifest.risk.min_hold_bars,
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

        // Warm-up bars are excluded from the curve: equity is flat there by
        // construction, and keeping them would dilute volatility and flatter
        // the Sharpe ratio of every short window.
        if index >= first_tradable {
            equity_curve.push(EquityPoint {
                ts: candle.ts_ms,
                equity: equity + unrealised(position.as_ref(), candle.close),
                price: candle.close,
            });
        }
    }

    // Close anything still open at the last bar, so metrics see realised PnL.
    if let Some(existing) = position {
        let last = candles[candles.len() - 1];
        let fill = fill_price(last.close, existing.direction, true, slippage);
        close_position(
            &mut position,
            fill,
            last.ts_ms,
            candles.len() - 1,
            ExitReason::EndOfData,
            fee_rate,
            &mut equity,
            &mut trades,
        );
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
        liquidations,
        warmup_bars: strategy.warmup_bars,
        funding_unmodelled: manifest.market.inst_type == crate::strategy::InstrumentType::Swap
            && config.funding_rates.is_empty(),
        metrics,
    })
}

fn can_enter(index: usize, last_exit: Option<usize>, cooldown: usize) -> bool {
    match (cooldown, last_exit) {
        (0, _) | (_, None) => true,
        (c, Some(exit)) => index - exit > c,
    }
}

#[allow(clippy::too_many_arguments)]
fn open_position(
    strategy: &CompiledStrategy,
    config: &BacktestConfig,
    position: &mut Option<OpenPosition>,
    direction: Direction,
    price: f64,
    ts: i64,
    index: usize,
    equity: &mut f64,
    leverage: f64,
    fee_rate: f64,
    atr: Option<f64>,
) {
    if !(price > 0.0) || !(*equity > 0.0) {
        return;
    }
    let manifest = &strategy.manifest;
    let stop_distance = crate::sizing::stop_distance(strategy, price, atr);

    let Some(notional) = crate::sizing::target_notional(
        strategy, *equity, price, leverage, stop_distance)
    else { return };

    let quantity = notional / price;
    let fee = notional * fee_rate;
    *equity -= fee;

    let mut new = OpenPosition {
        direction,
        quantity,
        entry_price: price,
        entry_ts: ts,
        entry_index: index,
        equity_at_entry: *equity + fee,
        fees: fee,
        funding: 0.0,
        stop_price: None,
        target_price: None,
        trail_anchor: Some(price),
        liquidation_price: None,
    };

    if let Some(distance) = stop_distance {
        new.stop_price = Some(if direction == Direction::Long {
            price - distance
        } else {
            price + distance
        });
    }
    if let Some(take_profit) = manifest.risk.take_profit_pct {
        new.target_price = Some(if direction == Direction::Long {
            price * (1.0 + take_profit / 100.0)
        } else {
            price * (1.0 - take_profit / 100.0)
        });
    }
    if leverage > 1.0 {
        let buffer = (1.0 - config.maintenance_margin_rate) / leverage;
        new.liquidation_price = Some(if direction == Direction::Long {
            price * (1.0 - buffer)
        } else {
            price * (1.0 + buffer)
        });
    }
    *position = Some(new);
}

#[allow(clippy::too_many_arguments)]
fn close_position(
    position: &mut Option<OpenPosition>,
    price: f64,
    ts: i64,
    index: usize,
    reason: ExitReason,
    fee_rate: f64,
    equity: &mut f64,
    trades: &mut Vec<Trade>,
) {
    let Some(existing) = position.take() else {
        return;
    };

    let exit_notional = existing.quantity * price;
    let exit_fee = exit_notional * fee_rate;
    let gross = existing.direction.sign() * (price - existing.entry_price) * existing.quantity;
    let net = gross - exit_fee - existing.funding;
    *equity += net;

    trades.push(Trade {
        id: trades.len() + 1,
        direction: existing.direction,
        entry_ts: existing.entry_ts,
        exit_ts: ts,
        entry_price: existing.entry_price,
        exit_price: price,
        quantity: existing.quantity,
        notional: existing.notional(),
        gross_pnl: gross,
        fees: existing.fees + exit_fee,
        funding: existing.funding,
        net_pnl: net - existing.fees,
        return_pct: if existing.equity_at_entry > 0.0 {
            (net - existing.fees) / existing.equity_at_entry * 100.0
        } else {
            0.0
        },
        bars: index - existing.entry_index,
        exit_reason: reason,
    });
}

/// Pick the worst outcome among every protective level this bar could have
/// touched. When both a stop and a target sit inside one candle there is no way
/// to know which came first, so the simulation assumes the loss.
fn protective_exit(
    strategy: &CompiledStrategy,
    position: &OpenPosition,
    candle: &Candle,
    leverage: f64,
) -> Option<PendingExit> {
    let mut candidates: Vec<PendingExit> = Vec::new();
    let is_long = position.direction == Direction::Long;

    let mut consider = |level: Option<f64>, reason: ExitReason, favourable: bool| {
        let Some(level) = level else { return };
        // A long exits downward on a stop and upward on a target.
        let downward = if is_long { !favourable } else { favourable };
        if downward {
            if candle.low <= level {
                candidates.push(PendingExit {
                    price: candle.open.min(level),
                    reason,
                });
            }
        } else if candle.high >= level {
            candidates.push(PendingExit {
                price: candle.open.max(level),
                reason,
            });
        }
    };

    let is_trailing = strategy.manifest.risk.trailing_stop_pct.is_some();
    consider(
        position.stop_price,
        if is_trailing {
            ExitReason::TrailingStop
        } else {
            ExitReason::StopLoss
        },
        false,
    );
    consider(position.target_price, ExitReason::TakeProfit, true);
    if leverage > 1.0 {
        consider(position.liquidation_price, ExitReason::Liquidation, false);
    }

    // "Worst" means lowest price for a long, highest for a short.
    let sign = position.direction.sign();
    candidates
        .into_iter()
        .reduce(|best, next| if sign * next.price < sign * best.price { next } else { best })
}

/// Map each funding settlement onto the bar whose interval contains it.
fn bucket_funding(
    candles: &[Candle],
    bar: &str,
    rates: &[FundingRate],
) -> HashMap<usize, Vec<f64>> {
    let mut result: HashMap<usize, Vec<f64>> = HashMap::new();
    if rates.is_empty() || candles.is_empty() {
        return result;
    }
    let mut sorted: Vec<FundingRate> = rates.to_vec();
    sorted.sort_by_key(|r| r.ts_ms);
    let span_ms = (bar_seconds(bar) * 1_000.0) as i64;

    let mut cursor = 0usize;
    for funding in sorted {
        while cursor + 1 < candles.len() && candles[cursor + 1].ts_ms <= funding.ts_ms {
            cursor += 1;
        }
        let start = candles[cursor].ts_ms;
        if funding.ts_ms >= start && funding.ts_ms < start + span_ms {
            result.entry(cursor).or_default().push(funding.rate);
        }
    }
    result
}

fn empty_result(
    strategy: &CompiledStrategy,
    candles: &[Candle],
    config: &BacktestConfig,
) -> BacktestResult {
    let manifest = &strategy.manifest;
    BacktestResult {
        strategy_id: manifest.id.clone(),
        inst_id: manifest.market.inst_id.clone(),
        bar: manifest.market.bar.clone(),
        start: candles.first().map(|c| c.ts_ms).unwrap_or(0),
        end: candles.last().map(|c| c.ts_ms).unwrap_or(0),
        bar_count: candles.len(),
        initial_capital: config.initial_capital,
        final_equity: config.initial_capital,
        trades: Vec::new(),
        equity_curve: candles
            .iter()
            .map(|c| EquityPoint {
                ts: c.ts_ms,
                equity: config.initial_capital,
                price: c.close,
            })
            .collect(),
        liquidations: 0,
        warmup_bars: strategy.warmup_bars,
        funding_unmodelled: manifest.market.inst_type == crate::strategy::InstrumentType::Swap
            && config.funding_rates.is_empty(),
        metrics: Metrics::compute(
            &[],
            &[],
            config.initial_capital,
            &manifest.market.bar,
            strategy.free_parameter_count,
        ),
    }
}

