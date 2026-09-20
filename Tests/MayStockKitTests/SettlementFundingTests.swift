import Foundation
import Testing
@testable import MayStockKit

/// Sizing the spot leg that pays for an option.
///
/// The test that matters most here is the one about padding. A hand-rolled
/// version of this arithmetic added 15% "just in case" and would have bought
/// ~19 USD of ETH nobody needed; nothing in the calculation is uncertain
/// enough to justify that, and these tests pin the amount to the lot size.
@Suite("Settlement funding")
struct SettlementFundingTests {

    /// May's live account: single-currency margin, no auto-borrow.
    private let account = AccountTradingConfig(
        positionMode: .longShort, accountLevel: 2, autoLoan: false)
    /// OKX option taker: 3 bps of notional, capped at 12.5% of premium.
    private let fees = FeeModel.flatBps(3)
    /// ETH-USDT: lot 0.000001, min 0.0001.
    private let lot = 0.000001
    private let minSize = 0.0001

    private func funding(
        contracts: Double = 73, contractValue: Double = 0.1,
        limit: Double = 0.0065, available: Double,
        config: AccountTradingConfig? = nil
    ) -> OptionPremiumFunding {
        OptionPremiumFunding(
            settleCurrency: "ETH", contracts: contracts, contractValue: contractValue,
            limitPrice: limit, fees: fees, feeCapPctOfPremium: 12.5,
            available: available, config: config ?? account)
    }

    private func plan(
        _ funding: OptionPremiumFunding, spotPrice: Double = 2604,
        lotSize: Double? = nil, minimum: Double? = nil, quoteAvailable: Double = 5391,
        takerBps: Double = 10
    ) -> SettlementFunding.Outcome {
        SettlementFunding.plan(
            funding: funding, spotInstId: "ETH-USDT", spotPrice: spotPrice,
            spotLotSize: lotSize ?? lot, spotMinSize: minimum ?? minSize,
            spotTakerBps: takerBps, quoteAvailable: quoteAvailable)
    }

    // MARK: - The spot fee is taken out of the coin that arrives

    @Test("grosses the purchase up by the spot fee, so the coin that arrives covers it")
    func grossesUpForSpotFee() throws {
        // The bug this pins: buying exactly the shortfall delivers less than
        // the shortfall, because the 0.1% fee is charged in ETH. In real use
        // that left 0.000043 ETH missing and stranded a funded account one step
        // short of its hedge, after the spot leg had already filled.
        let f = funding(available: 0)
        guard case .needed(let step) = plan(f, takerBps: 10) else {
            Issue.record("expected a funding step")
            return
        }
        let arrives = step.buyAmount * (1 - 10.0 / 10_000)
        #expect(arrives >= f.shortfall)
    }

    @Test("a zero-fee market needs no gross-up", arguments: [0.0, 10.0, 25.0])
    func arrivalCoversShortfallAtAnyFee(_ bps: Double) throws {
        let f = funding(available: 0)
        guard case .needed(let step) = plan(f, takerBps: bps) else {
            Issue.record("expected a funding step")
            return
        }
        // Whatever the fee, what lands has to cover the shortfall.
        #expect(step.buyAmount * (1 - bps / 10_000) >= f.shortfall)
        // And a bigger fee must mean a bigger order, never a smaller one.
        if bps > 0 {
            guard case .needed(let free) = plan(f, takerBps: 0) else { return }
            #expect(step.buyAmount >= free.buyAmount)
        }
    }

    // MARK: - The padding regression

    @Test("buys the shortfall plus the fee and one lot, and nothing more")
    func noArbitraryPadding() throws {
        // 73 contracts × 0.1 ETH × 0.0065 = 0.04745 premium
        // fee = min(7.3 × 3bps, premium × 12.5%) = min(0.00219, 0.005931) = 0.00219
        // need = 0.04964, available 0 → shortfall 0.04964
        let f = funding(available: 0)
        #expect(abs(f.premium - 0.04745) < 1e-9)
        #expect(abs(f.fee - 0.00219) < 1e-9)
        #expect(abs(f.required - 0.04964) < 1e-9)

        guard case .needed(let step) = plan(f, takerBps: 10) else {
            Issue.record("expected a funding step")
            return
        }
        // Grossed up for the 0.1% spot fee, rounded up to a lot, plus one lot.
        // A 15% buffer would be 0.0571 — nearly 20 USD of ETH bought for no
        // stated reason. The padding here is the fee (computable) plus one lot
        // (the rounding), and nothing else.
        let expectedGross = f.shortfall / (1 - 0.001)
        #expect(step.buyAmount >= expectedGross)
        #expect(step.buyAmount - expectedGross <= 2 * lot)
        #expect(step.coin == "ETH")
        #expect(step.instId == "ETH-USDT")
        #expect(abs(step.estimatedCostQuote - step.buyAmount * 2604) < 0.01)
    }

    @Test("with no fee, the padding is exactly the rounding")
    func paddingWithoutFeeIsJustRounding() throws {
        let f = funding(available: 0)
        guard case .needed(let step) = plan(f, takerBps: 0) else {
            Issue.record("expected a funding step")
            return
        }
        #expect(abs(step.buyAmount - 0.049641) < 1e-9)
        let padding = step.buyAmount - f.shortfall
        #expect(padding > 0)
        #expect(padding <= 2 * lot)
    }

    @Test("a shortfall already on a lot boundary still gets exactly one lot")
    func paddingIsOneLotOnBoundary() throws {
        // Contrive the need to land on a whole number of lots, and take the fee
        // out of the picture so the rounding is the only thing being measured.
        let f = funding(contracts: 100, contractValue: 0.1, limit: 0.001, available: 0)
        // 10 × 0.001 = 0.01 premium; fee = min(10 × 3bps, 0.00125) = 0.00125 (capped)
        guard case .needed(let step) = plan(f, takerBps: 0) else {
            Issue.record("expected a funding step")
            return
        }
        #expect(abs(step.buyAmount - (f.shortfall + lot)) < 1e-9)
    }

    @Test("the amount lands on the lot grid, not on a float artefact")
    func amountIsCleanOnTheLotGrid() throws {
        guard case .needed(let step) = plan(funding(available: 0)) else {
            Issue.record("expected a funding step")
            return
        }
        // 0.049641000000000004 would be sent to the exchange verbatim.
        let lots = step.buyAmount / lot
        #expect(abs(lots - lots.rounded()) < 1e-6)
    }

    // MARK: - When no leg is needed

    @Test("no leg when the coin is already there")
    func alreadyFunded() {
        guard case .notNeeded(.alreadyFunded(let available, let required)) =
                plan(funding(available: 1.0))
        else {
            Issue.record("expected alreadyFunded")
            return
        }
        #expect(available == 1.0)
        #expect(required > 0)
    }

    @Test("no leg when the account borrows what it lacks")
    func accountBorrows() {
        // Multi-currency margin with auto-borrow: the exchange funds it and
        // charges interest. Converting here would second-guess that.
        let borrowing = AccountTradingConfig(
            positionMode: .longShort, accountLevel: 3, autoLoan: true)
        guard case .notNeeded(.accountBorrows) =
                plan(funding(available: 0, config: borrowing))
        else {
            Issue.record("expected accountBorrows")
            return
        }
    }

    @Test("a shortfall below the market's minimum is reported, not rounded up")
    func belowMinimum() {
        // Tiny shortfall: one contract at a near-zero premium.
        let f = funding(contracts: 1, contractValue: 0.1, limit: 0.0001, available: 0)
        guard case .belowMinimum(let shortfall, let minimum) = plan(f) else {
            Issue.record("expected belowMinimum, got \(plan(f))")
            return
        }
        #expect(shortfall < minimum)
        #expect(minimum == minSize)
    }

    // MARK: - Affordability

    @Test("an unaffordable leg is flagged rather than hidden")
    func unaffordable() throws {
        guard case .needed(let step) = plan(funding(available: 0), quoteAvailable: 10) else {
            Issue.record("expected a funding step")
            return
        }
        #expect(!step.isAffordable)
        #expect(step.quoteAvailable == 10)
    }

    @Test("affordable when the quote balance covers the estimate")
    func affordable() throws {
        guard case .needed(let step) = plan(funding(available: 0), quoteAvailable: 5391) else {
            Issue.record("expected a funding step")
            return
        }
        #expect(step.isAffordable)
    }

    // MARK: - The spot market and order

    @Test("names the market the coin is bought on")
    func spotMarket() {
        #expect(SettlementFunding.spotMarket(for: "ETH") == "ETH-USDT")
        #expect(SettlementFunding.spotMarket(for: "btc") == "BTC-USDT")
        // Nothing to convert.
        #expect(SettlementFunding.spotMarket(for: "USDT") == nil)
        #expect(SettlementFunding.spotMarket(for: "usdt") == nil)
    }

    @Test("buys base units, so the coin acquired is the coin planned")
    func spotOrderIsBaseSized() throws {
        guard case .needed(let step) = plan(funding(available: 0)) else {
            Issue.record("expected a funding step")
            return
        }
        let order = SettlementFunding.spotOrder(for: step)
        #expect(order.instId == "ETH-USDT")
        #expect(order.instType == .spot)
        #expect(order.side == .buy)
        #expect(order.kind == .market)
        // Quote sizing would spend a known number of USDT for an unknown amount
        // of ETH — the wrong unknown when a specific amount of ETH is needed.
        #expect(order.sizeUnit == .base)
        #expect(order.size == step.buyAmount)
    }

    @Test("partial fills leave a shortfall the caller can still see")
    func shortfallAfterPartialFill() {
        // Half the coin arrived: still short, and by a stateable amount.
        let f = funding(available: 0.025)
        #expect(!f.isCovered)
        #expect(abs(f.shortfall - (f.required - 0.025)) < 1e-9)
    }
}
