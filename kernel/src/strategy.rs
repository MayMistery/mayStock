//! The strategy manifest, and compiling one into something executable.
//!
//! The kernel parses the manifest JSON itself rather than taking a pre-digested
//! struct from Swift. That keeps one definition of what a strategy *is*: if the
//! DSL gains a function or a risk rule gains a field, it changes here and the
//! Swift side needs no matching edit to stay correct.

use std::collections::{BTreeSet, HashMap};

use serde::{Deserialize, Serialize};

use crate::calendar::MarketCalendar;
use crate::expr::{eval, parser, Expr, ExprError, ExprResult};
use crate::fees::{self, FeeComponent, OrderSide};

// MARK: - Venue

/// Where an instrument trades. The venue decides the calendar bars follow,
/// what the quote currency is, and how an instrument id is spelled — none of
/// which the kernel may guess from the id itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Venue {
    /// OKX: crypto spot and perpetual swaps, trading every hour of every day.
    #[default]
    Okx,
    /// Charles Schwab: US equities on the New York session.
    Schwab,
}

impl Venue {
    pub fn calendar(self) -> MarketCalendar {
        match self {
            Self::Okx => MarketCalendar::Continuous,
            Self::Schwab => MarketCalendar::UsEquities,
        }
    }

    pub fn quote_currency(self) -> &'static str {
        match self {
            Self::Okx => "USDT",
            Self::Schwab => "USD",
        }
    }
}

// MARK: - Instrument

/// How margin is lent against a position, which decides where it is
/// liquidated.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MarginRegime {
    /// No borrowing: the position is fully paid for and cannot be liquidated.
    None,
    /// Isolated margin on a derivative: the position is backed by
    /// `notional / leverage`, and is closed out when the loss eats that
    /// collateral down to the maintenance rate.
    Isolated,
    /// Regulation T margin on a stock: the broker lends against the shares and
    /// calls the loan when equity falls below the maintenance share of the
    /// position's *current* value.
    RegT,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "UPPERCASE")]
pub enum InstrumentType {
    #[default]
    Spot,
    Swap,
    Stock,
}

/// Everything the rest of the system may need to know about an instrument
/// type, in one place, so Swift can ask rather than keep a copy.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstrumentPolicy {
    #[serde(rename = "instType")]
    pub inst_type: InstrumentType,
    #[serde(rename = "allowsShort")]
    pub allows_short: bool,
    #[serde(rename = "allowsLeverage")]
    pub allows_leverage: bool,
    #[serde(rename = "maxLeverage")]
    pub max_leverage: f64,
    /// Sized in contracts rather than in the base unit, so the exchange has to
    /// be asked what one contract is worth.
    #[serde(rename = "tradesInContracts")]
    pub trades_in_contracts: bool,
    #[serde(rename = "marginRegime")]
    pub margin_regime: MarginRegime,
    /// Maintenance margin assumed when a backtest states none.
    #[serde(rename = "defaultMaintenanceMarginRate")]
    pub default_maintenance_margin_rate: Option<f64>,
    /// Cost model assumed when neither the manifest nor the caller states one.
    /// `None` means the type has no defensible default and a caller must say.
    #[serde(rename = "defaultFees")]
    pub default_fees: Option<Vec<FeeComponent>>,
}

impl InstrumentType {
    pub fn allows_leverage(self) -> bool {
        self.max_leverage() > 1.0
    }

    pub fn allows_short(self) -> bool {
        matches!(self, Self::Swap | Self::Stock)
    }

    /// The most leverage a manifest may declare. Spot has none to give; a
    /// perpetual goes to fifty; a stock on Regulation T margin borrows at most
    /// half its value, which is two times.
    pub fn max_leverage(self) -> f64 {
        match self {
            Self::Spot => 1.0,
            Self::Swap => 50.0,
            Self::Stock => 2.0,
        }
    }

    pub fn trades_in_contracts(self) -> bool {
        matches!(self, Self::Swap)
    }

    pub fn margin_regime(self) -> MarginRegime {
        match self {
            Self::Spot => MarginRegime::None,
            Self::Swap => MarginRegime::Isolated,
            Self::Stock => MarginRegime::RegT,
        }
    }

    /// Maintenance margin when a backtest states none: OKX's tier-one rate on
    /// a perpetual, and FINRA's 25% minimum on a margined stock.
    pub fn default_maintenance_margin_rate(self) -> Option<f64> {
        match self {
            Self::Spot => None,
            Self::Swap => Some(0.005),
            Self::Stock => Some(0.25),
        }
    }

    /// Taker fee for a fresh OKX account, used when the manifest states no
    /// costs and the caller supplies none. A stock has no such default: its
    /// commission is a broker's choice and its regulatory levies change every
    /// year, so a caller has to say rather than have the kernel assume.
    pub fn default_fees(self) -> Option<Vec<FeeComponent>> {
        match self {
            Self::Spot => Some(vec![FeeComponent::flat_bps(10.0)]),
            Self::Swap => Some(vec![FeeComponent::flat_bps(5.0)]),
            Self::Stock => None,
        }
    }

    pub fn policy(self) -> InstrumentPolicy {
        InstrumentPolicy {
            inst_type: self,
            allows_short: self.allows_short(),
            allows_leverage: self.allows_leverage(),
            max_leverage: self.max_leverage(),
            trades_in_contracts: self.trades_in_contracts(),
            margin_regime: self.margin_regime(),
            default_maintenance_margin_rate: self.default_maintenance_margin_rate(),
            default_fees: self.default_fees(),
        }
    }

    pub const ALL: [InstrumentType; 3] = [Self::Spot, Self::Swap, Self::Stock];
}

// MARK: - Manifest

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Market {
    #[serde(rename = "instId")]
    pub inst_id: String,
    #[serde(rename = "instType", default)]
    pub inst_type: InstrumentType,
    #[serde(default = "default_bar")]
    pub bar: String,
    /// Absent in schema-1 manifests, which only ever meant OKX.
    #[serde(default)]
    pub venue: Venue,
}

impl Market {
    pub fn calendar(&self) -> MarketCalendar {
        self.venue.calendar()
    }

    pub fn bar_seconds(&self) -> f64 {
        bar_seconds(&self.bar)
    }

    /// Bars in a year on this market, for annualising anything.
    pub fn bars_per_year(&self) -> f64 {
        self.calendar().bars_per_year(self.bar_seconds())
    }
}

fn default_bar() -> String {
    "1H".to_string()
}

/// Seconds in one bar of the named interval. Unknown intervals fall back to an
/// hour rather than zero, which would make funding bucketing divide by nothing.
pub fn bar_seconds(bar: &str) -> f64 {
    match bar {
        "1m" => 60.0,
        "3m" => 180.0,
        "5m" => 300.0,
        "15m" => 900.0,
        "30m" => 1_800.0,
        "1H" => 3_600.0,
        "2H" => 7_200.0,
        "4H" => 14_400.0,
        "6H" => 21_600.0,
        "12H" => 43_200.0,
        "1D" => 86_400.0,
        "1W" => 604_800.0,
        _ => 3_600.0,
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParamSpec {
    pub name: String,
    #[serde(default, alias = "value")]
    pub default: Option<f64>,
    pub min: Option<f64>,
    pub max: Option<f64>,
    pub label: Option<String>,
    pub step: Option<f64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Signals {
    #[serde(rename = "longEntry")]
    pub long_entry: Option<String>,
    #[serde(rename = "longExit")]
    pub long_exit: Option<String>,
    #[serde(rename = "shortEntry")]
    pub short_entry: Option<String>,
    #[serde(rename = "shortExit")]
    pub short_exit: Option<String>,
    /// Continuous exposure in −1…+1, evaluated per bar. When present the
    /// strategy scales a position rather than switching in and out.
    pub exposure: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SizingMode {
    #[serde(rename = "equityPct")]
    EquityPct,
    #[serde(rename = "fixedQuote")]
    FixedQuote,
    #[serde(rename = "riskPerTrade")]
    RiskPerTrade,
    #[serde(rename = "volatilityTarget")]
    VolatilityTarget,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Sizing {
    pub mode: SizingMode,
    pub value: f64,
}

impl Default for Sizing {
    fn default() -> Self {
        Self {
            mode: SizingMode::EquityPct,
            value: 100.0,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct AtrStop {
    #[serde(default = "atr_period")]
    pub period: usize,
    #[serde(default = "atr_mult")]
    pub mult: f64,
}
fn atr_period() -> usize {
    14
}
fn atr_mult() -> f64 {
    2.5
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Risk {
    #[serde(rename = "stopLossPct")]
    pub stop_loss_pct: Option<f64>,
    #[serde(rename = "takeProfitPct")]
    pub take_profit_pct: Option<f64>,
    #[serde(rename = "trailingStopPct")]
    pub trailing_stop_pct: Option<f64>,
    #[serde(rename = "atrStop")]
    pub atr_stop: Option<AtrStop>,
    #[serde(default = "one")]
    pub leverage: f64,
    #[serde(rename = "cooldownBars", default)]
    pub cooldown_bars: usize,
    #[serde(rename = "minHoldBars", default)]
    pub min_hold_bars: usize,
    /// The third barrier: close after this many bars whatever the signal says.
    ///
    /// A stop and a take-profit bound the price a position may reach but say
    /// nothing about how long it may sit there. Without a time limit a trade
    /// whose thesis simply stopped being true — neither stopped out nor
    /// profitable — occupies the capital indefinitely. `None` means no limit,
    /// which is the historical behaviour.
    #[serde(rename = "maxHoldBars")]
    pub max_hold_bars: Option<usize>,
    #[serde(rename = "maxDailyLossPct")]
    pub max_daily_loss_pct: Option<f64>,
    #[serde(rename = "volLookbackBars", default = "vol_lookback")]
    pub vol_lookback_bars: usize,
    #[serde(rename = "maxExposure", default = "one")]
    pub max_exposure: f64,
    #[serde(rename = "rebalanceThreshold", default = "rebalance")]
    pub rebalance_threshold: f64,
}

fn one() -> f64 {
    1.0
}
fn vol_lookback() -> usize {
    60
}
fn rebalance() -> f64 {
    0.1
}

impl Default for Risk {
    fn default() -> Self {
        Self {
            stop_loss_pct: None,
            take_profit_pct: None,
            trailing_stop_pct: None,
            atr_stop: None,
            leverage: 1.0,
            cooldown_bars: 0,
            min_hold_bars: 0,
            max_hold_bars: None,
            max_daily_loss_pct: None,
            vol_lookback_bars: 60,
            max_exposure: 1.0,
            rebalance_threshold: 0.1,
        }
    }
}

/// What a fill costs beyond its price.
///
/// Written as `{"feeBps": 10, "slippageBps": 1}` when the model is the plain
/// both-sides percentage — the only shape there used to be — and as
/// `{"fees": [...], "slippageBps": 1}` otherwise. See [`crate::fees`].
#[derive(Debug, Clone, PartialEq)]
pub struct Costs {
    pub fees: Vec<FeeComponent>,
    pub slippage_bps: f64,
}

impl Costs {
    pub fn flat(fee_bps: f64, slippage_bps: f64) -> Self {
        Self {
            fees: vec![FeeComponent::flat_bps(fee_bps)],
            slippage_bps,
        }
    }

    /// What one fill pays in fees. `units` and `notional` are magnitudes.
    pub fn fee(&self, side: OrderSide, units: f64, notional: f64) -> f64 {
        fees::total_fee(&self.fees, side, units, notional)
    }

    /// The model as a single both-sides percentage, when it is one.
    pub fn flat_bps(&self) -> Option<f64> {
        fees::as_flat_bps(&self.fees)
    }
}

#[derive(Serialize, Deserialize)]
struct CostsWire {
    #[serde(rename = "feeBps", default, skip_serializing_if = "Option::is_none")]
    fee_bps: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fees: Option<Vec<FeeComponent>>,
    #[serde(rename = "slippageBps", default = "default_slippage")]
    slippage_bps: f64,
}

impl Serialize for Costs {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let wire = match self.flat_bps() {
            Some(bps) => CostsWire { fee_bps: Some(bps), fees: None, slippage_bps: self.slippage_bps },
            None => CostsWire { fee_bps: None, fees: Some(self.fees.clone()), slippage_bps: self.slippage_bps },
        };
        wire.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for Costs {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let wire = CostsWire::deserialize(deserializer)?;
        let fees = match (wire.fee_bps, wire.fees) {
            (Some(_), Some(_)) => {
                return Err(serde::de::Error::custom(
                    "costs 里 feeBps 和 fees 只能写一个：前者是后者的简写",
                ))
            }
            (Some(bps), None) => vec![FeeComponent::flat_bps(bps)],
            (None, Some(list)) => list,
            (None, None) => {
                return Err(serde::de::Error::custom("costs 必须写 feeBps 或 fees"))
            }
        };
        Ok(Self { fees, slippage_bps: wire.slippage_bps })
    }
}

/// Adverse price move assumed on a market fill, per side, in basis points.
///
/// One, not five. Five was a number somebody typed, and it was wrong by more
/// than an order of magnitude for the instruments this trades:
///
/// | component            | measured on BTC-USDT-SWAP |
/// |----------------------|---------------------------|
/// | bid-ask spread       | 0.0155 bps (one tick, and one tick essentially always) |
/// | our own book impact  | 0.06–0.08 bps, from real fills on ~7,500 USDT orders |
///
/// The top of book holds 500+ contracts — several hundred thousand USDT — so an
/// order this size does not move it. What remains is the drift between the bar
/// close that produced the signal and the moment the order actually lands,
/// which is roughly 1 bps unsigned over twenty seconds and has an expected
/// value near zero because its direction is not ours to choose.
///
/// One basis point is therefore already generous: an order of magnitude above
/// the measured spread and impact, with room for a thinner instrument or a
/// disorderly minute. It is still an assumption, and `ms_calibrate_slippage`
/// exists to replace it with this account's own fills.
///
/// Why this matters more than it looks: slippage is charged twice per round
/// trip, so five versus one is eight basis points of hurdle on every trade a
/// strategy makes. A sweep judged against the wrong hurdle discards good
/// strategies silently, and that is the expensive direction of this error.
pub fn default_slippage() -> f64 {
    1.0
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    pub id: String,
    #[serde(default)]
    pub name: String,
    pub market: Market,
    #[serde(default)]
    pub params: Vec<ParamSpec>,
    #[serde(default)]
    pub signals: Signals,
    #[serde(default)]
    pub sizing: Sizing,
    #[serde(default)]
    pub risk: Risk,
    pub costs: Option<Costs>,
}

// MARK: - Compiled form

/// A manifest whose expressions have been parsed and validated.
///
/// Compiling is the only place a strategy can be rejected for naming something
/// that does not exist. After this point every identifier is known to resolve
/// and every period is known to be a sane integer, so evaluation cannot fail
/// for a reason the author could have been told about at import time.
#[derive(Debug)]
pub struct CompiledStrategy {
    pub manifest: Manifest,
    pub params: HashMap<String, f64>,
    pub long_entry: Option<Expr>,
    pub long_exit: Option<Expr>,
    pub short_entry: Option<Expr>,
    pub short_exit: Option<Expr>,
    pub exposure: Option<Expr>,
    pub warmup_bars: usize,
    pub free_parameter_count: usize,
    /// Externally supplied series names this strategy was compiled against.
    ///
    /// Retained because `with_params` has to re-validate at the new values, and
    /// a re-validation that had forgotten the declared series would reject a
    /// manifest that legitimately reads `funding_rate`.
    pub known_series: Vec<String>,
}

impl CompiledStrategy {
    pub fn compile(manifest: Manifest, known_series: &[String]) -> ExprResult<Self> {
        let mut params = HashMap::new();
        for spec in &manifest.params {
            params.insert(spec.name.clone(), spec.default.unwrap_or(0.0));
        }

        let known: Vec<&str> = known_series.iter().map(|s| s.as_str()).collect();
        let parse_one = |source: &Option<String>| -> ExprResult<Option<Expr>> {
            match source {
                Some(text) if !text.trim().is_empty() => Ok(Some(parser::parse(text)?)),
                _ => Ok(None),
            }
        };

        let long_entry = parse_one(&manifest.signals.long_entry)?;
        let long_exit = parse_one(&manifest.signals.long_exit)?;
        let short_entry = parse_one(&manifest.signals.short_entry)?;
        let short_exit = parse_one(&manifest.signals.short_exit)?;
        let exposure = parse_one(&manifest.signals.exposure)?;

        let all: Vec<&Expr> = [
            &long_entry,
            &long_exit,
            &short_entry,
            &short_exit,
            &exposure,
        ]
        .into_iter()
        .flatten()
        .collect();

        // Reject unknown identifiers now, not on the first live bar.
        let mut identifiers = BTreeSet::new();
        for expr in &all {
            expr.identifiers(&mut identifiers);
        }
        for name in &identifiers {
            let known_name = params.contains_key(name)
                || crate::expr::MARKET_SERIES.contains(&name.as_str())
                || known.contains(&name.as_str());
            if !known_name {
                return Err(ExprError::UnknownIdentifier(name.clone()));
            }
        }

        // Shorting needs something to borrow; a manifest that declares a short
        // leg on an instrument that cannot be shorted is a mistake worth
        // naming rather than silently ignoring.
        let inst_type = manifest.market.inst_type;
        if !inst_type.allows_short() && (short_entry.is_some() || short_exit.is_some()) {
            return Err(ExprError::Syntax {
                message: format!("{inst_type:?} 不能做空，清单却声明了 shortEntry / shortExit"),
                column: 1,
            });
        }

        // Leverage beyond what the instrument's margin allows is not clamped:
        // a manifest tested at 3× and quietly run at 2× is a different
        // strategy from the one that was validated.
        let leverage = manifest.risk.leverage;
        if leverage > inst_type.max_leverage() + 1e-9 || leverage < 1.0 {
            return Err(ExprError::Syntax {
                message: format!(
                    "杠杆 {leverage}× 超出 {inst_type:?} 允许的范围（1~{}）",
                    inst_type.max_leverage()
                ),
                column: 1,
            });
        }

        // A ceiling below the floor can never be satisfied: the position would
        // be both forbidden to close and required to be closed. Refuse it here
        // instead of letting the barrier silently win every time.
        if let Some(limit) = manifest.risk.max_hold_bars {
            if limit < manifest.risk.min_hold_bars {
                return Err(ExprError::Syntax {
                    message: format!(
                        "maxHoldBars({limit}) 小于 minHoldBars({})，这两条规则无法同时满足",
                        manifest.risk.min_hold_bars
                    ),
                    column: 1,
                });
            }
        }

        // Dry-run every expression so an unknown function, a bad arity or a
        // nonsense period is refused *here* rather than on the first live bar.
        //
        // This is done by actually evaluating against a throwaway series rather
        // than by re-deriving the rules: a second validation table would be a
        // second thing to keep in step with the evaluator, and the case where
        // they disagree is precisely the case where a strategy imports cleanly
        // and then fails while holding a position.
        let probe = Self::probe_candles();
        // The probe must know about declared external series, or a manifest
        // that legitimately reads `funding_rate` would be rejected here for
        // naming something the *probe* happens not to have.
        let probe_external: HashMap<String, Vec<f64>> = known_series
            .iter()
            .map(|name| (name.clone(), vec![1.0; probe.len()]))
            .collect();
        let mut evaluator = eval::Evaluator::new(&probe, &params, &probe_external);
        for expr in &all {
            evaluator.evaluate(expr)?;
        }

        let mut warmup = all
            .iter()
            .map(|e| eval::warmup_bars(e, &params, &known))
            .max()
            .unwrap_or(0);
        // Volatility targeting needs a full lookback of returns before it can
        // size anything, which is independent of what the signal expressions
        // need. Folding it in here keeps one definition of "how much history
        // does this strategy require" for both the backtester and the runner.
        if manifest.sizing.mode == SizingMode::VolatilityTarget {
            warmup = warmup.max(manifest.risk.vol_lookback_bars + 1);
        }

        let free_parameter_count = manifest
            .params
            .iter()
            .filter(|p| match (p.min, p.max) {
                (Some(lo), Some(hi)) => hi > lo,
                _ => false,
            })
            .count();

        Ok(Self {
            manifest,
            params,
            long_entry,
            long_exit,
            short_entry,
            short_exit,
            exposure,
            warmup_bars: warmup,
            free_parameter_count,
            known_series: known_series.to_vec(),
        })
    }

    /// The same strategy with different parameter values.
    ///
    /// This is what makes a parameter sweep cheap. A parameter value does not
    /// change the *parsed* expression — the AST depends only on the source
    /// text — so a grid point is this struct with a different map, not a fresh
    /// lex, parse and validate of every rule.
    ///
    /// Warm-up *is* recomputed, because indicator periods come from parameters
    /// and a strategy that needs 200 bars at one setting and 20 at another must
    /// not be tested as though it always needed 200. That walk is arithmetic
    /// over an existing tree; the parse it replaces is not.
    ///
    /// Returns `None` when the values are outside what the manifest declares,
    /// or when they produce an expression the evaluator refuses — a period of
    /// zero, say. A grid point that cannot be evaluated is skipped by the
    /// caller rather than failing the sweep.
    pub fn with_params(&self, values: &HashMap<String, f64>) -> Option<Self> {
        let mut params = self.params.clone();
        for spec in &self.manifest.params {
            let Some(raw) = values.get(&spec.name) else { continue };
            // Clamped to the declared range, exactly as the manifest's own
            // loader does: a caller cannot widen a parameter's domain by
            // sending a number from outside it.
            let clamped = match (spec.min, spec.max) {
                (Some(lo), Some(hi)) if hi >= lo => raw.clamp(lo, hi),
                (Some(lo), None) => raw.max(lo),
                (None, Some(hi)) => raw.min(hi),
                _ => *raw,
            };
            if !clamped.is_finite() {
                return None;
            }
            params.insert(spec.name.clone(), clamped);
        }

        let known: Vec<&str> = self.known_series.iter().map(|s| s.as_str()).collect();
        let all: Vec<&Expr> = [
            self.long_entry.as_ref(),
            self.long_exit.as_ref(),
            self.short_entry.as_ref(),
            self.short_exit.as_ref(),
            self.exposure.as_ref(),
        ]
        .into_iter()
        .flatten()
        .collect();

        // The same dry run `compile` does, for the same reason: a period that
        // becomes illegal at these values must be caught here, not on the bar
        // where the sweep happens to reach it.
        let probe = Self::probe_candles();
        let probe_external: HashMap<String, Vec<f64>> = known
            .iter()
            .map(|name| ((*name).to_string(), vec![1.0; probe.len()]))
            .collect();
        let mut evaluator = eval::Evaluator::new(&probe, &params, &probe_external);
        for expr in &all {
            evaluator.evaluate(expr).ok()?;
        }

        let mut warmup = all
            .iter()
            .map(|e| eval::warmup_bars(e, &params, &known))
            .max()
            .unwrap_or(0);
        if self.manifest.sizing.mode == SizingMode::VolatilityTarget {
            warmup = warmup.max(self.manifest.risk.vol_lookback_bars + 1);
        }

        Some(Self {
            manifest: self.manifest.clone(),
            params,
            long_entry: self.long_entry.clone(),
            long_exit: self.long_exit.clone(),
            short_entry: self.short_entry.clone(),
            short_exit: self.short_exit.clone(),
            exposure: self.exposure.clone(),
            warmup_bars: warmup,
            free_parameter_count: self.free_parameter_count,
            known_series: self.known_series.clone(),
        })
    }

    /// A few well-formed bars used only to type-check expressions at compile
    /// time. Every indicator returns all-NaN on input this short, which is
    /// exactly what we want: the values are discarded, only the errors matter.
    ///
    /// The series must contain an external-series-free, sane OHLC so nothing
    /// fails for a reason the real data would not reproduce.
    fn probe_candles() -> Vec<crate::candle::Candle> {
        (0..4)
            .map(|i| crate::candle::Candle {
                ts_ms: i as i64 * 60_000,
                open: 100.0,
                high: 101.0,
                low: 99.0,
                close: 100.0,
                volume: 1.0,
                confirmed: 1,
            })
            .collect()
    }

    pub fn is_continuous(&self) -> bool {
        self.exposure.is_some()
    }

    /// Effective costs: the manifest's own when it states them, otherwise what
    /// the caller supplies from its fee schedule, otherwise the instrument's
    /// documented default. Never a hard-coded guess buried in the engine —
    /// and for an instrument with no defensible default, a refusal.
    pub fn costs(
        &self,
        fallback_fees: Option<&[FeeComponent]>,
        fallback_slippage_bps: Option<f64>,
    ) -> Result<Costs, String> {
        if let Some(costs) = &self.manifest.costs {
            return Ok(costs.clone());
        }
        let inst_type = self.manifest.market.inst_type;
        let fees = match fallback_fees {
            Some(list) => list.to_vec(),
            None => inst_type.default_fees().ok_or_else(|| {
                format!("{inst_type:?} 没有默认费率：清单未声明 costs，调用方也没有提供费率模型")
            })?,
        };
        Ok(Costs {
            fees,
            slippage_bps: fallback_slippage_bps.unwrap_or_else(default_slippage),
        })
    }

    /// Leverage the manifest declares. `compile` already refused anything the
    /// instrument cannot provide, so this is the declared figure, floored at 1.
    pub fn leverage(&self) -> f64 {
        self.manifest.risk.leverage.max(1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DONCHIAN: &str = r#"{
      "id": "03-btc-donchian-breakout",
      "name": "BTC Donchian",
      "market": { "instId": "BTC-USDT", "instType": "SPOT", "bar": "4H" },
      "params": [
        { "name": "entryLen", "default": 20, "min": 8, "max": 120 },
        { "name": "exitLen", "default": 10, "min": 4, "max": 60 }
      ],
      "signals": {
        "longEntry": "close > ref(highest(high, entryLen), 1)",
        "longExit": "close < ref(lowest(low, exitLen), 1)"
      },
      "sizing": { "mode": "riskPerTrade", "value": 1 },
      "risk": { "atrStop": { "period": 14, "mult": 2.5 }, "maxDailyLossPct": 5, "leverage": 1 }
    }"#;

    #[test]
    fn a_real_example_manifest_compiles() {
        let manifest: Manifest = serde_json::from_str(DONCHIAN).unwrap();
        let compiled = CompiledStrategy::compile(manifest, &[]).unwrap();
        assert_eq!(compiled.params["entryLen"], 20.0);
        assert!(compiled.long_entry.is_some());
        assert!(compiled.short_entry.is_none());
        assert!(!compiled.is_continuous());
        assert_eq!(compiled.free_parameter_count, 2);
        assert!(compiled.warmup_bars >= 20);
    }

    #[test]
    fn a_schema_one_manifest_is_an_okx_manifest() {
        let manifest: Manifest = serde_json::from_str(DONCHIAN).unwrap();
        assert_eq!(manifest.market.venue, Venue::Okx);
        assert_eq!(manifest.market.calendar(), MarketCalendar::Continuous);
    }

    #[test]
    fn spot_defaults_to_ten_basis_points() {
        let manifest: Manifest = serde_json::from_str(DONCHIAN).unwrap();
        let compiled = CompiledStrategy::compile(manifest, &[]).unwrap();
        let costs = compiled.costs(None, None).unwrap();
        assert_eq!(costs.flat_bps(), Some(10.0));
        // One definition of the default slippage, shared with the manifest
        // loader; it used to be 5 here and 1 there.
        assert_eq!(costs.slippage_bps, default_slippage());
    }

    #[test]
    fn a_stock_has_no_default_costs_and_says_so() {
        let json = DONCHIAN.replace(
            r#""market": { "instId": "BTC-USDT", "instType": "SPOT", "bar": "4H" }"#,
            r#""market": { "instId": "AAPL", "instType": "STOCK", "bar": "1D", "venue": "schwab" }"#,
        );
        let manifest: Manifest = serde_json::from_str(&json).unwrap();
        let compiled = CompiledStrategy::compile(manifest, &[]).unwrap();
        assert!(compiled.costs(None, None).is_err(), "a guess would be optimistic");
        let supplied = compiled
            .costs(Some(&[FeeComponent::flat_bps(0.0)]), Some(2.0))
            .unwrap();
        assert_eq!(supplied.slippage_bps, 2.0);
        assert_eq!(compiled.manifest.market.calendar(), MarketCalendar::UsEquities);
        assert_eq!(compiled.manifest.market.bars_per_year(), 252.0);
    }

    #[test]
    fn costs_read_the_shorthand_and_the_list_but_not_both() {
        let flat: Costs = serde_json::from_str(r#"{"feeBps": 10, "slippageBps": 5}"#).unwrap();
        assert_eq!(flat.flat_bps(), Some(10.0));
        assert_eq!(flat.slippage_bps, 5.0);
        // Written back as the shorthand it came from.
        assert_eq!(serde_json::to_string(&flat).unwrap(), r#"{"feeBps":10.0,"slippageBps":5.0}"#);

        let list: Costs = serde_json::from_str(
            r#"{"fees":[{"basis":"notional","bps":0.278,"side":"sell"}],"slippageBps":2}"#,
        )
        .unwrap();
        assert_eq!(list.flat_bps(), None);
        assert!(serde_json::to_string(&list).unwrap().contains("\"fees\":["));

        assert!(serde_json::from_str::<Costs>(r#"{"feeBps": 1, "fees": []}"#).is_err());
        assert!(serde_json::from_str::<Costs>(r#"{"slippageBps": 1}"#).is_err());
        // Omitted slippage takes the documented default.
        let bare: Costs = serde_json::from_str(r#"{"feeBps": 4}"#).unwrap();
        assert_eq!(bare.slippage_bps, default_slippage());
    }

    #[test]
    fn an_undeclared_parameter_is_rejected_at_compile_time() {
        let json = DONCHIAN.replace("entryLen\", 1)", "nosuchparam\", 1)");
        let json = json.replace("highest(high, entryLen)", "highest(high, nosuchparam)");
        let manifest: Manifest = serde_json::from_str(&json).unwrap();
        let err = CompiledStrategy::compile(manifest, &[]).unwrap_err();
        assert!(matches!(err, ExprError::UnknownIdentifier(_)));
    }

    #[test]
    fn a_spot_strategy_cannot_declare_shorts() {
        let json = DONCHIAN.replace(
            r#""longExit": "close < ref(lowest(low, exitLen), 1)""#,
            r#""longExit": "close < ref(lowest(low, exitLen), 1)", "shortEntry": "close < 0""#,
        );
        let manifest: Manifest = serde_json::from_str(&json).unwrap();
        assert!(CompiledStrategy::compile(manifest, &[]).is_err());
    }

    #[test]
    fn a_stock_may_declare_shorts_within_its_margin() {
        let json = DONCHIAN
            .replace(
                r#""market": { "instId": "BTC-USDT", "instType": "SPOT", "bar": "4H" }"#,
                r#""market": { "instId": "AAPL", "instType": "STOCK", "bar": "1D", "venue": "schwab" }"#,
            )
            .replace(
                r#""longExit": "close < ref(lowest(low, exitLen), 1)""#,
                r#""longExit": "close < ref(lowest(low, exitLen), 1)", "shortEntry": "close < 0""#,
            )
            .replace(r#""leverage": 1"#, r#""leverage": 2"#);
        let manifest: Manifest = serde_json::from_str(&json).unwrap();
        let compiled = CompiledStrategy::compile(manifest, &[]).unwrap();
        assert_eq!(compiled.leverage(), 2.0);
    }

    #[test]
    fn leverage_beyond_the_instrument_is_refused_not_clamped() {
        // Spot has no margin at all.
        let json = DONCHIAN.replace(r#""leverage": 1"#, r#""leverage": 10"#);
        let manifest: Manifest = serde_json::from_str(&json).unwrap();
        assert!(CompiledStrategy::compile(manifest, &[]).is_err(), "spot has no leverage to give");
        // A stock on Regulation T stops at two.
        let json = DONCHIAN
            .replace(
                r#""market": { "instId": "BTC-USDT", "instType": "SPOT", "bar": "4H" }"#,
                r#""market": { "instId": "AAPL", "instType": "STOCK", "bar": "1D", "venue": "schwab" }"#,
            )
            .replace(r#""leverage": 1"#, r#""leverage": 3"#);
        let manifest: Manifest = serde_json::from_str(&json).unwrap();
        assert!(CompiledStrategy::compile(manifest, &[]).is_err());
    }

    #[test]
    fn every_instrument_type_has_a_coherent_policy() {
        for inst_type in InstrumentType::ALL {
            let policy = inst_type.policy();
            assert_eq!(policy.allows_leverage, policy.max_leverage > 1.0);
            // Anything sized in contracts must ask the exchange for the
            // multiplier; anything else is one-for-one by definition.
            assert_eq!(policy.trades_in_contracts, inst_type == InstrumentType::Swap);
            // A margin regime exists exactly when there is something to lend.
            assert_eq!(
                policy.margin_regime == MarginRegime::None,
                !policy.allows_leverage,
                "{inst_type:?}"
            );
            assert_eq!(
                policy.default_maintenance_margin_rate.is_some(),
                policy.allows_leverage,
                "{inst_type:?}"
            );
            // The policy survives the wire, since Swift reads it from JSON.
            let json = serde_json::to_string(&policy).unwrap();
            let back: InstrumentPolicy = serde_json::from_str(&json).unwrap();
            assert_eq!(back.max_leverage, policy.max_leverage);
        }
    }

    #[test]
    fn bar_intervals_convert_to_seconds() {
        assert_eq!(bar_seconds("4H"), 14_400.0);
        assert_eq!(bar_seconds("1D"), 86_400.0);
        assert_eq!(bar_seconds("nonsense"), 3_600.0);
    }

    #[test]
    fn a_market_annualises_by_its_own_calendar() {
        let okx = Market { inst_id: "BTC-USDT".into(), inst_type: InstrumentType::Spot,
                           bar: "1D".into(), venue: Venue::Okx };
        assert!((okx.bars_per_year() - 365.25).abs() < 1e-9);
        let schwab = Market { inst_id: "AAPL".into(), inst_type: InstrumentType::Stock,
                              bar: "1H".into(), venue: Venue::Schwab };
        assert_eq!(schwab.bars_per_year(), 252.0 * 7.0);
        assert_eq!(Venue::Schwab.quote_currency(), "USD");
    }
}
