//! Options: the pricing model behind the backtest, the contract-selection
//! rule shared with live trading, and the exchange's fee rule.
//!
//! What this is, and what it is not. OKX serves no candles for a contract that
//! has expired, so an option strategy cannot be replayed against the prices it
//! would actually have traded at — there is nothing to read. The backtest
//! therefore prices every contract with Black–Scholes off the underlying's own
//! candles, using realised volatility scaled by a declared premium over it.
//! That makes it a *model-priced* backtest, and the report says so. The thing
//! it measures honestly is whether the directional signal earns more than the
//! premium it spends; the exact premium on any one day is the model's guess.
//!
//! Live trading never touches the model. It reads the exchange's chain, its
//! bid/ask and its mark, and shares exactly one thing with the simulation: the
//! rule for *which* contract to buy, which lives here as one function so the
//! two cannot pick differently.
//!
//! Only long options are traded — a call on a long signal, a put on a short
//! one. Selling options is a different business: the loss is unbounded and the
//! exchange margins it, and neither of those is modelled here. Refusing to
//! write them is a deliberate boundary, not an omission.

use crate::fees::{self, FeeComponent, OrderSide};
use serde::{Deserialize, Serialize};

use crate::decide::Direction;
use crate::strategy::{CompiledStrategy, SizingMode};

// MARK: - Contract kind

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OptionKind {
    Call,
    Put,
}

impl OptionKind {
    /// The contract that expresses a directional view.
    pub fn for_direction(direction: Direction) -> Self {
        match direction {
            Direction::Long => Self::Call,
            Direction::Short => Self::Put,
        }
    }

    /// The view a long position in this contract expresses.
    pub fn direction(self) -> Direction {
        match self {
            Self::Call => Direction::Long,
            Self::Put => Direction::Short,
        }
    }

    /// +1 for a call, −1 for a put: the direction a rising spot helps.
    pub fn sign(self) -> f64 {
        match self {
            Self::Call => 1.0,
            Self::Put => -1.0,
        }
    }

    /// The letter OKX puts at the end of an option instrument id.
    pub fn code(self) -> &'static str {
        match self {
            Self::Call => "C",
            Self::Put => "P",
        }
    }
}

// MARK: - Manifest block

/// The `options` block of a manifest whose market is `OPTION`.
///
/// Every field has a default, so a manifest may omit the block entirely and
/// trade the nearest weekly at-the-money contract.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct OptionsSpec {
    /// Underlying index the chain is keyed by, e.g. `BTC-USD`. Derived from
    /// the market's base currency when absent.
    #[serde(default)]
    pub uly: Option<String>,
    /// Nearest listed expiry at least this far away is the one traded. Short
    /// tenors pay less premium but decay faster; the default is a week.
    #[serde(rename = "minDaysToExpiry", default = "default_min_days")]
    pub min_days_to_expiry: f64,
    /// Strike offset from spot in percent, positive meaning out of the money
    /// in the direction traded: +5 buys a call 5% above spot or a put 5%
    /// below it. Zero is at the money.
    #[serde(rename = "moneynessPct", default)]
    pub moneyness_pct: f64,
    /// Strike grid the model lays out, in quote currency. Absent means one
    /// percent of spot rounded to a single significant figure, which is close
    /// to how the exchange lists them.
    #[serde(rename = "strikeStep")]
    pub strike_step: Option<f64>,
    /// Underlying units per contract, for rounding to whole contracts in the
    /// model. OKX's BTC options are 0.01 BTC each. Live trading reads the real
    /// figure from the exchange and ignores this.
    #[serde(rename = "contractMultiplier", default = "default_multiplier")]
    pub contract_multiplier: f64,
    /// Implied volatility as a multiple of realised. Options habitually trade
    /// above realised volatility — the premium sellers demand for taking the
    /// other side — and a model that priced at realised would buy them too
    /// cheaply. 1.2 is a conservative crypto default; the studio's IV readout
    /// is the number to replace it with.
    #[serde(rename = "impliedVolMultiplier", default = "default_iv_multiplier")]
    pub implied_vol_multiplier: f64,
    /// Fee cap as a share of premium. OKX charges options on the underlying
    /// notional but never more than 12.5% of the premium, which is what keeps
    /// a cheap far-out-of-the-money contract from costing more in fees than
    /// it is worth.
    #[serde(rename = "feeCapPctOfPremium", default = "default_fee_cap")]
    pub fee_cap_pct_of_premium: f64,
}

fn default_min_days() -> f64 {
    7.0
}
fn default_multiplier() -> f64 {
    0.01
}
fn default_iv_multiplier() -> f64 {
    1.2
}
fn default_fee_cap() -> f64 {
    12.5
}

impl Default for OptionsSpec {
    fn default() -> Self {
        Self {
            uly: None,
            min_days_to_expiry: default_min_days(),
            moneyness_pct: 0.0,
            strike_step: None,
            contract_multiplier: default_multiplier(),
            implied_vol_multiplier: default_iv_multiplier(),
            fee_cap_pct_of_premium: default_fee_cap(),
        }
    }
}

impl OptionsSpec {
    /// Why the block cannot be traded as written, or `None` when it can.
    pub fn validate(&self) -> Option<String> {
        if !(self.min_days_to_expiry > 0.0) || self.min_days_to_expiry > 365.0 {
            return Some(format!(
                "options.minDaysToExpiry 应在 0~365 天之间，实际 {}",
                self.min_days_to_expiry
            ));
        }
        if !self.moneyness_pct.is_finite() || self.moneyness_pct.abs() > 50.0 {
            return Some(format!(
                "options.moneynessPct 应在 -50~50 之间，实际 {}",
                self.moneyness_pct
            ));
        }
        if let Some(step) = self.strike_step {
            if !(step > 0.0) {
                return Some("options.strikeStep 必须大于 0".to_string());
            }
        }
        if !(self.contract_multiplier > 0.0) {
            return Some("options.contractMultiplier 必须大于 0".to_string());
        }
        if !(self.implied_vol_multiplier > 0.0) || self.implied_vol_multiplier > 5.0 {
            return Some(format!(
                "options.impliedVolMultiplier 应在 0~5 之间，实际 {}",
                self.implied_vol_multiplier
            ));
        }
        if !(self.fee_cap_pct_of_premium >= 0.0) || self.fee_cap_pct_of_premium > 100.0 {
            return Some("options.feeCapPctOfPremium 应在 0~100 之间".to_string());
        }
        None
    }
}

// MARK: - Pricing

/// Standard normal cumulative distribution.
pub fn normal_cdf(x: f64) -> f64 {
    0.5 * (1.0 + erf(x / std::f64::consts::SQRT_2))
}

/// Abramowitz & Stegun 7.1.26: absolute error below 1.5e-7, which is far
/// inside the precision any premium here is quoted to.
fn erf(x: f64) -> f64 {
    let sign = if x < 0.0 { -1.0 } else { 1.0 };
    let x = x.abs();
    let t = 1.0 / (1.0 + 0.327_591_1 * x);
    let poly = ((((1.061_405_429 * t - 1.453_152_027) * t) + 1.421_413_741) * t
        - 0.284_496_736)
        * t
        + 0.254_829_592;
    sign * (1.0 - poly * t * (-x * x).exp())
}

/// What the contract pays if it expired right now.
pub fn intrinsic(kind: OptionKind, spot: f64, strike: f64) -> f64 {
    match kind {
        OptionKind::Call => (spot - strike).max(0.0),
        OptionKind::Put => (strike - spot).max(0.0),
    }
}

/// Black–Scholes premium per unit of underlying, with zero rates — the funding
/// leg of a crypto option is not a risk-free rate and is not modelled.
///
/// `NaN` when the volatility is unknown: a price that cannot be computed must
/// not be guessed, exactly as an indicator in warm-up is NaN rather than zero.
pub fn black_scholes(kind: OptionKind, spot: f64, strike: f64, years: f64, sigma: f64) -> f64 {
    if !(spot > 0.0) || !(strike > 0.0) {
        return f64::NAN;
    }
    if years <= 0.0 {
        return intrinsic(kind, spot, strike);
    }
    if !sigma.is_finite() || !(sigma > 0.0) {
        return f64::NAN;
    }
    let vol_time = sigma * years.sqrt();
    let d1 = ((spot / strike).ln() + 0.5 * vol_time * vol_time) / vol_time;
    let d2 = d1 - vol_time;
    match kind {
        OptionKind::Call => spot * normal_cdf(d1) - strike * normal_cdf(d2),
        OptionKind::Put => strike * normal_cdf(-d2) - spot * normal_cdf(-d1),
    }
}

pub const DAY_MS: i64 = 86_400_000;
pub const YEAR_MS: f64 = 365.25 * 86_400_000.0;
/// OKX settles options at 08:00 UTC.
pub const EXPIRY_HOUR_MS: i64 = 8 * 3_600_000;

/// Years between two instants, floored at zero.
pub fn years_between(from_ms: i64, to_ms: i64) -> f64 {
    ((to_ms - from_ms) as f64 / YEAR_MS).max(0.0)
}

// MARK: - The model's chain

/// The first settlement instant at least `min_days` after `now_ms`.
///
/// Tenors of two days or less get the daily contract; anything longer snaps
/// to the following Friday, which is where the exchange's liquid weeklies and
/// monthlies sit. A model expiry that landed on a Tuesday would pay for time
/// no listed contract sells.
pub fn next_expiry_ms(now_ms: i64, min_days: f64) -> i64 {
    let earliest = now_ms + (min_days.max(0.0) * DAY_MS as f64).round() as i64;
    let day_start = earliest.div_euclid(DAY_MS) * DAY_MS;
    let mut candidate = day_start + EXPIRY_HOUR_MS;
    if candidate < earliest {
        candidate += DAY_MS;
    }
    if min_days <= 2.0 {
        return candidate;
    }
    // 1970-01-01 was a Thursday; with Sunday as 0 that day is 4.
    let weekday = (candidate.div_euclid(DAY_MS) + 4).rem_euclid(7);
    let to_friday = (5 - weekday).rem_euclid(7);
    candidate + to_friday * DAY_MS
}

/// One percent of spot, rounded to a single significant figure: 80,000 →
/// 800, 3,200 → 30. Close enough to the listed grids to keep the model's
/// strikes where real ones would be.
pub fn default_strike_step(spot: f64) -> f64 {
    if !(spot > 0.0) {
        return 1.0;
    }
    let raw = spot * 0.01;
    let magnitude = 10f64.powf(raw.log10().floor());
    (raw / magnitude).round().max(1.0) * magnitude
}

/// The strike a moneyness offset asks for, snapped to the grid.
pub fn target_strike(kind: OptionKind, spot: f64, moneyness_pct: f64, step: f64) -> f64 {
    let target = spot * (1.0 + kind.sign() * moneyness_pct / 100.0);
    let step = if step > 0.0 { step } else { default_strike_step(spot) };
    ((target / step).round() * step).max(step)
}

// MARK: - Selection

/// One listed (or modelled) contract.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ContractCandidate {
    #[serde(rename = "instId")]
    pub inst_id: String,
    pub strike: f64,
    #[serde(rename = "expiryMs")]
    pub expiry_ms: i64,
    pub kind: OptionKind,
}

/// Everything the selection rule needs, in one JSON-shaped struct so the
/// live caller and the simulator hand over identical inputs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SelectionRequest {
    pub kind: OptionKind,
    pub spot: f64,
    #[serde(rename = "nowMs")]
    pub now_ms: i64,
    #[serde(rename = "minDaysToExpiry")]
    pub min_days_to_expiry: f64,
    #[serde(rename = "moneynessPct", default)]
    pub moneyness_pct: f64,
    #[serde(rename = "strikeStep", default)]
    pub strike_step: Option<f64>,
    #[serde(default)]
    pub candidates: Vec<ContractCandidate>,
}

/// The one rule for which contract to buy: the nearest expiry at least
/// `minDaysToExpiry` away, and on it the strike closest to the moneyness
/// target — ties going to the strike nearer spot, which is the more liquid
/// one. `None` when nothing in the chain qualifies.
pub fn select_contract(request: &SelectionRequest) -> Option<ContractCandidate> {
    if !(request.spot > 0.0) {
        return None;
    }
    let earliest = request.now_ms + (request.min_days_to_expiry.max(0.0) * DAY_MS as f64) as i64;
    let eligible: Vec<&ContractCandidate> = request
        .candidates
        .iter()
        .filter(|c| c.kind == request.kind && c.expiry_ms >= earliest && c.strike > 0.0)
        .collect();
    let expiry = eligible.iter().map(|c| c.expiry_ms).min()?;
    let step = request
        .strike_step
        .filter(|s| *s > 0.0)
        .unwrap_or_else(|| default_strike_step(request.spot));
    let target = target_strike(request.kind, request.spot, request.moneyness_pct, step);
    eligible
        .into_iter()
        .filter(|c| c.expiry_ms == expiry)
        .min_by(|a, b| {
            let da = (a.strike - target).abs();
            let db = (b.strike - target).abs();
            da.partial_cmp(&db)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| {
                    (a.strike - request.spot)
                        .abs()
                        .partial_cmp(&(b.strike - request.spot).abs())
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
        })
        .cloned()
}

/// The chain the model lists around a spot price: one expiry, a handful of
/// strikes either side of the target. Fed through [`select_contract`] so the
/// simulation buys by the same rule live trading does.
pub fn synthetic_chain(
    kind: OptionKind,
    spot: f64,
    now_ms: i64,
    spec: &OptionsSpec,
) -> Vec<ContractCandidate> {
    if !(spot > 0.0) {
        return Vec::new();
    }
    let expiry = next_expiry_ms(now_ms, spec.min_days_to_expiry);
    let step = spec
        .strike_step
        .filter(|s| *s > 0.0)
        .unwrap_or_else(|| default_strike_step(spot));
    let centre = target_strike(kind, spot, spec.moneyness_pct, step);
    (-3..=3)
        .map(|offset| centre + offset as f64 * step)
        .filter(|strike| *strike > 0.0)
        .map(|strike| ContractCandidate {
            inst_id: format!("MODEL-{}-{}-{}", expiry, strike, kind.code()),
            strike,
            expiry_ms: expiry,
            kind,
        })
        .collect()
}

// MARK: - Costs and sizing

/// What the exchange charges for one option fill.
///
/// OKX bills options on the underlying notional, not on the premium, and caps
/// the charge at a share of the premium. Both halves matter: without the cap
/// a cheap far-out-of-the-money contract would cost more to trade than to
/// own, and without the notional basis an expensive deep-in-the-money one
/// would look nearly free. The venue's fee components are applied to the
/// underlying notional, so a schedule that charges by side or per unit is
/// honoured here as it is everywhere else.
pub fn option_fee(
    fees: &[FeeComponent],
    side: OrderSide,
    spot: f64,
    premium_per_unit: f64,
    units: f64,
    cap_pct_of_premium: f64,
) -> f64 {
    let on_notional = fees::total_fee(fees, side, units, spot * units);
    let cap = cap_pct_of_premium / 100.0 * premium_per_unit * units;
    on_notional.min(cap).max(0.0)
}

/// Premium the strategy may spend on one entry, in quote currency.
///
/// The premium *is* the position's maximum loss, so `equityPct` and
/// `riskPerTrade` mean the same thing here: the share of the budget put at
/// risk. Volatility targeting has nothing to scale and is refused at compile
/// time. `None` when there is no capital to spend.
pub fn premium_budget(strategy: &CompiledStrategy, equity: f64) -> Option<f64> {
    if !(equity > 0.0) {
        return None;
    }
    let sizing = &strategy.manifest.sizing;
    let raw = match sizing.mode {
        SizingMode::EquityPct | SizingMode::RiskPerTrade => equity * sizing.value / 100.0,
        SizingMode::FixedQuote => sizing.value,
        SizingMode::VolatilityTarget => return None,
    };
    let capped = raw.min(equity);
    (capped > 0.0).then_some(capped)
}

/// Whole contracts a budget buys at a premium, rounded down to the lot; zero
/// when it cannot afford one.
pub fn contracts_for(budget: f64, premium_per_unit: f64, multiplier: f64, lot: f64) -> f64 {
    let per_contract = premium_per_unit * multiplier;
    if !(per_contract > 0.0) || !(budget > 0.0) {
        return 0.0;
    }
    let lot = if lot > 0.0 { lot } else { 1.0 };
    (budget / per_contract / lot).floor() * lot
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_normal_cdf_is_symmetric_and_bounded() {
        assert!((normal_cdf(0.0) - 0.5).abs() < 1e-7);
        assert!((normal_cdf(1.96) - 0.975).abs() < 1e-3);
        assert!((normal_cdf(-1.96) - 0.025).abs() < 1e-3);
        assert!(normal_cdf(10.0) > 0.999_999);
        assert!(normal_cdf(-10.0) < 1e-6);
    }

    #[test]
    fn put_call_parity_holds_with_zero_rates() {
        let (spot, strike, years, sigma) = (80_000.0, 82_000.0, 0.05, 0.6);
        let call = black_scholes(OptionKind::Call, spot, strike, years, sigma);
        let put = black_scholes(OptionKind::Put, spot, strike, years, sigma);
        assert!((call - put - (spot - strike)).abs() < 1e-6, "C − P = S − K when r = 0");
    }

    #[test]
    fn a_premium_is_never_below_intrinsic_and_decays_to_it() {
        let call = black_scholes(OptionKind::Call, 100.0, 90.0, 0.1, 0.5);
        assert!(call > 10.0);
        assert_eq!(black_scholes(OptionKind::Call, 100.0, 90.0, 0.0, 0.5), 10.0);
        assert_eq!(black_scholes(OptionKind::Put, 100.0, 90.0, 0.0, 0.5), 0.0);
    }

    #[test]
    fn an_unknown_volatility_prices_to_unknown_not_zero() {
        assert!(black_scholes(OptionKind::Call, 100.0, 100.0, 0.1, f64::NAN).is_nan());
        assert!(black_scholes(OptionKind::Call, 100.0, 100.0, 0.1, 0.0).is_nan());
        assert!(black_scholes(OptionKind::Call, 0.0, 100.0, 0.1, 0.5).is_nan());
    }

    #[test]
    fn more_volatility_costs_more_premium() {
        let calm = black_scholes(OptionKind::Put, 100.0, 100.0, 0.1, 0.3);
        let wild = black_scholes(OptionKind::Put, 100.0, 100.0, 0.1, 0.9);
        assert!(wild > calm);
    }

    #[test]
    fn short_tenors_expire_daily_and_longer_ones_on_a_friday() {
        // 2026-09-07 is a Monday; 08:00 UTC that day.
        let monday_0800 = 1_788_768_000_000i64;
        assert_eq!(monday_0800.div_euclid(DAY_MS) * DAY_MS + EXPIRY_HOUR_MS, monday_0800);
        let now = monday_0800 + 2 * 3_600_000; // 10:00 Monday
        // One day out: the first 08:00 that is a full day away is Wednesday's —
        // Tuesday 08:00 is only 22 hours off, and "at least" means at least.
        assert_eq!(next_expiry_ms(now, 1.0), monday_0800 + 2 * DAY_MS);
        // From exactly 08:00, one day out is tomorrow's settlement.
        assert_eq!(next_expiry_ms(monday_0800, 1.0), monday_0800 + DAY_MS);
        // A week out: the Friday after next Monday, i.e. 11 days later.
        let expiry = next_expiry_ms(now, 7.0);
        assert!(expiry >= now + 7 * DAY_MS);
        let weekday = (expiry.div_euclid(DAY_MS) + 4).rem_euclid(7);
        assert_eq!(weekday, 5, "a weekly expiry lands on a Friday");
        assert_eq!(expiry.rem_euclid(DAY_MS), EXPIRY_HOUR_MS, "and at 08:00 UTC");
    }

    #[test]
    fn the_default_strike_grid_tracks_the_price_level() {
        assert_eq!(default_strike_step(79_527.0), 800.0);
        assert_eq!(default_strike_step(3_120.0), 30.0);
        assert_eq!(default_strike_step(0.0), 1.0);
    }

    #[test]
    fn moneyness_points_out_of_the_money_in_the_traded_direction() {
        // +5% on a call is above spot; +5% on a put is below it.
        assert_eq!(target_strike(OptionKind::Call, 100_000.0, 5.0, 1_000.0), 105_000.0);
        assert_eq!(target_strike(OptionKind::Put, 100_000.0, 5.0, 1_000.0), 95_000.0);
        assert_eq!(target_strike(OptionKind::Call, 100_000.0, 0.0, 1_000.0), 100_000.0);
    }

    fn candidate(id: &str, strike: f64, expiry_days: i64, kind: OptionKind) -> ContractCandidate {
        ContractCandidate {
            inst_id: id.into(),
            strike,
            expiry_ms: expiry_days * DAY_MS,
            kind,
        }
    }

    #[test]
    fn selection_takes_the_nearest_eligible_expiry_and_closest_strike() {
        let request = SelectionRequest {
            kind: OptionKind::Call,
            spot: 100_000.0,
            now_ms: 0,
            min_days_to_expiry: 7.0,
            moneyness_pct: 0.0,
            strike_step: Some(1_000.0),
            candidates: vec![
                candidate("too-soon", 100_000.0, 3, OptionKind::Call),
                candidate("wrong-kind", 100_000.0, 8, OptionKind::Put),
                candidate("far-strike", 110_000.0, 8, OptionKind::Call),
                candidate("right", 101_000.0, 8, OptionKind::Call),
                candidate("later", 100_000.0, 15, OptionKind::Call),
            ],
        };
        assert_eq!(select_contract(&request).unwrap().inst_id, "right");
    }

    #[test]
    fn selection_declines_when_nothing_qualifies() {
        let request = SelectionRequest {
            kind: OptionKind::Put,
            spot: 100_000.0,
            now_ms: 0,
            min_days_to_expiry: 30.0,
            moneyness_pct: 0.0,
            strike_step: None,
            candidates: vec![candidate("soon", 100_000.0, 5, OptionKind::Put)],
        };
        assert!(select_contract(&request).is_none());
    }

    #[test]
    fn the_model_chain_is_chosen_by_the_same_rule() {
        let spec = OptionsSpec { moneyness_pct: 5.0, ..OptionsSpec::default() };
        let chain = synthetic_chain(OptionKind::Put, 80_000.0, 0, &spec);
        assert_eq!(chain.len(), 7);
        let request = SelectionRequest {
            kind: OptionKind::Put,
            spot: 80_000.0,
            now_ms: 0,
            min_days_to_expiry: spec.min_days_to_expiry,
            moneyness_pct: spec.moneyness_pct,
            strike_step: spec.strike_step,
            candidates: chain,
        };
        let chosen = select_contract(&request).unwrap();
        assert_eq!(chosen.strike, 76_000.0, "5% under spot on an 800 grid");
        assert!(chosen.expiry_ms >= 7 * DAY_MS);
    }

    #[test]
    fn the_fee_is_on_notional_but_capped_by_the_premium() {
        let fees = [FeeComponent::flat_bps(3.0)];
        // 3 bps of 80,000 × 1 unit = 24; 12.5% of a 500 premium = 62.5 → 24.
        assert!((option_fee(&fees, OrderSide::Buy, 80_000.0, 500.0, 1.0, 12.5) - 24.0).abs() < 1e-9);
        // A 50 premium caps the fee at 6.25.
        assert!((option_fee(&fees, OrderSide::Sell, 80_000.0, 50.0, 1.0, 12.5) - 6.25).abs() < 1e-9);
        // A component that only charges sales charges nothing on the purchase.
        let sell_only = [FeeComponent { side: fees::FeeSide::Sell, ..FeeComponent::flat_bps(3.0) }];
        assert_eq!(option_fee(&sell_only, OrderSide::Buy, 80_000.0, 500.0, 1.0, 12.5), 0.0);
    }

    #[test]
    fn whole_contracts_only() {
        // 1,000 of budget at 30,000 per unit × 0.01 per contract = 3.33 → 3.
        assert_eq!(contracts_for(1_000.0, 30_000.0, 0.01, 1.0), 3.0);
        assert_eq!(contracts_for(100.0, 30_000.0, 0.01, 1.0), 0.0, "cannot afford one");
        assert_eq!(contracts_for(1_000.0, 0.0, 0.01, 1.0), 0.0, "no price, no size");
    }

    #[test]
    fn the_spec_rejects_nonsense() {
        assert!(OptionsSpec::default().validate().is_none());
        let bad = OptionsSpec { min_days_to_expiry: 0.0, ..OptionsSpec::default() };
        assert!(bad.validate().is_some());
        let bad = OptionsSpec { implied_vol_multiplier: 9.0, ..OptionsSpec::default() };
        assert!(bad.validate().is_some());
    }
}
