//! What a fill costs beyond its price.
//!
//! One rate on notional was enough while the only venue was a crypto exchange:
//! OKX takes a percentage of what was traded, on both sides, and nothing else.
//! A US stock broker takes nothing on the way in and two regulatory levies on
//! the way out — one a share of the sale value, one per share with a cap — and
//! an options broker charges per contract. Forcing those into a single
//! `feeBps` means either leaving them out (an optimistic backtest) or smearing
//! them into an invented percentage (a wrong one).
//!
//! So a cost model is a **list of components**, each with its own basis and
//! side. The percentage model is the one-component special case, and it still
//! reads and writes as `feeBps` so nobody has to spell out a list to say "ten
//! basis points".

use serde::{Deserialize, Serialize};

/// Which side of a trade a component is charged on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum FeeSide {
    #[default]
    Both,
    Buy,
    Sell,
}

/// The side of the order being priced. Opening a short is a *sale* — the
/// regulatory levies on a sale apply to it — so this is about what was sent to
/// the venue, not about the position it changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderSide {
    Buy,
    Sell,
}

impl FeeSide {
    pub fn applies(self, side: OrderSide) -> bool {
        match self {
            Self::Both => true,
            Self::Buy => side == OrderSide::Buy,
            Self::Sell => side == OrderSide::Sell,
        }
    }
}

/// What a component is proportional to.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(tag = "basis", rename_all = "lowercase")]
pub enum FeeBasis {
    /// Basis points of the traded notional. Negative is a rebate.
    Notional { bps: f64 },
    /// Quote currency per base unit traded — per share, per coin, per contract.
    Unit {
        #[serde(rename = "perUnit")]
        per_unit: f64,
    },
    /// Quote currency per order, whatever its size.
    Order {
        #[serde(rename = "perOrder")]
        per_order: f64,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FeeComponent {
    #[serde(flatten)]
    pub basis: FeeBasis,
    #[serde(default)]
    pub side: FeeSide,
    /// Floor on what one order pays for this component, in quote currency.
    #[serde(rename = "minPerOrder", default, skip_serializing_if = "Option::is_none")]
    pub min_per_order: Option<f64>,
    /// Ceiling on what one order pays for this component, in quote currency.
    /// A per-share levy with a cap is the common case.
    #[serde(rename = "maxPerOrder", default, skip_serializing_if = "Option::is_none")]
    pub max_per_order: Option<f64>,
    /// What this line is, for the report: "SEC §31", "FINRA TAF", "taker".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

impl FeeComponent {
    /// The classic exchange fee: a percentage of notional, both sides.
    pub fn flat_bps(bps: f64) -> Self {
        Self {
            basis: FeeBasis::Notional { bps },
            side: FeeSide::Both,
            min_per_order: None,
            max_per_order: None,
            label: None,
        }
    }

    /// Basis points when — and only when — this is the plain both-sides
    /// percentage component, so the manifest can keep writing `feeBps`.
    pub fn as_flat_bps(&self) -> Option<f64> {
        match (self.basis, self.side, self.min_per_order, self.max_per_order, &self.label) {
            (FeeBasis::Notional { bps }, FeeSide::Both, None, None, None) => Some(bps),
            _ => None,
        }
    }

    /// What one fill pays for this component. `units` and `notional` are both
    /// positive magnitudes.
    pub fn charge(&self, side: OrderSide, units: f64, notional: f64) -> f64 {
        if !self.side.applies(side) {
            return 0.0;
        }
        let raw = match self.basis {
            FeeBasis::Notional { bps } => notional * bps / 10_000.0,
            FeeBasis::Unit { per_unit } => units * per_unit,
            FeeBasis::Order { per_order } => per_order,
        };
        let floored = match self.min_per_order {
            Some(min) => raw.max(min),
            None => raw,
        };
        match self.max_per_order {
            Some(max) => floored.min(max),
            None => floored,
        }
    }
}

/// What one fill pays under the whole model.
pub fn total_fee(components: &[FeeComponent], side: OrderSide, units: f64, notional: f64) -> f64 {
    components
        .iter()
        .map(|component| component.charge(side, units, notional))
        .sum()
}

/// A model expressed as a single both-sides percentage, when it is one.
pub fn as_flat_bps(components: &[FeeComponent]) -> Option<f64> {
    match components {
        [single] => single.as_flat_bps(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sec_fee() -> FeeComponent {
        FeeComponent {
            basis: FeeBasis::Notional { bps: 0.278 },
            side: FeeSide::Sell,
            min_per_order: None,
            max_per_order: None,
            label: Some("SEC §31".into()),
        }
    }

    fn taf() -> FeeComponent {
        FeeComponent {
            basis: FeeBasis::Unit { per_unit: 0.000_166 },
            side: FeeSide::Sell,
            min_per_order: None,
            max_per_order: Some(8.30),
            label: Some("FINRA TAF".into()),
        }
    }

    #[test]
    fn a_percentage_component_charges_both_sides() {
        let taker = FeeComponent::flat_bps(10.0);
        assert!((taker.charge(OrderSide::Buy, 1.0, 10_000.0) - 10.0).abs() < 1e-12);
        assert!((taker.charge(OrderSide::Sell, 1.0, 10_000.0) - 10.0).abs() < 1e-12);
        assert_eq!(taker.as_flat_bps(), Some(10.0));
    }

    #[test]
    fn a_sell_side_levy_costs_nothing_on_a_buy() {
        assert_eq!(sec_fee().charge(OrderSide::Buy, 100.0, 10_000.0), 0.0);
        assert!((sec_fee().charge(OrderSide::Sell, 100.0, 10_000.0) - 0.278).abs() < 1e-12);
        assert_eq!(sec_fee().as_flat_bps(), None, "not the plain both-sides percentage");
    }

    #[test]
    fn a_per_unit_levy_is_capped_per_order() {
        // 10,000 shares × 0.000166 = 1.66, under the cap.
        assert!((taf().charge(OrderSide::Sell, 10_000.0, 1e6) - 1.66).abs() < 1e-9);
        // 100,000 shares would be 16.60; the cap holds it at 8.30.
        assert!((taf().charge(OrderSide::Sell, 100_000.0, 1e7) - 8.30).abs() < 1e-9);
    }

    #[test]
    fn a_minimum_lifts_a_tiny_order() {
        let per_share = FeeComponent {
            basis: FeeBasis::Unit { per_unit: 0.005 },
            side: FeeSide::Both,
            min_per_order: Some(1.0),
            max_per_order: None,
            label: None,
        };
        assert!((per_share.charge(OrderSide::Buy, 10.0, 1_000.0) - 1.0).abs() < 1e-12);
        assert!((per_share.charge(OrderSide::Buy, 1_000.0, 100_000.0) - 5.0).abs() < 1e-12);
    }

    #[test]
    fn a_rebate_is_a_negative_charge() {
        let maker = FeeComponent::flat_bps(-2.0);
        assert!((maker.charge(OrderSide::Sell, 1.0, 10_000.0) + 2.0).abs() < 1e-12);
    }

    #[test]
    fn the_total_is_the_sum_of_what_applies() {
        let model = vec![
            FeeComponent {
                basis: FeeBasis::Order { per_order: 0.0 },
                side: FeeSide::Both,
                min_per_order: None,
                max_per_order: None,
                label: Some("commission".into()),
            },
            sec_fee(),
            taf(),
        ];
        assert_eq!(total_fee(&model, OrderSide::Buy, 100.0, 10_000.0), 0.0);
        let sell = total_fee(&model, OrderSide::Sell, 100.0, 10_000.0);
        assert!((sell - (0.278 + 0.0166)).abs() < 1e-9, "{sell}");
        assert_eq!(as_flat_bps(&model), None);
        assert_eq!(as_flat_bps(&[FeeComponent::flat_bps(5.0)]), Some(5.0));
    }

    #[test]
    fn components_round_trip_through_json_with_their_basis_tag() {
        let model = vec![FeeComponent::flat_bps(10.0), sec_fee(), taf()];
        let json = serde_json::to_string(&model).unwrap();
        assert!(json.contains("\"basis\":\"notional\""), "{json}");
        assert!(json.contains("\"perUnit\":0.000166"), "{json}");
        assert!(json.contains("\"maxPerOrder\":8.3"), "{json}");
        let back: Vec<FeeComponent> = serde_json::from_str(&json).unwrap();
        assert_eq!(back, model);
    }

    #[test]
    fn a_component_without_a_side_is_charged_both_ways() {
        let parsed: FeeComponent =
            serde_json::from_str(r#"{"basis":"notional","bps":3}"#).unwrap();
        assert_eq!(parsed.side, FeeSide::Both);
        assert_eq!(parsed.as_flat_bps(), Some(3.0));
    }
}
