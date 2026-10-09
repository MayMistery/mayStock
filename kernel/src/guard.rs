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
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct OrderLimits {
    /// Hard ceiling on one order's notional, in quote currency. `None` for no
    /// cap, which is only sensible in a backtest.
    #[serde(rename = "maxOrderNotional")]
    pub max_order_notional: Option<f64>,
    #[serde(default)]
    pub state: TradingState,
}

/// How far past what sizing can produce one order may go before it is called
/// a runaway: half as much again, room for a fill that moved against the
/// estimate and none for a broken calculation.
pub const RUNAWAY_MARGIN: f64 = 1.5;

/// The share of equity, in percent, past which one order is a runaway for a
/// strategy whose sizing reaches `max_multiple` × equity
/// (`CompiledStrategy::max_notional_multiple`). Scales with the account and
/// with the strategy: a single figure for every strategy was either too tight
/// for the leveraged ones — the old 1 000% refused every full-size order above
/// 10×, silently, in backtests and live alike — or too loose for the rest.
pub fn runaway_equity_pct(max_multiple: f64) -> f64 {
    max_multiple.max(1.0) * 100.0 * RUNAWAY_MARGIN
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
/// `base_delta` is signed in coins, `held_base` is the position it acts on,
/// `max_multiple` the most of its equity the strategy's sizing can put behind
/// one position (`CompiledStrategy::max_notional_multiple`).
pub fn check_order(
    base_delta: f64,
    held_base: f64,
    price: f64,
    equity: f64,
    max_multiple: f64,
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

    let opening = opening_base(base_delta, held_base);
    match limits.state {
        TradingState::Halted => {
            return Some(OrderDenied {
                reason: "交易已暂停，不接受任何新订单".to_string(),
                by_policy: true,
            })
        }
        TradingState::Reducing if opening > 0.0 => {
            return Some(OrderDenied {
                reason: "当前仅允许减仓".to_string(),
                by_policy: true,
            })
        }
        _ => {}
    }

    // Size limits judge the exposure an order *adds*, never what it closes.
    // Refusing to close is how a protective limit turns into the thing it was
    // meant to prevent, and the exposure being closed was already permitted
    // when it was opened. That holds for the closing half of a reversal too:
    // judged whole, a full-size reversal is twice its position, and every one
    // of them — at any leverage — read as a runaway and was refused, leaving
    // the position its signal had turned against.
    if opening == 0.0 {
        return None;
    }

    let notional = opening * price;
    if let Some(cap) = limits.max_order_notional {
        if notional > cap {
            return Some(OrderDenied {
                reason: format!(
                    "单笔名义 {notional:.2} 超过上限 {cap:.2}，已拒绝"),
                by_policy: false,
            });
        }
    }
    let pct = runaway_equity_pct(max_multiple);
    if equity > 0.0 && notional > equity * pct / 100.0 {
        return Some(OrderDenied {
            reason: format!(
                "单笔名义 {notional:.2} 达到权益的 {:.0}%（这个策略的定仓最多 {:.0}%，上限 {pct:.0}%），\
                 这不像是正常的定仓结果，已拒绝",
                notional / equity * 100.0,
                max_multiple.max(1.0) * 100.0
            ),
            by_policy: false,
        });
    }
    None
}

/// The part of an order that adds exposure, in coins: all of it from flat or
/// when adding to a position, the overshoot past flat when it reverses one,
/// nothing when it only reduces. A reversal closes one position and opens
/// another, and the opening half deserves the same scrutiny as any entry —
/// that half, not the whole.
pub fn opening_base(base_delta: f64, held_base: f64) -> f64 {
    if held_base == 0.0 || (base_delta > 0.0) == (held_base > 0.0) {
        return base_delta.abs();
    }
    let overshoot = base_delta.abs() - held_base.abs();
    if overshoot > 1e-12 { overshoot } else { 0.0 }
}

/// Does this order only move the position towards flat?
pub fn reduces_exposure(base_delta: f64, held_base: f64) -> bool {
    held_base != 0.0 && base_delta != 0.0 && opening_base(base_delta, held_base) == 0.0
}

/// What an order may actually send.
#[derive(Debug, Clone, PartialEq)]
pub struct Admission {
    /// Coins to send, signed: the order as asked, the close alone, or zero.
    pub base_delta: f64,
    /// Why the order — or, when the close alone goes, its opening half — was
    /// refused.
    pub denied: Option<OrderDenied>,
}

/// The whole order when the guard allows it. When it reverses a position and
/// the whole is refused — its opening half too large, or the book only
/// reducing — the close alone, which every state but a halt allows: a refusal
/// must never keep a position its signal has turned against
/// (`TradingState::Reducing` exists so that closing stays available).
/// Nothing at all only when even the close is refused.
///
/// The live decision and the backtest both send what this admits, so a
/// refused reversal is the same flat position in both.
pub fn admit(
    base_delta: f64,
    held_base: f64,
    price: f64,
    equity: f64,
    max_multiple: f64,
    limits: &OrderLimits,
) -> Admission {
    let Some(denied) = check_order(base_delta, held_base, price, equity, max_multiple, limits) else {
        return Admission { base_delta, denied: None };
    };
    let reverses = held_base != 0.0
        && (base_delta > 0.0) != (held_base > 0.0)
        && opening_base(base_delta, held_base) > 0.0;
    if reverses && check_order(-held_base, held_base, price, equity, max_multiple, limits).is_none() {
        return Admission { base_delta: -held_base, denied: Some(denied) };
    }
    Admission { base_delta: 0.0, denied: Some(denied) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::strategy::InstrumentType;

    fn limits() -> OrderLimits {
        OrderLimits { max_order_notional: Some(50_000.0), state: TradingState::Active }
    }

    #[test]
    fn an_ordinary_order_passes() {
        assert!(check_order(1.0, 0.0, 100.0, 10_000.0, 1.0, &limits()).is_none());
    }

    #[test]
    fn a_nan_size_never_reaches_the_exchange() {
        // Not a big order — a broken calculation. Refused in every state.
        let denial = check_order(f64::NAN, 0.0, 100.0, 10_000.0, 1.0, &limits()).unwrap();
        assert!(!denial.by_policy);
        let mut reducing = limits();
        reducing.state = TradingState::Reducing;
        assert!(check_order(f64::INFINITY, 5.0, 100.0, 10_000.0, 1.0, &reducing).is_some());
    }

    #[test]
    fn an_absurd_notional_is_refused() {
        // The shape of a `riskPerTrade` sizing whose stop distance came back as
        // a rounding error.
        let denial = check_order(10_000.0, 0.0, 100.0, 10_000.0, 1.0, &limits()).unwrap();
        assert!(denial.reason.contains("超过上限"));
    }

    /// Walks every instrument family at every leverage it allows: a full-size
    /// order at that leverage passes, and one twice past it is refused. The
    /// old single 1 000% refused every full-size order above 10×.
    #[test]
    fn the_runaway_cap_follows_the_strategy_at_every_leverage_the_families_allow() {
        let equity = 10_000.0;
        let price = 100.0;
        let open = OrderLimits::default();
        for family in InstrumentType::ALL {
            let mut leverage = 1.0;
            while leverage <= family.max_leverage() + 1e-9 {
                let full = equity * leverage / price;
                assert!(check_order(full, 0.0, price, equity, leverage, &open).is_none(),
                        "{family:?} at {leverage}x: a full-size order is what sizing produces");
                assert!(check_order(full * 2.0, 0.0, price, equity, leverage, &open).is_some(),
                        "{family:?} at {leverage}x: twice that is a runaway");
                leverage += 1.0;
            }
        }
    }

    #[test]
    fn the_runaway_cap_scales_with_the_account() {
        let open = OrderLimits::default();
        // 300 units at 100 = 30_000 notional: 300% of 10_000, past 150% at 1x.
        assert!(check_order(300.0, 0.0, 100.0, 10_000.0, 1.0, &open).is_some());
        // The same order against a larger account is 30%.
        assert!(check_order(300.0, 0.0, 100.0, 100_000.0, 1.0, &open).is_none());
    }

    #[test]
    fn a_halted_engine_refuses_everything_as_policy() {
        let mut halted = limits();
        halted.state = TradingState::Halted;
        let denial = check_order(1.0, 0.0, 100.0, 10_000.0, 1.0, &halted).unwrap();
        assert!(denial.by_policy, "paused is not the same as suspect");
    }

    #[test]
    fn reducing_lets_a_close_through_but_not_an_open() {
        let mut reducing = limits();
        reducing.state = TradingState::Reducing;
        // Closing 5 of a 5-long.
        assert!(check_order(-5.0, 5.0, 100.0, 10_000.0, 1.0, &reducing).is_none());
        // Adding to it.
        assert!(check_order(1.0, 5.0, 100.0, 10_000.0, 1.0, &reducing).is_some());
        // Flipping through zero is an entry wearing an exit's clothes.
        assert!(check_order(-9.0, 5.0, 100.0, 10_000.0, 1.0, &reducing).is_some());
    }

    #[test]
    fn a_close_is_never_blocked_by_a_size_cap() {
        // Refusing to close is how a protective limit becomes the thing it was
        // meant to prevent. The exposure was already permitted when opened.
        let huge = check_order(-10_000.0, 10_000.0, 100.0, 10_000.0, 1.0, &limits());
        assert!(huge.is_none());
    }

    #[test]
    fn reduction_is_direction_aware() {
        assert!(reduces_exposure(-1.0, 5.0));
        assert!(reduces_exposure(1.0, -5.0));
        assert!(!reduces_exposure(1.0, 5.0));
        assert!(!reduces_exposure(1.0, 0.0), "from flat, nothing is a reduction");
        assert!(!reduces_exposure(-9.0, 5.0), "a reversal opens the other side");
    }

    #[test]
    fn the_opening_part_of_an_order_is_what_it_adds() {
        for (delta, held, opening) in [
            (3.0, 0.0, 3.0),    // from flat
            (-3.0, 0.0, 3.0),
            (2.0, 5.0, 2.0),    // adding
            (-2.0, 5.0, 0.0),   // trimming
            (-5.0, 5.0, 0.0),   // closing
            (-9.0, 5.0, 4.0),   // reversing: the overshoot
            (9.0, -5.0, 4.0),
        ] {
            assert!((opening_base(delta, held) - opening).abs() < 1e-12, "{delta} on {held}");
        }
    }

    /// Walks every instrument that can be reversed, at every whole leverage it
    /// allows: a full-size reversal — twice the position in one order — must
    /// pass, because what it opens is one full-size position. Judged whole it
    /// read as a runaway at every leverage, and live the reversal (close
    /// included) was refused.
    #[test]
    fn a_full_size_reversal_passes_at_every_leverage() {
        let equity = 10_000.0;
        let price = 100.0;
        for inst_type in InstrumentType::ALL.into_iter().filter(|t| t.allows_short() && !t.is_option()) {
            let mut leverage = 1.0;
            while leverage <= inst_type.max_leverage() {
                let held = equity * leverage / price;
                let denied = check_order(-2.0 * held, held, price, equity, leverage, &OrderLimits::default());
                assert!(denied.is_none(), "{inst_type:?} {leverage}x: {denied:?}");
                leverage += 1.0;
            }
        }
    }

    /// A reversal refused whole still closes: its opening half too large for
    /// the per-order cap, or the book only reducing. Only a halt sends nothing.
    #[test]
    fn a_refused_reversal_still_closes() {
        let capped = OrderLimits { max_order_notional: Some(300.0), state: TradingState::Active };
        let reducing = OrderLimits { max_order_notional: None, state: TradingState::Reducing };
        for limits in [capped, reducing] {
            let admitted = admit(-9.0, 5.0, 100.0, 10_000.0, 1.0, &limits);
            assert_eq!(admitted.base_delta, -5.0, "{limits:?}");
            assert!(admitted.denied.is_some(), "the refused half is reported");
        }
        let halted = OrderLimits { max_order_notional: None, state: TradingState::Halted };
        assert_eq!(admit(-9.0, 5.0, 100.0, 10_000.0, 1.0, &halted).base_delta, 0.0);
        // An entry refused outright sends nothing; one allowed goes whole.
        assert_eq!(admit(9.0, 0.0, 100.0, 10_000.0, 1.0, &capped).base_delta, 0.0);
        assert_eq!(admit(2.0, 0.0, 100.0, 10_000.0, 1.0, &capped), Admission { base_delta: 2.0, denied: None });
    }
}
