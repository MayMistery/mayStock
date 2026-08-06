//! How big a position should be, and where its protective stop sits.
//!
//! Extracted so the backtester and the live runner call *the same* function.
//! Before this module the backtester sized in Rust and the runner sized again
//! in Swift, and the two had already drifted: the Swift copy honoured only a
//! percentage stop, so a manifest using `riskPerTrade` with an ATR stop risked
//! 1% of capital per trade in simulation and committed the whole budget live.

use crate::strategy::{CompiledStrategy, SizingMode};

/// Absolute price distance to the protective stop, or `None` when the manifest
/// declares neither kind. Two stops configured → the tighter one governs,
/// because the first one touched is the one that fills.
pub fn stop_distance(strategy: &CompiledStrategy, entry: f64, atr: Option<f64>) -> Option<f64> {
    let risk = &strategy.manifest.risk;
    let mut candidates: Vec<f64> = Vec::new();
    if let Some(pct) = risk.stop_loss_pct {
        candidates.push(entry * pct / 100.0);
    }
    if let (Some(atr_stop), Some(atr)) = (risk.atr_stop, atr) {
        if !atr.is_nan() && atr > 0.0 {
            candidates.push(atr * atr_stop.mult);
        }
    }
    candidates.into_iter().reduce(f64::min)
}

/// Notional to commit, in quote currency. `None` when the strategy cannot be
/// sized on this bar — a risk-per-trade strategy whose stop distance is unknown
/// must stand aside rather than guess, because guessing means over-betting.
///
/// `equity` is the capital this strategy may deploy, not the whole account.
pub fn target_notional(
    strategy: &CompiledStrategy,
    equity: f64,
    price: f64,
    leverage: f64,
    stop_distance: Option<f64>,
) -> Option<f64> {
    if !(equity > 0.0) || !(price > 0.0) {
        return None;
    }
    let sizing = &strategy.manifest.sizing;
    let notional = match sizing.mode {
        SizingMode::EquityPct => equity * sizing.value / 100.0 * leverage,
        SizingMode::FixedQuote => sizing.value,
        SizingMode::RiskPerTrade => {
            // Size so that being stopped out costs `value` percent of equity.
            let distance = stop_distance?;
            if !(distance > 0.0) {
                return None;
            }
            (equity * sizing.value / 100.0) / distance * price
        }
        // Only reachable when a manifest asks for volatility targeting without
        // declaring an exposure expression; there is nothing to scale, so it
        // commits its budget. The continuous path sizes off the exposure.
        SizingMode::VolatilityTarget => equity * leverage,
    };
    // Two hard ceilings that no manifest can argue with: its own budget, and
    // that budget times leverage.
    let capped = notional.min(equity * leverage);
    (capped > 0.0).then_some(capped)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::strategy::Manifest;

    fn strategy(sizing: &str, risk: &str) -> CompiledStrategy {
        let json = format!(
            r#"{{"id":"t","market":{{"instId":"BTC-USDT","bar":"1H"}},
                 "signals":{{"longEntry":"close > 0"}},
                 "sizing":{},"risk":{}}}"#,
            sizing, risk
        );
        let manifest: Manifest = serde_json::from_str(&json).unwrap();
        CompiledStrategy::compile(manifest, &[]).unwrap()
    }

    #[test]
    fn equity_percent_commits_a_share_of_the_budget() {
        let s = strategy(r#"{"mode":"equityPct","value":50}"#, "{}");
        let n = target_notional(&s, 10_000.0, 100.0, 1.0, None).unwrap();
        assert!((n - 5_000.0).abs() < 1e-9);
    }

    #[test]
    fn fixed_quote_is_capped_by_the_budget() {
        let s = strategy(r#"{"mode":"fixedQuote","value":50000}"#, "{}");
        let n = target_notional(&s, 10_000.0, 100.0, 1.0, None).unwrap();
        assert!((n - 10_000.0).abs() < 1e-9, "never exceed the allocation");
    }

    /// The defect this module exists to prevent: an ATR-only stop must size by
    /// risk, not fall through to the whole budget.
    #[test]
    fn risk_per_trade_sizes_off_an_atr_stop() {
        let s = strategy(
            r#"{"mode":"riskPerTrade","value":1}"#,
            r#"{"atrStop":{"period":14,"mult":2.5}}"#,
        );
        let distance = stop_distance(&s, 64_000.0, Some(500.0)).unwrap();
        assert!((distance - 1_250.0).abs() < 1e-9, "2.5 x ATR");
        // Risking 1% of 10,000 = 100 over a 1,250 move is 0.08 coins = 5,120.
        let n = target_notional(&s, 10_000.0, 64_000.0, 1.0, Some(distance)).unwrap();
        assert!((n - 5_120.0).abs() < 1e-6, "got {n}");
    }

    #[test]
    fn risk_per_trade_stands_aside_without_a_stop() {
        let s = strategy(r#"{"mode":"riskPerTrade","value":1}"#, "{}");
        assert!(stop_distance(&s, 64_000.0, None).is_none());
        assert!(
            target_notional(&s, 10_000.0, 64_000.0, 1.0, None).is_none(),
            "no stop distance means no size — never the whole budget"
        );
    }

    #[test]
    fn the_tighter_of_two_stops_governs() {
        let s = strategy(
            r#"{"mode":"riskPerTrade","value":1}"#,
            r#"{"stopLossPct":1,"atrStop":{"period":14,"mult":2.5}}"#,
        );
        // 1% of 64,000 = 640; 2.5 x ATR(500) = 1,250. The stop hit first is 640.
        let d = stop_distance(&s, 64_000.0, Some(500.0)).unwrap();
        assert!((d - 640.0).abs() < 1e-9);
    }

    #[test]
    fn nonsense_inputs_yield_no_size() {
        let s = strategy(r#"{"mode":"equityPct","value":100}"#, "{}");
        assert!(target_notional(&s, 0.0, 100.0, 1.0, None).is_none());
        assert!(target_notional(&s, 10_000.0, 0.0, 1.0, None).is_none());
        assert!(target_notional(&s, -5.0, 100.0, 1.0, None).is_none());
    }
}
