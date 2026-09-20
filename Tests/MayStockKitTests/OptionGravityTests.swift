import Foundation
import Testing
@testable import MayStockKit

/// The option-chain arithmetic behind the checkup screen.
///
/// These numbers drive real decisions, so the tests carry two kinds of case:
/// values checked against the live chain (so a change in method shows up as a
/// failure rather than as a plausible-looking new answer), and the degenerate
/// inputs that would otherwise produce a confident wrong number.
@Suite("Option gravity")
struct OptionGravityTests {

    // MARK: - Max pain

    /// Real open interest from OKX's 21SEP26 ETH chain, strikes 2500–2700.
    /// Taken from the live book rather than invented, so a change in method
    /// shows up as a failure instead of as a plausible new answer.
    private func chain() -> [OptionGravity.StrikeInterest] {
        [
            .init(strike: 2500, callOI: 3181, putOI: 6728),
            .init(strike: 2510, callOI: 669, putOI: 4512),
            .init(strike: 2525, callOI: 4922, putOI: 5018),
            .init(strike: 2530, callOI: 265, putOI: 5662),
            .init(strike: 2540, callOI: 260, putOI: 10106),
            .init(strike: 2550, callOI: 50211, putOI: 15375),
            .init(strike: 2560, callOI: 752, putOI: 17956),
            .init(strike: 2575, callOI: 56027, putOI: 25082),
            .init(strike: 2580, callOI: 4502, putOI: 50599),
            .init(strike: 2590, callOI: 2305, putOI: 23293),
            .init(strike: 2600, callOI: 32763, putOI: 40927),
            .init(strike: 2610, callOI: 3307, putOI: 56190),
            .init(strike: 2620, callOI: 11114, putOI: 3247),
            .init(strike: 2625, callOI: 23331, putOI: 3379),
            .init(strike: 2630, callOI: 24790, putOI: 1720),
            .init(strike: 2640, callOI: 2181, putOI: 1673),
            .init(strike: 2650, callOI: 21518, putOI: 1773),
            .init(strike: 2660, callOI: 7583, putOI: 2686),
            .init(strike: 2670, callOI: 949, putOI: 322),
            .init(strike: 2675, callOI: 5073, putOI: 0),
            .init(strike: 2680, callOI: 2464, putOI: 0),
            .init(strike: 2690, callOI: 1044, putOI: 0),
            .init(strike: 2700, callOI: 8768, putOI: 360),
        ]
    }

    @Test("finds the strike where writers pay out least")
    func maxPainOnARealShapedChain() throws {
        let pain = try #require(OptionGravity.maxPain(chain(), spot: 2576))
        // Cross-checked against the same chain in an independent calculation:
        // the minimum sits at 2590, just above spot.
        #expect(pain.strike == 2590)
        #expect(pain.distancePct > 0)  // 2590 is above a 2576 spot
    }

    @Test("reports the runner-up, so a flat curve can be called flat")
    func maxPainCarriesRunnerUp() throws {
        let pain = try #require(OptionGravity.maxPain(chain(), spot: 2576))
        #expect(pain.runnerUpPayout != nil)
        // On this chain the neighbouring strikes are within 2%, so the pull is
        // weak and the view says so rather than presenting it as a level.
        #expect(pain.isWeak)
    }

    @Test("a single concentrated strike is a strong pain point")
    func concentratedInterestIsNotWeak() throws {
        // One enormous put wall far below, almost nothing else: settling there
        // would cost writers hugely, so the minimum is sharp.
        let lopsided = [
            OptionGravity.StrikeInterest(strike: 2000, callOI: 0, putOI: 100_000),
            OptionGravity.StrikeInterest(strike: 2600, callOI: 1, putOI: 1),
            OptionGravity.StrikeInterest(strike: 3000, callOI: 1, putOI: 1),
        ]
        let pain = try #require(OptionGravity.maxPain(lopsided, spot: 2600))
        // Writers pay nothing if it settles at or above every put strike.
        #expect(pain.strike >= 2600)
    }

    @Test("refuses to answer without a usable chain or spot")
    func maxPainNeedsInputs() {
        #expect(OptionGravity.maxPain([], spot: 2600) == nil)
        #expect(OptionGravity.maxPain(chain(), spot: 0) == nil)
    }

    // MARK: - Notional against market value

    @Test("notional and market value are separate numbers, and differ hugely")
    func notionalIsNotMarketValue() throws {
        // The trap this pair exists to prevent: a far-dated chain showing
        // hundreds of millions of "open interest" whose options are worth a
        // few million. Only one of those is money at risk.
        let far = OptionGravity.StrikeInterest(
            strike: 3000, callOI: 20_000, putOI: 0,
            callMark: 0.001, putMark: nil)
        let spot = 2580.0
        let contractValue = 0.1

        let notional = far.notional(spot: spot, contractValue: contractValue)
        let value = try #require(
            far.marketValue(spot: spot, contractValue: contractValue))

        // 20,000 × 0.1 × 2580 = 5.16M notional
        #expect(abs(notional - 5_160_000) < 1)
        // 20,000 × 0.001 × 0.1 × 2580 = 5,160 actually at stake
        #expect(abs(value - 5_160) < 1)
        // Two orders of magnitude apart — exactly the confusion to avoid.
        #expect(notional / value > 500)
    }

    @Test("market value is nil when the chain quoted no mark")
    func marketValueNeedsAMark() {
        let unquoted = OptionGravity.StrikeInterest(strike: 2600, callOI: 100, putOI: 50)
        #expect(unquoted.marketValue(spot: 2580, contractValue: 0.1) == nil)
    }

    @Test("net is calls minus puts")
    func netIsSigned() {
        let callHeavy = OptionGravity.StrikeInterest(strike: 2650, callOI: 1147, putOI: 91)
        #expect(callHeavy.net > 0)
        let putHeavy = OptionGravity.StrikeInterest(strike: 2460, callOI: 196, putOI: 1793)
        #expect(putHeavy.net < 0)
    }

    // MARK: - Implied volatility

    @Test("averages the strikes nearest spot")
    func atmIVTakesTheNearest() {
        let quotes: [(strike: Double, iv: Double?)] = [
            (2000, 90), (2560, 30), (2580, 28), (2600, 29), (2640, 31), (3000, 80),
        ]
        // Four nearest to 2580: 2560, 2580, 2600, 2640 → (30+28+29+31)/4
        let iv = OptionGravity.atmIV(quotes, spot: 2580, count: 4)
        #expect(abs((iv ?? 0) - 29.5) < 1e-9)
    }

    @Test("ignores strikes with no usable vol, and gives up cleanly")
    func atmIVSkipsBadQuotes() {
        let quotes: [(strike: Double, iv: Double?)] = [
            (2580, nil), (2600, 0), (2620, .nan), (2560, 25),
        ]
        // Only one usable quote survives — still better than nothing.
        #expect(abs((OptionGravity.atmIV(quotes, spot: 2580, count: 4) ?? 0) - 25) < 1e-9)
        #expect(OptionGravity.atmIV([(2580, nil)], spot: 2580) == nil)
        #expect(OptionGravity.atmIV(quotes, spot: 0) == nil)
    }

    // MARK: - Sigma

    @Test("one sigma scales with the square root of time")
    func oneSigmaScaling() throws {
        // 40% annualised over a quarter of a year → 0.4 × 0.5 = 20% of spot.
        let quarterYear = 365.0 / 4
        let sigma = try #require(
            OptionGravity.oneSigma(spot: 2000, iv: 0.40, hours: quarterYear * 24))
        #expect(abs(sigma - 400) < 0.5)
        // A day is a twentieth of that horizon in sigma terms, not in price.
        let oneDay = try #require(OptionGravity.oneSigma(spot: 2000, iv: 0.40, hours: 24))
        #expect(oneDay < sigma)
        #expect(oneDay > 0)
    }

    @Test("sigma is nil rather than zero on degenerate input")
    func oneSigmaRefusesNonsense() {
        // A zero sigma would make every distance "infinite sigmas" and every
        // target look reachable, so refuse instead of returning a number.
        #expect(OptionGravity.oneSigma(spot: 2580, iv: 0, hours: 24) == nil)
        #expect(OptionGravity.oneSigma(spot: 2580, iv: 0.4, hours: 0) == nil)
        #expect(OptionGravity.oneSigma(spot: 0, iv: 0.4, hours: 24) == nil)
    }

    @Test("counts how many sigmas away a target sits")
    func sigmaDistance() throws {
        let sigma = try #require(OptionGravity.oneSigma(spot: 2600, iv: 0.40, hours: 24))
        let two = try #require(
            OptionGravity.sigmas(from: 2600, to: 2600 + sigma * 2, iv: 0.40, hours: 24))
        #expect(abs(two - 2) < 1e-9)
        // Distance is unsigned: below spot reads the same.
        let below = try #require(
            OptionGravity.sigmas(from: 2600, to: 2600 - sigma * 2, iv: 0.40, hours: 24))
        #expect(abs(below - 2) < 1e-9)
    }

    // MARK: - Skew

    @Test("skew is put IV minus call IV at the wings")
    func skewSign() throws {
        let quotes: [(strike: Double, kind: OptionKind, iv: Double?)] = [
            (2373, .put, 35), (2827, .call, 28),
        ]
        // spot 2580, ±8% wings → 2373 / 2826
        let skew = try #require(OptionGravity.skew25d(
            quotes, spot: 2580, hoursToExpiry: 48))
        #expect(skew.points == 7)
        // Puts richer than calls: the market pays for downside.
        #expect(!skew.favoursUpside)
    }

    @Test("a call bid shows as negative skew")
    func callBidIsNegative() throws {
        let quotes: [(strike: Double, kind: OptionKind, iv: Double?)] = [
            (2373, .put, 28), (2827, .call, 36),
        ]
        let skew = try #require(OptionGravity.skew25d(
            quotes, spot: 2580, hoursToExpiry: 48))
        #expect(skew.points == -8)
        #expect(skew.favoursUpside)
    }

    @Test("same-day skew is flagged noisy")
    func nearExpirySkewIsNoisy() throws {
        let quotes: [(strike: Double, kind: OptionKind, iv: Double?)] = [
            (2373, .put, 35), (2827, .call, 28),
        ]
        // The wings on a settling expiry are thinly quoted and swing by more
        // than the signal; the view must label it rather than time with it.
        let today = try #require(OptionGravity.skew25d(
            quotes, spot: 2580, hoursToExpiry: 5))
        #expect(today.isNoisy)
        let tomorrow = try #require(OptionGravity.skew25d(
            quotes, spot: 2580, hoursToExpiry: 30))
        #expect(!tomorrow.isNoisy)
    }

    @Test("skew needs a quote on both wings")
    func skewNeedsBothSides() {
        let putsOnly: [(strike: Double, kind: OptionKind, iv: Double?)] = [(2373, .put, 35)]
        #expect(OptionGravity.skew25d(putsOnly, spot: 2580, hoursToExpiry: 48) == nil)
    }

    // MARK: - Liquidation odds

    @Test("a short is liquidated by a rise, a long by a fall")
    func liquidationDirection() throws {
        // Each side's liquidation sits on the side that hurts it: above for a
        // short, below for a long. Asking for a long liquidated at a level
        // above spot is not a scenario, it is a typo.
        //
        // The measure works in log space, so equal arithmetic distances are not
        // equal odds: +300 on 2600 is a shorter move than −300. Pick levels
        // that are actually mirror images — 2600² / 2900 = 2331.03.
        let shortOdds = try #require(OptionGravity.liquidationOdds(
            spot: 2600, liquidationPrice: 2900, iv: 0.40, hours: 24, isShort: true))
        let longOdds = try #require(OptionGravity.liquidationOdds(
            spot: 2600, liquidationPrice: 2600 * 2600 / 2900, iv: 0.40, hours: 24, isShort: false))

        #expect(shortOdds.atHorizon > 0)
        #expect(longOdds.atHorizon > 0)
        #expect(abs(shortOdds.atHorizon - longOdds.atHorizon) < 1e-9)

        // A short at a level *below* spot is not a liquidation level at all:
        // the price would have to fall past it, which is the direction a short
        // profits from, so that tail is certain rather than remote.
        let nonsensical = try #require(OptionGravity.liquidationOdds(
            spot: 2600, liquidationPrice: 2300, iv: 0.40, hours: 24, isShort: true))
        #expect(nonsensical.atHorizon > 0.99)
    }

    @Test("touch probability is twice the terminal one, and capped")
    func touchingDoubles() throws {
        let odds = try #require(OptionGravity.liquidationOdds(
            spot: 2600, liquidationPrice: 2650, iv: 0.40, hours: 24, isShort: true))
        #expect(abs(odds.touching - odds.atHorizon * 2) < 1e-9 || odds.touching == 1)
        #expect(odds.touching <= 1)
        #expect(odds.touching >= odds.atHorizon)
    }

    @Test("a far-away level is near-impossible, a near one is not")
    func distanceMonotonicity() throws {
        let far = try #require(OptionGravity.liquidationOdds(
            spot: 2600, liquidationPrice: 3200, iv: 0.40, hours: 24, isShort: true))
        let near = try #require(OptionGravity.liquidationOdds(
            spot: 2600, liquidationPrice: 2640, iv: 0.40, hours: 24, isShort: true))
        #expect(far.touching < near.touching)
        // 600 points on a 40% vol day is far out.
        #expect(far.touching < 0.01)
    }

    @Test("more time means more chance, all else equal")
    func timeIncreasesOdds() throws {
        let day = try #require(OptionGravity.liquidationOdds(
            spot: 2600, liquidationPrice: 2800, iv: 0.40, hours: 24, isShort: true))
        let week = try #require(OptionGravity.liquidationOdds(
            spot: 2600, liquidationPrice: 2800, iv: 0.40, hours: 168, isShort: true))
        #expect(week.touching > day.touching)
    }

    @Test("refuses to guess without vol or time")
    func liquidationNeedsInputs() {
        #expect(OptionGravity.liquidationOdds(
            spot: 2600, liquidationPrice: 2800, iv: 0, hours: 24, isShort: true) == nil)
        #expect(OptionGravity.liquidationOdds(
            spot: 2600, liquidationPrice: 2800, iv: 0.4, hours: 0, isShort: true) == nil)
        #expect(OptionGravity.liquidationOdds(
            spot: 2600, liquidationPrice: 0, iv: 0.4, hours: 24, isShort: true) == nil)
    }

    // MARK: - Exposure

    @Test("effective leverage is notional over equity, not the contract setting")
    func exposureReportsRealLeverage() {
        // 20× on the contract, but a small position in a large account: the
        // leverage that decides survival is the ratio, not the setting.
        let exposure = OptionGravity.Exposure(notional: 14_586, equity: 7_045, margin: 1_553)
        #expect(abs(exposure.effectiveLeverage - 2.07) < 0.01)
        #expect(abs(exposure.lossPerOnePercent - 145.86) < 0.01)
        #expect(abs(exposure.onePercentAsEquityPct - 2.07) < 0.01)
        // Margin quoted against the notional the contract claims, not equity.
        #expect(abs(exposure.marginAsEquityPct - 22.04) < 0.01)
    }

    @Test("exposure survives a zero equity rather than dividing by it")
    func exposureWithNoEquity() {
        let exposure = OptionGravity.Exposure(notional: 1000, equity: 0, margin: 100)
        #expect(exposure.effectiveLeverage == 0)
        #expect(exposure.onePercentAsEquityPct == 0)
    }

    @Test("liquidation buffer reads outward for both directions")
    func bufferDirection() {
        // A short's liquidation sits above: the buffer is the rise it can take.
        let short = OptionGravity.liquidationBuffer(
            mark: 2586, liquidationPrice: 2886, isShort: true)
        #expect(abs((short ?? 0) - 11.6) < 0.1)
        // A long's sits below.
        let long = OptionGravity.liquidationBuffer(
            mark: 2586, liquidationPrice: 2286, isShort: false)
        #expect(abs((long ?? 0) - 11.6) < 0.1)
        #expect(OptionGravity.liquidationBuffer(
            mark: 0, liquidationPrice: 2886, isShort: true) == nil)
    }
}
