import Foundation

/// The option-chain arithmetic a position review keeps asking for: where the
/// book's own pain point sits, how wide a move the market is pricing, and how
/// close a position is to being liquidated.
///
/// Every function here is pure — no network, no clock beyond what the caller
/// passes in — so the numbers on screen can be reproduced exactly in a test.
/// That matters because these drive real decisions: a wrong max-pain or a
/// mis-scaled sigma is worse than no number at all, since it reads as fact.
public enum OptionGravity {

    // MARK: - One strike's open interest

    /// Open interest at a strike, split by side, with **both** the notional and
    /// what the contracts are actually worth.
    ///
    /// Keeping those apart is the whole point. A chain can show two billion
    /// dollars of "open interest" whose options are worth a hundred and fifty
    /// thousand — deep out-of-the-money lottery tickets and cheap tail
    /// insurance. Reading the notional as money at risk turns a rounding error
    /// into a thesis, which is exactly the mistake this type exists to prevent.
    public struct StrikeInterest: Sendable, Equatable, Identifiable {
        public let strike: Double
        public let callOI: Double
        public let putOI: Double
        /// Mark price per contract, in the settlement coin, when known.
        public let callMark: Double?
        public let putMark: Double?

        /// A strike is unique within one expiry, which is the only way these
        /// are ever grouped.
        public var id: Double { strike }

        public init(
            strike: Double, callOI: Double, putOI: Double,
            callMark: Double? = nil, putMark: Double? = nil
        ) {
            self.strike = strike
            self.callOI = callOI
            self.putOI = putOI
            self.callMark = callMark
            self.putMark = putMark
        }

        public var totalOI: Double { callOI + putOI }
        /// Calls minus puts. Positive means the strike is call-heavy.
        public var net: Double { callOI - putOI }

        /// Underlying value the contracts here represent, in quote currency.
        /// **Not** money anyone has put up.
        public func notional(spot: Double, contractValue: Double) -> Double {
            totalOI * contractValue * spot
        }

        /// What the open contracts are actually worth right now, in quote
        /// currency. Nil when the chain did not quote a mark for either side.
        public func marketValue(spot: Double, contractValue: Double) -> Double? {
            guard callMark != nil || putMark != nil else { return nil }
            let calls = callOI * (callMark ?? 0)
            let puts = putOI * (putMark ?? 0)
            return (calls + puts) * contractValue * spot
        }
    }

    // MARK: - Max pain

    public struct MaxPain: Sendable, Equatable {
        /// The strike where option writers pay out least in total.
        public let strike: Double
        /// That minimum payout, in contracts × points.
        public let payout: Double
        /// How far it sits from spot, as a percentage.
        public let distancePct: Double
        /// Payout at the runner-up strike. Close to `payout` means the pull is
        /// weak and the level should not be leaned on.
        public let runnerUpPayout: Double?

        /// True when the next-best strike is within 5% of the minimum — the
        /// curve is flat, so no single price is meaningfully favoured.
        public var isWeak: Bool {
            guard let runnerUpPayout, payout > 0 else { return true }
            return (runnerUpPayout - payout) / payout < 0.05
        }
    }

    /// The strike that minimises total writer payout at expiry.
    ///
    /// This is a statistic, not a forecast: it says where price would have to
    /// settle for option sellers to owe the least, and dealers' delta hedging
    /// tends to offer least resistance there. It is routinely overrun by real
    /// flow — treat `isWeak` and the distance as part of the reading.
    public static func maxPain(_ interests: [StrikeInterest], spot: Double) -> MaxPain? {
        let strikes = interests.map(\.strike).sorted()
        guard !strikes.isEmpty, spot > 0 else { return nil }

        var best: (strike: Double, payout: Double)?
        var runnerUp: Double?
        for settle in strikes {
            var payout = 0.0
            for row in interests {
                // A call writer pays when settlement is above the strike.
                if settle > row.strike { payout += (settle - row.strike) * row.callOI }
                // A put writer pays when it is below.
                if settle < row.strike { payout += (row.strike - settle) * row.putOI }
            }
            if let current = best {
                if payout < current.payout {
                    runnerUp = current.payout
                    best = (settle, payout)
                } else if runnerUp == nil || payout < runnerUp! {
                    runnerUp = payout
                }
            } else {
                best = (settle, payout)
            }
        }
        guard let best else { return nil }
        return MaxPain(
            strike: best.strike, payout: best.payout,
            distancePct: (best.strike / spot - 1) * 100,
            runnerUpPayout: runnerUp)
    }

    // MARK: - Implied volatility

    /// Average implied volatility of the strikes nearest spot, as a fraction
    /// (0.32 for 32%). Nil when nothing near the money carries a quote.
    ///
    /// - Parameter count: how many nearest strikes to average, per side of the
    ///   book as the chain supplies them.
    public static func atmIV(
        _ quotes: [(strike: Double, iv: Double?)], spot: Double, count: Int = 4
    ) -> Double? {
        guard spot > 0 else { return nil }
        let usable = quotes
            .compactMap { q -> (Double, Double)? in
                guard let iv = q.iv, iv > 0, iv.isFinite else { return nil }
                return (abs(q.strike - spot), iv)
            }
            .sorted { $0.0 < $1.0 }
            .prefix(max(1, count))
        guard !usable.isEmpty else { return nil }
        return usable.map(\.1).reduce(0, +) / Double(usable.count)
    }

    /// One standard deviation of price over `hours`, in quote currency.
    ///
    /// The single most useful sanity check on a target: a level inside 1σ is
    /// noise, and a level beyond 3σ is a wish. Annualised IV is scaled by the
    /// square root of the fraction of a year remaining.
    public static func oneSigma(spot: Double, iv: Double, hours: Double) -> Double? {
        guard spot > 0, iv > 0, hours > 0 else { return nil }
        return spot * iv * (hours / 24 / 365).squareRoot()
    }

    /// How many sigmas away a price sits. Nil when there is no usable vol.
    public static func sigmas(
        from spot: Double, to target: Double, iv: Double, hours: Double
    ) -> Double? {
        guard let sigma = oneSigma(spot: spot, iv: iv, hours: hours), sigma > 0 else { return nil }
        return abs(target - spot) / sigma
    }

    // MARK: - Skew

    /// 25-delta skew: put IV minus call IV, in IV points. Positive means the
    /// market pays up for downside protection.
    ///
    /// **Unreliable on same-day expiries.** The wings there are thinly quoted
    /// and this number swings by more than its own signal — a full sixteen
    /// points inside one evening, with no corresponding move in price. Show it,
    /// label it, and do not time anything with it; see `isNoisy`.
    public struct Skew: Sendable, Equatable {
        public let points: Double
        public let hoursToExpiry: Double

        /// True when the expiry is too near for the wings to mean anything.
        public var isNoisy: Bool { hoursToExpiry < 24 }
        /// Negative skew is a call bid — the market paying up for upside.
        public var favoursUpside: Bool { points < 0 }
    }

    /// Put IV minus call IV at roughly 25 delta, approximated by strikes about
    /// 8% either side of spot when the chain carries no deltas.
    public static func skew25d(
        _ quotes: [(strike: Double, kind: OptionKind, iv: Double?)],
        spot: Double, hoursToExpiry: Double, wingPct: Double = 8
    ) -> Skew? {
        guard spot > 0 else { return nil }
        let putTarget = spot * (1 - wingPct / 100)
        let callTarget = spot * (1 + wingPct / 100)

        func nearestIV(_ kind: OptionKind, to target: Double) -> Double? {
            quotes
                .filter { $0.kind == kind && ($0.iv ?? 0) > 0 }
                .min { abs($0.strike - target) < abs($1.strike - target) }?
                .iv
        }
        guard let putIV = nearestIV(.put, to: putTarget),
              let callIV = nearestIV(.call, to: callTarget)
        else { return nil }
        // IV arrives as a percentage on OKX and Deribit alike; keep those units.
        return Skew(points: putIV - callIV, hoursToExpiry: hoursToExpiry)
    }

    // MARK: - Liquidation

    public struct LiquidationOdds: Sendable, Equatable {
        public let hours: Double
        /// Probability the price is beyond the liquidation level *at* the
        /// horizon.
        public let atHorizon: Double
        /// Probability it touches the level at any point before then —
        /// what actually matters, since a liquidation is irreversible.
        public let touching: Double
    }

    /// Risk-neutral odds of a position being liquidated, from implied vol.
    ///
    /// Touch probability uses the reflection principle for driftless Brownian
    /// motion, which makes it twice the terminal probability (capped at 1).
    /// That is an approximation — it ignores drift and the funding carry — but
    /// it errs toward caution, and understating a liquidation risk is the one
    /// direction that cannot be tolerated.
    ///
    /// - Parameters:
    ///   - isShort: a short is liquidated by a rise, a long by a fall.
    public static func liquidationOdds(
        spot: Double, liquidationPrice: Double, iv: Double, hours: Double, isShort: Bool
    ) -> LiquidationOdds? {
        guard spot > 0, liquidationPrice > 0, iv > 0, hours > 0 else { return nil }
        let sigma = iv * (hours / 24 / 365).squareRoot()
        guard sigma > 0 else { return nil }
        let z = (log(liquidationPrice / spot)) / sigma
        // A short dies above the level, a long below it.
        let terminal = isShort ? 1 - normalCDF(z) : normalCDF(z)
        return LiquidationOdds(
            hours: hours, atHorizon: terminal, touching: Swift.min(1, terminal * 2))
    }

    /// Standard normal CDF.
    static func normalCDF(_ x: Double) -> Double {
        0.5 * (1 + erf(x / 2.0.squareRoot()))
    }

    // MARK: - Exposure

    /// What a position actually risks, as opposed to what its leverage setting
    /// says.
    ///
    /// The contract can read 20× while the account is barely levered, or the
    /// reverse. What decides survival is notional against equity, so that is
    /// the number worth showing.
    public struct Exposure: Sendable, Equatable {
        /// Position notional in quote currency.
        public let notional: Double
        public let equity: Double
        /// Margin the exchange has locked for the position.
        public let margin: Double

        /// Notional ÷ equity. The leverage that matters.
        public var effectiveLeverage: Double { equity > 0 ? notional / equity : 0 }
        /// Quote-currency P&L from a 1% move in the underlying.
        public var lossPerOnePercent: Double { notional * 0.01 }
        /// That loss as a share of equity.
        public var onePercentAsEquityPct: Double {
            equity > 0 ? lossPerOnePercent / equity * 100 : 0
        }
        public var marginAsEquityPct: Double {
            equity > 0 ? margin / equity * 100 : 0
        }

        public init(notional: Double, equity: Double, margin: Double) {
            self.notional = notional
            self.equity = equity
            self.margin = margin
        }
    }

    /// Distance to liquidation as a percentage of the mark. Positive for a
    /// short (whose liquidation sits above) and for a long (below).
    public static func liquidationBuffer(
        mark: Double, liquidationPrice: Double, isShort: Bool
    ) -> Double? {
        guard mark > 0, liquidationPrice > 0 else { return nil }
        return isShort ? (liquidationPrice / mark - 1) * 100 : (1 - liquidationPrice / mark) * 100
    }
}
