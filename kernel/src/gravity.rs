//! The option-book arithmetic a position review keeps asking for: where the
//! book's own pain point sits, how wide a move the market is pricing, and how
//! close a position is to being liquidated. (How *likely* a liquidation is
//! reads off the smile, so it lives in `implied`.)
//!
//! Pure functions over numbers the caller supplies. These drive real
//! decisions, so a wrong max pain or a mis-scaled sigma is worse than no
//! number at all — it reads as fact.

/// Open interest at one strike of one expiry, in units of the underlying
/// (ETH, BTC) — never contracts, whose size differs by venue.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StrikeInterest {
    pub strike: f64,
    pub call_oi: f64,
    pub put_oi: f64,
    /// Dollar value of one unit of underlying's worth of the option, when a
    /// mark is known. Kept beside the open interest because a chain can show
    /// billions of notional whose options are worth a rounding error.
    pub call_mark_usd: Option<f64>,
    pub put_mark_usd: Option<f64>,
}

impl StrikeInterest {
    pub fn total_oi(&self) -> f64 {
        self.call_oi + self.put_oi
    }

    /// Underlying value the open contracts represent — **not** money anyone
    /// has put up.
    pub fn notional(&self, spot: f64) -> f64 {
        self.total_oi() * spot
    }

    /// What the open contracts are worth right now, in dollars; `None` when
    /// neither side carries a mark.
    pub fn market_value(&self) -> Option<f64> {
        if self.call_mark_usd.is_none() && self.put_mark_usd.is_none() {
            return None;
        }
        Some(self.call_oi * self.call_mark_usd.unwrap_or(0.0) + self.put_oi * self.put_mark_usd.unwrap_or(0.0))
    }
}

/// What writers owe in total, in dollars, if the expiry settles at `settle`.
pub fn writer_payout(interests: &[StrikeInterest], settle: f64) -> f64 {
    interests
        .iter()
        .map(|row| {
            // A call writer pays above the strike, a put writer below it.
            (settle - row.strike).max(0.0) * row.call_oi + (row.strike - settle).max(0.0) * row.put_oi
        })
        .sum()
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MaxPain {
    /// The strike where writers pay out least.
    pub strike: f64,
    /// That minimum payout, in dollars.
    pub payout: f64,
    /// How far it sits from spot, in percent.
    pub distance_pct: f64,
    /// Payout if settlement lands one expected move (1σ) away from the
    /// minimum, on the cheaper side. `None` without a sigma.
    pub payout_one_sigma_away: Option<f64>,
}

impl MaxPain {
    /// True when moving one expected move away from the minimum costs writers
    /// less than 5% more: the curve is a basin, not a point, and no single
    /// price in it is meaningfully favoured.
    ///
    /// Measured in sigma rather than against the neighbouring strike. The
    /// neighbour test measured the strike grid, not the book: merging venues
    /// makes the grid denser, adjacent strikes then always cost about the
    /// same, and on 2026-09-23 it flagged 8 of 9 expiries as weak. Against a
    /// one-sigma move the same books split cleanly — only the quarterly, whose
    /// payout rose 1.1% over ±$91, came out weak.
    pub fn is_weak(&self) -> bool {
        match self.payout_one_sigma_away {
            Some(away) => away <= self.payout * 1.05,
            None => true,
        }
    }
}

/// The strike that minimises total writer payout at expiry.
///
/// A statistic, not a forecast. Open interest is built over a contract's
/// life, so on a long-dated expiry the minimum tends to sit near the prices
/// at which the positions were opened; whether price goes there is a question
/// for `implied::probability_beyond`, not for this.
pub fn max_pain(interests: &[StrikeInterest], spot: f64, one_sigma: Option<f64>) -> Option<MaxPain> {
    if interests.is_empty() || !(spot > 0.0) {
        return None;
    }
    let mut best: Option<(f64, f64)> = None;
    for row in interests {
        let payout = writer_payout(interests, row.strike);
        best = match best {
            Some((_, current)) if current <= payout => best,
            _ => Some((row.strike, payout)),
        };
    }
    let (strike, payout) = best?;
    let payout_one_sigma_away = one_sigma.filter(|s| *s > 0.0).map(|sigma| {
        writer_payout(interests, strike + sigma).min(writer_payout(interests, (strike - sigma).max(0.0)))
    });
    Some(MaxPain { strike, payout, distance_pct: (strike / spot - 1.0) * 100.0, payout_one_sigma_away })
}

/// One standard deviation of price over `hours`, in quote currency.
/// Annualised vol scaled by the square root of the fraction of a year left.
pub fn one_sigma(spot: f64, iv: f64, hours: f64) -> Option<f64> {
    if !(spot > 0.0) || !(iv > 0.0) || !(hours > 0.0) {
        return None;
    }
    Some(spot * iv * (hours / 24.0 / 365.0).sqrt())
}

/// Put vol minus call vol at the wings, approximating 25 delta by strikes
/// `wing_pct` either side of the forward. Positive is a put bid.
///
/// Same-day wings are thin enough to swing ten points overnight on no flow,
/// so the caller is told when a reading is that close to expiry.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Skew {
    pub points: f64,
    pub hours_to_expiry: f64,
}

impl Skew {
    pub fn is_noisy(&self) -> bool {
        self.hours_to_expiry < 24.0
    }
}

pub fn skew(smile: &crate::implied::Smile, forward: f64, hours: f64, wing_pct: f64) -> Option<Skew> {
    let put = smile.iv_at(forward * (1.0 - wing_pct / 100.0), forward)?;
    let call = smile.iv_at(forward * (1.0 + wing_pct / 100.0), forward)?;
    Some(Skew { points: (put - call) * 100.0, hours_to_expiry: hours })
}

/// Distance to liquidation as a percentage of the mark, positive when the
/// level is still ahead of the position.
pub fn liquidation_buffer(mark: f64, liquidation: f64, is_short: bool) -> Option<f64> {
    if !(mark > 0.0) || !(liquidation > 0.0) {
        return None;
    }
    Some(if is_short { (liquidation / mark - 1.0) * 100.0 } else { (1.0 - liquidation / mark) * 100.0 })
}

/// What a position actually risks, as opposed to what its leverage setting
/// says: notional against equity decides survival, and the contract's own
/// setting routinely misstates it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Exposure {
    pub notional: f64,
    pub equity: f64,
    pub margin: f64,
}

impl Exposure {
    pub fn effective_leverage(&self) -> f64 {
        if self.equity > 0.0 { self.notional / self.equity } else { 0.0 }
    }
    /// Quote-currency P&L from a 1% move in the underlying.
    pub fn loss_per_one_percent(&self) -> f64 {
        self.notional * 0.01
    }
    pub fn one_percent_as_equity_pct(&self) -> f64 {
        if self.equity > 0.0 { self.loss_per_one_percent() / self.equity * 100.0 } else { 0.0 }
    }
    pub fn margin_as_equity_pct(&self) -> f64 {
        if self.equity > 0.0 { self.margin / self.equity * 100.0 } else { 0.0 }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn si(strike: f64, call_oi: f64, put_oi: f64) -> StrikeInterest {
        StrikeInterest { strike, call_oi, put_oi, call_mark_usd: None, put_mark_usd: None }
    }

    /// Real open interest from OKX's 21SEP26 ETH chain, strikes 2500–2700,
    /// taken from the live book so a change in method fails loudly.
    fn chain() -> Vec<StrikeInterest> {
        [
            (2500.0, 3181.0, 6728.0), (2510.0, 669.0, 4512.0), (2525.0, 4922.0, 5018.0),
            (2530.0, 265.0, 5662.0), (2540.0, 260.0, 10106.0), (2550.0, 50211.0, 15375.0),
            (2560.0, 752.0, 17956.0), (2575.0, 56027.0, 25082.0), (2580.0, 4502.0, 50599.0),
            (2590.0, 2305.0, 23293.0), (2600.0, 32763.0, 40927.0), (2610.0, 3307.0, 56190.0),
            (2620.0, 11114.0, 3247.0), (2625.0, 23331.0, 3379.0), (2630.0, 24790.0, 1720.0),
            (2640.0, 2181.0, 1673.0), (2650.0, 21518.0, 1773.0), (2660.0, 7583.0, 2686.0),
            (2670.0, 949.0, 322.0), (2675.0, 5073.0, 0.0), (2680.0, 2464.0, 0.0),
            (2690.0, 1044.0, 0.0), (2700.0, 8768.0, 360.0),
        ]
        .iter()
        .map(|&(k, c, p)| si(k, c, p))
        .collect()
    }

    #[test]
    fn finds_the_strike_where_writers_pay_least() {
        let pain = max_pain(&chain(), 2576.0, None).unwrap();
        // Cross-checked against an independent calculation on the same chain.
        assert_eq!(pain.strike, 2590.0);
        assert!(pain.distance_pct > 0.0);
    }

    #[test]
    fn without_a_sigma_the_pull_cannot_be_judged() {
        assert!(max_pain(&chain(), 2576.0, None).unwrap().is_weak());
    }

    #[test]
    fn a_basin_is_weak_and_a_point_is_not() {
        // Only tail interest: anywhere between 2000 and 3000 costs nothing.
        let basin = [si(2000.0, 0.0, 5_000.0), si(3000.0, 5_000.0, 0.0), si(2500.0, 0.0, 0.0)];
        assert!(max_pain(&basin, 2500.0, Some(90.0)).unwrap().is_weak());
        // Straddles written at 2600: one sigma either way costs real money.
        let point = [si(2600.0, 20_000.0, 20_000.0), si(2400.0, 10.0, 10.0), si(2800.0, 10.0, 10.0)];
        let pain = max_pain(&point, 2600.0, Some(90.0)).unwrap();
        assert_eq!(pain.strike, 2600.0);
        assert!(!pain.is_weak());
    }

    #[test]
    fn a_denser_strike_grid_does_not_make_a_point_look_weak() {
        // The regression the sigma rule exists for: the same sharp book with
        // many near-empty strikes in between (what merging venues produces).
        let mut dense = vec![si(2600.0, 20_000.0, 20_000.0)];
        for k in (2400..=2800).step_by(10) {
            if k != 2600 { dense.push(si(f64::from(k), 1.0, 1.0)); }
        }
        let pain = max_pain(&dense, 2600.0, Some(90.0)).unwrap();
        assert_eq!(pain.strike, 2600.0);
        assert!(!pain.is_weak(), "neighbouring strikes are close, but one sigma away is not");
    }

    #[test]
    fn refuses_to_answer_without_a_chain_or_spot() {
        assert!(max_pain(&[], 2600.0, None).is_none());
        assert!(max_pain(&chain(), 0.0, None).is_none());
    }

    #[test]
    fn notional_and_market_value_are_different_numbers() {
        // 20,000 ETH of deep out-of-the-money calls worth $2.58 each.
        let far = StrikeInterest { strike: 3000.0, call_oi: 2_000.0, put_oi: 0.0, call_mark_usd: Some(2.58), put_mark_usd: None };
        assert!((far.notional(2580.0) - 5_160_000.0).abs() < 1.0);
        assert!((far.market_value().unwrap() - 5_160.0).abs() < 1.0);
        assert!(si(2600.0, 100.0, 50.0).market_value().is_none());
    }

    #[test]
    fn one_sigma_scales_with_the_square_root_of_time() {
        let quarter = one_sigma(2000.0, 0.40, 0.25 * 365.0 * 24.0).unwrap();
        assert!((quarter - 400.0).abs() < 0.5);
        let day = one_sigma(2000.0, 0.40, 24.0).unwrap();
        assert!(day < quarter && day > 0.0);
        assert!(one_sigma(2580.0, 0.0, 24.0).is_none());
        assert!(one_sigma(2580.0, 0.4, 0.0).is_none());
        assert!(one_sigma(0.0, 0.4, 24.0).is_none());
    }

    #[test]
    fn buffers_point_outward_for_both_sides() {
        // 2886.06 / 2571.77 − 1 ≈ 12.22%
        assert!((liquidation_buffer(2571.77, 2886.06, true).unwrap() - 12.22).abs() < 0.05);
        assert!(liquidation_buffer(2600.0, 2340.0, false).unwrap() > 0.0);
        assert!(liquidation_buffer(0.0, 2340.0, false).is_none());
    }

    #[test]
    fn effective_leverage_is_notional_over_equity() {
        let exposure = Exposure { notional: 14_586.0, equity: 7_045.0, margin: 1_553.0 };
        assert!((exposure.effective_leverage() - 2.07).abs() < 0.01);
        assert!((exposure.loss_per_one_percent() - 145.86).abs() < 0.01);
        let broke = Exposure { notional: 1000.0, equity: 0.0, margin: 100.0 };
        assert_eq!(broke.effective_leverage(), 0.0);
    }
}
