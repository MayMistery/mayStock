import Foundation
import Testing
@testable import MayStockKit

@Suite("An option is paid for in its settlement coin")
struct OptionPremiumFundingTests {
    private let crossNoLoan = AccountTradingConfig(positionMode: .longShort, accountLevel: 3, autoLoan: false)

    @Test("需要的是限价权利金加手续费，手续费按标的名义额计、封顶权利金的一成二五")
    func requiredIsPremiumAtTheLimitPlusTheFee() {
        // The demo order: 3 contracts of 0.01 BTC at a 0.021 limit.
        let funding = OptionPremiumFunding(
            settleCurrency: "BTC", contracts: 3, contractValue: 0.01, limitPrice: 0.021,
            feeBps: 3, feeCapPctOfPremium: 12.5, available: 0, config: crossNoLoan)
        #expect(abs(funding.premium - 0.00063) < 1e-12)
        // 3 bps of 0.03 BTC notional is 0.000009; 12.5% of the premium would be more.
        #expect(abs(funding.fee - 0.000009) < 1e-12)
        #expect(abs(funding.required - 0.000639) < 1e-12)
        #expect(abs(funding.shortfall - 0.000639) < 1e-12)
        #expect(!funding.isCovered)

        // A near-worthless contract: the cap binds instead.
        let cheap = OptionPremiumFunding(
            settleCurrency: "BTC", contracts: 3, contractValue: 0.01, limitPrice: 0.0001,
            feeBps: 3, feeCapPctOfPremium: 12.5, available: 0, config: crossNoLoan)
        #expect(abs(cheap.fee - 0.000003 * 0.125) < 1e-15)
    }

    @Test("持有足够结算币就算覆盖，缺口为零")
    func aFundedAccountIsCovered() {
        let funding = OptionPremiumFunding(
            settleCurrency: "BTC", contracts: 3, contractValue: 0.01, limitPrice: 0.021,
            feeBps: 3, feeCapPctOfPremium: 12.5, available: 0.001, config: crossNoLoan)
        #expect(funding.isCovered)
        #expect(funding.shortfall == 0)
        #expect(!funding.explanation.contains("不足"))
        #expect(funding.explanation.contains("BTC 可用 0.001"))
    }

    @Test("能借币的账户没有结算币也算覆盖，并说明由交易所借出")
    func aBorrowingAccountIsCoveredWithoutTheCoin() {
        let funding = OptionPremiumFunding(
            settleCurrency: "BTC", contracts: 3, contractValue: 0.01, limitPrice: 0.021,
            feeBps: 3, feeCapPctOfPremium: 12.5, available: 0,
            config: AccountTradingConfig(positionMode: .longShort, accountLevel: 4, autoLoan: true))
        #expect(funding.borrows)
        #expect(funding.isCovered)
        #expect(funding.explanation.contains("自动借币"))
        #expect(funding.explanation.contains("计息"))
    }

    @Test("缺口文案写明可用、所需、缺多少和两条出路")
    func aShortfallSaysWhatToDo() {
        let funding = OptionPremiumFunding(
            settleCurrency: "BTC", contracts: 3, contractValue: 0.01, limitPrice: 0.021,
            feeBps: 3, feeCapPctOfPremium: 12.5, available: 0.0001, config: crossNoLoan)
        let words = funding.explanation
        #expect(words.hasPrefix("结算币不足：BTC 可用 0.0001"))
        #expect(words.contains("需约 0.000639 BTC"))
        #expect(words.contains("缺 0.000539 BTC"))
        #expect(words.contains("换入 BTC"))
        #expect(words.contains("自动借币"))
    }
}
