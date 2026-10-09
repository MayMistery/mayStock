//! How big a position should be, and where its protective stop sits.
//!
//! Extracted so the backtester and the live runner call *the same* function.
//! Before this module the backtester sized in Rust and the runner sized again
//! in Swift, and the two had already drifted: the Swift copy honoured only a
//! percentage stop, so a manifest using `riskPerTrade` with an ATR stop risked
//! 1% of capital per trade in simulation and committed the whole budget live.

use crate::decide::Direction;
use crate::fees::OrderSide;
use crate::strategy::{CompiledStrategy, Costs, MarginRegime, SizingMode};

// MARK: - What an order commits
//
// A position is paid for twice the moment an order opens it: the venue holds
// its margin, and the fill pays a fee. Both leave the capital at once, so both
// have to fit in it. Sizing used to fit the margin alone — at `equityPct: 100`
// the whole capital became margin and the fee came on top — and that was
// wrong everywhere it ran:
//
// - in a backtest an isolated liquidation takes exactly the margin
//   (`backtest::liquidation_fill`), so a full-size position liquidated left
//   the run at minus its opening fee, an equity no account can reach;
// - live, the exchange refuses the order. Measured on the OKX demo account
//   2026-10-09: refused with 51008 at 0.53 USDT over `availBal`, accepted at
//   0.35 under — never shrunk — with the opening fee reserved at the taker
//   rate and no closing fee reserved at all.
//
// So the rule: what an order leaves committed — the margin of the position
// after it and the fee the order pays — fits in the capital. It limits what an
// order adds, never what it keeps or closes; closing is always possible, the
// line `guard::check_order` holds too.

/// What an order is sized against: the capital behind it, marked at the
/// price the order fills at; the leverage and the regime the position is
/// margined under; what a fill costs; and the position it trades from —
/// signed, in base units, with its average entry price (0 when flat).
#[derive(Debug, Clone, Copy)]
pub struct Footing<'a> {
    pub costs: &'a Costs,
    /// What the strategy has realised, plus the held position's unrealised
    /// P&L at `price`.
    pub capital: f64,
    pub price: f64,
    pub leverage: f64,
    pub regime: MarginRegime,
    pub held_base: f64,
    pub held_basis: f64,
}

impl Footing<'_> {
    /// What holding `target_base` after the order commits: the margin the
    /// venue holds against all of it, and the fee the order pays to get there.
    /// Below 1× a position is simply paid for in full.
    ///
    /// Adding to an isolated position is paid for out of what the strategy has
    /// realised. Its margin is what was posted, at the prices it was bought
    /// at, and its unrealised profit is not cash — the venue lends nothing
    /// against it, and a liquidation takes the margin at the average price
    /// (`backtest::liquidation_fill`). Against capital marked to the price,
    /// that is the margin at the average entry plus the unrealised profit.
    /// Counted at the price instead, a scaled 10× position that added on a
    /// rally and was then liquidated ended a 10 000 backtest at −18 606
    /// (measured 2026-10-09). An unknown basis counts the whole held value as
    /// unrealised, so nothing is added on it. Everywhere else — opening from
    /// flat, a reversal, which realises the old side first, and the regimes
    /// whose lender counts the mark — the margin is the position at the price.
    pub fn committed(&self, target_base: f64) -> f64 {
        let traded = target_base - self.held_base;
        let fee = if traded == 0.0 {
            0.0
        } else {
            let side = if traded > 0.0 { OrderSide::Buy } else { OrderSide::Sell };
            self.costs.fee(side, traded.abs(), traded.abs() * self.price)
        };
        self.margin(target_base) + fee
    }

    /// The margin part of `committed`. It rises by `price / leverage` for
    /// every unit added, whichever way it is counted, and keeping an isolated
    /// position is counted the way adding to it is — the margin it posted and
    /// the profit that is not cash — so the two meet where adding begins.
    fn margin(&self, target_base: f64) -> f64 {
        let held = self.held_base;
        let leverage = self.leverage.max(1.0);
        let keeps_or_adds = held != 0.0 && (target_base > 0.0) == (held > 0.0) && target_base.abs() >= held.abs();
        if keeps_or_adds && self.regime == MarginRegime::Isolated {
            let unrealised = held * (self.price - self.held_basis);
            (held.abs() * self.held_basis + (target_base - held).abs() * self.price) / leverage + unrealised
        } else {
            target_base.abs() * self.price / leverage
        }
    }

    /// The position to hold after an order that asks for `wanted_base`: that,
    /// when the capital can commit to it, and otherwise the largest on the same
    /// side that it can. Never less than is already held on that side — the
    /// rule limits what an order adds — and flat when even the close of a
    /// reversal leaves nothing for the other side.
    pub fn affordable(&self, wanted_base: f64) -> f64 {
        let held = self.held_base;
        let same_side = held == 0.0 || (wanted_base > 0.0) == (held > 0.0);
        if wanted_base == 0.0 || (same_side && wanted_base.abs() <= held.abs()) {
            return wanted_base;
        }
        let keeps = if same_side { held.abs() } else { 0.0 };
        let sign = wanted_base.signum();
        if !(self.price > 0.0) {
            return sign * keeps;
        }
        // The margin alone bounds it: past what is kept it rises by the price
        // over the leverage per unit, so where it alone uses the capital up is
        // as far as the search need go.
        let room = (self.capital - self.margin(sign * keeps)).max(0.0);
        let bound = wanted_base.abs().min(keeps + room * self.leverage.max(1.0) / self.price);
        sign * largest_within(self.capital, keeps, bound.max(keeps), |size| self.committed(sign * size))
    }

    /// A scaled position: `exposure` of the capital at the leverage, signed,
    /// in base units — as much of it as the capital can commit to.
    pub fn exposure_target(&self, exposure: f64) -> f64 {
        self.affordable(exposure_base(exposure, self.capital, self.price, self.leverage))
    }
}

/// The position `exposure` of `capital` at `leverage` is, signed, in base
/// units at `price` — before any ceiling.
pub fn exposure_base(exposure: f64, capital: f64, price: f64, leverage: f64) -> f64 {
    if capital > 0.0 && price > 0.0 { capital * exposure * leverage / price } else { 0.0 }
}

/// The exposure `base` is, on the scale `exposure_base` sizes on: its notional
/// over the capital at the leverage. The backtest and the live runner measure
/// a rebalance's drift with this, so a threshold means the same in both — the
/// backtest used to leave the leverage out, saw a position on its target as
/// `leverage` times off it, and rebalanced it on every bar.
pub fn exposure_of(base: f64, capital: f64, price: f64, leverage: f64) -> f64 {
    if capital > 0.0 && leverage > 0.0 { base * price / (capital * leverage) } else { 0.0 }
}

/// The largest `size` in `keeps..=bound` whose `cost` fits in `budget` —
/// `keeps` when even that does not.
///
/// `cost` is what an order of that size commits. It rises with the size, in a
/// straight line between the floors, caps and per-order charges of the fee
/// components (`FeeComponent::charge`). So the bracket is narrowed by
/// interpolating along it — which lands on the answer once both ends lie on
/// its line: at once, under a plain percentage fee — and halved on alternate
/// steps, so a bend costs no more than halving would. It stops when the cost
/// that fits is the budget to within a rounding error, or the ends are
/// neighbouring numbers, and the end returned is always one whose cost was
/// seen to fit.
pub fn largest_within(budget: f64, keeps: f64, bound: f64, cost: impl Fn(f64) -> f64) -> f64 {
    let over_cost = cost(bound);
    if over_cost <= budget {
        return bound;
    }
    let fits_cost = cost(keeps);
    if !(fits_cost <= budget) {
        return keeps;
    }
    let (mut fits, mut fits_cost, mut over, mut over_cost) = (keeps, fits_cost, bound, over_cost);
    let mut interpolate = true;
    loop {
        if budget - fits_cost <= budget.abs() * 4.0 * f64::EPSILON {
            return fits;
        }
        let halfway = 0.5 * (fits + over);
        let along = fits + (budget - fits_cost) / (over_cost - fits_cost) * (over - fits);
        let next = if interpolate && along > fits && along < over { along } else { halfway };
        interpolate = !interpolate;
        // Each pass leaves a number strictly between the ends, or stops:
        // finitely many numbers lie between any two, so it always stops.
        if !(next > fits && next < over) {
            return fits;
        }
        let next_cost = cost(next);
        if next_cost <= budget {
            (fits, fits_cost) = (next, next_cost);
        } else {
            (over, over_cost) = (next, next_cost);
        }
    }
}

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

// MARK: - Trailing stop
//
// Three tiny functions rather than one, because the live runner needs the level
// without the backtester's mutable position: the simulator folds each bar into
// a running anchor as it goes, while the runner recomputes from the bars since
// entry on every tick. Sharing the *arithmetic* is what keeps them equal.

/// The extreme price seen since entry: the highest high for a long, the lowest
/// low for a short. Seeded with the entry price, so a position that never went
/// in its favour trails from where it was opened.
pub fn trail_anchor(
    direction: Direction, entry_price: f64, highs: &[f64], lows: &[f64],
) -> f64 {
    match direction {
        Direction::Long => highs
            .iter()
            .copied()
            .filter(|v| v.is_finite())
            .fold(entry_price, f64::max),
        Direction::Short => lows
            .iter()
            .copied()
            .filter(|v| v.is_finite())
            .fold(entry_price, f64::min),
    }
}

/// The stop level a trailing percentage implies for a given anchor.
pub fn trailing_stop_level(
    direction: Direction, anchor: f64, trail_pct: f64,
) -> f64 {
    match direction {
        Direction::Long => anchor * (1.0 - trail_pct / 100.0),
        Direction::Short => anchor * (1.0 + trail_pct / 100.0),
    }
}

/// Move a stop only in the position's favour.
///
/// The ratchet is the whole point of a trailing stop: a level that could loosen
/// would give back the protection it just gained, and on a round trip it would
/// end up wider than the stop the position opened with.
pub fn ratchet_stop(
    direction: Direction, current: Option<f64>, candidate: f64,
) -> f64 {
    match (current, direction) {
        (None, _) => candidate,
        (Some(current), Direction::Long) => current.max(candidate),
        (Some(current), Direction::Short) => current.min(candidate),
    }
}

/// The position a binary strategy takes on `direction`'s side, in signed base
/// units, trading there from `footing.held_base`. `None` when the strategy
/// cannot be sized on this bar — a risk-per-trade strategy whose stop
/// distance is unknown must stand aside rather than guess, because guessing
/// means over-betting — or when the capital cannot commit to any of it.
///
/// `footing.capital` is what this strategy may deploy, not the whole account.
pub fn target_base(
    strategy: &CompiledStrategy,
    footing: &Footing,
    stop_distance: Option<f64>,
    direction: Direction,
) -> Option<f64> {
    let (equity, price, leverage) = (footing.capital, footing.price, footing.leverage);
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
    // The one ceiling no manifest can argue with: what the order leaves
    // committed — margin and fee — fits in the capital.
    let target = footing.affordable(notional / price * direction.sign());
    (target != 0.0 && target.signum() == direction.sign()).then_some(target)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::strategy::{InstrumentType, Manifest};

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
    fn the_anchor_is_the_best_price_seen_since_entry() {
        let highs = [101.0, 108.0, 104.0];
        let lows = [99.0, 92.0, 96.0];
        assert_eq!(trail_anchor(Direction::Long, 100.0, &highs, &lows), 108.0);
        assert_eq!(trail_anchor(Direction::Short, 100.0, &highs, &lows), 92.0);
    }

    #[test]
    fn a_position_that_never_moved_trails_from_entry() {
        // Seeded with the entry price, so there is always an anchor.
        assert_eq!(trail_anchor(Direction::Long, 100.0, &[98.0], &[95.0]), 100.0);
        assert_eq!(trail_anchor(Direction::Short, 100.0, &[105.0], &[102.0]), 100.0);
    }

    #[test]
    fn a_nan_bar_cannot_poison_the_anchor() {
        // A malformed bar must not drag the stop to NaN and disable it.
        let anchor = trail_anchor(Direction::Long, 100.0, &[f64::NAN, 106.0], &[]);
        assert_eq!(anchor, 106.0);
    }

    #[test]
    fn the_level_sits_a_percentage_below_the_anchor() {
        assert!((trailing_stop_level(Direction::Long, 110.0, 5.0) - 104.5).abs() < 1e-9);
        assert!((trailing_stop_level(Direction::Short, 90.0, 5.0) - 94.5).abs() < 1e-9);
    }

    #[test]
    fn the_ratchet_only_ever_tightens() {
        // A long's stop may rise, never fall.
        assert_eq!(ratchet_stop(Direction::Long, Some(95.0), 97.0), 97.0);
        assert_eq!(ratchet_stop(Direction::Long, Some(95.0), 90.0), 95.0);
        // A short's stop may fall, never rise.
        assert_eq!(ratchet_stop(Direction::Short, Some(105.0), 103.0), 103.0);
        assert_eq!(ratchet_stop(Direction::Short, Some(105.0), 110.0), 105.0);
        // With nothing to ratchet from, the candidate stands.
        assert_eq!(ratchet_stop(Direction::Long, None, 90.0), 90.0);
    }

    fn footing(costs: &Costs, capital: f64, price: f64, leverage: f64) -> Footing<'_> {
        Footing { costs, capital, price, leverage, regime: MarginRegime::Isolated, held_base: 0.0, held_basis: 0.0 }
    }

    /// Notional of a long entry sized from flat.
    fn long_notional(s: &CompiledStrategy, costs: &Costs, capital: f64, price: f64, leverage: f64,
                     distance: Option<f64>) -> Option<f64> {
        target_base(s, &footing(costs, capital, price, leverage), distance, Direction::Long).map(|b| b * price)
    }

    #[test]
    fn equity_percent_commits_a_share_of_the_budget() {
        let s = strategy(r#"{"mode":"equityPct","value":50}"#, "{}");
        let n = long_notional(&s, &Costs::flat(10.0, 0.0), 10_000.0, 100.0, 1.0, None).unwrap();
        assert!((n - 5_000.0).abs() < 1e-9, "half the budget and its fee fit, so the fee takes nothing off");
    }

    #[test]
    fn fixed_quote_is_capped_by_what_the_budget_can_pay_for() {
        let s = strategy(r#"{"mode":"fixedQuote","value":50000}"#, "{}");
        let n = long_notional(&s, &Costs::flat(10.0, 0.0), 10_000.0, 100.0, 1.0, None).unwrap();
        // The position and its 10 bps fee together are the budget.
        assert!((n * (1.0 + 0.001) - 10_000.0).abs() < 1e-6, "never exceed the allocation: {n}");
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
        let n = long_notional(&s, &Costs::flat(10.0, 0.0), 10_000.0, 64_000.0, 1.0, Some(distance)).unwrap();
        assert!((n - 5_120.0).abs() < 1e-6, "got {n}");
    }

    #[test]
    fn risk_per_trade_stands_aside_without_a_stop() {
        let s = strategy(r#"{"mode":"riskPerTrade","value":1}"#, "{}");
        assert!(stop_distance(&s, 64_000.0, None).is_none());
        assert!(
            long_notional(&s, &Costs::flat(10.0, 0.0), 10_000.0, 64_000.0, 1.0, None).is_none(),
            "no stop distance means no size — never the whole budget"
        );
    }

    /// Cost models of every shape a schedule can state, for the walks below:
    /// each family's own default where it has one, a plain taker fee, a heavy
    /// one, a maker rebate, and a broker's — a sale levy, a capped per-share
    /// levy, a per-share commission with a minimum, a charge per order.
    fn cost_models(family: InstrumentType) -> Vec<Costs> {
        use crate::fees::{FeeBasis, FeeComponent, FeeSide};
        let component = |basis, side, min_per_order, max_per_order| FeeComponent {
            basis, side, min_per_order, max_per_order, label: None,
        };
        let mut models = vec![Costs::flat(5.0, 0.0), Costs::flat(50.0, 0.0), Costs::flat(-2.0, 0.0)];
        models.push(Costs {
            fees: vec![
                component(FeeBasis::Notional { bps: 0.278 }, FeeSide::Sell, None, None),
                component(FeeBasis::Unit { per_unit: 0.000_166 }, FeeSide::Sell, None, Some(8.30)),
                component(FeeBasis::Unit { per_unit: 0.005 }, FeeSide::Both, Some(1.0), None),
                component(FeeBasis::Order { per_order: 0.65 }, FeeSide::Both, None, None),
            ],
            slippage_bps: 0.0,
        });
        if let Some(fees) = family.default_fees() {
            models.push(Costs { fees, slippage_bps: 0.0 });
        }
        models
    }

    /// Walks every family the linear sizing serves (an option's premium is
    /// sized by `options::affordable_contracts`), at every whole leverage it
    /// allows, under every cost model, in every sizing mode, on both sides it
    /// can take: what an entry commits never exceeds the capital, and an entry
    /// the ceiling cut is cut only as far as the ceiling — it commits the
    /// capital to within a rounding error.
    #[test]
    fn no_entry_commits_more_than_the_capital() {
        let modes = [
            (r#"{"mode":"equityPct","value":100}"#, None),
            (r#"{"mode":"equityPct","value":250}"#, None),
            (r#"{"mode":"fixedQuote","value":1e9}"#, None),
            (r#"{"mode":"riskPerTrade","value":5}"#, Some(1e-6)),
            (r#"{"mode":"volatilityTarget","value":20}"#, None),
        ];
        let (capital, price) = (10_000.0, 37.5);
        let mut checked = 0;
        for family in InstrumentType::ALL.into_iter().filter(|f| !f.is_option()) {
            for costs in cost_models(family) {
                let mut leverage = 1.0;
                while leverage <= family.max_leverage() {
                    for (sizing, distance) in modes {
                        let s = strategy(sizing, "{}");
                        let at = Footing { regime: family.margin_regime(), ..footing(&costs, capital, price, leverage) };
                        let sides = if family.allows_short() { vec![Direction::Long, Direction::Short] } else { vec![Direction::Long] };
                        for direction in sides {
                            let base = target_base(&s, &at, distance, direction)
                                .unwrap_or_else(|| panic!("{family:?} {leverage}x {sizing} {direction:?}: unsized"));
                            assert_eq!(base.signum(), direction.sign());
                            let committed = at.committed(base);
                            assert!(committed <= capital,
                                    "{family:?} {leverage}x {sizing} {direction:?} {:?}: commits {committed}", costs.fees);
                            // Every mode here asks for at least what the margin
                            // alone allows, so each ends on the ceiling: the
                            // capital committed, or — when a rebate pays the
                            // fee — the margin-only bound itself.
                            let at_margin_bound = base.abs() * price >= capital * leverage * (1.0 - 1e-12);
                            assert!(capital - committed <= 1e-9 * capital || at_margin_bound
                                        || at.committed(base * (1.0 + 1e-12)) > capital,
                                    "{family:?} {leverage}x {sizing}: cut further than the ceiling — {committed}");
                            checked += 1;
                        }
                    }
                    leverage += 1.0;
                }
            }
        }
        assert!(checked > 1_000, "the walk covered {checked} entries");
    }

    /// A flat fee has an exact ceiling: margin and fee are both proportional
    /// to the notional, so the most an entry can be is the capital over the
    /// sum of the two rates.
    #[test]
    fn under_a_flat_fee_the_ceiling_is_exact() {
        let s = strategy(r#"{"mode":"equityPct","value":100}"#, "{}");
        for leverage in [1.0, 10.0, InstrumentType::Swap.max_leverage()] {
            let costs = Costs::flat(5.0, 0.0);
            let n = long_notional(&s, &costs, 10_000.0, 100.0, leverage, None).unwrap();
            let exact = 10_000.0 / (1.0 / leverage + 0.0005);
            assert!((n - exact).abs() < 1e-9 * exact, "{leverage}x: {n} vs {exact}");
        }
    }

    /// The rule limits what an order adds. A reduction, or keeping what is
    /// held, is never cut — even when losses have left the capital unable to
    /// back the position — and a reversal pays the close out of the capital
    /// before the other side is sized.
    #[test]
    fn the_ceiling_limits_what_an_order_adds_and_nothing_else() {
        let costs = Costs::flat(5.0, 0.0);
        let held = Footing { held_base: 50.0, held_basis: 100.0, ..footing(&costs, 100.0, 100.0, 10.0) };
        // 50 coins at 100 on 10x is 500 of margin against 100 of capital.
        assert_eq!(held.affordable(30.0), 30.0, "a trim goes whole");
        assert_eq!(held.affordable(0.0), 0.0, "a close goes whole");
        assert_eq!(held.affordable(80.0), 50.0, "adding is refused, keeping is not");

        let flat_capital = 10_000.0;
        let reversing = Footing { held_base: 400.0, held_basis: 100.0, ..footing(&costs, flat_capital, 100.0, 10.0) };
        let short = reversing.affordable(-1_000.0);
        // The close of 400 and the opening of the short trade in one order;
        // its fee on 400 + |short| comes out of the same capital.
        let fee = (400.0 - short) * 100.0 * 0.0005;
        assert!((short.abs() * 100.0 / 10.0 + fee - flat_capital).abs() < 1e-6, "short {short}");
        assert!(short < 0.0);
    }

    /// An isolated position's unrealised profit is not cash: a winner cannot
    /// add on it, a loser can add on the cash its own margin did not take, and
    /// a lender that counts the mark — Reg T — lends against the profit.
    #[test]
    fn adding_to_an_isolated_position_is_paid_for_out_of_realised_capital() {
        let costs = Costs::flat(0.0, 0.0);
        // 10 coins bought at 100 on 10x posted 100 of margin, all the capital
        // there was; at 200 the position shows 1 000 of profit.
        let winner = Footing { held_base: 10.0, held_basis: 100.0, ..footing(&costs, 1_100.0, 200.0, 10.0) };
        assert!((winner.affordable(55.0) - 10.0).abs() < 1e-9, "nothing realised is left to add with");
        let marked = Footing { regime: MarginRegime::RegT, ..winner };
        assert!((marked.affordable(55.0) - 55.0).abs() < 1e-9, "a lender of the mark lends on the profit");

        // Bought at 100 with 300 of capital on 10x — 100 posted, 200 free —
        // and now at 90: the loss is its own margin's, the free cash adds.
        let loser = Footing { held_base: 10.0, held_basis: 100.0, ..footing(&costs, 300.0 - 100.0, 90.0, 10.0) };
        let added = loser.affordable(1_000.0) - 10.0;
        assert!((added * 90.0 / 10.0 - 200.0).abs() < 1e-6, "adds what 200 of free cash posts: {added}");

        // An unknown basis adds nothing.
        let unknown = Footing { held_basis: 0.0, ..winner };
        assert!((unknown.affordable(55.0) - 10.0).abs() < 1e-9);
    }

    #[test]
    fn exposure_is_measured_on_the_scale_it_is_sized_on() {
        let costs = Costs::flat(5.0, 0.0);
        let mut leverage = 1.0;
        while leverage <= InstrumentType::Swap.max_leverage() {
            let at = footing(&costs, 10_000.0, 100.0, leverage);
            let half = at.exposure_target(0.5);
            assert!((exposure_of(half, 10_000.0, 100.0, leverage) - 0.5).abs() < 1e-12, "{leverage}x");
            // Full exposure is cut to what the capital can commit.
            let full = at.exposure_target(1.0);
            assert!(at.committed(full) <= 10_000.0 && full < exposure_base(1.0, 10_000.0, 100.0, leverage));
            leverage += 1.0;
        }
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
        let costs = Costs::flat(10.0, 0.0);
        assert!(long_notional(&s, &costs, 0.0, 100.0, 1.0, None).is_none());
        assert!(long_notional(&s, &costs, 10_000.0, 0.0, 1.0, None).is_none());
        assert!(long_notional(&s, &costs, -5.0, 100.0, 1.0, None).is_none());
        // A charge per order larger than the whole capital leaves nothing.
        let ruinous = Costs {
            fees: vec![crate::fees::FeeComponent {
                basis: crate::fees::FeeBasis::Order { per_order: 50.0 },
                side: crate::fees::FeeSide::Both, min_per_order: None, max_per_order: None, label: None,
            }],
            slippage_bps: 0.0,
        };
        assert!(long_notional(&s, &ruinous, 20.0, 100.0, 1.0, None).is_none());
    }
}
