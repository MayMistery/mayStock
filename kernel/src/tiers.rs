//! A venue's position tiers: how much maintenance a position owes, and how big
//! it may grow, by its size.
//!
//! OKX states both per instrument (`/api/v5/public/position-tiers`), and
//! measured on the demo account (2026-10-09) it applies them like this:
//!
//! - a position's tier is the first whose size limit holds it, and its
//!   maintenance is that tier's rate on the **whole** position — 2 600
//!   SOL-USDT-SWAP contracts, in the second tier, owed 0.75% of all 287 295
//!   USDT, not 0.5% of the first 2 500 and 0.75% of the rest;
//! - a position may hold no more than the last tier, counted from the first,
//!   that allows its leverage: at 50× `max-size` stops at the first tier's
//!   limit on every instrument read (DOGE 1 500, TRX 300, XRP and SOL 2 500
//!   contracts), at 40× SOL's at the second's (10 000);
//! - an order past that limit is refused (51004), never shrunk.
//!
//! The venue counts in contracts; a caller converts to base units, the
//! kernel's own, before handing a table over.

use serde::{Deserialize, Serialize};

/// One rung: positions up to `max_base` base units owe
/// `maintenance_margin_rate` of their value and may be levered up to
/// `max_leverage`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PositionTier {
    pub max_base: f64,
    pub maintenance_margin_rate: f64,
    pub max_leverage: f64,
}

/// A whole table, smallest positions first, checked once.
#[derive(Debug, Clone, PartialEq)]
pub struct PositionTiers {
    tiers: Vec<PositionTier>,
}

impl PositionTiers {
    /// The table as a venue states it, or why it cannot be one: empty, sizes
    /// that do not rise, a rate that is not a share of the value, a leverage
    /// below one.
    pub fn new(tiers: Vec<PositionTier>) -> Result<Self, String> {
        if tiers.is_empty() {
            return Err("档位表是空的".into());
        }
        let mut below = 0.0;
        for (index, tier) in tiers.iter().enumerate() {
            let rung = index + 1;
            if !(tier.max_base.is_finite() && tier.max_base > below) {
                return Err(format!("第 {rung} 档的持仓上限 {} 没有比上一档大", tier.max_base));
            }
            if !(0.0..1.0).contains(&tier.maintenance_margin_rate) {
                return Err(format!("第 {rung} 档的维持保证金率 {} 不在 0 到 1 之间", tier.maintenance_margin_rate));
            }
            if !(tier.max_leverage.is_finite() && tier.max_leverage >= 1.0) {
                return Err(format!("第 {rung} 档的最高杠杆 {} 小于 1", tier.max_leverage));
            }
            below = tier.max_base;
        }
        Ok(Self { tiers })
    }

    /// The maintenance rate a position of `base` units owes on its whole
    /// value: its tier's. Past the last tier — a position the venue would not
    /// have let grow so far — the last tier's.
    pub fn maintenance_rate(&self, base: f64) -> f64 {
        self.tiers
            .iter()
            .find(|tier| base.abs() <= tier.max_base)
            .unwrap_or(&self.tiers[self.tiers.len() - 1])
            .maintenance_margin_rate
    }

    /// The most a position may hold at `leverage`: the limit of the last tier,
    /// counted from the first, that allows it. `None` when not even the first
    /// does — the venue will not set that leverage at all.
    pub fn max_base(&self, leverage: f64) -> Option<f64> {
        self.tiers
            .iter()
            .take_while(|tier| tier.max_leverage >= leverage - 1e-9)
            .last()
            .map(|tier| tier.max_base)
    }

    /// The highest leverage the table allows any position.
    pub fn max_leverage(&self) -> f64 {
        self.tiers[0].max_leverage
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    fn tier(max_base: f64, maintenance_margin_rate: f64, max_leverage: f64) -> PositionTier {
        PositionTier { max_base, maintenance_margin_rate, max_leverage }
    }

    /// SOL-USDT-SWAP's isolated tiers on the demo account, 2026-10-09 (one
    /// contract is one SOL).
    pub(crate) fn sol_demo() -> PositionTiers {
        PositionTiers::new(vec![tier(2_500.0, 0.005, 50.0), tier(10_000.0, 0.0075, 40.0), tier(20_000.0, 0.01, 33.33)])
            .unwrap()
    }

    #[test]
    fn a_position_owes_its_tiers_rate_on_all_of_it() {
        let tiers = sol_demo();
        assert_eq!(tiers.maintenance_rate(1.0), 0.005);
        assert_eq!(tiers.maintenance_rate(2_500.0), 0.005);
        assert_eq!(tiers.maintenance_rate(2_600.0), 0.0075);
        assert_eq!(tiers.maintenance_rate(-2_600.0), 0.0075, "a short is sized by its magnitude");
        assert_eq!(tiers.maintenance_rate(50_000.0), 0.01, "past the table, the last tier");
    }

    /// What OKX's `max-size` read at each leverage on 2026-10-09.
    #[test]
    fn a_position_may_hold_the_last_tier_that_allows_its_leverage() {
        let tiers = sol_demo();
        assert_eq!(tiers.max_base(50.0), Some(2_500.0));
        assert_eq!(tiers.max_base(41.0), Some(2_500.0));
        assert_eq!(tiers.max_base(40.0), Some(10_000.0));
        assert_eq!(tiers.max_base(3.0), Some(20_000.0));
        assert_eq!(tiers.max_base(51.0), None, "no tier allows it");
        assert_eq!(tiers.max_leverage(), 50.0);
    }

    #[test]
    fn a_table_that_is_not_one_is_refused() {
        assert!(PositionTiers::new(vec![]).is_err());
        assert!(PositionTiers::new(vec![tier(10.0, 0.01, 20.0), tier(10.0, 0.02, 10.0)]).is_err(), "sizes must rise");
        assert!(PositionTiers::new(vec![tier(10.0, 1.0, 20.0)]).is_err(), "a rate of the whole value");
        assert!(PositionTiers::new(vec![tier(10.0, f64::NAN, 20.0)]).is_err());
        assert!(PositionTiers::new(vec![tier(10.0, 0.01, 0.5)]).is_err());
        assert!(PositionTiers::new(vec![tier(f64::INFINITY, 0.01, 5.0)]).is_err());
    }
}
