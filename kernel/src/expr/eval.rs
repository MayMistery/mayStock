//! Evaluates parsed strategy expressions into full series, one value per candle.
//!
//! Evaluation is *vectorised and memoised*: `ema(close, 12)` appearing in three
//! rules is computed once. Nothing here can reach outside the arrays it is
//! given — the entire surface is the function table in the parent module.
//!
//! **Three-valued logic.** NaN means "not yet known" (indicator warm-up). It
//! propagates through arithmetic and comparison, but a definitively-false
//! operand still short-circuits `and`, and a definitively-true one
//! short-circuits `or`. [`truthy`] treats NaN as false, so a strategy never
//! trades on a signal its indicators cannot yet support.

use std::collections::HashMap;

use super::{arity_of, BinaryOp, Expr, ExprError, ExprResult, EMA_FAMILY, MARKET_SERIES, MAX_PERIOD};
use crate::candle::Candle;
use crate::series;

pub struct Evaluator<'a> {
    candles: &'a [Candle],
    params: &'a HashMap<String, f64>,
    /// Named non-OHLCV series declared in the manifest's `data` block, already
    /// aligned to `candles`.
    external: HashMap<String, Vec<f64>>,
    cache: HashMap<Expr, Vec<f64>>,
    count: usize,
}

/// True when the series value at `index` is a definite "yes".
pub fn truthy(series: &[f64], index: usize) -> bool {
    match series.get(index) {
        Some(v) => !v.is_nan() && *v != 0.0,
        None => false,
    }
}

impl<'a> Evaluator<'a> {
    pub fn new(
        candles: &'a [Candle],
        params: &'a HashMap<String, f64>,
        external: &HashMap<String, Vec<f64>>,
    ) -> Self {
        let count = candles.len();
        // Length-mismatched series would silently misalign signals; pad or trim
        // to the candle count so an index is always meaningful.
        let external = external
            .iter()
            .map(|(name, values)| {
                let mut fixed: Vec<f64> = values.iter().copied().take(count).collect();
                fixed.resize(count, f64::NAN);
                (name.clone(), fixed)
            })
            .collect();
        Self {
            candles,
            params,
            external,
            cache: HashMap::new(),
            count,
        }
    }

    pub fn evaluate(&mut self, expression: &Expr) -> ExprResult<Vec<f64>> {
        if let Some(hit) = self.cache.get(expression) {
            return Ok(hit.clone());
        }
        let result = self.compute(expression)?;
        self.cache.insert(expression.clone(), result.clone());
        Ok(result)
    }

    fn compute(&mut self, expression: &Expr) -> ExprResult<Vec<f64>> {
        match expression {
            Expr::Number(value) => Ok(vec![value.get(); self.count]),
            Expr::Variable(name) => self.named_series(name),
            Expr::Negate(inner) => Ok(self
                .evaluate(inner)?
                .into_iter()
                .map(|v| if v.is_nan() { f64::NAN } else { -v })
                .collect()),
            Expr::Not(inner) => Ok(self
                .evaluate(inner)?
                .into_iter()
                .map(|v| {
                    if v.is_nan() {
                        f64::NAN
                    } else if v == 0.0 {
                        1.0
                    } else {
                        0.0
                    }
                })
                .collect()),
            Expr::Binary(op, lhs, rhs) => {
                let a = self.evaluate(lhs)?;
                let b = self.evaluate(rhs)?;
                Ok(apply(*op, &a, &b))
            }
            Expr::Call(name, arguments) => self.call(name, arguments),
        }
    }

    // MARK: Base series

    fn named_series(&mut self, name: &str) -> ExprResult<Vec<f64>> {
        if let Some(value) = self.params.get(name) {
            return Ok(vec![*value; self.count]);
        }
        if let Some(external) = self.external.get(name) {
            return Ok(external.clone());
        }
        let c = self.candles;
        Ok(match name {
            "open" => c.iter().map(|k| k.open).collect(),
            "high" => c.iter().map(|k| k.high).collect(),
            "low" => c.iter().map(|k| k.low).collect(),
            "close" => c.iter().map(|k| k.close).collect(),
            "volume" => c.iter().map(|k| k.volume).collect(),
            "hl2" => c.iter().map(|k| (k.high + k.low) / 2.0).collect(),
            "hlc3" => c
                .iter()
                .map(|k| (k.high + k.low + k.close) / 3.0)
                .collect(),
            "ohlc4" => c
                .iter()
                .map(|k| (k.open + k.high + k.low + k.close) / 4.0)
                .collect(),
            "bar_index" => (0..self.count).map(|i| i as f64).collect(),
            _ => return Err(ExprError::UnknownIdentifier(name.to_string())),
        })
    }

    // MARK: Function table

    fn call(&mut self, name: &str, arguments: &[Expr]) -> ExprResult<Vec<f64>> {
        let Some((lo, hi)) = arity_of(name) else {
            return Err(ExprError::UnknownFunction(name.to_string()));
        };
        if arguments.len() < lo || arguments.len() > hi {
            let expected = if lo == hi {
                lo.to_string()
            } else {
                format!("{lo}~{hi}")
            };
            return Err(ExprError::BadArity {
                function: name.to_string(),
                expected,
                got: arguments.len(),
            });
        }

        let high: Vec<f64> = self.candles.iter().map(|k| k.high).collect();
        let low: Vec<f64> = self.candles.iter().map(|k| k.low).collect();
        let close: Vec<f64> = self.candles.iter().map(|k| k.close).collect();

        Ok(match name {
            "sma" => {
                let (x, p) = self.series_and_period(name, arguments)?;
                series::sma(&x, p)
            }
            "ema" => {
                let (x, p) = self.series_and_period(name, arguments)?;
                series::ema(&x, p)
            }
            "rma" => {
                let (x, p) = self.series_and_period(name, arguments)?;
                series::rma(&x, p)
            }
            "wma" => {
                let (x, p) = self.series_and_period(name, arguments)?;
                series::wma(&x, p)
            }
            "rsi" => {
                let (x, p) = self.series_and_period(name, arguments)?;
                series::rsi(&x, p)
            }
            "stdev" => {
                let (x, p) = self.series_and_period(name, arguments)?;
                series::stdev(&x, p)
            }
            "highest" => {
                let (x, p) = self.series_and_period(name, arguments)?;
                series::highest(&x, p)
            }
            "lowest" => {
                let (x, p) = self.series_and_period(name, arguments)?;
                series::lowest(&x, p)
            }
            "roc" => {
                let (x, p) = self.series_and_period(name, arguments)?;
                series::roc(&x, p)
            }
            "ref" => {
                let (x, p) = self.series_and_period(name, arguments)?;
                series::shift(&x, p as i64)
            }

            "atr" => {
                let p = self.period(&arguments[0], name, 1)?;
                series::atr(&high, &low, &close, p)
            }
            "natr" => {
                // ATR normalised by price, in percent — comparable across
                // instruments.
                let p = self.period(&arguments[0], name, 1)?;
                let atr = series::atr(&high, &low, &close, p);
                series::zip2(&atr, &close, |a, c| if c == 0.0 { f64::NAN } else { a / c * 100.0 })
            }

            "macd" => {
                let x = self.evaluate(&arguments[0])?;
                let fast = self.period(&arguments[1], name, 2)?;
                let slow = self.period(&arguments[2], name, 3)?;
                series::macd(&x, fast, slow, 9).macd
            }
            "macd_signal" | "macd_hist" => {
                let x = self.evaluate(&arguments[0])?;
                let fast = self.period(&arguments[1], name, 2)?;
                let slow = self.period(&arguments[2], name, 3)?;
                let signal = self.period(&arguments[3], name, 4)?;
                let m = series::macd(&x, fast, slow, signal);
                if name == "macd_signal" {
                    m.signal
                } else {
                    m.histogram
                }
            }

            "bb_upper" | "bb_lower" | "bb_width" => {
                let x = self.evaluate(&arguments[0])?;
                let period = self.period(&arguments[1], name, 2)?;
                let mult = self.constant(&arguments[2], name, 3)?;
                let band = series::bollinger(&x, period, mult);
                match name {
                    "bb_upper" => band.upper,
                    "bb_lower" => band.lower,
                    _ => {
                        let spread = series::zip2(&band.upper, &band.lower, |u, l| u - l);
                        series::zip2(&spread, &band.middle, |s, m| {
                            if m == 0.0 {
                                f64::NAN
                            } else {
                                s / m * 100.0
                            }
                        })
                    }
                }
            }

            "abs" => self
                .evaluate(&arguments[0])?
                .into_iter()
                .map(|v| if v.is_nan() { f64::NAN } else { v.abs() })
                .collect(),
            "sign" => self
                .evaluate(&arguments[0])?
                .into_iter()
                .map(|v| {
                    if v.is_nan() {
                        f64::NAN
                    } else if v > 0.0 {
                        1.0
                    } else if v < 0.0 {
                        -1.0
                    } else {
                        0.0
                    }
                })
                .collect(),
            "min" => {
                let a = self.evaluate(&arguments[0])?;
                let b = self.evaluate(&arguments[1])?;
                series::zip2(&a, &b, f64::min)
            }
            "max" => {
                let a = self.evaluate(&arguments[0])?;
                let b = self.evaluate(&arguments[1])?;
                series::zip2(&a, &b, f64::max)
            }
            "clamp" => {
                let value = self.evaluate(&arguments[0])?;
                let lower = self.constant(&arguments[1], name, 2)?;
                let upper = self.constant(&arguments[2], name, 3)?;
                value
                    .into_iter()
                    .map(|v| {
                        if v.is_nan() {
                            f64::NAN
                        } else {
                            v.max(lower).min(upper)
                        }
                    })
                    .collect()
            }

            "crossover" | "crossunder" => {
                let a = self.evaluate(&arguments[0])?;
                let b = self.evaluate(&arguments[1])?;
                if name == "crossover" {
                    series::crosses_above(&a, &b)
                } else {
                    series::crosses_below(&a, &b)
                }
            }

            _ => return Err(ExprError::UnknownFunction(name.to_string())),
        })
    }

    fn series_and_period(
        &mut self,
        name: &str,
        arguments: &[Expr],
    ) -> ExprResult<(Vec<f64>, usize)> {
        let x = self.evaluate(&arguments[0])?;
        let p = self.period(&arguments[1], name, 2)?;
        Ok((x, p))
    }

    // MARK: Constant folding

    /// Resolve an argument that must not vary bar-to-bar (periods, multipliers).
    /// Only numbers, declared params and arithmetic over them qualify.
    fn constant(&self, expression: &Expr, function: &str, position: usize) -> ExprResult<f64> {
        let known: Vec<&str> = self.external.keys().map(|s| s.as_str()).collect();
        match fold_constant(expression, self.params, &known)? {
            Some(value) => Ok(value),
            None => Err(ExprError::NonConstantArgument {
                function: function.to_string(),
                position,
            }),
        }
    }

    fn period(&self, expression: &Expr, function: &str, position: usize) -> ExprResult<usize> {
        let value = self.constant(expression, function, position)?;
        let rounded = value.round();
        if !(rounded >= 1.0 && rounded <= MAX_PERIOD as f64 && (value - rounded).abs() < 1e-9) {
            return Err(ExprError::InvalidPeriod {
                function: function.to_string(),
                value,
            });
        }
        Ok(rounded as usize)
    }
}

// MARK: Operators

fn apply(op: BinaryOp, a: &[f64], b: &[f64]) -> Vec<f64> {
    match op {
        BinaryOp::Add => series::zip2(a, b, |x, y| x + y),
        BinaryOp::Subtract => series::zip2(a, b, |x, y| x - y),
        BinaryOp::Multiply => series::zip2(a, b, |x, y| x * y),
        BinaryOp::Divide => series::zip2(a, b, |x, y| if y == 0.0 { f64::NAN } else { x / y }),
        BinaryOp::Modulo => series::zip2(a, b, |x, y| if y == 0.0 { f64::NAN } else { x % y }),
        BinaryOp::Greater => series::zip2(a, b, |x, y| if x > y { 1.0 } else { 0.0 }),
        BinaryOp::GreaterEqual => series::zip2(a, b, |x, y| if x >= y { 1.0 } else { 0.0 }),
        BinaryOp::Less => series::zip2(a, b, |x, y| if x < y { 1.0 } else { 0.0 }),
        BinaryOp::LessEqual => series::zip2(a, b, |x, y| if x <= y { 1.0 } else { 0.0 }),
        BinaryOp::Equal => series::zip2(a, b, |x, y| if x == y { 1.0 } else { 0.0 }),
        BinaryOp::NotEqual => series::zip2(a, b, |x, y| if x != y { 1.0 } else { 0.0 }),
        BinaryOp::CrossesAbove => series::crosses_above(a, b),
        BinaryOp::CrossesBelow => series::crosses_below(a, b),
        // A definite false makes `and` false even when the other side is still
        // warming up; a definite true does the same for `or`. This is what lets
        // `close > 0 and ema(close, 200) > 0` stay unknown rather than
        // silently false during warm-up, while `false and unknown` collapses.
        BinaryOp::And => kleene(a, b, |lhs, rhs| match (lhs, rhs) {
            (Some(false), _) | (_, Some(false)) => Some(false),
            (Some(true), Some(true)) => Some(true),
            _ => None,
        }),
        BinaryOp::Or => kleene(a, b, |lhs, rhs| match (lhs, rhs) {
            (Some(true), _) | (_, Some(true)) => Some(true),
            (Some(false), Some(false)) => Some(false),
            _ => None,
        }),
    }
}

fn kleene<F: Fn(Option<bool>, Option<bool>) -> Option<bool>>(
    a: &[f64],
    b: &[f64],
    f: F,
) -> Vec<f64> {
    let n = a.len().min(b.len());
    let mut out = vec![f64::NAN; n];
    for i in 0..n {
        let lhs = if a[i].is_nan() {
            None
        } else {
            Some(a[i] != 0.0)
        };
        let rhs = if b[i].is_nan() {
            None
        } else {
            Some(b[i] != 0.0)
        };
        if let Some(result) = f(lhs, rhs) {
            out[i] = if result { 1.0 } else { 0.0 };
        }
    }
    out
}

// MARK: Constant folding (free function so warm-up analysis can reuse it)

/// Fold an expression to a scalar, or `None` when it depends on market data.
pub fn fold_constant(
    expression: &Expr,
    params: &HashMap<String, f64>,
    known_series: &[&str],
) -> ExprResult<Option<f64>> {
    Ok(match expression {
        Expr::Number(value) => Some(value.get()),
        Expr::Variable(name) => {
            if let Some(value) = params.get(name) {
                return Ok(Some(*value));
            }
            // A known market or declared series is legitimately non-constant;
            // anything else is a typo the author deserves to hear about now.
            if !MARKET_SERIES.contains(&name.as_str()) && !known_series.contains(&name.as_str()) {
                return Err(ExprError::UnknownIdentifier(name.clone()));
            }
            None
        }
        Expr::Negate(inner) => fold_constant(inner, params, known_series)?.map(|v| -v),
        Expr::Not(inner) => {
            fold_constant(inner, params, known_series)?.map(|v| if v == 0.0 { 1.0 } else { 0.0 })
        }
        Expr::Call(_, _) => None,
        Expr::Binary(op, lhs, rhs) => {
            let (Some(a), Some(b)) = (
                fold_constant(lhs, params, known_series)?,
                fold_constant(rhs, params, known_series)?,
            ) else {
                return Ok(None);
            };
            match op {
                BinaryOp::Add => Some(a + b),
                BinaryOp::Subtract => Some(a - b),
                BinaryOp::Multiply => Some(a * b),
                BinaryOp::Divide => {
                    if b == 0.0 {
                        None
                    } else {
                        Some(a / b)
                    }
                }
                BinaryOp::Modulo => {
                    if b == 0.0 {
                        None
                    } else {
                        Some(a % b)
                    }
                }
                BinaryOp::Greater => Some(if a > b { 1.0 } else { 0.0 }),
                BinaryOp::GreaterEqual => Some(if a >= b { 1.0 } else { 0.0 }),
                BinaryOp::Less => Some(if a < b { 1.0 } else { 0.0 }),
                BinaryOp::LessEqual => Some(if a <= b { 1.0 } else { 0.0 }),
                BinaryOp::Equal => Some(if a == b { 1.0 } else { 0.0 }),
                BinaryOp::NotEqual => Some(if a != b { 1.0 } else { 0.0 }),
                BinaryOp::And => Some(if a != 0.0 && b != 0.0 { 1.0 } else { 0.0 }),
                BinaryOp::Or => Some(if a != 0.0 || b != 0.0 { 1.0 } else { 0.0 }),
                BinaryOp::CrossesAbove | BinaryOp::CrossesBelow => None,
            }
        }
    })
}

/// Upper bound on how many leading bars this expression cannot answer for.
/// Drives how much extra history to fetch so live signals match backtests.
pub fn warmup_bars(
    expression: &Expr,
    params: &HashMap<String, f64>,
    known_series: &[&str],
) -> usize {
    match expression {
        Expr::Number(_) | Expr::Variable(_) => 0,
        Expr::Negate(inner) | Expr::Not(inner) => warmup_bars(inner, params, known_series),
        Expr::Binary(_, lhs, rhs) => {
            warmup_bars(lhs, params, known_series).max(warmup_bars(rhs, params, known_series)) + 1
        }
        Expr::Call(name, arguments) => {
            let child = arguments
                .iter()
                .map(|a| warmup_bars(a, params, known_series))
                .max()
                .unwrap_or(0);
            let longest = arguments
                .iter()
                .filter_map(|a| fold_constant(a, params, known_series).ok().flatten())
                .filter(|v| *v >= 1.0 && *v <= MAX_PERIOD as f64)
                .fold(0.0f64, f64::max);
            let factor = if EMA_FAMILY.contains(&name.as_str()) {
                3.0
            } else {
                1.0
            };
            child + (longest * factor).ceil() as usize
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::candle::Candle;
    use crate::expr::parser::parse;

    fn candles(closes: &[f64]) -> Vec<Candle> {
        closes
            .iter()
            .enumerate()
            .map(|(i, c)| Candle {
                ts_ms: i as i64 * 60_000,
                open: *c,
                high: *c,
                low: *c,
                close: *c,
                volume: 1.0,
                confirmed: 1,
            })
            .collect()
    }

    fn run(source: &str, closes: &[f64]) -> Vec<f64> {
        let ks = candles(closes);
        let params = HashMap::new();
        let mut ev = Evaluator::new(&ks, &params, &HashMap::new());
        ev.evaluate(&parse(source).unwrap()).unwrap()
    }

    #[test]
    fn comparisons_yield_one_and_zero() {
        let out = run("close > 2", &[1.0, 2.0, 3.0]);
        assert_eq!(out, vec![0.0, 0.0, 1.0]);
    }

    #[test]
    fn a_definite_false_beats_an_unknown_in_and() {
        // sma(close, 10) is NaN this early, but `close > 1e9` is definitely
        // false, so the conjunction is false — not unknown.
        let out = run("close > 1000000000 and sma(close, 10) > 0", &[1.0, 2.0, 3.0]);
        assert_eq!(out, vec![0.0, 0.0, 0.0]);
    }

    #[test]
    fn an_unknown_survives_when_the_other_side_is_true() {
        let out = run("close > 0 and sma(close, 10) > 0", &[1.0, 2.0, 3.0]);
        assert!(out.iter().all(|v| v.is_nan()));
    }

    #[test]
    fn a_definite_true_beats_an_unknown_in_or() {
        let out = run("close > 0 or sma(close, 10) > 0", &[1.0, 2.0, 3.0]);
        assert_eq!(out, vec![1.0, 1.0, 1.0]);
    }

    #[test]
    fn truthy_treats_unknown_as_no() {
        assert!(!truthy(&[f64::NAN], 0));
        assert!(!truthy(&[0.0], 0));
        assert!(truthy(&[1.0], 0));
        assert!(!truthy(&[1.0], 5), "out of range is not a signal");
    }

    #[test]
    fn division_by_zero_is_unknown_not_infinity() {
        let out = run("close / 0", &[1.0, 2.0]);
        assert!(out.iter().all(|v| v.is_nan()));
    }

    #[test]
    fn unknown_identifiers_are_rejected() {
        let ks = candles(&[1.0, 2.0]);
        let params = HashMap::new();
        let mut ev = Evaluator::new(&ks, &params, &HashMap::new());
        let err = ev.evaluate(&parse("nosuchthing").unwrap()).unwrap_err();
        assert!(matches!(err, ExprError::UnknownIdentifier(_)));
    }

    #[test]
    fn unknown_functions_are_rejected() {
        let ks = candles(&[1.0, 2.0]);
        let params = HashMap::new();
        let mut ev = Evaluator::new(&ks, &params, &HashMap::new());
        let err = ev.evaluate(&parse("system(close)").unwrap()).unwrap_err();
        assert!(matches!(err, ExprError::UnknownFunction(_)));
    }

    #[test]
    fn a_period_that_depends_on_price_is_rejected() {
        let ks = candles(&[1.0, 2.0, 3.0]);
        let params = HashMap::new();
        let mut ev = Evaluator::new(&ks, &params, &HashMap::new());
        let err = ev.evaluate(&parse("sma(close, close)").unwrap()).unwrap_err();
        assert!(matches!(err, ExprError::NonConstantArgument { .. }));
    }

    #[test]
    fn absurd_periods_are_rejected() {
        let ks = candles(&[1.0, 2.0, 3.0]);
        let params = HashMap::new();
        let mut ev = Evaluator::new(&ks, &params, &HashMap::new());
        for source in ["sma(close, 0)", "sma(close, -5)", "sma(close, 9999999)", "sma(close, 2.5)"] {
            let err = ev.evaluate(&parse(source).unwrap()).unwrap_err();
            assert!(
                matches!(err, ExprError::InvalidPeriod { .. }),
                "{source} should be an invalid period, got {err:?}"
            );
        }
    }

    #[test]
    fn params_resolve_as_constants() {
        let ks = candles(&[1.0, 2.0, 3.0, 4.0, 5.0]);
        let mut params = HashMap::new();
        params.insert("fast".to_string(), 3.0);
        let mut ev = Evaluator::new(&ks, &params, &HashMap::new());
        let out = ev.evaluate(&parse("sma(close, fast)").unwrap()).unwrap();
        assert!((out[2] - 2.0).abs() < 1e-9);
    }

    #[test]
    fn memoisation_returns_the_same_series() {
        let ks = candles(&[1.0, 2.0, 3.0, 4.0, 5.0]);
        let params = HashMap::new();
        let mut ev = Evaluator::new(&ks, &params, &HashMap::new());
        let e = parse("ema(close, 3)").unwrap();
        let first = ev.evaluate(&e).unwrap();
        let second = ev.evaluate(&e).unwrap();
        assert_eq!(first.len(), second.len());
        for (a, b) in first.iter().zip(second.iter()) {
            assert!((a.is_nan() && b.is_nan()) || a == b);
        }
    }

    #[test]
    fn external_series_are_aligned_to_the_candles() {
        let ks = candles(&[1.0, 2.0, 3.0, 4.0]);
        let params = HashMap::new();
        let mut external = HashMap::new();
        external.insert("funding".to_string(), vec![0.1, 0.2]); // too short
        let mut ev = Evaluator::new(&ks, &params, &external);
        let out = ev.evaluate(&parse("funding").unwrap()).unwrap();
        assert_eq!(out.len(), 4);
        assert!(out[2].is_nan() && out[3].is_nan());
    }

    #[test]
    fn warmup_accounts_for_the_ema_tail() {
        let params = HashMap::new();
        let sma = warmup_bars(&parse("sma(close, 20)").unwrap(), &params, &[]);
        let ema = warmup_bars(&parse("ema(close, 20)").unwrap(), &params, &[]);
        assert_eq!(sma, 20);
        assert_eq!(ema, 60, "EMA needs roughly three windows to converge");
    }
}
