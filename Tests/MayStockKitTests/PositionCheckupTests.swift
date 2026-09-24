import Foundation
import Testing
@testable import MayStockKit

/// The checkup's job is to answer "how exposed am I" from whatever the account
/// actually holds — now through the kernel's live layer, fed here offline with
/// the same documents the CLI fallback hands it.
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

    /// The CLI's `account positions --json` document for one position.
    private func positions(
        instId: String = "ETH-USDT-SWAP", side: String = "short", pos: Double = 56.36,
        average: Double = 2623.21, mark: Double = 2571.77, upl: Double = 289.89,
        liquidation: Double = 2886.06, notional: Double = 14_489,
        margin: Double = 1_553.86, mmr: Double = 58.05, ratio: Double = 28.27
    ) -> String {
        """
        {"data":[{"instId":"\(instId)","instType":"SWAP","posSide":"\(side)","pos":"\(pos)","avgPx":"\(average)",
        "markPx":"\(mark)","upl":"\(upl)","lever":"50","liqPx":"\(liquidation)","notionalUsd":"\(notional)",
        "margin":"\(margin)","mmr":"\(mmr)","mgnRatio":"\(ratio)"}]}
        """
    }

    private let balance = #"{"data":[{"totalEq":"7130.97","details":[{"ccy":"USDT","eq":"7000"}]}]}"#

    private func model(instId: String = "ETH-USDT-SWAP", follows: Bool = true) -> CheckupModel {
        let model = CheckupModel(
            venue: FakeVenue(), mode: .live, instId: instId, followsHeldPosition: follows,
            okxConfigPath: nil, network: false, nowOverrideMs: 1_790_164_800_000)
        model.start()
        return model
    }

    @Test("adopts the perpetual the account holds, whatever it was constructed with")
    func adoptsHeldPosition() throws {
        // Constructed pointed at a spot pair — exactly the watchlist guess that
        // caused the bug.
        let model = model(instId: "BTC-USDT")
        defer { model.stop() }
        try model.ingest(topic: "cli.positions", payload: positions())
        let snapshot = try #require(model.snapshot)
        #expect(snapshot.instrument.instId == "ETH-USDT-SWAP")
        #expect(snapshot.risk.position?.contracts == -56.36)
    }

    @Test("reports a real position rather than claiming the account is flat")
    func doesNotClaimFlatWhenHolding() throws {
        let model = model(instId: "TSLA")
        defer { model.stop() }
        try model.ingest(topic: "cli.positions", payload: positions())
        let risk = try #require(model.snapshot?.risk)
        // The failure this guards: "no position" on screen while a position is
        // open is worse than an empty page, because it is a confident lie.
        #expect(risk.position != nil)
        #expect(risk.wasRead)
        #expect(risk.source == "cli")
    }

    @Test("stays where it was told when it is not following positions")
    func respectsAnExplicitInstrument() throws {
        let model = model(instId: "ETH-USDT-SWAP", follows: false)
        defer { model.stop() }
        try model.ingest(topic: "cli.positions", payload: positions(instId: "SOL-USDT-SWAP"))
        let snapshot = try #require(model.snapshot)
        // A deep link naming an instrument is a request, not a guess.
        #expect(snapshot.instrument.instId == "ETH-USDT-SWAP")
        #expect(snapshot.risk.position == nil)
        #expect(snapshot.risk.held == ["SOL-USDT-SWAP"])
    }

    @Test("an empty account keeps its instrument and is reported flat — because it was read")
    func flatAccountKeepsItsInstrument() throws {
        let model = model()
        defer { model.stop() }
        try model.ingest(topic: "cli.positions", payload: #"{"data":[]}"#)
        let risk = try #require(model.snapshot?.risk)
        #expect(risk.instId == "ETH-USDT-SWAP")
        #expect(risk.position == nil)
        #expect(risk.wasRead, "read succeeded and found nothing: flat is a claim this state may make")
    }

    @Test("reads margin, maintenance and the exchange's own ratio")
    func carriesMarginFigures() throws {
        let model = model()
        defer { model.stop() }
        try model.ingest(topic: "cli.positions", payload: positions())
        let position = try #require(model.snapshot?.risk.position)
        #expect(position.margin == 1_553.86)
        #expect(position.maintenanceMargin == 58.05)
        #expect(position.marginRatio == 28.27)
    }

    @Test("effective leverage is notional over equity, not the contract setting")
    func effectiveLeverageIgnoresTheContractSetting() throws {
        let model = model()
        defer { model.stop() }
        try model.ingest(topic: "cli.positions", payload: positions())
        try model.ingest(topic: "cli.account", payload: balance)
        let risk = try #require(model.snapshot?.risk)
        // 14,489 / 7,130.97 ≈ 2.03 — a 50× contract says nothing about it.
        #expect(abs((risk.exposure?.effectiveLeverage ?? 0) - 2.03) < 0.01)
        #expect(risk.position?.leverageSetting == 50)
    }

    @Test("computes the liquidation buffer outward for a short")
    func liquidationBuffer() throws {
        let model = model()
        defer { model.stop() }
        try model.ingest(topic: "cli.positions", payload: positions())
        let position = try #require(model.snapshot?.risk.position)
        // 2886.06 / 2571.77 − 1 ≈ 12.22%
        #expect(abs((position.liquidationBufferPct ?? 0) - 12.22) < 0.05)
        #expect(position.isShort)
    }

    @Test("an unread account says so and does not claim it is flat")
    func unreadIsNotFlatness() throws {
        let model = model()
        defer { model.stop() }
        let risk = try #require(model.snapshot?.risk)
        // Distinguishable from the flat case above: the view renders these two
        // differently, and only one of them may say "无持仓".
        #expect(!risk.wasRead)
        #expect(risk.position == nil)
        #expect(risk.note != nil)
        #expect(risk.fallbackNeeded, "no account socket: the app is asked to read through the CLI")
    }

    @Test("a page nobody can see keeps reading but redraws nothing, and catches up the moment it is shown")
    func hiddenPageCatchesUpWhenShown() throws {
        let model = model()
        defer { model.stop() }
        model.isVisible = false
        try model.ingest(topic: "cli.positions", payload: positions())
        #expect(model.snapshot?.risk.position != nil, "the snapshot is still read while hidden")
        #expect(model.risk?.position == nil, "but nothing is published to the cards")
        model.isVisible = true
        #expect(model.risk?.position?.contracts == -56.36, "published at once when shown, without waiting for the next frame")
    }

    @Test("switching instrument clears the previous instrument's readings")
    func switchingResetsStaleReadings() throws {
        let model = model()
        defer { model.stop() }
        try model.ingest(topic: "cli.positions", payload: positions())
        #expect(model.snapshot?.risk.position != nil)

        // Point it elsewhere: showing the old position's numbers under a new
        // heading would be worse than showing nothing.
        model.followsHeldPosition = false
        model.instId = "SOL-USDT-SWAP"
        let snapshot = try #require(model.snapshot)
        #expect(snapshot.instrument.instId == "SOL-USDT-SWAP")
        #expect(snapshot.risk.position == nil)
    }
}
