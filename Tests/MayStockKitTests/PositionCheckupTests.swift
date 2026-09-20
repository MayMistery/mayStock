import Foundation
import Testing
@testable import MayStockKit

/// The checkup model's job is to answer "how exposed am I" from whatever the
/// account actually holds.
///
/// The bug these tests exist for: the page was handed an instrument guessed
/// from the watchlist — which holds spot pairs and equities, never perpetuals —
/// so it matched no position and reported **"no position"** while a real
/// perpetual was open and losing money. A read that succeeds and finds nothing
/// is indistinguishable from a read that succeeds and the account is flat, so
/// the instrument has to come from the positions themselves.
@Suite("Position checkup")
@MainActor
struct PositionCheckupTests {

    private func position(
        instId: String = "ETH-USDT-SWAP", side: PositionSide = .short,
        quantity: Double = -56.36, average: Double = 2623.21,
        mark: Double = 2571.77, upl: Double = 289.89,
        liquidation: Double? = 2886.06, notional: Double? = 14_489,
        margin: Double? = 1_553.86, mmr: Double? = 58.05, ratio: Double? = 28.27
    ) -> ExchangePosition {
        ExchangePosition(
            instId: instId, posSide: side, quantity: quantity, averagePrice: average,
            markPrice: mark, unrealisedPnL: upl, leverage: 50, liquidationPrice: liquidation,
            notionalUsd: notional, instType: "SWAP",
            margin: margin, maintenanceMargin: mmr, marginRatio: ratio)
    }

    private func venue(holding positions: [ExchangePosition], equity: Double = 7_130.97) -> FakeVenue {
        let fake = FakeVenue()
        fake.positionsResult = .success(positions)
        fake.equity = equity
        return fake
    }

    @Test("adopts the perpetual the account holds, whatever it was constructed with")
    func adoptsHeldPosition() async {
        // Constructed pointed at a spot pair — exactly the watchlist guess that
        // caused the bug.
        let model = CheckupModel(
            venue: venue(holding: [position()]), mode: .live, instId: "BTC-USDT")
        await model.refreshRisk()

        #expect(model.instId == "ETH-USDT-SWAP")
        #expect(model.risk.hasPosition)
        #expect(model.risk.contracts == -56.36)
    }

    @Test("reports a real position rather than claiming the account is flat")
    func doesNotClaimFlatWhenHolding() async {
        let model = CheckupModel(
            venue: venue(holding: [position()]), mode: .live, instId: "TSLA")
        await model.refreshRisk()

        // The failure this guards: "no position" on screen while a position is
        // open is worse than an empty page, because it is a confident lie.
        #expect(model.risk.hasPosition)
        #expect(model.risk.instId == "ETH-USDT-SWAP")
    }

    @Test("stays where it was told when it is not following positions")
    func respectsAnExplicitInstrument() async {
        let model = CheckupModel(
            venue: venue(holding: [position(instId: "SOL-USDT-SWAP")]),
            mode: .live, instId: "ETH-USDT-SWAP", followsHeldPosition: false)
        await model.refreshRisk()

        // A deep link naming an instrument is a request, not a guess.
        #expect(model.instId == "ETH-USDT-SWAP")
        #expect(!model.risk.hasPosition)
    }

    @Test("an empty account leaves the instrument alone and reports flat")
    func flatAccountKeepsItsInstrument() async {
        let model = CheckupModel(
            venue: venue(holding: []), mode: .live, instId: "ETH-USDT-SWAP")
        await model.refreshRisk()

        #expect(model.instId == "ETH-USDT-SWAP")
        #expect(!model.risk.hasPosition)
        #expect(model.riskState.errorText == nil)  // read succeeded, account is flat
    }

    @Test("reads margin, maintenance and the exchange's own ratio")
    func carriesMarginFigures() async {
        let model = CheckupModel(venue: venue(holding: [position()]), mode: .live)
        await model.refreshRisk()

        // These were dropped by the parser entirely, so the page showed
        // "保证金 $0.00" no matter what was posted.
        #expect(model.risk.margin == 1_553.86)
        #expect(model.risk.maintenanceMargin == 58.05)
        #expect(model.risk.marginRatio == 28.27)
    }

    @Test("effective leverage is notional over equity, not the contract setting")
    func effectiveLeverageIgnoresTheContractSetting() async {
        let model = CheckupModel(venue: venue(holding: [position()]), mode: .live)
        await model.refreshRisk()

        let exposure = model.risk.exposure
        #expect(exposure != nil)
        // 14,489 / 7,130.97 ≈ 2.03 — a 50× contract size says nothing about it.
        #expect(abs((exposure?.effectiveLeverage ?? 0) - 2.03) < 0.01)
        #expect(model.risk.leverageSetting == 50)
    }

    @Test("computes the liquidation buffer outward for a short")
    func liquidationBuffer() async {
        let model = CheckupModel(venue: venue(holding: [position()]), mode: .live)
        await model.refreshRisk()

        // 2886.06 / 2571.77 − 1 ≈ 12.22%
        #expect(abs((model.risk.liquidationBuffer ?? 0) - 12.22) < 0.05)
        #expect(model.risk.isShort)
    }

    @Test("a failed read says so and does not claim the account is flat")
    func failedReadIsNotFlatness() async {
        let fake = FakeVenue()
        fake.positionsResult = .failure(ExchangeVenueError.unsupported("测试", "positions"))
        let model = CheckupModel(venue: fake, mode: .live, instId: "ETH-USDT-SWAP")
        await model.refreshRisk()

        // Distinguishable from the flat case above: the view renders these two
        // differently, and only one of them may say "无持仓".
        #expect(model.riskState.errorText != nil)
        #expect(!model.risk.hasPosition)
    }

    @Test("an unread position does not overwrite the last good instrument")
    func failedReadKeepsInstrument() async {
        let fake = FakeVenue()
        fake.positionsResult = .failure(ExchangeVenueError.unsupported("测试", "positions"))
        let model = CheckupModel(venue: fake, mode: .live, instId: "ETH-USDT-SWAP")
        await model.refreshRisk()

        #expect(model.instId == "ETH-USDT-SWAP")
    }

    @Test("switching instrument clears the previous instrument's readings")
    func switchingResetsStaleReadings() async {
        let model = CheckupModel(
            venue: venue(holding: [position()]), mode: .live, instId: "ETH-USDT-SWAP")
        await model.refreshRisk()
        #expect(model.risk.hasPosition)

        // Point it elsewhere: showing the old position's numbers under a new
        // heading would be worse than showing nothing.
        model.followsHeldPosition = false
        model.instId = "SOL-USDT-SWAP"
        #expect(!model.risk.hasPosition)
        #expect(model.risk.contracts == 0)
        #expect(model.riskState == .never)
    }
}
