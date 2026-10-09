//! When a position that is lent against is closed out, and what that takes.
//!
//! Both engines ask one `Lender`, so each question has one answer.
//!
//! **When.** A lender closes a position once the equity it counts no longer
//! covers what it requires the position to keep. Both sides of that are the
//! venue's own, and neither is mirrored from a long to a short:
//!
//! - **Isolated margin** (a perpetual on OKX) counts the margin posted at the
//!   entry, less the funding settled out of it, plus the unrealised P&L. It
//!   requires the maintenance rate of the position's *current* value, plus the
//!   fee a close would pay there. For a long that is a price ratio of
//!   `(1 − 1/L) / (1 − mmr − fee)`, for a short `(1 + 1/L) / (1 + mmr + fee)`.
//!   Measured on the OKX demo account 2026-10-09 — ETH-USDT-SWAP and
//!   SOL-USDT-SWAP, tier-one maintenance 0.4% and 0.5%, VIP1 taker 0.045%,
//!   1× to 100×, both legs, 30 positions — OKX's `liqPx` is this level on every
//!   one, rounded one tick towards the entry. A backtest does not know the
//!   tick, which is a few millionths of the price.
//! - **Regulation T** counts the whole account — the capital the run has
//!   realised plus the position's unrealised P&L — since a broker lends against
//!   the account, not the position. It requires the house rate of the current
//!   value, and never less than FINRA's minimum (`finra_maintenance`).
//! - Nothing lent, nothing to close: a fully paid position has no level.
//!
//! The rule this replaced took the maintenance as a share of the margin,
//! `(1 − mmr) / L` either way: at 50× it liquidated a long 1.99% down where
//! OKX does at 1.56%, so a stop between the two filled as a stop — on a gap,
//! for more than the margin — where the exchange takes the margin. It mirrored
//! a long's Reg T call onto a short (+33% at 2×, where FINRA calls at +15%).
//! And it set no level below 2×, which only a long can do without: an
//! isolated 1× short rode a rally past +99% (OKX: 4 956.97 on a 2 489.52
//! entry) and a Reg T short any rally at all. Whether a level exists is the
//! arithmetic's answer, not the leverage's.
//!
//! **What.** `Lender::liquidation_fill`.

use std::cell::Cell;

use super::{closing_side, BacktestConfig, ExitFill};
use crate::decide::Direction;
use crate::expr::{ExprError, ExprResult};
use crate::strategy::{CompiledStrategy, Costs, MarginRegime};

/// FINRA Rule 4210(c), the least maintenance a broker may hold against a
/// position on Regulation T margin, per share at `price`: 25% of a long's
/// current value ((c)(1)); for a short, the greater of $5.00 a share and 30%
/// at $5.00 and above ((c)(3)), of $2.50 a share and 100% below ((c)(2)).
/// Read from the rule on finra.org, 2026-10-09. A short's pieces meet, so they
/// are one expression: $2.50 up to $2.50, the price up to $5.00, $5.00 up to
/// $16.67, 30% above.
pub(crate) fn finra_maintenance(direction: Direction, price: f64) -> f64 {
    match direction {
        Direction::Long => 0.25 * price,
        Direction::Short => 2.5_f64.max(price.min(5.0)).max(0.3 * price),
    }
}

/// A position as its lender sees it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Holding {
    pub direction: Direction,
    /// Base units held, a magnitude.
    pub quantity: f64,
    /// The average price it was entered at.
    pub basis: f64,
    /// Funding settled against it so far; positive when it paid.
    pub funding: f64,
    /// What the run has realised, its entry fees paid: the account a
    /// Regulation T loan is made against.
    pub capital: f64,
}

/// Who lends against a run's positions, on what terms: the instrument's margin
/// regime, the manifest's leverage, the maintenance rate held against them,
/// and what a closing fill pays. One per run, asked by both engines.
pub(crate) struct Lender<'a> {
    regime: MarginRegime,
    leverage: f64,
    maintenance: f64,
    costs: &'a Costs,
    /// The last level worked out and the position it was worked out for. A
    /// level moves only when the position does — a fill, a funding
    /// settlement — and the engines ask on every bar.
    last: Cell<Option<(Holding, Option<f64>)>>,
}

/// How many times the search for a bracket doubles its far end. Past this a
/// position is out of reach of any price a market will print.
const DOUBLINGS: usize = 64;

impl<'a> Lender<'a> {
    pub(crate) fn new(regime: MarginRegime, leverage: f64, maintenance: f64, costs: &'a Costs) -> Self {
        Self { regime, leverage: leverage.max(1.0), maintenance, costs, last: Cell::new(None) }
    }

    /// The lender of one run. The maintenance rate is the caller's, else the
    /// instrument's documented default (`InstrumentType::default_maintenance_margin_rate`),
    /// else none beyond the regime's own floor; one that is not a share of the
    /// position's value — negative, NaN, or 100% and more, which no position
    /// could ever meet — is refused rather than simulated.
    pub(crate) fn for_run(strategy: &CompiledStrategy, config: &BacktestConfig, costs: &'a Costs) -> ExprResult<Self> {
        let inst_type = strategy.manifest.market.inst_type;
        let maintenance = config
            .maintenance_margin_rate
            .or_else(|| inst_type.default_maintenance_margin_rate())
            .unwrap_or(0.0);
        if !(0.0..1.0).contains(&maintenance) {
            return Err(ExprError::Policy(format!(
                "维持保证金率 {maintenance} 不是仓位价值的一个比例（应在 0 到 1 之间，不含 1）"
            )));
        }
        Ok(Self::new(inst_type.margin_regime(), strategy.leverage(), maintenance, costs))
    }

    /// The margin posted against an isolated position: its value at the price
    /// it was entered at, over the leverage.
    fn margin(&self, held: &Holding) -> f64 {
        held.quantity * held.basis / self.leverage
    }

    /// The equity the lender counts at `price`.
    fn equity(&self, held: &Holding, price: f64) -> f64 {
        let moved = held.direction.sign() * (price - held.basis) * held.quantity - held.funding;
        match self.regime {
            MarginRegime::Isolated => self.margin(held) + moved,
            MarginRegime::RegT | MarginRegime::None => held.capital + moved,
        }
    }

    /// What the lender requires the position to keep at `price`.
    fn requirement(&self, held: &Holding, price: f64) -> f64 {
        let value = held.quantity * price;
        match self.regime {
            MarginRegime::Isolated => {
                self.maintenance * value + self.costs.fee(closing_side(held.direction), held.quantity, value)
            }
            MarginRegime::RegT => {
                held.quantity * (self.maintenance * price).max(finra_maintenance(held.direction, price))
            }
            MarginRegime::None => 0.0,
        }
    }

    /// The price at which `held` is closed out — at and below it for a long,
    /// at and above it for a short — or `None` where no price can: nothing is
    /// lent, or a long is covered all the way down to zero, as a fully paid
    /// one is. A position already short of its requirement at its entry has
    /// its level past the entry, and one short of it at every price is closed
    /// on the first bar: a long's level is then infinite, a short's zero.
    pub(crate) fn liquidation_level(&self, held: &Holding) -> Option<f64> {
        if let Some((seen, level)) = self.last.get() {
            if seen == *held {
                return level;
            }
        }
        let level = self.solve(held);
        self.last.set(Some((*held, level)));
        level
    }

    fn solve(&self, held: &Holding) -> Option<f64> {
        if self.regime == MarginRegime::None || !(held.quantity > 0.0) || !(held.basis > 0.0) {
            return None;
        }
        // Not negative where the position is closed out. Equity moves with
        // the price at the position's size and the requirement at a share of
        // it, so this crosses zero once.
        let shortfall = |price: f64| self.requirement(held, price) - self.equity(held, price);
        match held.direction {
            Direction::Long => {
                if shortfall(0.0) < 0.0 {
                    return None;
                }
                let mut outside = held.basis;
                for _ in 0..DOUBLINGS {
                    if shortfall(outside) < 0.0 {
                        let level = boundary(0.0, outside, shortfall);
                        return (level > 0.0).then_some(level);
                    }
                    outside *= 2.0;
                }
                Some(f64::INFINITY)
            }
            Direction::Short => {
                if shortfall(held.basis) >= 0.0 {
                    return Some(if shortfall(0.0) >= 0.0 { 0.0 } else { boundary(held.basis, 0.0, shortfall) });
                }
                let mut outside = held.basis;
                for _ in 0..DOUBLINGS {
                    let inside = outside * 2.0;
                    if shortfall(inside) >= 0.0 {
                        return Some(boundary(inside, outside, shortfall));
                    }
                    outside = inside;
                }
                None
            }
        }
    }

    /// How a liquidation fills, by margin regime.
    ///
    /// **Isolated margin** backs a position with `notional / leverage`, and a
    /// liquidation takes all of it — never more. The exchange closes at the
    /// bankruptcy price: where the move, the funding settled against the margin
    /// and an ordinary closing fee together use the margin up exactly; whatever
    /// the market did past that, a gap included, is the insurance fund's. This
    /// is OKX's own booking of a liquidated isolated 5× BTC short
    /// (positions-history, 2025-05): price P&L −614.60 at the close price,
    /// funding +14.12, and a fee of 1.81 on the close at the same ≈0.05% the
    /// opening fill paid — so the close realised −602.29, the margin (0.0324 BTC
    /// × 92 945.9 / 5) to the cent, and the trade −603.79 with its opening fee.
    /// The level that *triggers* a liquidation (`liquidation_level`) only
    /// decides when; this decides what.
    ///
    /// **Regulation T** has no such floor: the broker sells into the market, and
    /// a gap past the call is the customer's debt — an ordinary market close at
    /// the trigger, slippage and all. A fully paid position is never liquidated
    /// (it has no level).
    pub(crate) fn liquidation_fill(&self, held: &Holding, trigger: f64, slippage: f64) -> ExitFill {
        match self.regime {
            MarginRegime::Isolated => {
                let margin = self.margin(held);
                let side = closing_side(held.direction);
                // The fee depends on the price and the price on the fee, but the
                // fee moves only by its rate times the price change: a few rounds
                // settle it far below a cent. The books balance exactly whatever
                // the round count — the price is always solved from the fee.
                let mut fill = ExitFill { price: trigger, fee: 0.0 };
                for _ in 0..4 {
                    let fee = self.costs.fee(side, held.quantity, held.quantity * fill.price);
                    // gross − fee − funding = −margin
                    let gross = fee + held.funding - margin;
                    fill = ExitFill { price: held.basis + gross / (held.direction.sign() * held.quantity), fee };
                }
                fill
            }
            MarginRegime::RegT | MarginRegime::None => {
                ExitFill::market(self.costs, held.direction, held.quantity, trigger, slippage)
            }
        }
    }
}

/// Where the position turns from closed out to covered, between `inside`,
/// where `shortfall` is not negative, and `outside`, where it is: the end on
/// the closed-out side, to within a millionth of a millionth of the price.
///
/// `shortfall` is a straight line between the bends of the fee schedule and
/// FINRA's per-share floors, so the bracket is narrowed by interpolating
/// along it — which lands on the answer once both ends lie on one piece — and
/// halved on alternate steps, so a bend costs no more than halving would: the
/// search `sizing::largest_within` makes, run towards a crossing.
fn boundary(mut inside: f64, mut outside: f64, shortfall: impl Fn(f64) -> f64) -> f64 {
    let (mut inside_shortfall, mut outside_shortfall) = (shortfall(inside), shortfall(outside));
    let mut interpolate = true;
    loop {
        if inside_shortfall == 0.0 || (inside - outside).abs() <= 1e-12 * inside.abs().max(outside.abs()) {
            return inside;
        }
        let along = inside + inside_shortfall / (inside_shortfall - outside_shortfall) * (outside - inside);
        let strictly_between = |price: f64| (price - inside) * (price - outside) < 0.0;
        let next = if interpolate && strictly_between(along) { along } else { 0.5 * (inside + outside) };
        interpolate = !interpolate;
        // Each pass leaves a price strictly between the ends, or stops.
        if !strictly_between(next) {
            return inside;
        }
        let next_shortfall = shortfall(next);
        if next_shortfall >= 0.0 {
            (inside, inside_shortfall) = (next, next_shortfall);
        } else {
            (outside, outside_shortfall) = (next, next_shortfall);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fees::{FeeBasis, FeeComponent, FeeSide};
    use crate::strategy::InstrumentType;

    fn held(direction: Direction, quantity: f64, basis: f64, funding: f64, capital: f64) -> Holding {
        Holding { direction, quantity, basis, funding, capital }
    }

    /// Every position measured on the OKX demo account, 2026-10-09: the
    /// instrument's tier-one maintenance rate, the leverage, the leg, the
    /// average entry and OKX's `liqPx`. VIP1 taker 0.045%; one contract each,
    /// margin exactly entry × size / leverage. The level is OKX's to a tick
    /// (0.01 on both), which OKX rounds towards the entry; a 1× long has none.
    #[test]
    fn the_isolated_level_is_where_okx_puts_it_on_every_position_measured() {
        let readings: [(f64, f64, Direction, f64, f64); 30] = {
            use Direction::{Long as L, Short as S};
            [
                (0.004, 1.0, L, 2489.08, 0.0), (0.004, 1.0, S, 2489.52, 4956.971432624819),
                (0.005, 1.0, L, 110.28, 0.0), (0.005, 1.0, S, 110.27, 219.33457208215228),
                (0.004, 2.0, L, 2488.98, 1250.0627346692781), (0.004, 2.0, S, 2489.07, 3717.0540649111454),
                (0.005, 2.0, L, 110.28, 55.45215977075058), (0.005, 2.0, S, 110.3, 164.54318514098165),
                (0.004, 3.0, L, 2489.39, 1667.0215346625816), (0.004, 3.0, S, 2489.27, 3304.3124318449563),
                (0.005, 3.0, L, 110.3, 73.94628609253766), (0.005, 3.0, S, 110.29, 146.2462368425415),
                (0.004, 5.0, L, 2489.4497, 2000.471815077093), (0.004, 5.0, S, 2489.1912, 2973.786047588232),
                (0.005, 5.0, L, 110.28, 88.71745563320096), (0.005, 5.0, S, 110.27, 131.59674324929136),
                (0.004, 10.0, L, 2489.32, 2250.412290191352), (0.004, 10.0, S, 2489.2, 2725.9793474040516),
                (0.005, 10.0, L, 110.24, 99.76969031220149), (0.005, 10.0, S, 110.23, 120.5857531453578),
                (0.004, 20.0, L, 2489.8808, 2375.969781025564), (0.004, 20.0, S, 2490.5508, 2603.4827970531132),
                (0.005, 20.0, L, 110.32, 105.38831179930621), (0.005, 20.0, S, 110.31, 115.1876726838729),
                (0.004, 50.0, L, 2490.16, 2451.2749289337553), (0.004, 50.0, S, 2490.0, 2528.537961571009),
                (0.005, 50.0, L, 110.28, 108.67663315067115), (0.005, 50.0, S, 110.27, 111.85573176189764),
                (0.004, 100.0, L, 2489.86, 2475.9895088142234), (0.004, 100.0, S, 2489.8, 2503.5471705908703),
            ]
        };
        let costs = Costs::flat(4.5, 0.0);
        for (mmr, leverage, direction, basis, okx) in readings {
            let lender = Lender::new(MarginRegime::Isolated, leverage, mmr, &costs);
            let level = lender.liquidation_level(&held(direction, 0.1, basis, 0.0, 0.0));
            let label = format!("{leverage}x {direction:?} at {basis}");
            if okx == 0.0 {
                assert_eq!(level, None, "{label}");
                continue;
            }
            let level = level.unwrap_or_else(|| panic!("{label}: no level, OKX {okx}"));
            assert!((level - okx).abs() <= 0.01 + 1e-9 * okx, "{label}: {level} vs OKX {okx}");
            // And the tick is towards the entry: OKX liquidates a hair sooner.
            assert!(direction.sign() * (okx - level) > 0.0, "{label}: {level} vs OKX {okx}");
        }
    }

    /// Cost models of every shape: a taker fee, a rebate, and a broker's
    /// floors, caps and per-order charge.
    fn cost_models() -> Vec<Costs> {
        let component = |basis, side, min_per_order, max_per_order| FeeComponent {
            basis, side, min_per_order, max_per_order, label: None,
        };
        vec![
            Costs::flat(5.0, 0.0),
            Costs::flat(-2.0, 0.0),
            Costs {
                fees: vec![
                    component(FeeBasis::Notional { bps: 0.278 }, FeeSide::Sell, None, None),
                    component(FeeBasis::Unit { per_unit: 0.005 }, FeeSide::Both, Some(1.0), None),
                    component(FeeBasis::Order { per_order: 0.65 }, FeeSide::Both, None, Some(2.0)),
                ],
                slippage_bps: 0.0,
            },
        ]
    }

    /// Walks every instrument type, at every whole leverage it allows, on
    /// every side it can take, under every cost model, at full and at half
    /// size, with funding paid, none, and received: where a level exists the
    /// lender's requirement meets the equity it counts there, falls short a
    /// hair on the closed-out side and is covered a hair on the other; where
    /// none exists the position is covered at every price down to zero, which
    /// only a fully paid long or one with nothing lent is.
    #[test]
    fn a_level_is_where_the_equity_meets_the_requirement_and_nowhere_else() {
        let mut walked = 0;
        let mut levels = 0;
        for family in InstrumentType::ALL {
            let maintenance = family.default_maintenance_margin_rate().unwrap_or(0.0);
            for costs in cost_models() {
                let mut leverage = 1.0;
                while leverage <= family.max_leverage() {
                    let lender = Lender::new(family.margin_regime(), leverage, maintenance, &costs);
                    let sides = if family.allows_short() { vec![Direction::Long, Direction::Short] } else { vec![Direction::Long] };
                    for direction in sides {
                        for size in [1.0, 0.5] {
                            for funding in [0.0, 30.0, -30.0] {
                                let (quantity, basis) = (40.0, 100.0);
                                // The capital behind a position of `size` of
                                // the full one at this leverage.
                                let capital = quantity * basis / leverage / size;
                                let position = held(direction, quantity, basis, funding, capital);
                                let label = format!("{family:?} {leverage}x {direction:?} size {size} funding {funding} {:?}", costs.fees);
                                let shortfall = |price: f64| lender.requirement(&position, price) - lender.equity(&position, price);
                                let sign = direction.sign();
                                match lender.liquidation_level(&position) {
                                    Some(level) => {
                                        assert_ne!(family.margin_regime(), MarginRegime::None, "{label}");
                                        assert!(level.is_finite() && level >= 0.0, "{label}: {level}");
                                        let hair = 1e-7 * basis;
                                        assert!(shortfall(level) >= 0.0, "{label}: covered at its own level {level}");
                                        assert!(shortfall(level + sign * hair) < 0.0, "{label}: short of it past {level}");
                                        if level - sign * hair > 0.0 {
                                            assert!(shortfall(level - sign * hair) >= 0.0, "{label}: covered beyond {level}");
                                        }
                                        levels += 1;
                                    }
                                    None => {
                                        let lends = family.margin_regime() != MarginRegime::None;
                                        if lends {
                                            assert_eq!(direction, Direction::Long, "{label}: a short is always lent against");
                                            for price in [basis * 1e-6, basis * 0.01, basis * 0.5, basis] {
                                                assert!(shortfall(price) < 0.0, "{label}: short of it at {price}");
                                            }
                                        }
                                    }
                                }
                                walked += 1;
                            }
                        }
                    }
                    leverage += 1.0;
                }
            }
        }
        assert!(walked > 1_000 && levels > 500, "walked {walked}, {levels} levels");
    }

    /// Only a long can be covered all the way down: a short is lent the very
    /// thing it sold. So at 1×, where the margin is the whole value, every
    /// regime that lends has a level for a short and none for a long — the
    /// leverage alone never decides it.
    #[test]
    fn at_one_times_a_short_lent_against_has_a_level_and_a_long_does_not() {
        let costs = Costs::flat(5.0, 0.0);
        let mut lending = 0;
        for family in InstrumentType::ALL {
            let lender = Lender::new(family.margin_regime(), 1.0, family.default_maintenance_margin_rate().unwrap_or(0.0), &costs);
            let long = lender.liquidation_level(&held(Direction::Long, 10.0, 100.0, 0.0, 1_000.0));
            let short = lender.liquidation_level(&held(Direction::Short, 10.0, 100.0, 0.0, 1_000.0));
            assert_eq!(long, None, "{family:?}");
            if family.margin_regime() == MarginRegime::None {
                assert_eq!(short, None, "{family:?}");
                continue;
            }
            assert!(family.allows_short(), "{family:?} is lent against but never short");
            let short = short.unwrap_or_else(|| panic!("{family:?}: a 1x short has no level"));
            assert!(short > 100.0 && short < 200.0, "{family:?}: {short}");
            lending += 1;
        }
        assert!(lending >= 2, "every lending regime walked: {lending}");
    }

    /// Funding is settled out of an isolated margin, so what a long has paid
    /// brings its level up by the payment over what a unit of price is worth
    /// to it, `Q (1 − mmr − fee)`, and what it received takes it down.
    #[test]
    fn funding_moves_an_isolated_level_by_what_it_settled() {
        let costs = Costs::flat(5.0, 0.0);
        let mut leverage = 1.0;
        while leverage <= InstrumentType::Swap.max_leverage() {
            let lender = Lender::new(MarginRegime::Isolated, leverage, 0.005, &costs);
            let level = |funding: f64| lender.liquidation_level(&held(Direction::Long, 2.0, 100.0, funding, 0.0));
            let paid = 0.5 * 2.0 * 100.0 / leverage;
            let moved = paid / (2.0 * (1.0 - 0.005 - 0.0005));
            match (level(0.0), level(paid), level(-paid)) {
                (None, Some(after), _) => assert!((after - moved).abs() < 1e-9, "{leverage}x: {after}"),
                (Some(before), Some(after), received) => {
                    assert!((after - before - moved).abs() < 1e-9, "{leverage}x: {before} → {after}");
                    let received = received.unwrap_or(0.0);
                    assert!((before - received - moved).abs() < 1e-9 || received == 0.0, "{leverage}x: {received}");
                }
                other => panic!("{leverage}x: {other:?}"),
            }
            leverage += 1.0;
        }
    }

    /// FINRA's numbers, worked by hand: a long at 2× on 25% is called at two
    /// thirds of its price; a short at 2× on 30% at 1.5 / 1.3 of it, at 1×
    /// at 2 / 1.3; a $10 short at 1× at $15, where the $5.00 a share binds; a
    /// $3 short at 1× at once, where 100% binds and it holds exactly 100%.
    /// The rule this replaced called the 2× short at +33% and the 1× short
    /// never.
    #[test]
    fn a_reg_t_call_is_finras_minimum_on_the_whole_account() {
        let costs = Costs::flat(0.0, 0.0);
        let at = |leverage: f64, direction: Direction, basis: f64, capital: f64| {
            Lender::new(MarginRegime::RegT, leverage, 0.0, &costs)
                .liquidation_level(&held(direction, 10.0, basis, 0.0, capital))
        };
        let close = |level: Option<f64>, expected: f64| level.is_some_and(|l| (l - expected).abs() < 1e-9 * expected);
        assert!(close(at(2.0, Direction::Long, 100.0, 500.0), 100.0 * 0.5 / 0.75));
        assert!(close(at(2.0, Direction::Short, 100.0, 500.0), 100.0 * 1.5 / 1.3));
        assert!(close(at(1.0, Direction::Short, 100.0, 1_000.0), 100.0 * 2.0 / 1.3));
        assert!(close(at(1.0, Direction::Short, 10.0, 100.0), 15.0));
        assert!(close(at(1.0, Direction::Short, 3.0, 30.0), 3.0));
        // The broker lends against the account: half the capital in a 2×
        // position borrows nothing, and nothing is called.
        assert_eq!(at(2.0, Direction::Long, 100.0, 1_000.0), None);
        // A house rate above FINRA's is the rate.
        let house = Lender::new(MarginRegime::RegT, 2.0, 0.4, &costs)
            .liquidation_level(&held(Direction::Long, 10.0, 100.0, 0.0, 500.0));
        assert!(close(house, 100.0 * 0.5 / 0.6));
    }

    #[test]
    fn finras_short_minimum_is_continuous_and_matches_the_rule_piece_by_piece() {
        for (price, expected) in [(1.0, 2.5), (2.5, 2.5), (4.0, 4.0), (5.0, 5.0), (10.0, 5.0), (50.0 / 3.0, 5.0), (20.0, 6.0)] {
            assert!((finra_maintenance(Direction::Short, price) - expected).abs() < 1e-12, "{price}");
        }
        assert_eq!(finra_maintenance(Direction::Long, 40.0), 10.0);
    }
}
