//! The last thing between a computed order and the exchange.
//!
//! Sizing already caps a position at its budget and its leverage, so in the
//! normal case nothing here ever fires. That is the point. These are the checks
//! that catch the *abnormal* case — a stop distance that came back as a
//! rounding error and made `riskPerTrade` size to the moon, a mark price read
//! from a bad tick, a manifest edited to `fixedQuote: 1000000`. Every one of
//! those produces a number that sizing is happy to return.
//!
//! Modelled on NautilusTrader's RiskEngine, which puts notional caps, rate
//! limits and a trading state machine in front of every submission rather than
//! trusting the strategy that produced the order.

use serde::{Deserialize, Serialize};

/// What the venue is currently permitted to be asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum TradingState {
    /// Normal operation.
    #[default]
    Active,
    /// No new orders at all. Used while something is being investigated.
    Halted,
    /// Only orders that shrink exposure. This is what a breaker should trip
    /// into rather than `Halted`: a halted engine cannot close the position
    /// that tripped it.
    Reducing,
}

/// Limits applied to every order, independent of the strategy that asked.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct OrderLimits {
    /// Hard ceiling on one order's notional, in quote currency. `None` for no
    /// cap, which is only sensible in a backtest.
    #[serde(rename = "maxOrderNotional")]
    pub max_order_notional: Option<f64>,
    /// Ceiling on one order's notional as a share of account equity. Catches
    /// the same class of bug as the absolute cap but scales with the account,
    /// so it stays meaningful after the balance changes.
    #[serde(rename = "maxOrderEquityPct")]
    pub max_order_equity_pct: Option<f64>,
    pub state: TradingState,
}

impl Default for OrderLimits {
    fn default() -> Self {
        Self {
            max_order_notional: None,
            // Ten times the account is not a plausible single order for any
            // strategy this workbench runs, and is comfortably above anything
            // legitimate sizing produces at the leverage caps in use.
            max_order_equity_pct: Some(1_000.0),
            state: TradingState::Active,
        }
    }
}

/// Why an order was refused. `None` means it may go.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OrderDenied {
    pub reason: String,
    /// True when the refusal is a policy state rather than a suspect order, so
    /// the caller can report "paused" instead of "something is wrong".
    #[serde(rename = "byPolicy")]
    pub by_policy: bool,
}

/// Check one order against the limits.
///
/// `base_delta` is signed in coins, `held_base` is the position it acts on.
pub fn check_order(
    base_delta: f64,
    held_base: f64,
    price: f64,
    equity: f64,
    limits: &OrderLimits,
) -> Option<OrderDenied> {
    if base_delta == 0.0 {
        return None;
    }
    // A non-finite size is not a large order, it is a broken calculation, and
    // it must never reach an exchange in any trading state.
    if !base_delta.is_finite() || !price.is_finite() || price <= 0.0 {
        return Some(OrderDenied {
            reason: "下单量或价格不是有效数字，计算已出错".to_string(),
            by_policy: false,
        });
    }

    let reduces = reduces_exposure(base_delta, held_base);
    match limits.state {
        TradingState::Halted => {
            return Some(OrderDenied {
                reason: "交易已暂停，不接受任何新订单".to_string(),
                by_policy: true,
            })
        }
        TradingState::Reducing if !reduces => {
            return Some(OrderDenied {
                reason: "当前仅允许减仓".to_string(),
                by_policy: true,
            })
        }
        _ => {}
    }

    // Size limits are deliberately *not* applied to a reduction. Refusing to
    // close is how a protective limit turns into the thing it was meant to
    // prevent, and the exposure being closed was already permitted when it was
    // opened.
    if reduces {
        return None;
    }

    let notional = base_delta.abs() * price;
    if let Some(cap) = limits.max_order_notional {
        if notional > cap {
            return Some(OrderDenied {
                reason: format!(
                    "单笔名义 {notional:.2} 超过上限 {cap:.2}，已拒绝"),
                by_policy: false,
            });
        }
    }
    if let Some(pct) = limits.max_order_equity_pct {
        if equity > 0.0 && notional > equity * pct / 100.0 {
            return Some(OrderDenied {
                reason: format!(
                    "单笔名义 {notional:.2} 达到权益的 {:.0}%（上限 {pct:.0}%），\
                     这不像是正常的定仓结果，已拒绝",
                    notional / equity * 100.0
                ),
                by_policy: false,
            });
        }
    }
    None
}

/// Does this order move the position towards flat?
///
/// A delta that overshoots through zero into the opposite side does *not*
/// count: it closes one position and opens another, and the opening half
/// deserves the same scrutiny as any other entry.
pub fn reduces_exposure(base_delta: f64, held_base: f64) -> bool {
    if held_base == 0.0 {
        return false;
    }
    let opposing = (base_delta > 0.0) != (held_base > 0.0);
    opposing && base_delta.abs() <= held_base.abs() + 1e-12
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits() -> OrderLimits {
        OrderLimits {
            max_order_notional: Some(50_000.0),
            max_order_equity_pct: Some(200.0),
            state: TradingState::Active,
        }
    }

    #[test]
    fn an_ordinary_order_passes() {
        assert!(check_order(1.0, 0.0, 100.0, 10_000.0, &limits()).is_none());
    }

    #[test]
    fn a_nan_size_never_reaches_the_exchange() {
        // Not a big order — a broken calculation. Refused in every state.
        let denial = check_order(f64::NAN, 0.0, 100.0, 10_000.0, &limits()).unwrap();
        assert!(!denial.by_policy);
        let mut reducing = limits();
        reducing.state = TradingState::Reducing;
        assert!(check_order(f64::INFINITY, 5.0, 100.0, 10_000.0, &reducing).is_some());
    }

    #[test]
    fn an_absurd_notional_is_refused() {
        // The shape of a `riskPerTrade` sizing whose stop distance came back as
        // a rounding error.
        let denial = check_order(10_000.0, 0.0, 100.0, 10_000.0, &limits()).unwrap();
        assert!(denial.reason.contains("超过上限"));
    }

    #[test]
    fn the_equity_share_cap_scales_with_the_account() {
        let mut only_pct = limits();
        only_pct.max_order_notional = None;
        // 300 units at 100 = 30_000 notional against 10_000 equity = 300%.
        assert!(check_order(300.0, 0.0, 100.0, 10_000.0, &only_pct).is_some());
        // The same order against a larger account is within 200%.
        assert!(check_order(300.0, 0.0, 100.0, 100_000.0, &only_pct).is_none());
    }

    #[test]
    fn a_halted_engine_refuses_everything_as_policy() {
        let mut halted = limits();
        halted.state = TradingState::Halted;
        let denial = check_order(1.0, 0.0, 100.0, 10_000.0, &halted).unwrap();
        assert!(denial.by_policy, "paused is not the same as suspect");
    }

    #[test]
    fn reducing_lets_a_close_through_but_not_an_open() {
        let mut reducing = limits();
        reducing.state = TradingState::Reducing;
        // Closing 5 of a 5-long.
        assert!(check_order(-5.0, 5.0, 100.0, 10_000.0, &reducing).is_none());
        // Adding to it.
        assert!(check_order(1.0, 5.0, 100.0, 10_000.0, &reducing).is_some());
        // Flipping through zero is an entry wearing an exit's clothes.
        assert!(check_order(-9.0, 5.0, 100.0, 10_000.0, &reducing).is_some());
    }

    #[test]
    fn a_close_is_never_blocked_by_a_size_cap() {
        // Refusing to close is how a protective limit becomes the thing it was
        // meant to prevent. The exposure was already permitted when opened.
        let huge = check_order(-10_000.0, 10_000.0, 100.0, 10_000.0, &limits());
        assert!(huge.is_none());
    }

    #[test]
    fn the_default_cap_still_catches_a_runaway() {
        // Ten times the account: nothing legitimate produces this at the
        // leverage caps in use, and it is the signature of a sizing bug.
        let denial = check_order(2_000.0, 0.0, 100.0, 10_000.0, &OrderLimits::default());
        assert!(denial.is_some());
        // While a fully committed 3x position passes untouched.
        assert!(check_order(300.0, 0.0, 100.0, 10_000.0, &OrderLimits::default()).is_none());
    }

    #[test]
    fn reduction_is_direction_aware() {
        assert!(reduces_exposure(-1.0, 5.0));
        assert!(reduces_exposure(1.0, -5.0));
        assert!(!reduces_exposure(1.0, 5.0));
        assert!(!reduces_exposure(1.0, 0.0), "from flat, nothing is a reduction");
    }
}
