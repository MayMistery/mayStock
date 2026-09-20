import Foundation

/// Turning "the account is short the settlement coin" into the one spot order
/// that fixes it.
///
/// A bought option is paid for in its settlement coin — ETH for an ETH option —
/// while the account may hold only USDT. `OptionPremiumFunding` already answers
/// whether the coin is there and by how much it falls short; it deliberately
/// converts nothing. This type is the missing step: it sizes the spot buy that
/// covers the shortfall, so a proposal can be confirmed once and executed in
/// two steps rather than failing at the exchange with a margin error.
///
/// **The amount carries no arbitrary padding.** An earlier hand-rolled version
/// of this added 15% "just in case" and bought ~19 USD of ETH nobody needed.
/// Nothing here is uncertain enough to justify a buffer: the premium is capped
/// by the limit price the order will carry, and the fee is a deterministic
/// function of notional. The only real slack is the lot size the spot market
/// rounds to, so that — and exactly that — is what gets added.
public struct SettlementFunding: Sendable, Equatable {

    /// The spot leg: buy this much of the settlement coin first.
    public struct Step: Sendable, Equatable {
        /// The spot market to buy on, e.g. `ETH-USDT`.
        public let instId: String
        public let coin: String
        /// Base units to buy, already rounded up to the market's lot size.
        public let buyAmount: Double
        /// What that costs in the quote currency at the current price. An
        /// estimate: the leg goes out as a market order, so the fill decides.
        public let estimatedCostQuote: Double
        /// Quote currency free to spend. Below `estimatedCostQuote` the plan
        /// cannot be afforded, and saying so beats a rejected order.
        public let quoteAvailable: Double

        public var isAffordable: Bool { quoteAvailable >= estimatedCostQuote }

        public init(
            instId: String, coin: String, buyAmount: Double,
            estimatedCostQuote: Double, quoteAvailable: Double
        ) {
            self.instId = instId
            self.coin = coin
            self.buyAmount = buyAmount
            self.estimatedCostQuote = estimatedCostQuote
            self.quoteAvailable = quoteAvailable
        }
    }

    /// Why no spot leg is needed, when that is the answer.
    public enum Skip: Sendable, Equatable {
        /// The coin is already there.
        case alreadyFunded(available: Double, required: Double)
        /// The account borrows what it lacks and the exchange charges interest.
        /// Its business, not ours — converting here would be a second opinion
        /// on a decision the account already made.
        case accountBorrows
        /// Premiums are paid in the currency the account already quotes in.
        case sameCurrency
    }

    public enum Outcome: Sendable, Equatable {
        case needed(Step)
        case notNeeded(Skip)
        /// The shortfall is real but smaller than the spot market will trade.
        /// Reported rather than rounded up to a size that would be refused.
        case belowMinimum(shortfall: Double, minimum: Double)
    }

    /// Plan the spot leg for an option purchase.
    ///
    /// - Parameters:
    ///   - funding: the coverage question already answered — reuse it rather
    ///     than recomputing premium and fee here, so one rule decides both.
    ///   - spotInstId: the market to buy the coin on.
    ///   - spotPrice: the coin's current price in the quote currency.
    ///   - spotLotSize: the market's lot size; the buy is rounded up to it.
    ///   - spotMinSize: the market's minimum order size.
    ///   - spotTakerBps: the spot fee, in basis points. **Charged in the coin
    ///     being bought**, so buying exactly the shortfall delivers less than
    ///     the shortfall and the option leg is still refused. Learned the hard
    ///     way: a 0.1% fee left 0.000043 ETH missing and stranded a funded
    ///     account one step short of its hedge.
    ///   - quoteAvailable: quote currency free to spend.
    public static func plan(
        funding: OptionPremiumFunding,
        spotInstId: String,
        spotPrice: Double,
        spotLotSize: Double,
        spotMinSize: Double,
        spotTakerBps: Double = SettlementFunding.defaultSpotTakerBps,
        quoteAvailable: Double
    ) -> Outcome {
        if funding.borrows { return .notNeeded(.accountBorrows) }
        let shortfall = funding.shortfall
        guard shortfall > 0 else {
            return .notNeeded(.alreadyFunded(
                available: funding.available, required: funding.required))
        }
        // Gross up for the exchange's cut, so what *arrives* covers the
        // shortfall. Buying `s` delivers `s × (1 − bps/10000)`, so the order
        // has to ask for `s / (1 − bps/10000)`.
        let feeRate = Swift.max(0, spotTakerBps) / 10_000
        let grossed = feeRate < 1 ? shortfall / (1 - feeRate) : shortfall
        // Then round up to a whole number of lots and add one. That single lot
        // is the only padding, and it exists for a reason a number can be put
        // to: premium and fill price carry more decimals than the coin is held
        // in, so the last lot can round the wrong way.
        let lot = spotLotSize > 0 ? spotLotSize : 0
        var amount = grossed
        if lot > 0 {
            let lots = (grossed / lot - 1e-9).rounded(.up)
            amount = (lots + 1) * lot
            // Keep the decimals the lot size implies; floating point otherwise
            // leaves 0.049641000000000004 to be sent to the exchange.
            amount = (amount / lot).rounded() * lot
            amount = (amount * 1e12).rounded() / 1e12
        }
        if spotMinSize > 0 && amount < spotMinSize {
            return .belowMinimum(shortfall: amount, minimum: spotMinSize)
        }
        return .needed(Step(
            instId: spotInstId, coin: funding.settleCurrency, buyAmount: amount,
            estimatedCostQuote: amount * spotPrice, quoteAvailable: quoteAvailable))
    }

    /// OKX spot taker for a VIP1 account, in basis points. A default rather
    /// than a guess at call sites: the fee schedule is the better source when
    /// the caller has one.
    public static let defaultSpotTakerBps: Double = 10

    /// The spot market a settlement coin is bought on, quoted in `quote`.
    /// Nil when no conversion is meaningful because they are the same coin.
    public static func spotMarket(for coin: String, quote: String = "USDT") -> String? {
        let coin = coin.uppercased()
        let quote = quote.uppercased()
        guard coin != quote else { return nil }
        return "\(coin)-\(quote)"
    }

    /// The order that buys the coin: a market buy sized in base units, so the
    /// amount of coin acquired is the amount that was planned. Sizing it in
    /// quote units instead would spend a known number of USDT and acquire an
    /// unknown amount of ETH, which is the wrong unknown for this job.
    public static func spotOrder(for step: Step, clOrdId: String? = nil) -> OrderRequest {
        OrderRequest(
            instId: step.instId,
            instType: .spot,
            side: .buy,
            kind: .market,
            size: step.buyAmount,
            sizeUnit: .base,
            clOrdId: clOrdId)
    }
}
