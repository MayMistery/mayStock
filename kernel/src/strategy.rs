//! The strategy manifest, and compiling one into something executable.
//!
//! The kernel parses the manifest JSON itself rather than taking a pre-digested
//! struct from Swift. That keeps one definition of what a strategy *is*: if the
//! DSL gains a function or a risk rule gains a field, it changes here and the
//! Swift side needs no matching edit to stay correct.

use std::collections::{BTreeSet, HashMap};

use serde::{Deserialize, Serialize};

use crate::expr::{eval, parser, Expr, ExprError, ExprResult};

// MARK: - Manifest

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "UPPERCASE")]
pub enum InstrumentType {
    #[default]
    Spot,
    Swap,
}

impl InstrumentType {
    pub fn allows_leverage(self) -> bool {
        matches!(self, Self::Swap)
    }
    pub fn allows_short(self) -> bool {
        matches!(self, Self::Swap)
    }
    /// Taker fee in basis points for a fresh account, used when the manifest
    /// states no costs of its own.
    pub fn default_fee_bps(self) -> f64 {
        match self {
            Self::Spot => 10.0,
            Self::Swap => 5.0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Market {
    #[serde(rename = "instId")]
    pub inst_id: String,
    #[serde(rename = "instType", default)]
    pub inst_type: InstrumentType,
    #[serde(default = "default_bar")]
    pub bar: String,
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

/// Bars in a year, for annualising Sharpe and returns.
pub fn bars_per_year(bar: &str) -> f64 {
    365.0 * 86_400.0 / bar_seconds(bar)
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

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Costs {
    #[serde(rename = "feeBps")]
    pub fee_bps: f64,
    #[serde(rename = "slippageBps", default = "default_slippage")]
    pub slippage_bps: f64,
}
fn default_slippage() -> f64 {
    5.0
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

        // Shorting is a swap-only capability; a spot manifest that declares a
        // short leg is a mistake worth naming rather than silently ignoring.
        if !manifest.market.inst_type.allows_short()
            && (short_entry.is_some() || short_exit.is_some())
        {
            return Err(ExprError::Syntax {
                message: "现货策略不能声明做空信号（shortEntry / shortExit）".into(),
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

    /// Effective costs: a manifest may state its own, otherwise the instrument
    /// default. Never a hard-coded guess buried in the engine.
    pub fn costs(&self, fallback_fee_bps: Option<f64>, fallback_slippage_bps: Option<f64>) -> Costs {
        self.manifest.costs.unwrap_or(Costs {
            fee_bps: fallback_fee_bps
                .unwrap_or_else(|| self.manifest.market.inst_type.default_fee_bps()),
            slippage_bps: fallback_slippage_bps.unwrap_or(5.0),
        })
    }

    pub fn leverage(&self) -> f64 {
        if self.manifest.market.inst_type.allows_leverage() {
            self.manifest.risk.leverage.max(1.0)
        } else {
            1.0
        }
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
    fn spot_defaults_to_ten_basis_points() {
        let manifest: Manifest = serde_json::from_str(DONCHIAN).unwrap();
        let compiled = CompiledStrategy::compile(manifest, &[]).unwrap();
        let costs = compiled.costs(None, None);
        assert_eq!(costs.fee_bps, 10.0);
        assert_eq!(costs.slippage_bps, 5.0);
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
    fn leverage_is_clamped_to_one_on_spot() {
        let json = DONCHIAN.replace(r#""leverage": 1"#, r#""leverage": 10"#);
        let manifest: Manifest = serde_json::from_str(&json).unwrap();
        let compiled = CompiledStrategy::compile(manifest, &[]).unwrap();
        assert_eq!(compiled.leverage(), 1.0, "spot has no leverage to give");
    }

    #[test]
    fn bar_intervals_convert_to_seconds() {
        assert_eq!(bar_seconds("4H"), 14_400.0);
        assert_eq!(bar_seconds("1D"), 86_400.0);
        assert_eq!(bar_seconds("nonsense"), 3_600.0);
        assert!((bars_per_year("1D") - 365.0).abs() < 1e-9);
    }
}
