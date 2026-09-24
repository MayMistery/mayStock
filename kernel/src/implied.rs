//! What the option market says about where the underlying will settle: the
//! risk-neutral distribution implied by one expiry's volatility smile.
//!
//! This is the number a "will it get there?" question actually wants. A max
//! pain level, a round number, a support line — each is a place; this says
//! how likely the place is, in the market's own prices. It is **risk-neutral**:
//! it carries the premium people pay for protection, so it leans toward the
//! tails (downside above all) compared with what history would say.
//!
//! Pure arithmetic, like the rest of the kernel: no network, no clock beyond
//! what the caller passes in, so every probability on screen can be
//! reproduced exactly in a test.

use crate::options::{black_scholes, normal_cdf, normal_pdf, OptionKind};

/// One quoted point of a smile.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SmilePoint {
    pub strike: f64,
    /// Implied volatility as a fraction (0.46 for 46%).
    pub iv: f64,
}

/// One expiry's implied volatility as a smooth curve, fitted to the quotes it
/// was built from, together with the forward it was quoted against.
///
/// Why a fitted curve, and which — each learned on 2026-09-23 data:
/// - The probabilities are the slope of put prices in strike, so they pick up
///   `dσ/dK`. A curve threaded through every quote handed each quote's noise
///   to the distribution, and three near-flat wing marks became a range with
///   negative probability.
/// - Raw five-parameter SVI (`w = a + b(ρ(k−m) + √((k−m)² + s²))`) prices the
///   quarterly's near-the-money puts to within 6% — but on a steep next-day
///   smile it extrapolated its wings to 190% vol and broke the butterfly
///   condition, and cumulative probability went below 0 and above 1.
/// - An SSVI slice (`w = θ/2·(1 + ρφk + √((φk+ρ)² + 1 − ρ²))`) held inside
///   `θφ(1+|ρ|) < 4`, `θφ²(1+|ρ|) ≤ 4` is free of butterfly arbitrage by
///   theorem (Gatheral & Jacquier 2014, Thm 4.2), at the cost of about a vol
///   point near the money on that same quarterly.
///
/// So SVI is fitted first and its distribution is checked across a wide band
/// of strikes; if it is not a distribution (falls anywhere, or leaves
/// [0, 1]), the SSVI fit is used instead and `model` says so.
///
/// Vol is read in log-moneyness against the live forward ("sticky
/// moneyness"): when spot moves between two updates, the smile moves with it.
#[derive(Debug, Clone, PartialEq)]
pub struct Smile {
    /// The forward the quotes were struck against.
    pub forward: f64,
    /// Years to expiry when quoted; both curves are in total variance.
    years: f64,
    curve: Curve,
    /// Root-mean-square miss of the fit against the quotes, in vol points,
    /// weighted the way the fit was.
    pub fit_error: f64,
    pub quotes: usize,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Curve {
    Svi { a: f64, b: f64, rho: f64, m: f64, s: f64 },
    Ssvi { theta: f64, rho: f64, phi: f64 },
}

impl Curve {
    fn total_variance(&self, k: f64) -> f64 {
        match *self {
            Curve::Svi { a, b, rho, m, s } => {
                let y = k - m;
                a + b * (rho * y + (y * y + s * s).sqrt())
            }
            Curve::Ssvi { theta, rho, phi } => {
                theta / 2.0 * (1.0 + rho * phi * k + ((phi * k + rho).powi(2) + 1.0 - rho * rho).sqrt())
            }
        }
    }

    fn slope(&self, k: f64) -> f64 {
        match *self {
            Curve::Svi { b, rho, m, s, .. } => {
                let y = k - m;
                b * (rho + y / (y * y + s * s).sqrt())
            }
            Curve::Ssvi { theta, rho, phi } => {
                theta / 2.0 * (rho * phi + phi * (phi * k + rho) / ((phi * k + rho).powi(2) + 1.0 - rho * rho).sqrt())
            }
        }
    }

    fn error(&self, nodes: &[Node]) -> f64 {
        nodes.iter().map(|&(k, w, weight)| weight * (self.total_variance(k) - w).powi(2)).sum()
    }
}

/// One quote as the fit sees it: log-moneyness, total variance, weight.
type Node = (f64, f64, f64);

/// Weighted least squares for SVI's (a, bρ, b) with (m, s) fixed — the linear
/// half of the quasi-explicit fit.
fn svi_linear(nodes: &[Node], m: f64, s: f64) -> Option<Curve> {
    let mut ata = [[0.0f64; 3]; 3];
    let mut atv = [0.0f64; 3];
    for &(k, w, weight) in nodes {
        let y = k - m;
        let row = [1.0, y, (y * y + s * s).sqrt()];
        for i in 0..3 {
            atv[i] += weight * row[i] * w;
            for j in 0..3 {
                ata[i][j] += weight * row[i] * row[j];
            }
        }
    }
    let [a, d, c] = solve3(ata, atv)?;
    // Keep the curve a smile: b ≥ 0, |ρ| < 1, non-negative at its low.
    let c = c.max(1e-12);
    let d = d.clamp(-c * 0.999, c * 0.999);
    let floor = -s * (c * c - d * d).sqrt();
    Some(Curve::Svi { a: a.max(floor), b: c, rho: d / c, m, s })
}

fn solve3(a: [[f64; 3]; 3], b: [f64; 3]) -> Option<[f64; 3]> {
    let det = |m: [[f64; 3]; 3]| {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    };
    let d = det(a);
    if d.abs() < 1e-30 {
        return None;
    }
    let mut out = [0.0; 3];
    for (col, slot) in out.iter_mut().enumerate() {
        let mut m = a;
        for row in 0..3 {
            m[row][col] = b[row];
        }
        *slot = det(m) / d;
    }
    Some(out)
}

/// SVI: a coarse grid over (m, s), then Nelder–Mead from its best point,
/// each point solving the linear half exactly.
fn fit_svi(nodes: &[Node]) -> Option<Curve> {
    let lo = nodes.iter().map(|n| n.0).fold(f64::INFINITY, f64::min);
    let hi = nodes.iter().map(|n| n.0).fold(f64::NEG_INFINITY, f64::max);
    let solve = |x: [f64; 3]| svi_linear(nodes, x[0].clamp(lo, hi), x[1].clamp(1e-4, 2.0));
    let cost = |x: [f64; 3]| solve(x).map(|c| c.error(nodes)).unwrap_or(f64::INFINITY);
    let mut seed = [0.0, 0.1, 0.0];
    let mut seed_cost = f64::INFINITY;
    for i in 0..=12 {
        for j in 0..=12 {
            let x = [lo + (hi - lo) * f64::from(i) / 12.0, 0.005 * 200f64.powf(f64::from(j) / 12.0), 0.0];
            let c = cost(x);
            if c < seed_cost {
                (seed, seed_cost) = (x, c);
            }
        }
    }
    // The third coordinate is unused; a zero step keeps it put.
    let (best, _) = nelder_mead(&cost, seed, [(hi - lo).max(0.02) * 0.1, seed[1] * 0.5, 0.0], 400);
    solve(best)
}

/// SSVI in unconstrained coordinates (ln θ, atanh ρ, logit of the share of
/// the allowed φ), so every point tried is already arbitrage-free.
fn fit_ssvi(nodes: &[Node], theta_guess: f64) -> Option<Curve> {
    let decode = |x: [f64; 3]| -> Curve {
        let theta = x[0].exp();
        let rho = x[1].tanh().clamp(-0.999, 0.999);
        let spread = theta * (1.0 + rho.abs());
        let limit = (4.0 / spread * 0.999).min((4.0 / spread).sqrt());
        Curve::Ssvi { theta, rho, phi: limit / (1.0 + (-x[2]).exp()) }
    };
    let cost = |x: [f64; 3]| decode(x).error(nodes);
    let mut best: Option<([f64; 3], f64)> = None;
    for rho0 in [-0.6f64, -0.2, 0.2] {
        for share in [0.15f64, 0.6] {
            let start = [theta_guess.max(1e-12).ln(), rho0.atanh(), (share / (1.0 - share)).ln()];
            let (x, c) = nelder_mead(&cost, start, [0.3, 0.3, 1.0], 600);
            if best.is_none_or(|(_, b)| c < b) {
                best = Some((x, c));
            }
        }
    }
    best.map(|(x, _)| decode(x))
}

fn nelder_mead(cost: &dyn Fn([f64; 3]) -> f64, start: [f64; 3], step: [f64; 3], iterations: usize) -> ([f64; 3], f64) {
    let dims: Vec<usize> = (0..3).filter(|d| step[*d] != 0.0).collect();
    let n = dims.len();
    let mut points: Vec<[f64; 3]> = vec![start; n + 1];
    for (i, d) in dims.iter().enumerate() {
        points[i + 1][*d] += step[*d];
    }
    let mut values: Vec<f64> = points.iter().map(|p| cost(*p)).collect();
    for _ in 0..iterations {
        let mut order: Vec<usize> = (0..=n).collect();
        order.sort_by(|a, b| values[*a].total_cmp(&values[*b]));
        let (best, worst, second_worst) = (order[0], order[n], order[n - 1]);
        if (values[worst] - values[best]).abs() <= 1e-24 + 1e-12 * values[best].abs() {
            break;
        }
        let mut centroid = [0.0; 3];
        for &i in &order[..n] {
            for d in 0..3 {
                centroid[d] += points[i][d] / n as f64;
            }
        }
        let along = |t: f64| {
            let mut x = [0.0; 3];
            for d in 0..3 {
                x[d] = centroid[d] + t * (points[worst][d] - centroid[d]);
            }
            x
        };
        let reflected = along(-1.0);
        let fr = cost(reflected);
        if fr < values[best] {
            let expanded = along(-2.0);
            let fe = cost(expanded);
            (points[worst], values[worst]) = if fe < fr { (expanded, fe) } else { (reflected, fr) };
        } else if fr < values[second_worst] {
            (points[worst], values[worst]) = (reflected, fr);
        } else {
            let contracted = along(0.5);
            let fc = cost(contracted);
            if fc < values[worst] {
                (points[worst], values[worst]) = (contracted, fc);
            } else {
                for &i in &order[1..] {
                    for d in 0..3 {
                        points[i][d] = (points[i][d] + points[best][d]) / 2.0;
                    }
                    values[i] = cost(points[i]);
                }
            }
        }
    }
    let best = (0..=n).min_by(|a, b| values[*a].total_cmp(&values[*b])).unwrap_or(0);
    (points[best], values[best])
}

impl Smile {
    /// `None` without a positive forward, a positive time and at least five
    /// usable quotes — too few to say anything about the curve's shape, and a
    /// curve the quotes do not determine is a guess shown as a fact.
    ///
    /// Each quote is weighted by how much its price moves with variance, which
    /// makes this a fit to prices: a far out-of-the-money option worth a
    /// fraction of a dollar says little about the curve, and its mark — the
    /// venue's own extrapolation, not a traded price — is where marks stop
    /// being arbitrage-free (on 2026-09-23 Deribit's next-day 2480/2500/2520
    /// puts marked 0.000268/0.000291/0.000294 ETH, not even convex). The
    /// weight lets those count for what they are worth instead of cutting
    /// them at an arbitrary price.
    pub fn new(forward: f64, years: f64, points: &[SmilePoint]) -> Option<Smile> {
        if !(forward > 0.0) || !forward.is_finite() || !(years > 0.0) {
            return None;
        }
        let mut by_strike: Vec<(f64, f64, u32)> = Vec::new();
        let mut usable: Vec<SmilePoint> = points
            .iter()
            .copied()
            .filter(|p| p.strike > 0.0 && p.iv > 0.0 && p.iv.is_finite() && p.strike.is_finite())
            .collect();
        usable.sort_by(|a, b| a.strike.total_cmp(&b.strike));
        for point in usable {
            match by_strike.last_mut() {
                Some(last) if last.0 == point.strike => {
                    last.1 += point.iv;
                    last.2 += 1;
                }
                _ => by_strike.push((point.strike, point.iv, 1)),
            }
        }
        if by_strike.len() < 5 {
            return None;
        }
        let root = years.sqrt();
        let nodes: Vec<Node> = by_strike
            .iter()
            .map(|(strike, sum, count)| {
                let iv = sum / f64::from(*count);
                let v = iv * root;
                let d1 = ((forward / strike).ln() + v * v / 2.0) / v;
                // Price change per unit of total variance, up to a constant.
                let weight = (normal_pdf(d1) / (2.0 * v)).powi(2);
                ((strike / forward).ln(), iv * iv * years, weight)
            })
            .collect();
        let total: f64 = nodes.iter().map(|n| n.2).sum();
        if !(total > 0.0) || !total.is_finite() {
            return None;
        }
        let nodes: Vec<Node> = nodes.into_iter().map(|(k, w, weight)| (k, w, weight / total)).collect();
        let theta_guess = nodes.iter().min_by(|a, b| a.0.abs().total_cmp(&b.0.abs()))?.1;
        let make = |curve: Curve| {
            let fit_error = nodes
                .iter()
                .map(|&(k, w, weight)| weight * ((curve.total_variance(k).max(0.0) / years).sqrt() - (w / years).sqrt()).powi(2))
                .sum::<f64>()
                .sqrt()
                * 100.0;
            Smile { forward, years, curve, fit_error, quotes: nodes.len() }
        };
        if let Some(svi) = fit_svi(&nodes).map(make) {
            if svi.is_a_distribution() {
                return Some(svi);
            }
        }
        fit_ssvi(&nodes, theta_guess).map(make)
    }

    /// Which curve the fit settled on: "SVI", or "SSVI" when SVI's
    /// distribution was not a distribution.
    pub fn model(&self) -> &'static str {
        match self.curve {
            Curve::Svi { .. } => "SVI",
            Curve::Ssvi { .. } => "SSVI",
        }
    }

    /// Does the curve imply a probability distribution across a wide band of
    /// strikes (log-moneyness ±0.5): cumulative probability never falling
    /// and never leaving [0, 1]?
    fn is_a_distribution(&self) -> bool {
        let mut previous = 0.0;
        for i in 0..=200 {
            let k = -0.5 + f64::from(i) * 0.005;
            let Some(p) = probability_below(self.forward * k.exp(), self, self.forward, self.years) else { return false };
            if !(-1e-9..=1.0 + 1e-9).contains(&p) || p < previous - 1e-9 {
                return false;
            }
            previous = p;
        }
        true
    }

    /// Years to expiry when the curve was quoted.
    pub fn years(&self) -> f64 {
        self.years
    }

    /// Vol at a strike once the forward has moved to `forward`.
    pub fn iv_at(&self, strike: f64, forward: f64) -> Option<f64> {
        vol_at(self, strike, forward)
    }
}

/// Implied vol by log-moneyness, and its slope — what every probability here
/// is read from. One expiry's fitted smile is one; two smiles blended at a
/// horizon between their expiries (`TermSmile`) are another.
pub trait VolCurve {
    /// Vol and its slope `dσ/dk` at log-moneyness `k`.
    fn vol_at_log_moneyness(&self, k: f64) -> (f64, f64);
}

impl VolCurve for Smile {
    fn vol_at_log_moneyness(&self, k: f64) -> (f64, f64) {
        let total = self.curve.total_variance(k).max(1e-12);
        let sigma = (total / self.years).sqrt();
        (sigma, self.curve.slope(k) / (2.0 * sigma * self.years))
    }
}

/// Vol at a strike against a (live) forward, on any curve.
pub fn vol_at<C: VolCurve + ?Sized>(curve: &C, strike: f64, forward: f64) -> Option<f64> {
    if !(strike > 0.0) || !(forward > 0.0) {
        return None;
    }
    Some(curve.vol_at_log_moneyness((strike / forward).ln()).0)
}

/// Where a horizon falls against the expiries it is read from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Placement {
    /// Between two expiries: their total variances are blended.
    Between,
    /// Sooner than the first expiry: that expiry's vols are carried back.
    BeforeFirst,
    /// Later than the last expiry: that expiry's vols are carried forward.
    AfterLast,
}

/// Two expiries' smiles blended at a horizon, linearly in total variance
/// `w = σ²T` at fixed log-moneyness.
///
/// Taking the one expiry nearest a horizon dropped variance the horizon
/// covers: on 2026-09-24 the 24-hour horizon read the next day's expiry,
/// which settles at 15.3 h — before the US data at 20:30 that only the
/// following expiry's variance carries — and put the touch at 5.9% where
/// blending the two gives 8.7% (reported by a parallel session). A day
/// expiry's wings are also shaped for its own maturity, and moving them
/// whole to another is its own distortion.
pub struct TermSmile<'a> {
    near: &'a Smile,
    far: &'a Smile,
    years: f64,
    pub placement: Placement,
}

impl VolCurve for TermSmile<'_> {
    fn vol_at_log_moneyness(&self, k: f64) -> (f64, f64) {
        if self.placement != Placement::Between {
            return self.near.vol_at_log_moneyness(k);
        }
        let weight = ((self.years - self.near.years) / (self.far.years - self.near.years)).clamp(0.0, 1.0);
        let total = |smile: &Smile| -> (f64, f64) {
            let (sigma, slope) = smile.vol_at_log_moneyness(k);
            (sigma * sigma * smile.years, 2.0 * sigma * slope * smile.years)
        };
        let (w1, dw1) = total(self.near);
        let (w2, dw2) = total(self.far);
        let w = (w1 + weight * (w2 - w1)).max(1e-12);
        let dw = dw1 + weight * (dw2 - dw1);
        let sigma = (w / self.years).sqrt();
        (sigma, dw / (2.0 * sigma * self.years))
    }
}

/// The curve for a horizon of `years`, from smiles sorted by their own time
/// to expiry, with the expiries it was read from.
pub fn term_smile<'a, T: Copy>(smiles: &[(T, &'a Smile)], years: f64) -> Option<(TermSmile<'a>, T, Option<T>)> {
    let (first_tag, first) = *smiles.first()?;
    let (last_tag, last) = *smiles.last()?;
    if years <= first.years {
        return Some((TermSmile { near: first, far: first, years, placement: Placement::BeforeFirst }, first_tag, None));
    }
    if years >= last.years {
        return Some((TermSmile { near: last, far: last, years, placement: Placement::AfterLast }, last_tag, None));
    }
    let index = smiles.windows(2).position(|pair| pair[0].1.years <= years && years <= pair[1].1.years)?;
    let (near_tag, near) = smiles[index];
    let (far_tag, far) = smiles[index + 1];
    Some((TermSmile { near, far, years, placement: Placement::Between }, near_tag, Some(far_tag)))
}

/// The horizons liquidation odds are read at, in hours. Declared once: the
/// state reads each of them and the tests walk the same list.
pub const LIQUIDATION_HORIZONS: [f64; 3] = [24.0, 72.0, 168.0];

/// Risk-neutral probability that the underlying settles at or below `strike`.
///
/// The derivative of an undiscounted put price in strike, taken analytically
/// so the smile's slope is included: `P(S ≤ K) = N(−d₂) + F·φ(d₁)·√T·σ'(K)`.
/// The second term is the whole reason a skewed market prices a crash
/// differently from a flat one; dropping it overstates the probability just
/// below spot and understates it in the far tail.
///
/// `forward` is the live forward; `years` the time left, `None` once expired.
pub fn probability_below<C: VolCurve + ?Sized>(strike: f64, smile: &C, forward: f64, years: f64) -> Option<f64> {
    if !(strike > 0.0) || !(forward > 0.0) || !(years > 0.0) {
        return None;
    }
    let (sigma, slope_in_x) = smile.vol_at_log_moneyness((strike / forward).ln());
    let root = years.sqrt();
    let v = sigma * root;
    if !(v > 0.0) {
        return None;
    }
    let d1 = ((forward / strike).ln() + v * v / 2.0) / v;
    let d2 = d1 - v;
    // dσ/dK from dσ/dx: x = ln(K/F), so dx/dK = 1/K.
    let slope_in_strike = slope_in_x / strike;
    let p = normal_cdf(-d2) + forward * normal_pdf(d1) * root * slope_in_strike;
    p.is_finite().then_some(p)
}

/// Settlement probabilities for the ranges a set of price edges cuts out.
#[derive(Debug, Clone, PartialEq)]
pub struct Buckets {
    /// Ascending price edges.
    pub edges: Vec<f64>,
    /// `edges.len() + 1` probabilities: below the first edge, between each
    /// pair, and above the last.
    pub probabilities: Vec<f64>,
    /// Indices into `probabilities` whose raw value came out negative and are
    /// shown as 0. Only possible when the smile is not arbitrage-free (or the
    /// interpolation between two quotes bends the wrong way). Recorded rather
    /// than silently clamped, so the view can say a reading was repaired.
    pub clamped: Vec<usize>,
}

pub fn buckets<C: VolCurve + ?Sized>(edges: &[f64], smile: &C, forward: f64, years: f64) -> Option<Buckets> {
    let mut sorted: Vec<f64> = edges.iter().copied().filter(|e| *e > 0.0).collect();
    sorted.sort_by(f64::total_cmp);
    if sorted.is_empty() {
        return None;
    }
    let mut cumulative = Vec::with_capacity(sorted.len());
    for edge in &sorted {
        cumulative.push(probability_below(*edge, smile, forward, years)?);
    }
    let mut raw = Vec::with_capacity(sorted.len() + 1);
    raw.push(cumulative[0]);
    for pair in cumulative.windows(2) {
        raw.push(pair[1] - pair[0]);
    }
    raw.push(1.0 - cumulative[cumulative.len() - 1]);
    let mut clamped = Vec::new();
    let probabilities = raw
        .into_iter()
        .enumerate()
        .map(|(index, value)| {
            // Rounding at the 1e-12 level is not a negative probability.
            if value < -1e-9 {
                clamped.push(index);
            }
            value.clamp(0.0, 1.0)
        })
        .collect();
    Some(Buckets { edges: sorted, probabilities, clamped })
}

/// Probability of settling at or beyond `target` on its side of the forward:
/// below it when it sits below, above it when above. The answer to "will it
/// get there by expiry" for a max pain twelve per cent under spot.
pub fn probability_beyond<C: VolCurve + ?Sized>(target: f64, smile: &C, forward: f64, years: f64) -> Option<f64> {
    let below = probability_below(target, smile, forward, years)?;
    let beyond = if target < forward { below } else { 1.0 - below };
    Some(beyond.clamp(0.0, 1.0))
}

/// Risk-neutral odds of a position being liquidated before `years`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LiquidationOdds {
    /// Probability the price ends beyond the liquidation level.
    pub at_horizon: f64,
    /// Probability it touches the level at any time before then — what
    /// matters, since a liquidation cannot be undone.
    pub touching: f64,
    /// The smile's vol at the level, as a fraction.
    pub iv: f64,
}

/// Liquidation odds read off the smile at the liquidation level itself.
///
/// The terminal probability is the smile's own, at the level — not a
/// lognormal at the at-the-money vol. On 2026-09-24 a 20× long's liquidation
/// sat 3.7% under spot where the smile's vol was 54% against 37% at the
/// money, and the at-the-money reading put the touch at 1.9% where the smile
/// says 3.5% (reported by a parallel session, and reproduced in the tests
/// below).
///
/// Touching comes from static replication under put–call symmetry (Carr,
/// Ellis & Gupta 1998): a one-touch below the reference is worth
/// `2·P(S ≤ L) − Put(L)/L`, one above it `2·P(S ≥ L) + Call(L)/L`. With flat
/// vol this is exactly the first-passage probability of a driftless price, so
/// a touch below is slightly less than twice the terminal odds and a touch
/// above slightly more — the old "twice the terminal" rule had both wrong.
/// It is still a model: ETH's history (3 years of hours, vol-scaled, measured
/// 2026-09-24) touched a level 3.7–5% below 2.4–2.7 times as often as it
/// closed beyond it, because wicks come back; the screen says so.
///
/// `reference` is the price that triggers the liquidation (the perpetual's
/// mark). A level already crossed is certain: both odds are 1.
pub fn liquidation_odds<C: VolCurve + ?Sized>(level: f64, smile: &C, reference: f64, years: f64, is_short: bool) -> Option<LiquidationOdds> {
    if !(level > 0.0) || !(reference > 0.0) || !(years > 0.0) {
        return None;
    }
    let iv = vol_at(smile, level, reference)?;
    // A short dies above its level, a long below it.
    if (is_short && level <= reference) || (!is_short && level >= reference) {
        return Some(LiquidationOdds { at_horizon: 1.0, touching: 1.0, iv });
    }
    let below = probability_below(level, smile, reference, years)?.clamp(0.0, 1.0);
    let (terminal, touching) = if is_short {
        let call = black_scholes(OptionKind::Call, reference, level, years, iv);
        let terminal = 1.0 - below;
        (terminal, 2.0 * terminal + call / level)
    } else {
        let put = black_scholes(OptionKind::Put, reference, level, years, iv);
        (below, 2.0 * below - put / level)
    };
    Some(LiquidationOdds { at_horizon: terminal, touching: touching.clamp(terminal, 1.0), iv })
}

/// The forward implied by one strike's call and put marks on a venue that
/// quotes options in the coin (Deribit): put–call parity with no rates,
/// `C − P = F − K` in dollars, and coin prices are dollars over `F`. Solving
/// `(C − P)·F = F − K` gives `F = K / (1 − C + P)`.
pub fn parity_forward(strike: f64, call_in_coin: f64, put_in_coin: f64) -> Option<f64> {
    let denominator = 1.0 - call_in_coin + put_in_coin;
    if !(strike > 0.0) || call_in_coin < 0.0 || put_in_coin < 0.0 || !(denominator > 0.0) {
        return None;
    }
    let forward = strike / denominator;
    forward.is_finite().then_some(forward)
}

/// Median of the parity forwards at the `count` strikes nearest `reference`.
/// Several strikes rather than one, because a single pair of marks can be a
/// tick off; the median ignores one bad pair without averaging it in.
pub fn parity_forward_near(pairs: &[(f64, f64, f64)], reference: f64, count: usize) -> Option<f64> {
    let mut ordered: Vec<&(f64, f64, f64)> = pairs.iter().collect();
    ordered.sort_by(|a, b| (a.0 - reference).abs().total_cmp(&(b.0 - reference).abs()));
    let mut estimates: Vec<f64> = ordered
        .into_iter()
        .take(count.max(1))
        .filter_map(|(k, c, p)| parity_forward(*k, *c, *p))
        .collect();
    if estimates.is_empty() {
        return None;
    }
    estimates.sort_by(f64::total_cmp);
    let mid = estimates.len() / 2;
    Some(if estimates.len() % 2 == 1 {
        estimates[mid]
    } else {
        (estimates[mid - 1] + estimates[mid]) / 2.0
    })
}

/// A round step close to `fraction` of spot: 1, 2, 2.5 or 5 times a power of
/// ten. About 3.5% keeps a range near one day's move for a major coin — 100
/// for ETH around 2,700, 5,000 for BTC around 110,000.
pub fn nice_step(spot: f64, fraction: f64) -> Option<f64> {
    if !(spot > 0.0) || !(fraction > 0.0) {
        return None;
    }
    let raw = spot * fraction;
    let magnitude = 10f64.powf(raw.log10().floor());
    [1.0, 2.0, 2.5, 5.0, 10.0]
        .iter()
        .map(|m| m * magnitude)
        .min_by(|a, b| (a - raw).abs().total_cmp(&(b - raw).abs()))
}

/// Price edges around spot: `below` whole steps under the range spot sits in,
/// `above` over it. The grid keeps its anchor until spot has left the anchor
/// range by a quarter step, so a price hovering on an edge does not make every
/// row of the table jump back and forth.
pub fn price_edges(
    spot: f64,
    step: f64,
    previous_anchor: Option<f64>,
    below: i32,
    above: i32,
) -> Option<(f64, Vec<f64>)> {
    if !(spot > 0.0) || !(step > 0.0) {
        return None;
    }
    let mut anchor = (spot / step).floor() * step;
    if let Some(previous) = previous_anchor {
        if spot >= previous - step * 0.25 && spot < previous + step * 1.25 {
            anchor = previous;
        }
    }
    let edges = (-below..=above)
        .map(|k| anchor + f64::from(k) * step)
        .filter(|e| *e > 0.0)
        .collect();
    Some((anchor, edges))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flat(forward: f64, iv: f64) -> Smile {
        let points: Vec<SmilePoint> = [0.6, 0.8, 1.0, 1.25, 1.6].iter().map(|m| SmilePoint { strike: forward * m, iv }).collect();
        Smile::new(forward, 30.0 / 365.0, &points).unwrap()
    }

    /// Deribit's ETH 25SEP26 marks at 2026-09-23 11:38:43 UTC, forward
    /// 2720.05, 44.35 hours before settlement: (strike, mark vol, put mark in
    /// dollars). Taken from the live book rather than invented, so a change in
    /// method fails here instead of producing a plausible new answer.
    const DERIBIT_25SEP: [(f64, f64, Option<f64>); 17] = [
        (2200.0, 1.1304, Some(0.2557)), (2300.0, 0.9267, Some(0.2883)), (2350.0, 0.8812, Some(0.5277)),
        (2400.0, 0.7945, Some(0.6773)), (2450.0, 0.7222, Some(1.0282)), (2500.0, 0.6474, Some(1.5858)),
        (2550.0, 0.5761, Some(2.6656)), (2600.0, 0.5196, Some(5.2877)), (2650.0, 0.4812, Some(11.8048)),
        (2700.0, 0.4670, Some(26.7839)), (2750.0, 0.4711, Some(53.5197)), (2800.0, 0.4964, Some(91.3053)),
        (2850.0, 0.5322, None), (2900.0, 0.5803, None), (3000.0, 0.6589, None), (3100.0, 0.7739, None),
        (3200.0, 0.8821, None),
    ];
    const YEARS_25SEP: f64 = 159_676.2 / (365.0 * 86_400.0);

    fn deribit_25sep() -> (Smile, f64) {
        let points: Vec<SmilePoint> = DERIBIT_25SEP.iter().map(|&(strike, iv, _)| SmilePoint { strike, iv }).collect();
        (Smile::new(2720.05, YEARS_25SEP, &points).unwrap(), YEARS_25SEP)
    }

    #[test]
    fn a_flat_smile_is_plain_black_scholes() {
        let smile = flat(2700.0, 0.5);
        let years = 30.0 / 365.0;
        for strike in [2200.0, 2500.0, 2700.0, 3000.0] {
            let v = 0.5 * f64::sqrt(years);
            let d2 = ((2700.0f64 / strike).ln() - v * v / 2.0) / v;
            let expected = normal_cdf(-d2);
            let got = probability_below(strike, &smile, 2700.0, years).unwrap();
            assert!((got - expected).abs() < 1e-6, "{strike}: {got} vs {expected}");
        }
    }

    #[test]
    fn the_skew_term_matches_a_numerical_derivative_of_the_put() {
        // The analytic form is only worth having if it equals the slope of the
        // put price it claims to be. Check it against a finite difference.
        let (smile, years) = deribit_25sep();
        let put = |k: f64| {
            let sigma = smile.iv_at(k, 2720.05).unwrap();
            crate::options::black_scholes(crate::options::OptionKind::Put, 2720.05, k, years, sigma)
        };
        for strike in [2400.0, 2525.0, 2650.0, 2800.0] {
            let h = 0.01;
            let numeric = (put(strike + h) - put(strike - h)) / (2.0 * h);
            let analytic = probability_below(strike, &smile, 2720.05, years).unwrap();
            assert!((numeric - analytic).abs() < 2e-4, "{strike}: {numeric} vs {analytic}");
        }
    }

    #[test]
    fn the_fit_prices_the_money_where_the_money_is() {
        // Near the money, where the premium is, the fitted curve must price
        // Deribit's own puts to within a few per cent. (The deep wing's marks
        // are Deribit's extrapolation and carry almost no weight.)
        let (smile, years) = deribit_25sep();
        for &(strike, _, mark) in DERIBIT_25SEP.iter().filter(|q| (2550.0..=2700.0).contains(&q.0)) {
            let mark = mark.unwrap();
            let fitted = crate::options::black_scholes(crate::options::OptionKind::Put, 2720.05, strike, years, smile.iv_at(strike, 2720.05).unwrap());
            assert!((fitted - mark).abs() / mark < 0.06, "{strike}: fitted {fitted:.3} vs mark {mark:.3}");
        }
        assert!(smile.fit_error < 1.5, "fit error {} vol points", smile.fit_error);
        assert_eq!(smile.model(), "SVI", "the quarterly's SVI fit is a distribution and is kept");
    }

    #[test]
    fn a_real_smile_integrates_back_to_the_market_put_spreads() {
        // A put spread (P(hi) − P(lo)) / (hi − lo) is the average cumulative
        // probability over [lo, hi] — the market's own number. Over a range
        // wide enough not to be one quote's rounding, the analytic
        // distribution integrated the same way must give it back.
        let (smile, years) = deribit_25sep();
        let average = |lo: f64, hi: f64| {
            let steps = 400;
            let width = (hi - lo) / f64::from(steps);
            (0..steps)
                .map(|i| probability_below(lo + (f64::from(i) + 0.5) * width, &smile, 2720.05, years).unwrap())
                .sum::<f64>()
                / f64::from(steps)
        };
        // Same snapshot: (P2700 − P2500)/200 = 12.60%, (P2500 − P2300)/200 = 0.65%.
        let body = average(2500.0, 2700.0);
        assert!((body - 0.1260).abs() < 0.012, "2500–2700 {body}");
        let tail = average(2300.0, 2500.0);
        assert!((0.002..0.015).contains(&tail), "2300–2500 {tail}");
    }

    #[test]
    fn buckets_partition_the_whole_distribution() {
        let (smile, years) = deribit_25sep();
        let (_, edges) = price_edges(2718.99, 100.0, None, 4, 5).unwrap();
        let result = buckets(&edges, &smile, 2720.05, years).unwrap();
        assert_eq!(result.probabilities.len(), edges.len() + 1);
        let total: f64 = result.probabilities.iter().sum();
        assert!((total - 1.0).abs() < 1e-9, "sum {total}");
        assert!(result.clamped.is_empty(), "a real, arbitrage-free smile needs no repair");
        // The distribution is monotone: each cumulative step is non-negative.
        let mut cumulative = 0.0;
        for p in &result.probabilities {
            assert!(*p >= 0.0);
            cumulative += p;
            assert!(cumulative <= 1.0 + 1e-9);
        }
    }

    #[test]
    fn beyond_reads_the_side_of_the_forward_the_target_is_on() {
        let smile = flat(2700.0, 0.5);
        let years = 2.0 / 365.0;
        let below = probability_beyond(2400.0, &smile, 2700.0, years).unwrap();
        let above = probability_beyond(3000.0, &smile, 2700.0, years).unwrap();
        assert!(below < 0.05 && above < 0.05, "both are tails: {below} {above}");
        let at_the_money = probability_beyond(2700.0, &smile, 2700.0, years).unwrap();
        assert!((at_the_money - 0.5).abs() < 0.02);
    }

    #[test]
    fn parity_recovers_the_forward_from_coin_marks() {
        // Price a call and a put in dollars off a known forward, convert to
        // coin, and ask parity for the forward back.
        let (forward, strike, years, sigma) = (2720.0, 2700.0, 44.0 / 8760.0, 0.47);
        let call = crate::options::black_scholes(crate::options::OptionKind::Call, forward, strike, years, sigma) / forward;
        let put = crate::options::black_scholes(crate::options::OptionKind::Put, forward, strike, years, sigma) / forward;
        let recovered = parity_forward(strike, call, put).unwrap();
        assert!((recovered - forward).abs() < 1e-6, "{recovered}");
        assert_eq!(parity_forward(2700.0, 1.2, 0.0), None, "a denominator ≤ 0 is not a forward");
        let pairs = [(2600.0, 0.0, 0.0), (2700.0, call, put), (2800.0, 0.5, 0.5)];
        assert!((parity_forward_near(&pairs, 2720.0, 1).unwrap() - forward).abs() < 1e-6);
    }

    #[test]
    fn steps_are_round_numbers_near_three_and_a_half_percent() {
        assert_eq!(nice_step(2718.99, 0.035), Some(100.0));
        assert_eq!(nice_step(110_000.0, 0.035), Some(5_000.0));
        assert_eq!(nice_step(0.0, 0.035), None);
    }

    #[test]
    fn edges_hold_their_anchor_while_spot_hovers() {
        let (anchor, edges) = price_edges(2718.0, 100.0, None, 4, 5).unwrap();
        assert_eq!(anchor, 2700.0);
        assert_eq!(edges.first(), Some(&2300.0));
        assert_eq!(edges.last(), Some(&3200.0));
        // A dip just under the anchor keeps it; a real move re-anchors.
        assert_eq!(price_edges(2690.0, 100.0, Some(2700.0), 4, 5).unwrap().0, 2700.0);
        assert_eq!(price_edges(2640.0, 100.0, Some(2700.0), 4, 5).unwrap().0, 2600.0);
        assert_eq!(price_edges(2810.0, 100.0, Some(2700.0), 4, 5).unwrap().0, 2700.0);
        assert_eq!(price_edges(2830.0, 100.0, Some(2700.0), 4, 5).unwrap().0, 2800.0);
    }

    /// Exact first passage of a driftless price through a fixed level.
    fn first_passage(spot: f64, level: f64, sigma: f64, years: f64) -> f64 {
        let v = sigma * years.sqrt();
        let d1 = ((spot / level).ln() + v * v / 2.0) / v;
        let d2 = d1 - v;
        if level < spot {
            normal_cdf(-d2) + spot / level * normal_cdf(-d1)
        } else {
            normal_cdf(d2) + spot / level * normal_cdf(d1)
        }
    }

    #[test]
    fn with_flat_vol_the_touch_is_the_exact_first_passage() {
        let years = 15.5 / 8760.0;
        let smile = flat(2662.0, 0.45);
        for (level, is_short) in [(2564.69, false), (2450.0, false), (2760.0, true), (2900.0, true)] {
            let odds = liquidation_odds(level, &smile, 2662.0, years, is_short).unwrap();
            let exact = first_passage(2662.0, level, 0.45, years);
            assert!((odds.touching - exact).abs() < 1e-5, "{level}: {} vs {exact}", odds.touching);
            // A driftless price touches a level below less than twice as often
            // as it ends beyond it, and one above more than twice.
            if is_short {
                assert!(odds.touching > 2.0 * odds.at_horizon);
            } else {
                assert!(odds.touching < 2.0 * odds.at_horizon);
            }
        }
    }

    #[test]
    fn the_liquidation_level_is_read_off_the_smile_not_the_money() {
        // The reported case: a 20× long, liquidation 2564.69 under 2662, 15.5 h
        // to the day's expiry, 36.9% vol at the money and about 54% at the level.
        let quotes = [(2450.0, 0.70), (2500.0, 0.62), (2550.0, 0.555), (2600.0, 0.47), (2640.0, 0.40),
                      (2662.0, 0.369), (2690.0, 0.37), (2730.0, 0.40), (2780.0, 0.46), (2830.0, 0.53)];
        let points: Vec<SmilePoint> = quotes.iter().map(|&(strike, iv)| SmilePoint { strike, iv }).collect();
        let years = 15.5 / 8760.0;
        let smile = Smile::new(2662.0, years, &points).unwrap();
        let odds = liquidation_odds(2564.69, &smile, 2662.0, years, false).unwrap();
        assert!(odds.iv > 0.5, "vol at the level {}", odds.iv);
        // Bounded on both sides by model-free facts rather than pinned to a
        // number from a smile this one only resembles. Below: the at-the-money
        // reading — the bug — must be well under it. Above: a world flat at the
        // level's own vol, since a smile falling toward the money makes the
        // digital smaller than that world's.
        let at_the_money = first_passage(2662.0, 2564.69, 0.369, years);
        let flat_at_level = first_passage(2662.0, 2564.69, odds.iv, years);
        assert!(odds.touching > 1.5 * at_the_money, "smile {} vs at-the-money {}", odds.touching, at_the_money);
        assert!(odds.touching < flat_at_level, "smile {} vs flat at the level {}", odds.touching, flat_at_level);
    }

    #[test]
    fn touching_is_never_below_ending_beyond_whichever_way_the_smile_leans() {
        let years = 3.0 / 365.0;
        for lean in [-1.0, 1.0] {
            let points: Vec<SmilePoint> = (0..11)
                .map(|i| {
                    let k = -0.25 + 0.05 * f64::from(i);
                    SmilePoint { strike: 2700.0 * f64::exp(k), iv: 0.5 + lean * 0.6 * k + 1.5 * k * k }
                })
                .collect();
            let smile = Smile::new(2700.0, years, &points).unwrap();
            for (level, is_short) in [(2500.0, false), (2600.0, false), (2800.0, true), (2950.0, true)] {
                let odds = liquidation_odds(level, &smile, 2700.0, years, is_short).unwrap();
                assert!(odds.touching >= odds.at_horizon && odds.touching <= 1.0, "lean {lean} {level}: {odds:?}");
            }
        }
    }

    #[test]
    fn farther_and_sooner_are_less_likely_and_a_crossed_level_is_certain() {
        let smile = flat(2600.0, 0.5);
        let near = liquidation_odds(2700.0, &smile, 2600.0, 1.0 / 365.0, true).unwrap();
        let far = liquidation_odds(3400.0, &smile, 2600.0, 1.0 / 365.0, true).unwrap();
        assert!(far.touching < near.touching && far.touching < 0.01);
        let week = liquidation_odds(2800.0, &smile, 2600.0, 7.0 / 365.0, true).unwrap();
        let day = liquidation_odds(2800.0, &smile, 2600.0, 1.0 / 365.0, true).unwrap();
        assert!(week.touching > day.touching);
        // A short's level below the mark has already been passed.
        assert_eq!(liquidation_odds(2300.0, &smile, 2600.0, 1.0 / 365.0, true).unwrap().touching, 1.0);
        assert!(liquidation_odds(2300.0, &smile, 2600.0, 0.0, true).is_none());
    }

    fn skewed(forward: f64, years: f64, level: f64) -> Smile {
        let points: Vec<SmilePoint> = (0..11)
            .map(|i| {
                let k = -0.25 + 0.05 * f64::from(i);
                SmilePoint { strike: forward * f64::exp(k), iv: level - 0.6 * k + 1.5 * k * k }
            })
            .collect();
        Smile::new(forward, years, &points).unwrap()
    }

    #[test]
    fn a_flat_term_structure_blends_to_the_same_curve() {
        // Same vols at both expiries (total variance ∝ T): every declared
        // horizon between them must read exactly the single curve.
        let near = skewed(2662.0, 15.0 / 8760.0, 0.45);
        let far = skewed(2662.0, 240.0 / 8760.0, 0.45);
        let smiles = [(1, &near), (2, &far)];
        for hours in LIQUIDATION_HORIZONS {
            let years = hours / 8760.0;
            let (curve, near_tag, far_tag) = term_smile(&smiles, years).unwrap();
            assert_eq!((curve.placement, near_tag, far_tag), (Placement::Between, 1, Some(2)));
            let blended = liquidation_odds(2564.69, &curve, 2662.0, years, false).unwrap();
            let single = liquidation_odds(2564.69, &near, 2662.0, years, false).unwrap();
            assert!((blended.touching - single.touching).abs() < 1e-3, "{hours}h: {} vs {}", blended.touching, single.touching);
        }
    }

    #[test]
    fn more_variance_in_the_later_expiry_raises_a_horizon_between_them() {
        let near = skewed(2662.0, 15.0 / 8760.0, 0.40);
        let calm = skewed(2662.0, 240.0 / 8760.0, 0.40);
        let eventful = skewed(2662.0, 240.0 / 8760.0, 0.55);
        for hours in LIQUIDATION_HORIZONS {
            let years = hours / 8760.0;
            let (calm_curve, _, _) = term_smile(&[(1, &near), (2, &calm)], years).unwrap();
            let (event_curve, _, _) = term_smile(&[(1, &near), (2, &eventful)], years).unwrap();
            let before = liquidation_odds(2564.69, &calm_curve, 2662.0, years, false).unwrap();
            let after = liquidation_odds(2564.69, &event_curve, 2662.0, years, false).unwrap();
            assert!(after.touching > before.touching, "{hours}h: {} vs {}", after.touching, before.touching);
        }
    }

    #[test]
    fn horizons_outside_the_expiries_say_so() {
        let near = skewed(2662.0, 30.0 / 8760.0, 0.45);
        let far = skewed(2662.0, 100.0 / 8760.0, 0.45);
        let smiles = [(1, &near), (2, &far)];
        let (early, tag, _) = term_smile(&smiles, 24.0 / 8760.0).unwrap();
        assert_eq!((early.placement, tag), (Placement::BeforeFirst, 1));
        let (late, tag, _) = term_smile(&smiles, 168.0 / 8760.0).unwrap();
        assert_eq!((late.placement, tag), (Placement::AfterLast, 2));
        assert!(term_smile::<i32>(&[], 0.1).is_none());
    }

    #[test]
    fn a_smile_needs_a_forward_and_five_quotes() {
        let four: Vec<SmilePoint> = [2400.0, 2600.0, 2800.0, 3000.0].iter().map(|&strike| SmilePoint { strike, iv: 0.5 }).collect();
        assert!(Smile::new(2700.0, 0.1, &four).is_none(), "four quotes cannot pin five parameters");
        assert!(Smile::new(0.0, 0.1, &four).is_none());
        assert_eq!(probability_below(2700.0, &flat(2700.0, 0.5), 2700.0, 0.0), None);
    }

    #[test]
    fn the_fit_recovers_a_known_smile() {
        // Quotes generated from a known arbitrage-free curve come back almost exactly.
        let years = 7.0 / 365.0;
        let truth = Curve::Ssvi { theta: 0.004, rho: -0.3, phi: 8.0 };
        let points: Vec<SmilePoint> = (0..15)
            .map(|i| {
                let k = -0.35 + 0.05 * f64::from(i);
                SmilePoint { strike: 2700.0 * k.exp(), iv: (truth.total_variance(k) / years).sqrt() }
            })
            .collect();
        let smile = Smile::new(2700.0, years, &points).unwrap();
        assert!(smile.fit_error < 0.05, "fit error {} vol points", smile.fit_error);
    }

    #[test]
    fn noisy_wings_do_not_produce_negative_ranges() {
        // The shape that broke the threaded curve: near-equal wing vols with a
        // kink, as tick-rounded marks produce.
        let quotes = [(2480.0, 0.855), (2500.0, 0.789), (2520.0, 0.712), (2540.0, 0.657), (2560.0, 0.595),
                      (2580.0, 0.539), (2600.0, 0.486), (2620.0, 0.444), (2640.0, 0.412), (2660.0, 0.401),
                      (2680.0, 0.397), (2700.0, 0.405), (2720.0, 0.431), (2740.0, 0.470), (2760.0, 0.515)];
        let points: Vec<SmilePoint> = quotes.iter().map(|&(strike, iv)| SmilePoint { strike, iv }).collect();
        let smile = Smile::new(2682.6, 16.7 / 8760.0, &points).unwrap();
        let (_, edges) = price_edges(2680.0, 100.0, None, 4, 5).unwrap();
        let result = buckets(&edges, &smile, 2682.6, 16.7 / 8760.0).unwrap();
        assert!(result.clamped.is_empty(), "clamped {:?} of {:?}", result.clamped, result.probabilities);
        assert_eq!(smile.model(), "SSVI", "SVI's wings on this smile are not a distribution; the fallback must be taken");
    }
}
