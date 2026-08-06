//! The signal decision, and the live sizing that follows from it.
//!
//! This module is the whole point of moving the kernel to Rust. In the Swift
//! implementation the backtester had `BacktestEngine.desiredDirection` and the
//! live runner had `StrategyRunner.decide`, two functions that were required to
//! agree by convention and a comment. Here there is exactly one
//! [`desired_direction`], called by the simulator on bar *i* and by the live
//! runner on the latest confirmed bar. They cannot drift apart, because there
//! is nothing to drift from.

use serde::{Deserialize, Serialize};

use crate::candle::Candle;
use crate::expr::eval::{truthy, Evaluator};
use crate::expr::ExprResult;
use crate::strategy::{CompiledStrategy, SizingMode};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Long,
    Short,
}

impl Direction {
    pub fn sign(self) -> f64 {
        match self {
            Self::Long => 1.0,
            Self::Short => -1.0,
        }
    }

    /// The FFI encoding: 1 long, −1 short, 0 flat.
    pub fn to_i32(value: Option<Self>) -> i32 {
        match value {
            Some(Self::Long) => 1,
            Some(Self::Short) => -1,
            None => 0,
        }
    }

    pub fn from_i32(value: i32) -> Option<Self> {
        match value {
            1 => Some(Self::Long),
            -1 => Some(Self::Short),
            _ => None,
        }
    }
}

/// Target position for the *next* bar, given this bar's signals.
///
/// Exits are considered before entries. Two entry signals firing at once is
/// treated as no signal — an ambiguous strategy should not silently pick a side
/// on the user's money.
#[allow(clippy::too_many_arguments)]
pub fn desired_direction(
    index: usize,
    current: Option<Direction>,
    bars_held: usize,
    min_hold: usize,
    max_hold: Option<usize>,
    long_entry: Option<&[f64]>,
    long_exit: Option<&[f64]>,
    short_entry: Option<&[f64]>,
    short_exit: Option<&[f64]>,
    script_targets: Option<&[i32]>,
) -> Option<Direction> {
    // A script engine has already decided; risk rules elsewhere still apply.
    if let Some(targets) = script_targets {
        return match targets.get(index) {
            Some(value) => Direction::from_i32(*value),
            None => current,
        };
    }

    let fires = |series: Option<&[f64]>| match series {
        Some(s) => truthy(s, index),
        None => false,
    };

    let wants_long = fires(long_entry);
    let wants_short = fires(short_entry);

    // The time barrier outranks every signal, including a reversal. A position
    // that has run out of time is closed and left closed; re-entering is a
    // fresh decision on the next bar, subject to the cooldown like any other.
    // Letting a reversal bypass it would make the limit unenforceable in
    // exactly the choppy market it exists for.
    if current.is_some() && max_hold.is_some_and(|limit| bars_held >= limit) {
        return None;
    }

    match current {
        None => {
            if wants_long && wants_short {
                return None;
            }
            if wants_long {
                return Some(Direction::Long);
            }
            if wants_short {
                return Some(Direction::Short);
            }
            None
        }
        Some(Direction::Long) => {
            if wants_short && !wants_long {
                return Some(Direction::Short); // reversal
            }
            if bars_held < min_hold {
                return Some(Direction::Long);
            }
            if fires(long_exit) {
                None
            } else {
                Some(Direction::Long)
            }
        }
        Some(Direction::Short) => {
            if wants_long && !wants_short {
                return Some(Direction::Long);
            }
            if bars_held < min_hold {
                return Some(Direction::Short);
            }
            if fires(short_exit) {
                None
            } else {
                Some(Direction::Short)
            }
        }
    }
}

// MARK: - Live decision

/// Everything the runner needs in order to place (or withhold) one order.
///
/// The runner used to receive only a direction and then size the position
/// itself in Swift, duplicating the backtester's sizing, its daily-loss gate
/// and its rebalance threshold. Those three copies are gone: the kernel now
/// returns a finished plan and Swift's only job is to submit `base_delta`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiveDecision {
    /// 1 long, −1 short, 0 flat.
    pub target: i32,
    /// Position the strategy should hold, in coins (signed).
    #[serde(rename = "targetBaseQuantity")]
    pub target_base_quantity: f64,
    /// Coins to buy (positive) or sell (negative) to get there.
    #[serde(rename = "baseDelta")]
    pub base_delta: f64,
    /// False when the plan is "do nothing" — below the rebalance threshold,
    /// unsizeable, or already in position.
    #[serde(rename = "shouldTrade")]
    pub should_trade: bool,
    /// The daily-loss circuit breaker has tripped: close out and stand down
    /// for the rest of the UTC day.
    #[serde(rename = "haltDailyLoss")]
    pub halt_daily_loss: bool,
    /// Human-readable justification, for the runtime status line.
    pub reason: String,
    /// Protective levels to attach to the entry order, so the *exchange*
    /// enforces them. Polling for a stop on a 20-second tick would miss
    /// exactly the intrabar spike a stop exists for, and would not protect the
    /// position at all while the app is closed.
    #[serde(rename = "stopPrice")]
    pub stop_price: Option<f64>,
    #[serde(rename = "takeProfitPrice")]
    pub take_profit_price: Option<f64>,
    /// Where the trailing stop of the *currently held* position now sits.
    ///
    /// Reported on every bar, including bars where the signal has not changed
    /// and nothing is traded, because the level moves even when the position
    /// does not. The runner's job is to keep the exchange's stop in step with
    /// this number; the number itself is computed here, from confirmed bars,
    /// exactly as the backtester computes it.
    ///
    /// Deliberately *not* delegated to the exchange's own trailing-stop order.
    /// OKX trails on every tick, the backtest trails on bar extremes, and a
    /// stop that behaves differently in production than in simulation is worth
    /// less than a slightly slower one that behaves identically.
    #[serde(rename = "trailingStopPrice")]
    pub trailing_stop_price: Option<f64>,
    /// Continuous exposure in −1…+1 for exposure strategies; NaN otherwise.
    #[serde(rename = "targetExposure")]
    pub target_exposure: f64,
    /// Confirmed bars available after filtering.
    #[serde(rename = "confirmedBars")]
    pub confirmed_bars: usize,
    /// Timestamp of the bar the decision was made on, so the caller can tell
    /// whether it has already acted on this bar.
    #[serde(rename = "barTs")]
    pub bar_ts: i64,
    /// True while indicators are still warming up — the caller should hold, not
    /// treat the flat target as a signal to sell.
    #[serde(rename = "warmingUp")]
    pub warming_up: bool,
}

/// What the runner knows about the account when it asks for a plan.
#[derive(Debug, Clone, Copy)]
pub struct AccountState {
    /// Capital this strategy may deploy, already compounded by its own P&L.
    pub equity: f64,
    /// Coins currently held (signed).
    pub held_base: f64,
    /// Strategy equity at the start of the current UTC day, for the breaker.
    pub day_start_equity: f64,
    /// Cap from the portfolio, if tighter than the manifest's.
    pub leverage_cap: Option<f64>,
    /// Bars since this strategy last closed a position, for the cooldown rule.
    /// `None` means it has never held one.
    pub bars_since_exit: Option<usize>,
    /// The daily-loss breaker already tripped today.
    pub halted_today: bool,
    /// Average entry price of the held position; 0 when flat. Seeds the
    /// trailing anchor, so a position that never moved in its favour trails
    /// from where it was opened rather than from an arbitrary bar.
    pub entry_price: f64,
}

impl Default for AccountState {
    fn default() -> Self {
        Self {
            equity: 0.0,
            held_base: 0.0,
            day_start_equity: 0.0,
            leverage_cap: None,
            bars_since_exit: None,
            halted_today: false,
            entry_price: 0.0,
        }
    }
}

/// May a new position be opened, given the cooldown rule? Shared with the
/// backtester so "wait N bars after an exit" means the same in both.
pub fn can_enter(bars_since_exit: Option<usize>, cooldown: usize) -> bool {
    match (cooldown, bars_since_exit) {
        (0, _) | (_, None) => true,
        (c, Some(since)) => since > c,
    }
}

#[allow(clippy::too_many_arguments)]
fn idle(reason: &str, current: Option<Direction>, held: f64, bars: usize, ts: i64,
        warming: bool, trailing: Option<f64>) -> LiveDecision {
    LiveDecision {
        target: Direction::to_i32(current),
        target_exposure: f64::NAN,
        target_base_quantity: held,
        base_delta: 0.0,
        should_trade: false,
        halt_daily_loss: false,
        reason: reason.to_string(),
        confirmed_bars: bars,
        bar_ts: ts,
        warming_up: warming,
        stop_price: None,
        take_profit_price: None,
        trailing_stop_price: trailing,
    }
}

/// Where the held position's trailing stop sits on this bar.
///
/// Recomputed from the bars since entry rather than carried between calls: the
/// runner is a stateless caller by design, and a level derived from data the
/// exchange can confirm is one that survives a restart.
fn trailing_level(
    strategy: &CompiledStrategy,
    candles: &[Candle],
    index: usize,
    current: Option<Direction>,
    bars_held: usize,
    entry_price: f64,
) -> Option<f64> {
    let direction = current?;
    let trail_pct = strategy.manifest.risk.trailing_stop_pct?;
    if !(entry_price > 0.0) {
        return None;
    }
    let start = index.saturating_sub(bars_held);
    let highs: Vec<f64> = candles[start..=index].iter().map(|c| c.high).collect();
    let lows: Vec<f64> = candles[start..=index].iter().map(|c| c.low).collect();
    let anchor = crate::sizing::trail_anchor(direction, entry_price, &highs, &lows);
    let level = crate::sizing::trailing_stop_level(direction, anchor, trail_pct);

    // The fixed stop the position opened with is the floor this ratchets from,
    // matching the backtester, where the trail may only tighten `stop_price`.
    //
    // Its ATR is read at the bar the entry was *decided* on — one before the
    // fill — because that is the bar the backtester sizes from. Reading it at
    // the current bar instead would make the floor drift with volatility, and
    // a stop that loosens as the market calms is not a stop.
    let atr = strategy.manifest.risk.atr_stop.map(|spec| {
        let highs: Vec<f64> = candles.iter().map(|c| c.high).collect();
        let lows: Vec<f64> = candles.iter().map(|c| c.low).collect();
        let closes: Vec<f64> = candles.iter().map(|c| c.close).collect();
        let series = crate::series::atr(&highs, &lows, &closes, spec.period.max(1));
        series
            .get(start.saturating_sub(1))
            .copied()
            .unwrap_or(f64::NAN)
    });
    let opening = crate::sizing::stop_distance(strategy, entry_price, atr).map(|d| {
        if direction == Direction::Long { entry_price - d } else { entry_price + d }
    });
    Some(crate::sizing::ratchet_stop(direction, opening, level))
}

/// Evaluate a strategy against the latest confirmed bar and size the result.
///
/// This is the live counterpart of one iteration of the backtest loop, and it
/// deliberately shares [`desired_direction`] and [`crate::sizing`] with it.
pub fn decide_live(
    strategy: &CompiledStrategy,
    raw_candles: &[Candle],
    current: Option<Direction>,
    bars_held: usize,
    external: &std::collections::HashMap<String, Vec<f64>>,
    account: AccountState,
) -> ExprResult<LiveDecision> {
    let mut candles: Vec<Candle> = raw_candles
        .iter()
        .copied()
        .filter(|c| c.is_confirmed())
        .collect();
    candles.sort_by_key(|c| c.ts_ms);

    if candles.is_empty() {
        return Ok(idle("无已确认 K 线", None, account.held_base, 0, 0, true, None));
    }

    let index = candles.len() - 1;
    let bar_ts = candles[index].ts_ms;
    // The backtester never trades before `warmup_bars`; the live runner must
    // not either, or the first live signal would be one the backtest refused.
    if candles.len() <= strategy.warmup_bars + 1 {
        return Ok(idle(
            "指标预热中", current, account.held_base, candles.len(), bar_ts, true, None));
    }

    // The held position's trailing stop, recomputed on every bar — it moves
    // even when the signal does not, and the runner needs it on the quiet bars
    // most of all.
    let trailing = trailing_level(
        strategy, &candles, index, current, bars_held, account.entry_price);

    let price = candles[index].close;
    let manifest_leverage = if strategy.manifest.market.inst_type.allows_leverage() {
        strategy.manifest.risk.leverage.max(1.0)
    } else {
        1.0
    };
    let leverage = account
        .leverage_cap
        .map_or(manifest_leverage, |cap| manifest_leverage.min(cap));

    // The daily-loss breaker outranks every signal: once it trips the only
    // legitimate action is to close out. Checked before sizing so a halted
    // strategy cannot be handed a position to open.
    if let Some(limit) = strategy.manifest.risk.max_daily_loss_pct {
        let tripped = account.day_start_equity > 0.0
            && (account.day_start_equity - account.equity) / account.day_start_equity * 100.0
                >= limit;
        if tripped || account.halted_today {
            return Ok(LiveDecision {
                target: 0,
                target_exposure: f64::NAN,
                target_base_quantity: 0.0,
                base_delta: -account.held_base,
                should_trade: account.held_base.abs() > 1e-12,
                halt_daily_loss: true,
                reason: format!("日内亏损达到 {limit:.1}%，本日停止交易"),
                confirmed_bars: candles.len(),
                bar_ts,
                warming_up: false,
                stop_price: None,
                take_profit_price: None,
                trailing_stop_price: None,
            });
        }
    }

    let mut evaluator = Evaluator::new(&candles, &strategy.params, external);

    if let Some(exposure) = strategy.exposure.as_ref() {
        let series = evaluator.evaluate(exposure)?;
        let raw = series.get(index).copied().unwrap_or(f64::NAN);
        // Unknown means flat, never a guess.
        let clamped = if raw.is_nan() { 0.0 } else { raw };
        let allows_short = strategy.manifest.market.inst_type.allows_short();
        let floor = if allows_short { -1.0 } else { 0.0 };
        let bounded = clamped.clamp(floor, 1.0);

        let scale = match strategy.manifest.sizing.mode {
            SizingMode::VolatilityTarget => {
                let closes: Vec<f64> = candles.iter().map(|c| c.close).collect();
                let vol = realised_volatility(
                    &closes,
                    strategy.manifest.risk.vol_lookback_bars,
                    &strategy.manifest.market.bar,
                );
                volatility_scale(
                    strategy.manifest.sizing.value,
                    vol[index],
                    strategy.manifest.risk.max_exposure,
                )
            }
            SizingMode::EquityPct => strategy.manifest.sizing.value / 100.0,
            _ => 1.0,
        };
        let cap = strategy.manifest.risk.max_exposure;
        let effective = (bounded * scale).clamp(if allows_short { -cap } else { 0.0 }, cap);

        // Size to the fraction, not merely to its sign.
        let target_base = if price > 0.0 && account.equity > 0.0 {
            account.equity * effective * leverage / price
        } else {
            0.0
        };
        let current_exposure = if account.equity > 0.0 && leverage > 0.0 {
            account.held_base * price / (account.equity * leverage)
        } else {
            0.0
        };
        // Rebalancing every bar would churn the edge away in fees; this is the
        // same threshold the backtester honours.
        let threshold = strategy.manifest.risk.rebalance_threshold.max(0.0);
        let drift = (effective - current_exposure).abs();

        return Ok(LiveDecision {
            target: if effective > 1e-9 { 1 } else if effective < -1e-9 { -1 } else { 0 },
            target_exposure: effective,
            target_base_quantity: target_base,
            base_delta: target_base - account.held_base,
            should_trade: drift >= threshold,
            halt_daily_loss: false,
            reason: if drift >= threshold {
                format!("敞口 {current_exposure:.3} → {effective:.3}")
            } else {
                format!("敞口 {current_exposure:.3} → {effective:.3}，未达再平衡阈值 {threshold:.3}")
            },
            confirmed_bars: candles.len(),
            bar_ts,
            warming_up: false,
            // Continuous strategies express risk through exposure size, not
            // through a stop level; attaching one would fight the rebalancer.
            stop_price: None,
            take_profit_price: None,
            trailing_stop_price: None,
        });
    }

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

    let target = desired_direction(
        index,
        current,
        bars_held,
        strategy.manifest.risk.min_hold_bars,
        strategy.manifest.risk.max_hold_bars,
        long_entry.as_deref(),
        long_exit.as_deref(),
        short_entry.as_deref(),
        short_exit.as_deref(),
        None,
    );

    // Binary strategies switch in and out; nothing to do while the side is
    // unchanged.
    if target == current {
        return Ok(idle("信号未变", target, account.held_base, candles.len(), bar_ts, false, trailing));
    }

    // Cooldown: reversing straight out of a losing side is the signal working,
    // but re-entering the same side immediately after an exit is churn. The
    // backtester enforces this; without it live re-enters a bar early.
    if target.is_some() && current.is_none()
        && !can_enter(account.bars_since_exit, strategy.manifest.risk.cooldown_bars)
    {
        return Ok(idle(
            "冷却中", None, account.held_base, candles.len(), bar_ts, false, trailing));
    }

    let mut target_base = 0.0;
    let mut stop_price = None;
    let mut take_profit_price = None;
    if let Some(direction) = target {
        let highs: Vec<f64> = candles.iter().map(|c| c.high).collect();
        let lows: Vec<f64> = candles.iter().map(|c| c.low).collect();
        let closes: Vec<f64> = candles.iter().map(|c| c.close).collect();
        // The ATR as known at the decision bar, matching the backtester, which
        // sizes from the bar *before* the fill.
        let atr = strategy.manifest.risk.atr_stop.map(|spec| {
            let series = crate::series::atr(&highs, &lows, &closes, spec.period.max(1));
            series.get(index).copied().unwrap_or(f64::NAN)
        });
        let distance = crate::sizing::stop_distance(strategy, price, atr);
        // Levels ride along with the order so the exchange, not this loop,
        // enforces them.
        stop_price = distance.map(|d| {
            if direction == Direction::Long { price - d } else { price + d }
        });
        take_profit_price = strategy.manifest.risk.take_profit_pct.map(|pct| {
            if direction == Direction::Long {
                price * (1.0 + pct / 100.0)
            } else {
                price * (1.0 - pct / 100.0)
            }
        });
        match crate::sizing::target_notional(strategy, account.equity, price, leverage, distance) {
            Some(notional) => target_base = notional / price * direction.sign(),
            None => {
                // The signal is still the signal. Reporting it as "flat"
                // because the position cannot be sized would tell the caller
                // the strategy has no opinion, when in fact it has one it
                // cannot act on — and a status line saying so is the point.
                return Ok(LiveDecision {
                    target: Direction::to_i32(target),
                    target_exposure: f64::NAN,
                    target_base_quantity: account.held_base,
                    base_delta: 0.0,
                    should_trade: false,
                    halt_daily_loss: false,
                    reason: "无法定仓（缺少止损距离或资金为零）".to_string(),
                    confirmed_bars: candles.len(),
                    bar_ts,
                    warming_up: false,
                    stop_price: None,
                    take_profit_price: None,
                    trailing_stop_price: trailing,
                });
            }
        }
    }

    let delta = target_base - account.held_base;
    Ok(LiveDecision {
        target: Direction::to_i32(target),
        target_exposure: f64::NAN,
        target_base_quantity: target_base,
        base_delta: delta,
        should_trade: delta.abs() > 1e-12,
        halt_daily_loss: false,
        reason: match target {
            Some(d) => format!("信号{}", if d == Direction::Long { "做多" } else { "做空" }),
            None => "信号平仓".to_string(),
        },
        confirmed_bars: candles.len(),
        bar_ts,
        warming_up: false,
        stop_price,
        take_profit_price,
        // A position being opened or reversed on this bar starts its trail from
        // the entry, which `stop_price` already expresses; the level below
        // belongs to the position being *left*, so it must not leak into the
        // new one.
        trailing_stop_price: if target == current { trailing } else { None },
    })
}

// MARK: - Volatility targeting

/// Annualised realised volatility, in percent, from a trailing window of
/// close-to-close returns.
///
/// Bar-aware: the same 60-bar window means 60 hours on 1H and 60 days on 1D,
/// and the annualisation factor differs accordingly.
pub fn realised_volatility(closes: &[f64], lookback: usize, bar: &str) -> Vec<f64> {
    let mut out = vec![f64::NAN; closes.len()];
    if lookback <= 1 || closes.len() <= lookback {
        return out;
    }

    let bars_per_year = 365.25 * 86_400.0 / crate::strategy::bar_seconds(bar);
    let mut returns = vec![f64::NAN; closes.len()];
    for index in 1..closes.len() {
        if closes[index - 1] > 0.0 && closes[index] > 0.0 {
            returns[index] = closes[index] / closes[index - 1] - 1.0;
        }
    }

    for index in lookback..closes.len() {
        let window = &returns[(index + 1 - lookback)..=index];
        let valid: Vec<f64> = window.iter().copied().filter(|v| !v.is_nan()).collect();
        if valid.len() <= 2 {
            continue;
        }
        let mean = valid.iter().sum::<f64>() / valid.len() as f64;
        let variance: f64 = valid.iter().map(|v| (v - mean) * (v - mean)).sum();
        let deviation = (variance / (valid.len() - 1) as f64).sqrt();
        out[index] = deviation * bars_per_year.sqrt() * 100.0;
    }
    out
}

/// Multiplier that takes a position from raw exposure to target volatility.
/// Returns 0 when volatility is unknown — never a guess.
pub fn volatility_scale(target_vol_pct: f64, realised_vol_pct: f64, cap: f64) -> f64 {
    if !realised_vol_pct.is_finite() || realised_vol_pct <= 1e-9 || target_vol_pct <= 0.0 {
        return 0.0;
    }
    (target_vol_pct / realised_vol_pct).min(cap)
}

#[cfg(test)]
mod tests {
    use super::*;

    const YES: &[f64] = &[1.0, 1.0, 1.0];
    const NO: &[f64] = &[0.0, 0.0, 0.0];
    const UNKNOWN: &[f64] = &[f64::NAN, f64::NAN, f64::NAN];

    fn decide(
        current: Option<Direction>,
        long_entry: Option<&[f64]>,
        long_exit: Option<&[f64]>,
        short_entry: Option<&[f64]>,
        short_exit: Option<&[f64]>,
    ) -> Option<Direction> {
        desired_direction(1, current, 99, 0, None, long_entry, long_exit, short_entry, short_exit, None)
    }

    #[test]
    fn a_long_entry_from_flat_goes_long() {
        assert_eq!(decide(None, Some(YES), None, None, None), Some(Direction::Long));
    }

    #[test]
    fn two_entries_at_once_is_no_signal() {
        // Ambiguity must not silently pick a side on the user's money.
        assert_eq!(decide(None, Some(YES), None, Some(YES), None), None);
    }

    #[test]
    fn an_exit_signal_flattens() {
        assert_eq!(decide(Some(Direction::Long), None, Some(YES), None, None), None);
    }

    #[test]
    fn holding_continues_without_an_exit() {
        assert_eq!(
            decide(Some(Direction::Long), None, Some(NO), None, None),
            Some(Direction::Long)
        );
    }

    #[test]
    fn an_unknown_signal_never_trades() {
        assert_eq!(decide(None, Some(UNKNOWN), None, None, None), None);
        assert_eq!(
            decide(Some(Direction::Long), None, Some(UNKNOWN), None, None),
            Some(Direction::Long),
            "an unknown exit must not close a position"
        );
    }

    #[test]
    fn an_opposing_entry_reverses() {
        assert_eq!(
            decide(Some(Direction::Long), Some(NO), None, Some(YES), None),
            Some(Direction::Short)
        );
    }

    #[test]
    fn min_hold_defers_the_exit_but_not_the_reversal() {
        // Held 1 bar, minimum 5: the exit is ignored…
        assert_eq!(
            desired_direction(1, Some(Direction::Long), 1, 5, None, None, Some(YES), None, None, None),
            Some(Direction::Long)
        );
        // …but an opposing entry still reverses, because that is the signal
        // working rather than churn.
        assert_eq!(
            desired_direction(1, Some(Direction::Long), 1, 5, None, Some(NO), Some(YES), Some(YES), None, None),
            Some(Direction::Short)
        );
    }

    #[test]
    fn the_time_barrier_closes_a_position_that_ran_out_of_bars() {
        // Held 10 bars with a 10-bar limit and no exit signal in sight.
        assert_eq!(
            desired_direction(1, Some(Direction::Long), 10, 0, Some(10), None, Some(NO), None, None, None),
            None
        );
        // One bar short of the limit it is still held.
        assert_eq!(
            desired_direction(1, Some(Direction::Long), 9, 0, Some(10), None, Some(NO), None, None, None),
            Some(Direction::Long)
        );
    }

    #[test]
    fn the_time_barrier_outranks_a_reversal() {
        // Otherwise a strategy that flips every bar would never age out.
        assert_eq!(
            desired_direction(1, Some(Direction::Long), 10, 0, Some(10), Some(NO), None, Some(YES), None, None),
            None
        );
    }

    #[test]
    fn the_time_barrier_does_not_block_a_fresh_entry() {
        assert_eq!(
            desired_direction(1, None, 99, 0, Some(10), Some(YES), None, None, None, None),
            Some(Direction::Long)
        );
    }

    #[test]
    fn script_targets_override_expressions() {
        let targets = [0, -1, 1];
        assert_eq!(
            desired_direction(1, None, 0, 0, None, Some(YES), None, None, None, Some(&targets)),
            Some(Direction::Short)
        );
        // Past the end of the script, hold what we have rather than dumping.
        assert_eq!(
            desired_direction(9, Some(Direction::Long), 0, 0, None, None, None, None, None, Some(&targets)),
            Some(Direction::Long)
        );
    }

    // MARK: Trailing stop

    fn bar(ts: i64, open: f64, high: f64, low: f64, close: f64) -> Candle {
        Candle { ts_ms: ts, open, high, low, close, volume: 1.0, confirmed: 1 }
    }

    /// A long that runs up, then pulls back. The trail must follow the peak and
    /// stay there.
    fn rally_then_pullback() -> Vec<Candle> {
        let path = [
            (100.0, 100.0), (102.0, 101.0), (106.0, 104.0),
            (110.0, 108.0), (109.0, 105.0), (107.0, 103.0),
        ];
        path.iter()
            .enumerate()
            .map(|(i, (high, close))| {
                bar(i as i64 * 3_600_000, close - 0.5, *high, close - 1.0, *close)
            })
            .collect()
    }

    fn trailing_strategy(extra_risk: &str) -> CompiledStrategy {
        let json = format!(
            r#"{{"id":"t","market":{{"instId":"BTC-USDT","bar":"1H"}},
                 "signals":{{"longEntry":"close > 0","longExit":"close < 0"}},
                 "risk":{{"trailingStopPct":5{extra_risk}}}}}"#
        );
        let manifest: crate::strategy::Manifest = serde_json::from_str(&json).unwrap();
        CompiledStrategy::compile(manifest, &[]).unwrap()
    }

    fn held_long(strategy: &CompiledStrategy, candles: &[Candle], bars_held: usize)
        -> LiveDecision
    {
        decide_live(
            strategy,
            candles,
            Some(Direction::Long),
            bars_held,
            &std::collections::HashMap::new(),
            AccountState { equity: 10_000.0, held_base: 1.0, entry_price: 100.0,
                           ..AccountState::default() },
        )
        .unwrap()
    }

    #[test]
    fn the_trail_follows_the_peak_and_does_not_give_it_back() {
        let strategy = trailing_strategy("");
        let candles = rally_then_pullback();
        // Held since bar 0; the peak high is 110.
        let level = held_long(&strategy, &candles, 5).trailing_stop_price.unwrap();
        assert!((level - 110.0 * 0.95).abs() < 1e-9,
                "the trail sits 5% under the highest high, not under the latest one");
    }

    #[test]
    fn the_trail_is_reported_on_bars_where_nothing_is_traded() {
        // The whole point: the level moves on quiet bars, and the runner needs
        // it precisely then.
        let strategy = trailing_strategy("");
        let candles = rally_then_pullback();
        let decision = held_long(&strategy, &candles, 5);
        assert!(!decision.should_trade, "no signal change, so no order");
        assert!(decision.trailing_stop_price.is_some());
    }

    #[test]
    fn the_trail_never_loosens_past_the_opening_stop() {
        // A position that only ever went against us: the anchor stays at the
        // entry, so the trail implies 5% under 100 = 95. The 3% fixed stop the
        // position opened with sits at 97, which is tighter — and a trailing
        // stop that *widened* the protection a position started with would be
        // worse than having none.
        let strategy = trailing_strategy(r#","stopLossPct":3"#);
        let candles: Vec<Candle> = [99.5, 99.0, 98.5, 98.0, 97.6, 97.3]
            .iter()
            .enumerate()
            .map(|(i, close)| bar(i as i64 * 3_600_000, close - 0.5, *close, close - 1.0, *close))
            .collect();
        let level = held_long(&strategy, &candles, 5).trailing_stop_price.unwrap();
        assert!((level - 97.0).abs() < 1e-9, "got {level}");
    }

    #[test]
    fn a_flat_strategy_reports_no_trail() {
        let strategy = trailing_strategy("");
        let candles = rally_then_pullback();
        let decision = decide_live(
            &strategy, &candles, None, 0, &std::collections::HashMap::new(),
            AccountState { equity: 10_000.0, ..AccountState::default() }).unwrap();
        assert!(decision.trailing_stop_price.is_none());
    }

    #[test]
    fn live_trails_to_the_same_price_the_backtest_does() {
        // The property the whole design exists for. The backtester folds each
        // bar into a running anchor as it walks forward; the runner recomputes
        // from the bars since entry. They must land on the same number.
        let strategy = trailing_strategy("");
        let candles = rally_then_pullback();
        let entry_price = 100.0;

        // What the backtester's step 4 arrives at, expressed as its own fold.
        let mut simulated: Option<f64> = None;
        let mut anchor = entry_price;
        for candle in &candles {
            anchor = crate::sizing::trail_anchor(
                Direction::Long, anchor, &[candle.high], &[candle.low]);
            let level = crate::sizing::trailing_stop_level(Direction::Long, anchor, 5.0);
            simulated = Some(crate::sizing::ratchet_stop(Direction::Long, simulated, level));
        }

        let live = held_long(&strategy, &candles, candles.len() - 1)
            .trailing_stop_price
            .unwrap();
        assert!((live - simulated.unwrap()).abs() < 1e-9,
                "live {live} vs backtest {:?}", simulated);
    }

    #[test]
    fn volatility_scale_is_zero_when_volatility_is_unknown() {
        assert_eq!(volatility_scale(20.0, f64::NAN, 2.0), 0.0);
        assert_eq!(volatility_scale(20.0, 0.0, 2.0), 0.0);
        assert_eq!(volatility_scale(0.0, 20.0, 2.0), 0.0);
    }

    #[test]
    fn volatility_scale_is_capped() {
        // A very calm market would otherwise lever the book to the moon.
        assert_eq!(volatility_scale(40.0, 1.0, 2.0), 2.0);
        assert!((volatility_scale(20.0, 40.0, 2.0) - 0.5).abs() < 1e-9);
    }

    #[test]
    fn realised_volatility_is_bar_aware() {
        // The same series annualises differently on 1H and 1D.
        let closes: Vec<f64> = (0..200)
            .map(|i| 100.0 * (1.0 + 0.01 * ((i as f64) * 0.7).sin()))
            .collect();
        let hourly = realised_volatility(&closes, 60, "1H");
        let daily = realised_volatility(&closes, 60, "1D");
        let h = hourly[199];
        let d = daily[199];
        assert!(h.is_finite() && d.is_finite());
        assert!(h > d, "an hourly bar annualises by a larger factor");
    }

    #[test]
    fn realised_volatility_needs_a_full_window() {
        let closes: Vec<f64> = (0..10).map(|i| 100.0 + i as f64).collect();
        assert!(realised_volatility(&closes, 60, "1D").iter().all(|v| v.is_nan()));
    }
}
