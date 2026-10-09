//! A contract's terms, and the money a holding is worth at a price.
//!
//! One rule, two callers: the close ticket prices a close at a level of the
//! book, and the live account (`live::state`) re-marks every position the
//! account holds at the mark the moment it streams. Both ask the same
//! question — "what is this holding worth at that price" — so there is one
//! answer, and the profit the ticket estimates for closing at the mark is
//! exactly the profit the account shows as floating there.
//!
//! The arithmetic is OKX's own, checked against its fields on the live
//! account (2026-10-08, ETH-USDT-SWAP long 214.97 contracts at
//! 2558.0145621063…): at the mark 2535.78 the linear rule gives −477.976, and
//! the venue's `upl` read −477.97638159930744; at the last trade 2535.76 it
//! gives −478.406 against `uplLastPx` −478.40632159930703.

use serde::{Deserialize, Serialize};

use super::wire::Family;
use crate::live::book::{Px, Spec};

/// From this price up, prices move in steps of `tick`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct TickBand {
    pub from: f64,
    pub tick: f64,
}

/// The step that applies at `price`: the band with the highest start at or
/// below it; `fallback` when there are no bands.
pub fn tick_at(bands: &[TickBand], price: f64, fallback: f64) -> f64 {
    bands.iter().filter(|b| b.from <= price + 1e-12).max_by(|a, b| a.from.total_cmp(&b.from)).map_or(fallback, |b| b.tick)
}

/// Contract terms as numbers.
#[derive(Debug, Clone, PartialEq)]
pub struct Terms {
    /// The step at every price, or — where `tick_bands` is not empty — the
    /// step of the first band.
    pub tick: f64,
    /// Where the step changes with the price; empty when `tick` holds
    /// throughout.
    pub tick_bands: Vec<TickBand>,
    pub lot: f64,
    pub min: f64,
    pub price_decimals: usize,
    /// Base units per contract (`ctVal × ctMult`); 1 for spot and shares.
    pub contract_value: f64,
    /// `linear` or `inverse`; empty for spot.
    pub ct_type: String,
    pub ct_val_ccy: String,
    pub settle_ccy: String,
    pub quote_ccy: String,
    pub inst_type: String,
}

fn decimals(text: &str) -> usize {
    text.split_once('.').map(|(_, f)| f.trim_end_matches('0').len()).unwrap_or(0)
}

fn positive(text: &str, what: &str) -> Result<f64, String> {
    let value = Px::parse(text).map(Px::as_f64).filter(|v| *v > 0.0);
    value.ok_or_else(|| format!("合约规格的 {what} 不合法：{text:?}"))
}

impl Terms {
    pub fn read(spec: &Spec) -> Result<Terms, String> {
        let ct_val = Px::parse(&spec.ct_val).map(Px::as_f64).filter(|v| *v > 0.0);
        let ct_mult = Px::parse(&spec.ct_mult).map(Px::as_f64).filter(|v| *v > 0.0).unwrap_or(1.0);
        let mut tick_bands = Vec::with_capacity(spec.tick_bands.len());
        for band in &spec.tick_bands {
            let from = Px::parse(&band.from).map(Px::as_f64).filter(|v| *v >= 0.0);
            let from = from.ok_or_else(|| format!("合约规格的价位分段起点不合法：{:?}", band.from))?;
            tick_bands.push(TickBand { from, tick: positive(&band.tick_sz, "tickBands.tickSz")? });
        }
        tick_bands.sort_by(|a, b| a.from.total_cmp(&b.from));
        let price_decimals = spec.tick_bands.iter().map(|b| decimals(&b.tick_sz)).chain([decimals(&spec.tick_sz)]).max().unwrap_or(0);
        Ok(Terms {
            tick: positive(&spec.tick_sz, "tickSz")?,
            tick_bands,
            lot: positive(&spec.lot_sz, "lotSz")?,
            min: positive(&spec.min_sz, "minSz")?,
            price_decimals,
            contract_value: ct_val.map_or(1.0, |v| v * ct_mult),
            ct_type: spec.ct_type.clone(),
            ct_val_ccy: spec.ct_val_ccy.clone(),
            settle_ccy: spec.settle_ccy.clone(),
            quote_ccy: spec.quote_ccy.clone(),
            inst_type: spec.inst_type.clone(),
        })
    }

    /// The step a price of `price` has to keep to.
    pub fn tick_at(&self, price: f64) -> f64 {
        tick_at(&self.tick_bands, price, self.tick)
    }
}

/// An amount and the currency it is in.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Money {
    pub amount: f64,
    pub ccy: String,
    /// As it reads, written once by the close planner (`close::money_text`)
    /// for every screen; empty where nobody reads it as text.
    #[serde(default)]
    pub text: String,
}

impl Money {
    pub fn of(amount: f64, ccy: impl Into<String>) -> Money {
        Money { amount, ccy: ccy.into(), text: String::new() }
    }
}

/// The family a venue files a position under, as these rules read it. A
/// delivery future is margined and settled exactly like a perpetual, so it is
/// one; a margin position or anything unnamed has no rule here.
pub fn family_of_inst_type(inst_type: &str) -> Option<Family> {
    match inst_type {
        "SWAP" | "FUTURES" => Some(Family::Swap),
        "OPTION" => Some(Family::Option),
        "SPOT" => Some(Family::Spot),
        _ => None,
    }
}

/// Profit booked by closing `size` at `exit`, before fees — where the
/// arithmetic is exact: linear and inverse perpetuals from their terms,
/// options on their premium, shares. A coin balance has no cost here.
///
/// At the mark, this is the position's unrealised profit as the venue
/// computes it.
pub fn pnl(family: Family, is_long: bool, average: Option<f64>, terms: Option<&Terms>, size: f64, exit: f64) -> Option<Money> {
    let average = average.filter(|p| *p > 0.0)?;
    if !(exit > 0.0) {
        return None;
    }
    let direction = if is_long { 1.0 } else { -1.0 };
    match family {
        Family::Swap => {
            let terms = terms?;
            let amount = match terms.ct_type.as_str() {
                // Settled in the quote: the move times the base covered.
                "linear" => (exit - average) * size * terms.contract_value,
                // Settled in the coin: contracts are worth a fixed number of
                // dollars, and profit is the change in coins those buy.
                "inverse" => (1.0 / average - 1.0 / exit) * size * terms.contract_value,
                _ => return None,
            };
            Some(Money::of(amount * direction, terms.settle_ccy.clone())).filter(|m| !m.ccy.is_empty())
        }
        // Quoted in the settlement coin per unit of the underlying.
        Family::Option => {
            let terms = terms?;
            Some(Money::of((exit - average) * size * terms.contract_value * direction, terms.settle_ccy.clone()))
                .filter(|m| !m.ccy.is_empty())
        }
        Family::Stock => Some(Money::of((exit - average) * size * direction, "USD")),
        Family::Spot => None,
    }
}

/// The fee on `size` filled at `price`, in the currency it is charged in.
/// `selling` matters only to spot, where a sale is charged in the quote.
pub fn fee(family: Family, selling: bool, terms: Option<&Terms>, size: f64, price: f64, rate: f64) -> Option<Money> {
    let terms = terms?;
    if !(price > 0.0) {
        return None;
    }
    match family {
        Family::Swap => match terms.ct_type.as_str() {
            "linear" => Some(Money::of(rate * size * terms.contract_value * price, terms.settle_ccy.clone())),
            "inverse" => Some(Money::of(rate * size * terms.contract_value / price, terms.settle_ccy.clone())),
            _ => None,
        },
        // OKX charges an option the lesser of the rate on the underlying
        // covered and 12.5% of the premium.
        Family::Option => {
            let underlying = rate * size * terms.contract_value;
            let cap = 0.125 * price * size * terms.contract_value;
            Some(Money::of(underlying.min(cap), terms.settle_ccy.clone()))
        }
        // A sale is charged in what it receives: the quote.
        Family::Spot => (!terms.quote_ccy.is_empty() && selling).then(|| Money::of(rate * size * price, terms.quote_ccy.clone())),
        Family::Stock => None,
    }
    .filter(|m| !m.ccy.is_empty() && m.amount.is_finite())
}

/// What `size` at `price` is worth, in the currency it settles in.
pub fn value(family: Family, terms: Option<&Terms>, size: f64, price: f64) -> Option<Money> {
    if !(price > 0.0) {
        return None;
    }
    match family {
        Family::Swap => {
            let terms = terms?;
            match terms.ct_type.as_str() {
                "linear" => Some(Money::of(size * terms.contract_value * price, terms.settle_ccy.clone())),
                // A contract is a fixed number of dollars, whatever the price.
                "inverse" => Some(Money::of(size * terms.contract_value, terms.ct_val_ccy.clone())),
                _ => None,
            }
        }
        Family::Option => {
            let terms = terms?;
            Some(Money::of(size * terms.contract_value * price, terms.settle_ccy.clone()))
        }
        Family::Spot => {
            let terms = terms?;
            Some(Money::of(size * price, terms.quote_ccy.clone()))
        }
        Family::Stock => Some(Money::of(size * price, "USD")),
    }
    .filter(|m| !m.ccy.is_empty() && m.amount.is_finite())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn eth_swap() -> Terms {
        Terms::read(&Spec {
            inst_type: "SWAP".into(), tick_sz: "0.01".into(), lot_sz: "0.01".into(), min_sz: "0.01".into(),
            ct_val: "0.1".into(), ct_mult: "1".into(), ct_type: "linear".into(), ct_val_ccy: "ETH".into(),
            settle_ccy: "USDT".into(), ..Spec::default()
        })
        .unwrap()
    }

    /// The live account's own numbers, read from `account/positions` on
    /// 2026-10-08: the rule must reproduce the venue's `upl` and `uplLastPx`
    /// from the same average and prices to the venue's own precision.
    #[test]
    fn reproduces_the_venues_floating_profit_to_the_cent() {
        let terms = eth_swap();
        let average = Some(2558.0145621063081902);
        let at_mark = pnl(Family::Swap, true, average, Some(&terms), 214.97, 2535.78).unwrap();
        assert_eq!(at_mark.ccy, "USDT");
        assert!((at_mark.amount - -477.97638159930744).abs() < 1e-6, "{}", at_mark.amount);
        let at_last = pnl(Family::Swap, true, average, Some(&terms), 214.97, 2535.76).unwrap();
        assert!((at_last.amount - -478.40632159930703).abs() < 1e-6, "{}", at_last.amount);
        let short = pnl(Family::Swap, false, average, Some(&terms), 214.97, 2535.78).unwrap();
        assert!((short.amount - 477.97638159930744).abs() < 1e-6);
    }

    #[test]
    fn a_family_without_a_rule_has_no_number() {
        assert_eq!(family_of_inst_type("FUTURES"), Some(Family::Swap));
        assert_eq!(family_of_inst_type("MARGIN"), None);
        assert!(pnl(Family::Swap, true, Some(2500.0), None, 1.0, 2600.0).is_none());
        assert!(pnl(Family::Swap, true, None, Some(&eth_swap()), 1.0, 2600.0).is_none());
    }

    fn spec(inst_type: &str, ct_val: &str, ct_mult: &str, ct_type: &str, ct_val_ccy: &str, settle: &str) -> Terms {
        Terms::read(&Spec {
            inst_type: inst_type.into(), tick_sz: "0.0001".into(), lot_sz: "1".into(), min_sz: "1".into(),
            ct_val: ct_val.into(), ct_mult: ct_mult.into(), ct_type: ct_type.into(), ct_val_ccy: ct_val_ccy.into(),
            settle_ccy: settle.into(), ..Spec::default()
        })
        .unwrap()
    }

    #[test]
    fn inverse_and_option_arithmetic() {
        let terms = spec("SWAP", "100", "1", "inverse", "USD", "BTC");
        let profit = pnl(Family::Swap, true, Some(80_000.0), Some(&terms), 10.0, 84_000.0).unwrap();
        // 10 contracts of $100: $1,000, bought at 80k and sold at 84k.
        assert!((profit.amount - 1_000.0 * (1.0 / 80_000.0 - 1.0 / 84_000.0)).abs() < 1e-12 && profit.ccy == "BTC");
        let paid = fee(Family::Swap, true, Some(&terms), 10.0, 84_000.0, 0.0005).unwrap();
        assert!((paid.amount - 0.0005 * 1_000.0 / 84_000.0).abs() < 1e-15);

        let terms = spec("OPTION", "1", "0.1", "inverse", "ETH", "ETH");
        let profit = pnl(Family::Option, true, Some(0.05), Some(&terms), 5.0, 0.06).unwrap();
        assert!((profit.amount - 0.01 * 5.0 * 0.1).abs() < 1e-12 && profit.ccy == "ETH");
        // The fee is the lesser of the rate on 0.5 ETH covered and 12.5% of
        // the premium.
        let cheap = fee(Family::Option, true, Some(&terms), 5.0, 0.001, 0.0003).unwrap();
        assert!((cheap.amount - 0.125 * 0.001 * 0.5).abs() < 1e-15);
        let dear = fee(Family::Option, true, Some(&terms), 5.0, 0.06, 0.0003).unwrap();
        assert!((dear.amount - 0.0003 * 0.5).abs() < 1e-15);
    }
}
