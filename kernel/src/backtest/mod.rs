//! Bar-by-bar simulator.
//!
//! Execution model (see `docs/STRATEGY.md`):
//! - signals are evaluated on the **close of bar i**, using data up to i only;
//! - the resulting order fills at the **open of bar i+1**, plus slippage;
//! - protective exits are checked against bar highs/lows. What the bar makes
//!   certain is used — a level it opened past fills at the open, and adverse
//!   levels are met nearest-first — and only what it leaves unknowable, a bar
//!   that reaches both the stop and the target, is assumed against the
//!   position (`protective_exit`);
//! - every close is a fill (`ExitFill`): a market order pays slippage and the
//!   fee schedule, and an isolated-margin liquidation takes the position's
//!   margin — exactly, never more (`liquidation_fill`).
//!
//! Look-ahead bias is structurally impossible here: the evaluation window ends
//! where the execution window begins.

pub mod continuous;
pub mod metrics;
pub mod options;

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::calendar::MarketCalendar;
use crate::candle::Candle;
use crate::decide::{desired_direction, Direction};
use crate::expr::eval::Evaluator;
use crate::expr::{ExprError, ExprResult};
use crate::fees::{FeeComponent, OrderSide};
use crate::series;
use crate::strategy::{bar_seconds, CompiledStrategy, Costs, MarginRegime};

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
    /// Maintenance margin rate for the liquidation check. `None` takes the
    /// instrument's documented default (`InstrumentType::default_maintenance_margin_rate`).
    #[serde(rename = "maintenanceMarginRate", default)]
    pub maintenance_margin_rate: Option<f64>,
    /// Real funding history; empty means funding is not modelled (flagged in
    /// the report rather than silently assumed to be zero).
    #[serde(rename = "fundingRates", default)]
    pub funding_rates: Vec<FundingRate>,
    /// Fee model from the caller's schedule, used when the manifest states no
    /// costs. See `crate::fees`.
    #[serde(default)]
    pub fees: Option<Vec<FeeComponent>>,
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

impl Default for BacktestConfig {
    fn default() -> Self {
        Self {
            initial_capital: 10_000.0,
            maintenance_margin_rate: None,
            funding_rates: Vec::new(),
            fees: None,
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
    /// The opposite entry fired while holding: this close is the first leg
    /// of a reversal, and the new side opens on the same fill. Its own name
    /// because a report where most exits read "signal" hides whether a
    /// strategy leaves by its exit rule or is turned over by the other side.
    Reversal,
    StopLoss,
    TakeProfit,
    TrailingStop,
    Liquidation,
    DailyLossHalt,
    EndOfData,
    /// An option contract reached its settlement and paid its intrinsic value.
    Expiry,
}

impl ExitReason {
    /// Every reason, for anything that has to cover them all; the app's list
    /// is checked against this one (`ms_exit_reasons`).
    pub const ALL: [ExitReason; 9] = [
        ExitReason::Signal,
        ExitReason::Reversal,
        ExitReason::StopLoss,
        ExitReason::TakeProfit,
        ExitReason::TrailingStop,
        ExitReason::Liquidation,
        ExitReason::DailyLossHalt,
        ExitReason::EndOfData,
        ExitReason::Expiry,
    ];
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
    /// Net PnL as a **percentage** of the equity that existed when the trade
    /// opened — 5.0 means +5%, not +500%.
    ///
    /// The name says pct and the value is scaled by 100; an earlier comment
    /// here claimed "as a fraction", which is how a caller came to feed these
    /// straight into a compounding routine and produce a 100% drawdown on a
    /// strategy that lost 28%.
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
    /// Entries the pre-trade guard refused — orders the live runner would
    /// refuse too. Zero for a sound strategy; anything else is a sizing
    /// problem the backtest shows rather than quietly skipping, which it
    /// used to (a 20× strategy traded nothing and said nothing).
    #[serde(rename = "guardRefusals")]
    pub guard_refusals: usize,
    /// Why the first refusal was refused.
    #[serde(rename = "guardRefusal")]
    pub guard_refusal: Option<String>,
    /// What the candle series itself was like.
    ///
    /// A backtest run over history with holes in it is not wrong so much as
    /// *less than it appears*: a 60-bar lookback spanning a gap covers more
    /// than 60 bars of market. The live path refuses to trade on such a
    /// series; a backtest cannot refuse retrospectively, so it says so instead.
    #[serde(rename = "dataQuality")]
    pub data_quality: crate::quality::DataQuality,
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

/// Fractional adverse move that gets a position closed out by its lender.
///
/// Shared with the continuous engine so "when does this get liquidated" has
/// one definition rather than two that must be kept in step. The arithmetic
/// differs by margin regime because the collateral does:
///
/// - isolated margin backs the position with `notional / leverage` and closes
///   it when the loss has eaten that down to the maintenance rate;
/// - Regulation T lends against the shares and calls the loan when equity
///   falls below the maintenance share of the position's *current* value,
///   so at 2× and 25% the buffer is a third, not the 37.5% the isolated
///   formula would give.
pub(crate) fn liquidation_buffer(regime: MarginRegime, maintenance_margin_rate: f64, leverage: f64) -> f64 {
    match regime {
        // Fully paid: only a price of zero takes it away.
        MarginRegime::None => 1.0,
        MarginRegime::Isolated => (1.0 - maintenance_margin_rate) / leverage,
        MarginRegime::RegT => {
            if leverage <= 1.0 {
                1.0
            } else {
                1.0 - (1.0 - 1.0 / leverage) / (1.0 - maintenance_margin_rate)
            }
        }
    }
}

/// Costs the simulation charges: the manifest's own, else the caller's fee
/// schedule, else the instrument's documented default. A manifest with no
/// costs on an instrument with no default is refused rather than simulated
/// for free.
fn resolve_costs(strategy: &CompiledStrategy, config: &BacktestConfig) -> ExprResult<Costs> {
    strategy
        .costs(config.fees.as_deref(), config.slippage_bps)
        .map_err(ExprError::Policy)
}

/// Maintenance margin the simulation liquidates against.
fn resolve_maintenance(strategy: &CompiledStrategy, config: &BacktestConfig) -> f64 {
    config
        .maintenance_margin_rate
        .or_else(|| strategy.manifest.market.inst_type.default_maintenance_margin_rate())
        .unwrap_or(0.0)
}

fn unrealised(position: Option<&OpenPosition>, price: f64) -> f64 {
    match position {
        None => 0.0,
        Some(p) => p.direction.sign() * (price - p.entry_price) * p.quantity - p.funding,
    }
}

/// Buying pays up; selling receives less.
pub(crate) fn market_price(reference: f64, buying: bool, slippage: f64) -> f64 {
    reference * if buying { 1.0 + slippage } else { 1.0 - slippage }
}

/// Entering long or exiting short buys; the rest sells.
fn fill_price(reference: f64, direction: Direction, is_exit: bool, slippage: f64) -> f64 {
    let buying = if is_exit {
        direction == Direction::Short
    } else {
        direction == Direction::Long
    };
    market_price(reference, buying, slippage)
}

/// The order that closes a `direction` position.
fn closing_side(direction: Direction) -> OrderSide {
    if direction == Direction::Long { OrderSide::Sell } else { OrderSide::Buy }
}

/// One closing fill: the price the position left at and the fee the venue
/// charged for it. Every close in the binary and continuous engines is built
/// by `market` or `liquidation_fill`, so how a close fills has one answer.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ExitFill {
    pub price: f64,
    pub fee: f64,
}

impl ExitFill {
    /// A market order closing `quantity` of a `direction` position against
    /// `reference`: slippage and the fee schedule, like every taker fill.
    /// Stops, targets and trailing stops are conditional *market* orders live
    /// (`trade::wire` sends them with an order price of −1), so they fill this
    /// way too. They used to fill at the bare level — the only closes that
    /// paid no slippage, flattering exactly the tight-stop strategies most
    /// sensitive to cost.
    pub(crate) fn market(costs: &Costs, direction: Direction, quantity: f64, reference: f64, slippage: f64) -> Self {
        let price = fill_price(reference, direction, true, slippage);
        Self { price, fee: costs.fee(closing_side(direction), quantity, quantity * price) }
    }
}

/// How a liquidation fills, by margin regime.
///
/// **Isolated margin** backs a position with `notional / leverage`, and a
/// liquidation takes all of it — never more. The exchange closes at the
/// bankruptcy price: where the move, the funding settled against the margin
/// and an ordinary closing fee together use the margin up exactly; whatever
/// the market did past that, a gap included, is the insurance fund's. This is
/// OKX's own booking of a liquidated isolated 5× BTC short (positions-history,
/// 2025-05): price P&L −614.60 at the close price, funding +14.12, and a fee of
/// 1.81 on the close at the same ≈0.05% the opening fill paid — so the close
/// realised −602.29, the margin (0.0324 BTC × 92 945.9 / 5) to the cent, and
/// the trade −603.79 with its opening fee. The level that *triggers* a
/// liquidation (`liquidation_buffer`) only decides when; this decides what.
///
/// **Regulation T** has no such floor: the broker sells into the market, and a
/// gap past the call is the customer's debt — an ordinary market close at the
/// trigger, slippage and all. A fully paid position is never liquidated
/// (its buffer is the whole price).
#[allow(clippy::too_many_arguments)]
pub(crate) fn liquidation_fill(
    regime: MarginRegime,
    direction: Direction,
    quantity: f64,
    basis: f64,
    leverage: f64,
    funding: f64,
    trigger: f64,
    slippage: f64,
    costs: &Costs,
) -> ExitFill {
    match regime {
        MarginRegime::Isolated => {
            let margin = quantity * basis / leverage;
            let side = closing_side(direction);
            // The fee depends on the price and the price on the fee, but the
            // fee moves only by its rate times the price change: a few rounds
            // settle it far below a cent. The books balance exactly whatever
            // the round count — the price is always solved from the fee.
            let mut fill = ExitFill { price: trigger, fee: 0.0 };
            for _ in 0..4 {
                let fee = costs.fee(side, quantity, quantity * fill.price);
                // gross − fee − funding = −margin
                let gross = fee + funding - margin;
                fill = ExitFill { price: basis + gross / (direction.sign() * quantity), fee };
            }
            fill
        }
        MarginRegime::RegT | MarginRegime::None => {
            ExitFill::market(costs, direction, quantity, trigger, slippage)
        }
    }
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
    if strategy.manifest.market.inst_type.is_option() {
        return crate::backtest::options::run(strategy, raw_candles, config);
    }

    let mut candles: Vec<Candle> = raw_candles.iter().copied().filter(|c| c.is_confirmed()).collect();
    candles.sort_by_key(|c| c.ts_ms);

    let manifest = &strategy.manifest;
    let costs = resolve_costs(strategy, config)?;
    let maintenance = resolve_maintenance(strategy, config);
    let calendar: MarketCalendar = manifest.market.calendar();
    let slippage = costs.slippage_bps / 10_000.0;
    let leverage = strategy.leverage();
    // The absolute pre-trade limits, so a sizing bug is capped here exactly as
    // it would be live. The trading-state machine is *not* applied: a portfolio
    // drawdown brake is a live risk control, not a rule of the strategy.
    let limits = crate::guard::OrderLimits::default();
    let mut refusals = GuardRefusals::default();

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
    let mut current_day = calendar.session_key(candles[0].ts_ms);

    let funding_by_bar = bucket_funding(&candles, &manifest.market.bar, &config.funding_rates);
    let first_tradable = strategy.warmup_bars.min(candles.len() - 1);

    for index in 0..candles.len() {
        let candle = candles[index];

        // --- New trading day (by the market's calendar): reset the
        //     daily-loss circuit breaker.
        let day = calendar.session_key(candle.ts_ms);
        if day != current_day {
            current_day = day;
            day_start_equity = equity + unrealised(position.as_ref(), candle.open);
            halted_day = None;
        }

        // --- 1. Execute the order decided at the previous bar's close.
        if let Some(target) = pending_target.take() {
            // A reversal — the opposite entry firing while holding — opens its
            // new side whatever the cooldown, which only gates an entry from
            // flat: reversing out of a losing side is the signal working, not
            // churn. That is the live rule (`decide::decide_live` checks the
            // cooldown only when nothing is held). This loop used to measure
            // a reversal's cooldown from the exit before it, so a reversal
            // chained inside the window closed one side and opened nothing —
            // a strategy the runner does not run.
            let mut reversing = false;
            if let Some(existing) = position {
                if Some(existing.direction) != target {
                    reversing = target.is_some();
                    let fill = ExitFill::market(
                        &costs, existing.direction, existing.quantity, candle.open, slippage);
                    close_position(
                        &mut position,
                        fill,
                        candle.ts_ms,
                        index,
                        if reversing { ExitReason::Reversal } else { ExitReason::Signal },
                        &mut equity,
                        &mut trades,
                    );
                    last_exit_index = Some(index);
                }
            }
            if position.is_none() && halted_day.is_none() {
                if let Some(direction) = target {
                    let since_exit = last_exit_index.map(|exit| index - exit);
                    if reversing || crate::decide::can_enter(since_exit, manifest.risk.cooldown_bars) {
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
                            maintenance,
                            &mut position,
                            direction,
                            fill,
                            candle.ts_ms,
                            index,
                            &mut equity,
                            leverage,
                            &limits,
                            &mut refusals,
                            &costs,
                            atr,
                        );
                    }
                }
            }
        }

        // --- 2. Protective exits, checked against this bar's range.
        if let Some(existing) = position {
            if let Some(exit) = protective_exit(strategy, &existing, &candle, leverage) {
                let fill = if exit.reason == ExitReason::Liquidation {
                    liquidations += 1;
                    liquidation_fill(
                        manifest.market.inst_type.margin_regime(),
                        existing.direction,
                        existing.quantity,
                        existing.entry_price,
                        leverage,
                        existing.funding,
                        exit.price,
                        slippage,
                        &costs,
                    )
                } else {
                    ExitFill::market(&costs, existing.direction, existing.quantity, exit.price, slippage)
                };
                close_position(
                    &mut position,
                    fill,
                    candle.ts_ms,
                    index,
                    exit.reason,
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
                // The same three functions the live runner calls, so a stop
                // that trails in simulation trails to the same price in
                // production.
                let updated = crate::sizing::trail_anchor(
                    existing.direction,
                    existing.trail_anchor.unwrap_or(existing.entry_price),
                    &[candle.high],
                    &[candle.low],
                );
                existing.trail_anchor = Some(updated);
                let level =
                    crate::sizing::trailing_stop_level(existing.direction, updated, trail_pct);
                existing.stop_price = Some(crate::sizing::ratchet_stop(
                    existing.direction,
                    existing.stop_price,
                    level,
                ));
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
                    let fill = ExitFill::market(
                        &costs, existing.direction, existing.quantity, candle.close, slippage);
                    close_position(
                        &mut position,
                        fill,
                        candle.ts_ms,
                        index,
                        ExitReason::DailyLossHalt,
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
        let fill = ExitFill::market(&costs, existing.direction, existing.quantity, last.close, slippage);
        close_position(
            &mut position,
            fill,
            last.ts_ms,
            candles.len() - 1,
            ExitReason::EndOfData,
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
        funding_unmodelled: manifest.market.inst_type == crate::strategy::InstrumentType::Swap
            && config.funding_rates.is_empty(),
        guard_refusals: refusals.count,
        guard_refusal: refusals.first,
        metrics,
    })
}

/// Entries the pre-trade guard refused during one run, and why the first was.
#[derive(Debug, Default)]
pub(crate) struct GuardRefusals {
    pub count: usize,
    pub first: Option<String>,
}

impl GuardRefusals {
    pub(crate) fn note(&mut self, denied: crate::guard::OrderDenied) {
        self.count += 1;
        if self.first.is_none() {
            self.first = Some(denied.reason);
        }
    }
}


#[allow(clippy::too_many_arguments)]
fn open_position(
    strategy: &CompiledStrategy,
    maintenance_margin_rate: f64,
    position: &mut Option<OpenPosition>,
    direction: Direction,
    price: f64,
    ts: i64,
    index: usize,
    equity: &mut f64,
    leverage: f64,
    limits: &crate::guard::OrderLimits,
    refusals: &mut GuardRefusals,
    costs: &Costs,
    atr: Option<f64>,
) {
    if !(price > 0.0) || !(*equity > 0.0) {
        return;
    }
    let manifest = &strategy.manifest;
    let stop_distance = crate::sizing::stop_distance(strategy, price, atr);

    // Sized from flat — a reversal has already closed and paid for the close —
    // so that the margin and this fill's fee together fit in the equity left.
    let footing = crate::sizing::Footing {
        costs, capital: *equity, price, leverage, regime: manifest.market.inst_type.margin_regime(),
        held_base: 0.0, held_basis: 0.0,
    };
    let Some(base) = crate::sizing::target_base(strategy, &footing, stop_distance, direction)
    else { return };

    // The same pre-trade limits the live runner applies. Only a sizing bug
    // ever reaches them, and this is where such a bug should surface: a
    // backtest that quietly simulated an order live would refuse is a backtest
    // that cannot be traded.
    //
    // Deliberately *not* the live trading-state machine — a portfolio drawdown
    // brake is a live risk control, not a rule of the strategy, and folding it
    // into the simulation would test a different strategy than the one written.
    let quantity = base.abs();
    let notional = quantity * price;
    if let Some(denied) = crate::guard::check_order(
        base, 0.0, price, *equity, strategy.max_notional_multiple(), limits)
    {
        refusals.note(denied);
        return;
    }
    // Opening a long buys; opening a short sells — and a short sale pays the
    // levies a sale pays.
    let side = if direction == Direction::Long { OrderSide::Buy } else { OrderSide::Sell };
    let fee = costs.fee(side, quantity, notional);
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
        let buffer = liquidation_buffer(
            manifest.market.inst_type.margin_regime(), maintenance_margin_rate, leverage);
        new.liquidation_price = Some(if direction == Direction::Long {
            price * (1.0 - buffer)
        } else {
            price * (1.0 + buffer)
        });
    }
    *position = Some(new);
}

fn close_position(
    position: &mut Option<OpenPosition>,
    fill: ExitFill,
    ts: i64,
    index: usize,
    reason: ExitReason,
    equity: &mut f64,
    trades: &mut Vec<Trade>,
) {
    let Some(existing) = position.take() else {
        return;
    };

    let (price, exit_fee) = (fill.price, fill.fee);
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

/// Which protective level this bar fills, and the price it fills against.
///
/// What the bar makes certain is used; only what it leaves unknowable is
/// assumed against the position.
///
/// - A level the bar **opened** past was crossed before anything else could
///   trade, and fills at the open — a gap over the target takes the target,
///   whatever the bar did afterwards. Opening past the liquidation level
///   liquidates even with a stop nearer: the exchange's risk engine acts on
///   the mark the moment it crosses, before a stop's market order can trade.
/// - Otherwise adverse levels are met in order from the open, so the nearer
///   one fires: a long's stop above its liquidation level closes it at the
///   stop, not at the liquidation the stop prevented.
/// - A bar that reaches both an adverse level and the target leaves the path
///   inside it unknowable, and the adverse one is assumed.
///
/// These used to collapse into one rule — the worst price among every level
/// the bar touched — which turned a gap through the target into a stop-out,
/// and a stop above the liquidation level into a lost margin.
fn protective_exit(
    strategy: &CompiledStrategy,
    position: &OpenPosition,
    candle: &Candle,
    leverage: f64,
) -> Option<PendingExit> {
    let sign = position.direction.sign();
    // Whether `price` is at or past `level` against the position (below a
    // long's level, above a short's), or in its favour.
    let against = |price: f64, level: f64| sign * (level - price) >= 0.0;
    let in_favour = |price: f64, level: f64| sign * (price - level) >= 0.0;
    let stop_reason = if strategy.manifest.risk.trailing_stop_pct.is_some() {
        ExitReason::TrailingStop
    } else {
        ExitReason::StopLoss
    };
    let liquidation = if leverage > 1.0 { position.liquidation_price } else { None };
    let adverse = [(liquidation, ExitReason::Liquidation), (position.stop_price, stop_reason)];

    // 1. Opened past a level: liquidation first, then the stop, then the target.
    for (level, reason) in adverse {
        if level.is_some_and(|level| against(candle.open, level)) {
            return Some(PendingExit { price: candle.open, reason });
        }
    }
    if position.target_price.is_some_and(|level| in_favour(candle.open, level)) {
        return Some(PendingExit { price: candle.open, reason: ExitReason::TakeProfit });
    }

    // 2. Adverse levels reached inside the bar, the nearest to the open first.
    let adverse_extreme = if sign > 0.0 { candle.low } else { candle.high };
    let first_adverse = adverse
        .into_iter()
        .filter_map(|(level, reason)| {
            level.filter(|&level| against(adverse_extreme, level)).map(|price| PendingExit { price, reason })
        })
        .reduce(|met, next| if sign * next.price > sign * met.price { next } else { met });
    if first_adverse.is_some() {
        return first_adverse;
    }

    // 3. The target, reached inside the bar.
    let favourable_extreme = if sign > 0.0 { candle.high } else { candle.low };
    position
        .target_price
        .filter(|&level| in_favour(favourable_extreme, level))
        .map(|price| PendingExit { price, reason: ExitReason::TakeProfit })
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
        data_quality: crate::quality::inspect(
            &candles, manifest.market.calendar(), manifest.market.bar_seconds(), None),
        funding_unmodelled: manifest.market.inst_type == crate::strategy::InstrumentType::Swap
            && config.funding_rates.is_empty(),
        guard_refusals: 0,
        guard_refusal: None,
        metrics: Metrics::compute(
            &[],
            &[],
            config.initial_capital,
            manifest.market.bars_per_year(),
            strategy.free_parameter_count,
        ),
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::strategy::Manifest;

    fn compile(json: &str) -> CompiledStrategy {
        let manifest: Manifest = serde_json::from_str(json).unwrap();
        CompiledStrategy::compile(manifest, &[]).unwrap()
    }

    fn swap(leverage: f64) -> CompiledStrategy {
        compile(&format!(
            r#"{{"id":"b","name":"b","market":{{"instId":"BTC-USDT-SWAP","instType":"SWAP","bar":"1H"}},
                 "signals":{{"longEntry":"close > 0","longExit":"close < 0"}},
                 "sizing":{{"mode":"equityPct","value":100}},
                 "risk":{{"leverage":{leverage}}}}}"#
        ))
    }

    /// Always long, at `leverage`, with `risk` added to the risk block.
    fn always_long(inst_type: &str, leverage: f64, pct: f64, risk: &str) -> CompiledStrategy {
        compile(&format!(
            r#"{{"id":"l","name":"l","market":{{"instId":"X","instType":"{inst_type}","bar":"1H"}},
                 "signals":{{"longEntry":"close > 0","longExit":"close < 0"}},
                 "sizing":{{"mode":"equityPct","value":{pct}}},
                 "risk":{{"leverage":{leverage}{risk}}}}}"#
        ))
    }

    fn bar(i: i64, open: f64, high: f64, low: f64, close: f64) -> Candle {
        Candle { ts_ms: i * 3_600_000, open, high, low, close, volume: 1.0, confirmed: 1 }
    }

    fn flat(count: i64) -> Vec<Candle> {
        (0..count).map(|i| bar(i, 100.0, 100.5, 99.5, 100.0)).collect()
    }

    /// Flat at 100 for `before` bars, then `crash`, then flat at its close.
    fn flat_then(before: i64, crash: (f64, f64, f64, f64), after: i64) -> Vec<Candle> {
        let (open, high, low, close) = crash;
        let mut bars: Vec<Candle> = (0..before).map(|i| bar(i, 100.0, 100.0, 100.0, 100.0)).collect();
        bars.push(bar(before, open, high, low, close));
        bars.extend((before + 1..before + 1 + after).map(|i| bar(i, close, close, close, close)));
        bars
    }

    fn costs(fee_bps: f64, slippage_bps: f64) -> BacktestConfig {
        BacktestConfig {
            fees: Some(vec![FeeComponent::flat_bps(fee_bps)]),
            slippage_bps: Some(slippage_bps),
            ..BacktestConfig::default()
        }
    }

    fn first(result: &BacktestResult, reason: ExitReason) -> Trade {
        result.trades.iter().find(|t| t.exit_reason == reason).cloned().unwrap_or_else(|| {
            panic!("no {reason:?} exit in {:?}", result.trades.iter().map(|t| t.exit_reason).collect::<Vec<_>>())
        })
    }

    /// Walks every leverage a perpetual allows: a full-size entry is what
    /// sizing produces at that leverage and what the live runner sends. The
    /// old single 1 000% cap refused every one above 10× — the run traded
    /// nothing and said nothing.
    #[test]
    fn a_full_size_entry_opens_at_every_leverage_a_perpetual_allows() {
        let max = crate::strategy::InstrumentType::Swap.max_leverage() as i64;
        for leverage in [1, 5, 10, 11, 20, max] {
            let result = run(&swap(leverage as f64), &flat(48), &BacktestConfig::default()).unwrap();
            assert_eq!(result.guard_refusals, 0, "{leverage}x: {:?}", result.guard_refusal);
            assert!(!result.trades.is_empty(), "{leverage}x opened and closed nothing");
        }
    }

    /// An isolated liquidation takes the position's margin — to the cent, with
    /// the funding it ran up and the closing fee inside it — and a bar that
    /// gaps far past the level costs exactly the same. It used to fill at the
    /// trigger level and charge the fee on top, so at 20× a liquidation lost
    /// more than the margin the exchange can take.
    #[test]
    fn an_isolated_liquidation_loses_the_margin_and_never_more() {
        let max = crate::strategy::InstrumentType::Swap.max_leverage();
        for (leverage, crash) in [
            (10.0, (100.0, 100.0, 85.0, 86.0)),  // reaches the level inside the bar
            (10.0, (40.0, 40.0, 30.0, 35.0)),    // opens far past it
            (20.0, (100.0, 100.0, 90.0, 92.0)),
            (max, (100.0, 100.0, 97.0, 99.0)),
        ] {
            let mut config = costs(5.0, 3.0);
            // One settlement while the position is open, so funding is part
            // of what the margin has to cover.
            config.funding_rates = vec![FundingRate { ts_ms: 3 * 3_600_000, rate: 0.0004 }];
            let result = run(&always_long("SWAP", leverage, 50.0, ""), &flat_then(6, crash, 3), &config).unwrap();
            let liquidated = first(&result, ExitReason::Liquidation);
            let margin = liquidated.notional / leverage;
            let entry_fee = liquidated.notional * 0.0005;
            assert!((liquidated.net_pnl + margin + entry_fee).abs() < 1e-6,
                    "{leverage}x {crash:?}: lost {} on a {margin} margin", -liquidated.net_pnl);
            assert!(liquidated.funding > 0.0, "the settlement was charged");
            // The record is consistent: the price it left at explains the
            // gross, and the fees include an ordinary closing fee.
            let gross = (liquidated.exit_price - liquidated.entry_price) * liquidated.quantity;
            assert!((liquidated.gross_pnl - gross).abs() < 1e-6);
            let exit_fee = liquidated.fees - entry_fee;
            assert!((exit_fee - liquidated.quantity * liquidated.exit_price * 0.0005).abs() < 1e-6,
                    "closing fee {exit_fee}");
            assert_eq!(result.liquidations, 1);
        }
    }

    /// Always in on `direction`'s side at `leverage`, full size.
    fn always_in(family: crate::strategy::InstrumentType, direction: Direction, leverage: f64) -> CompiledStrategy {
        let signals = match direction {
            Direction::Long => r#""longEntry":"close > 0","longExit":"close < 0""#,
            Direction::Short => r#""shortEntry":"close > 0","shortExit":"close < 0""#,
        };
        let family = serde_json::to_value(family).unwrap();
        compile(&format!(
            r#"{{"id":"f","name":"f","market":{{"instId":"X","instType":{family},"bar":"1H"}},
                 "signals":{{{signals}}},"sizing":{{"mode":"equityPct","value":100}},
                 "risk":{{"leverage":{leverage}}}}}"#
        ))
    }

    /// Walks every family the binary engine trades (a bought option has its
    /// own engine and its own walk), at every whole leverage it allows, long
    /// and — where it can be — short, at full size. What the entry commits, its
    /// margin and its fee, never exceeds the equity behind it; so the worst
    /// exit the family's margin defines leaves the run at or above zero: an
    /// isolated liquidation takes exactly the margin, a fully paid position at
    /// most its price, a Reg T call met inside its bar what the move took. A
    /// full-size isolated liquidation used to end the run at minus the
    /// opening fee.
    #[test]
    fn a_full_size_entry_never_commits_more_than_the_equity_behind_it() {
        use crate::strategy::{InstrumentType, MarginRegime};
        let (fee, slippage) = (5.0, 3.0);
        let mut walked = 0;
        for family in InstrumentType::ALL.into_iter().filter(|f| !f.is_option()) {
            let maintenance = family.default_maintenance_margin_rate().unwrap_or(0.0);
            let mut leverage = 1.0;
            while leverage <= family.max_leverage() {
                let sides = if family.allows_short() { vec![Direction::Long, Direction::Short] } else { vec![Direction::Long] };
                for direction in sides {
                    let sign = direction.sign();
                    // The position fills at 100 through the slippage; the bar
                    // after five quiet ones is the worst its margin allows.
                    let fill = 100.0 * (1.0 + sign * slippage / 10_000.0);
                    let lends = leverage > 1.0 && family.margin_regime() != MarginRegime::None;
                    let level = fill * (1.0 - sign * liquidation_buffer(family.margin_regime(), maintenance, leverage));
                    let worst = match (lends, family.margin_regime()) {
                        // Opened far past the liquidation level.
                        (true, MarginRegime::Isolated) => {
                            let gap = level * (1.0 - sign * 0.5);
                            (gap, gap, gap, gap)
                        }
                        // The call met inside the bar: the broker sells there.
                        (true, _) => (100.0, level.max(100.0), level.min(100.0), level),
                        // Nothing lent: all but the whole price, either way.
                        (false, _) => {
                            let moved = 100.0 * (1.0 - sign * 0.99);
                            (moved, moved, moved, moved)
                        }
                    };
                    let result = run(&always_in(family, direction, leverage), &flat_then(6, worst, 3),
                                     &costs(fee, slippage)).unwrap();
                    let label = format!("{family:?} {leverage}x {direction:?}");
                    let entry = result.trades.first().unwrap_or_else(|| panic!("{label}: never entered"));
                    let committed = entry.notional / leverage + entry.notional * fee / 10_000.0;
                    assert!(committed <= result.initial_capital * (1.0 + 1e-12), "{label}: commits {committed}");
                    assert!(result.final_equity >= -1e-9 * result.initial_capital,
                            "{label}: ends at {} after {:?}", result.final_equity,
                            result.trades.iter().map(|t| t.exit_reason).collect::<Vec<_>>());
                    if lends && family.margin_regime() == MarginRegime::Isolated {
                        assert_eq!(result.liquidations, 1, "{label}");
                        assert!(result.final_equity.abs() < 1e-9 * result.initial_capital,
                                "{label}: a full-size liquidation takes everything committed and no more — {}",
                                result.final_equity);
                    }
                    walked += 1;
                }
                leverage += 1.0;
            }
        }
        assert!(walked > 100, "walked {walked}");
    }

    /// Regulation T has no floor under the loss: the broker sells into the
    /// market, so a gap past the call fills at the open, slippage and all.
    #[test]
    fn a_reg_t_call_is_a_market_close_at_the_open_it_gapped_to() {
        let result = run(
            &always_long("STOCK", 2.0, 50.0, ""),
            &flat_then(6, (50.0, 50.0, 45.0, 48.0), 3),
            &costs(0.0, 10.0),
        ).unwrap();
        let called = first(&result, ExitReason::Liquidation);
        assert!((called.exit_price - 50.0 * (1.0 - 0.001)).abs() < 1e-9, "filled at {}", called.exit_price);
    }

    /// Protective fills are conditional market orders live, so they pay
    /// slippage like every other taker fill. Large slippage, so the assertion
    /// cannot pass by accident.
    #[test]
    fn a_stop_loss_fill_pays_slippage() {
        let result = run(
            &always_long("SPOT", 1.0, 100.0, r#","stopLossPct":2"#),
            &flat_then(3, (100.0, 100.0, 95.0, 95.0), 0),
            &costs(0.0, 100.0),
        ).unwrap();
        let stopped = first(&result, ExitReason::StopLoss);
        let level = 100.0 * 1.01 * (1.0 - 0.02);
        assert!((stopped.exit_price - level * (1.0 - 0.01)).abs() < 1e-9,
                "stop filled at {} but the slipped level is {}", stopped.exit_price, level * 0.99);
    }

    /// A gap over the target took the target before anything else traded; a
    /// low later in the bar cannot turn it into a stop-out.
    #[test]
    fn a_bar_that_opens_past_the_target_takes_the_target() {
        let result = run(
            &always_long("SPOT", 1.0, 100.0, r#","stopLossPct":2,"takeProfitPct":3"#),
            &flat_then(3, (105.0, 106.0, 90.0, 95.0), 0),
            &costs(0.0, 0.0),
        ).unwrap();
        let taken = first(&result, ExitReason::TakeProfit);
        assert_eq!(taken.exit_price, 105.0);
    }

    /// Reaching both inside one bar leaves the order unknowable: the stop is
    /// assumed.
    #[test]
    fn a_bar_that_reaches_both_the_stop_and_the_target_assumes_the_stop() {
        let result = run(
            &always_long("SPOT", 1.0, 100.0, r#","stopLossPct":2,"takeProfitPct":3"#),
            &flat_then(3, (100.0, 104.0, 97.0, 100.0), 0),
            &costs(0.0, 0.0),
        ).unwrap();
        let stopped = first(&result, ExitReason::StopLoss);
        assert!((stopped.exit_price - 98.0).abs() < 1e-9);
    }

    /// Falling through a long's stop on the way to its liquidation level, the
    /// stop fires first — the liquidation is what it prevented. Opening past
    /// the liquidation level liquidates even with the stop nearer: the risk
    /// engine acts on the mark before a stop's market order can trade.
    #[test]
    fn adverse_levels_fire_in_the_order_the_price_meets_them() {
        let strategy = always_long("SWAP", 10.0, 50.0, r#","stopLossPct":5"#);
        let inside = run(&strategy, &flat_then(3, (100.0, 100.0, 80.0, 85.0), 0), &costs(0.0, 0.0)).unwrap();
        assert_eq!(first(&inside, ExitReason::StopLoss).exit_price, 95.0);
        assert_eq!(inside.liquidations, 0);

        let gapped = run(&strategy, &flat_then(3, (85.0, 86.0, 80.0, 85.0), 0), &costs(0.0, 0.0)).unwrap();
        first(&gapped, ExitReason::Liquidation);
    }

    /// A reversal opens its new side whatever the cooldown — the live rule —
    /// however deep the chain: every reversal close is followed by an entry
    /// on the other side at the same fill. The second reversal here falls
    /// inside the first one's cooldown, which used to close the short and
    /// open nothing.
    #[test]
    fn a_chained_reversal_inside_the_cooldown_still_opens_the_new_side() {
        let strategy = compile(
            r#"{"id":"r","name":"r","market":{"instId":"BTC-USDT-SWAP","instType":"SWAP","bar":"1H"},
                "signals":{"longEntry":"close > 100","shortEntry":"close < 100"},
                "sizing":{"mode":"equityPct","value":50},"risk":{"leverage":1,"cooldownBars":50}}"#);
        let mut bars: Vec<Candle> = (0..4).map(|i| bar(i, 101.0, 101.0, 101.0, 101.0)).collect();
        bars.extend((4..8).map(|i| bar(i, 99.0, 99.0, 99.0, 99.0)));
        bars.extend((8..12).map(|i| bar(i, 101.0, 101.0, 101.0, 101.0)));
        let result = run(&strategy, &bars, &costs(0.0, 0.0)).unwrap();

        let reversals: Vec<&Trade> =
            result.trades.iter().filter(|t| t.exit_reason == ExitReason::Reversal).collect();
        assert_eq!(reversals.len(), 2, "{:?}", result.trades.iter().map(|t| t.exit_reason).collect::<Vec<_>>());
        for closed in reversals {
            assert!(result.trades.iter().any(|t| t.entry_ts == closed.exit_ts && t.direction != closed.direction),
                    "the reversal at {} closed without opening the other side", closed.exit_ts);
        }
        // A plain exit to flat still waits out the cooldown.
        assert!(result.trades.iter().all(|t| t.exit_reason != ExitReason::Signal));
    }

    /// A reason added to the enum fails to compile here until it is placed;
    /// the arm is the reminder that it belongs in `ALL` too.
    #[test]
    fn all_lists_every_exit_reason_once() {
        let position = |reason: ExitReason| match reason {
            ExitReason::Signal => 0,
            ExitReason::Reversal => 1,
            ExitReason::StopLoss => 2,
            ExitReason::TakeProfit => 3,
            ExitReason::TrailingStop => 4,
            ExitReason::Liquidation => 5,
            ExitReason::DailyLossHalt => 6,
            ExitReason::EndOfData => 7,
            ExitReason::Expiry => 8,
        };
        for (index, reason) in ExitReason::ALL.iter().enumerate() {
            assert_eq!(position(*reason), index, "{reason:?}");
        }
    }

    /// Every engine books exactly what it pays: final equity is the initial
    /// capital plus the sum of the trades' net P&L, every trade's net is its
    /// gross less its fees and funding, and the curve ends where the books do.
    /// Run over every strategy the repository ships — whichever engine it
    /// routes to — and over scenarios built to reach the rarer branches
    /// (liquidations, trims, flips, funding both ways). The continuous engine
    /// failed this by every funding bill it had reported and never paid.
    #[test]
    fn every_engine_books_exactly_what_it_pays() {
        let mut cases: Vec<(String, CompiledStrategy, Vec<Candle>, BacktestConfig)> = Vec::new();
        let candles = wandering(1_200);
        let funding: Vec<FundingRate> = (0..150)
            .map(|k| FundingRate { ts_ms: k * 8 * 3_600_000, rate: 0.0003 * ((k as f64) * 0.7).sin() })
            .collect();

        let library = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../Strategies");
        let mut files: Vec<std::path::PathBuf> = Vec::new();
        for dir in [library.clone(), library.join("examples")] {
            for entry in std::fs::read_dir(&dir).unwrap() {
                let path = entry.unwrap().path();
                if path.extension().is_some_and(|e| e == "json") {
                    files.push(path);
                }
            }
        }
        assert!(files.len() >= 10, "the strategy library moved: {}", library.display());
        for path in files {
            let raw: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            // Declared alternative series get a synthetic stand-in; a script
            // strategy gets targets standing in for its script.
            let series: Vec<String> = raw.get("data").and_then(|d| d.as_object())
                .map(|d| d.keys().cloned().collect()).unwrap_or_default();
            let manifest: Manifest = serde_json::from_value(raw.clone()).unwrap();
            let strategy = CompiledStrategy::compile(manifest, &series).unwrap();
            let mut config = BacktestConfig { funding_rates: funding.clone(), ..BacktestConfig::default() };
            for name in &series {
                config.external_series.insert(
                    name.clone(),
                    (0..candles.len()).map(|i| ((i as f64) * 0.05).sin() * 0.0004).collect(),
                );
            }
            if raw.pointer("/engine/kind").and_then(|k| k.as_str()) == Some("script") {
                config.script_targets = Some((0..candles.len()).map(|i| [1, 1, 0, -1][(i / 37) % 4]).collect());
            }
            cases.push((path.file_name().unwrap().to_string_lossy().into_owned(), strategy, candles.clone(), config));
        }

        let levered = |signals: &str, leverage: f64, risk: &str| compile(&format!(
            r#"{{"id":"s","name":"s","market":{{"instId":"BTC-USDT-SWAP","instType":"SWAP","bar":"1H"}},
                 "signals":{signals},"sizing":{{"mode":"equityPct","value":40}},
                 "risk":{{"leverage":{leverage},"rebalanceThreshold":0.02,"maxExposure":1{risk}}}}}"#));
        let funded = |fee: f64, slip: f64| BacktestConfig { funding_rates: funding.clone(), ..costs(fee, slip) };
        let crossing = r#"{"longEntry":"close > sma(close, 20)","longExit":"close < sma(close, 20)",
                           "shortEntry":"close < sma(close, 20)","shortExit":"close > sma(close, 20)"}"#;
        cases.push(("binary 25x reversals and liquidations".into(),
                    levered(crossing, 25.0, r#","stopLossPct":3,"takeProfitPct":4"#), candles.clone(), funded(5.0, 3.0)));
        cases.push(("binary trailing stop".into(),
                    levered(crossing, 3.0, r#","trailingStopPct":2,"maxDailyLossPct":4"#), candles.clone(), funded(5.0, 3.0)));
        cases.push(("continuous flips at 8x".into(),
                    levered(r#"{"exposure":"clamp((close - sma(close, 30)) / sma(close, 30) * 40, -1, 1)"}"#, 8.0, ""),
                    candles.clone(), funded(5.0, 3.0)));
        cases.push(("continuous liquidated at 20x".into(),
                    levered(r#"{"exposure":"1"}"#, 20.0, ""), candles.clone(), funded(5.0, 3.0)));

        let mut liquidated = 0;
        for (name, strategy, bars, config) in &cases {
            let result = run(strategy, bars, config).unwrap();
            let booked: f64 = result.trades.iter().map(|t| t.net_pnl).sum();
            let drift = result.final_equity - result.initial_capital - booked;
            assert!(drift.abs() < 1e-6 * result.initial_capital,
                    "{name}: final equity {} but the ledger books {} ({} trades)",
                    result.final_equity, result.initial_capital + booked, result.trades.len());
            for trade in &result.trades {
                assert!((trade.gross_pnl - trade.fees - trade.funding - trade.net_pnl).abs() < 1e-6,
                        "{name}: trade {} does not add up: {trade:?}", trade.id);
            }
            if let Some(last) = result.equity_curve.last() {
                assert!((last.equity - result.final_equity).abs() < 1e-6, "{name}: the curve ends elsewhere");
            }
            liquidated += result.liquidations;
        }
        assert!(liquidated > 0, "the scenarios no longer reach a liquidation");
    }

    /// A random walk with regime shifts: enough to cross averages, trip stops
    /// and, at high leverage, liquidate.
    fn wandering(count: usize) -> Vec<Candle> {
        let mut state = 7u64;
        let mut next = || {
            state = state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            (state >> 11) as f64 / (1u64 << 53) as f64
        };
        let mut price = 30_000.0;
        (0..count)
            .map(|i| {
                let drift = if i % 300 < 150 { 0.0008 } else { -0.0006 };
                let open = price;
                price *= 1.0 + drift + (next() - 0.5) * 0.03;
                let high = open.max(price) * (1.0 + next() * 0.01);
                let low = open.min(price) * (1.0 - next() * 0.01);
                bar(i as i64, open, high, low, price)
            })
            .collect()
    }
}
