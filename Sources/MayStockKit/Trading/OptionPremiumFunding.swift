import Foundation

/// Whether the account can pay for an option it is about to buy.
///
/// A bought option is paid for in the contract's settlement coin — BTC for a
/// BTC option — and so is its fee, while the strategy's budget is stated in
/// the quote currency. An account holding only USDT is refused by the
/// exchange with a margin error that names no amount and no remedy. This
/// rule asks the question before the order goes out and answers it with the
/// numbers, so the strategy's message says what to fund.
///
/// One rule, used by the runner before it places and by the demo harness
/// when it reports. Borrowing is the account's business: a multi-currency or
/// portfolio margin account with auto-borrow on pays in a coin it lacks and
/// the exchange charges interest on it; nothing here converts anything.
public struct OptionPremiumFunding: Sendable, Equatable {
    public let settleCurrency: String
    /// Premium at the limit price, in the settlement coin.
    public let premium: Double
    /// The fee the exchange charges on the fill, in the settlement coin.
    public let fee: Double
    /// What the account holds free in the settlement coin.
    public let available: Double
    /// The account borrows what it lacks, so the balance is not the limit.
    public let borrows: Bool

    public var required: Double { premium + fee }
    public var shortfall: Double { Swift.max(0, required - available) }
    public var isCovered: Bool { borrows || shortfall <= 0 }

    /// - Parameters:
    ///   - contracts: whole contracts the order asks for.
    ///   - contractValue: underlying units per contract (`ctVal × ctMult`).
    ///   - limitPrice: the most the order pays per unit, in the settlement
    ///     coin — the amount the exchange freezes, not the ask.
    ///   - fees: the venue's cost model for the family. It is charged on the
    ///     underlying notional, which stated in the settlement coin *is* the
    ///     units traded — one unit of BTC underlying is one BTC.
    ///   - feeCapPctOfPremium: the exchange's cap on that fee, as a share of
    ///     the premium.
    public init(
        settleCurrency: String, contracts: Double, contractValue: Double, limitPrice: Double,
        fees: FeeModel, feeCapPctOfPremium: Double, available: Double,
        config: AccountTradingConfig
    ) {
        let units = contracts * contractValue
        let premium = units * limitPrice
        self.settleCurrency = settleCurrency
        self.premium = premium
        self.fee = Swift.min(fees.charge(side: .buy, units: units, notional: units),
                             premium * feeCapPctOfPremium / 100)
        self.available = available
        self.borrows = config.borrowsMissingCoin
    }

    /// The verdict in words, for the strategy's message and the log.
    public var explanation: String {
        let coin = settleCurrency
        let need = "买入需约 \(Self.amount(required)) \(coin)"
            + "（权利金 \(Self.amount(premium)) + 手续费 \(Self.amount(fee))）"
        if borrows {
            return "\(coin) 可用 \(Self.amount(available))，\(need)；账户开启了自动借币，不足部分由交易所借出并计息"
        }
        if shortfall <= 0 {
            return "\(coin) 可用 \(Self.amount(available))，\(need)"
        }
        return "结算币不足：\(coin) 可用 \(Self.amount(available))，\(need)，缺 \(Self.amount(shortfall)) \(coin)。"
            + "期权权利金以 \(coin) 支付，请先换入 \(coin)，"
            + "或在 OKX 账户设置里开启自动借币（仅跨币种 / 组合保证金模式）"
    }

    private static func amount(_ value: Double) -> String {
        PriceFormatter.plain(value)
    }
}
