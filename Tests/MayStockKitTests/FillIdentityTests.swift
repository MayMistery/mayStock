import Foundation
import Testing
@testable import MayStockKit

// MARK: - Fill identity

/// The ledger's guard against booking one execution twice.
///
/// This is where 「最近成交」 was empty from, so the tests are about the shape
/// of the failure rather than about one field. The failure was: a fill is
/// offered once under `tradeId` and once under `billId`, the book compares
/// names, the names differ, the fill is booked twice — or, read the other way,
/// a listing that starts naming fills differently stops matching the rows
/// already on disk and the whole window is re-ingested. Both directions are
/// the same bug and both are tested here.
@Suite("成交身份")
@MainActor
struct FillIdentityTests {
    private func exchange(
        _ instId: String, tradeId: String?, billId: String?,
        ts: Date = Date(), side: OrderSide = .buy, clOrdId: String? = nil
    ) -> ExchangeFill {
        ExchangeFill(
            id: tradeId ?? billId ?? instId, instId: instId, side: side, posSide: .long,
            price: 100, size: 1, fee: -0.1, feeCcy: "USDT",
            ordId: "o1", clOrdId: clOrdId, ts: ts, billId: billId, tradeId: tradeId)
    }

    /// The rule the whole mechanism rests on: two records of one execution are
    /// the same execution when *any* name they both carry agrees. Asserted over
    /// the kernel's own answer rather than over a spelling written here, so a
    /// key added or renamed in the kernel is covered the day it lands.
    @Test func anySharedNameMakesTwoRecordsOneExecution() throws {
        let named = exchange("ETH-USDT-SWAP", tradeId: "4294122652", billId: "3931253135398440960")
        let legacy = exchange("ETH-USDT-SWAP", tradeId: "4294122652", billId: nil)
        let other = exchange("ETH-USDT-SWAP", tradeId: "4294122653", billId: nil)

        let index = KernelIdentities.of([legacy.kernelRecord])
        #expect(index.holds(named.kernelRecord), "the bill id is new but the trade id is not")
        #expect(!index.holds(other.kernelRecord), "a different trade id is a different fill")

        // And the other direction, which is the one a re-listing triggers.
        let fromNamed = KernelIdentities.of([named.kernelRecord])
        #expect(fromNamed.holds(legacy.kernelRecord))
    }

    /// A counter is not an identity without its instrument. OKX numbers an
    /// option's fills per contract — the two live ones are 32 and 50 on
    /// different strikes — so collapsing on the bare number would merge two
    /// real executions into one.
    @Test func oneCounterOnTwoInstrumentsIsTwoFills() {
        let call = exchange("ETH-USD-260919-2610-C", tradeId: "32", billId: nil)
        let other = exchange("ETH-USD-260919-2625-C", tradeId: "32", billId: nil)
        let index = KernelIdentities.of([call.kernelRecord])
        #expect(!index.holds(other.kernelRecord))
    }

    /// The whole point of the index, at the level the bug was observed: a
    /// listing re-offered to a book that already holds every row must book
    /// nothing.
    @Test func reOfferingTheSameListingBooksNothing() throws {
        let ledger = StrategyLedger(mode: .demo)
        let listing = [
            exchange("ETH-USDT-SWAP", tradeId: "1", billId: "b1", clOrdId: OrderTag.make(strategyId: "s")),
            exchange("ETH-USDT-SWAP", tradeId: "2", billId: "b2", clOrdId: OrderTag.make(strategyId: "s")),
        ]
        // The multiplier a perpetual is sized by, taught the way the runner
        // teaches it — a derivative fill whose size nobody has supplied is
        // deliberately not booked at a guess.
        let sizes = ["ETH-USDT-SWAP": 0.1]
        #expect(ledger.ingest(listing, knownStrategyIds: ["s"], venue: .okx, contractSizes: sizes) == 2)
        #expect(ledger.ingest(listing, knownStrategyIds: ["s"], venue: .okx, contractSizes: sizes) == 0)
        #expect(ledger.fills.count == 2)
    }

    /// The same listing read by a build that now stamps bill ids where it used
    /// to read only trade ids. The rows on disk carry one name, the listing
    /// carries both, and they are the same fills — so nothing is re-booked.
    /// This is the case a `Set<String>` of identities gets wrong, and it is
    /// the one that turns a week of history into a doubled position.
    @Test func aRicherListingDoesNotReBookWhatTheBookAlreadyHas() throws {
        let ledger = StrategyLedger(mode: .demo)
        let clOrdId = OrderTag.make(strategyId: "s")
        let sizes = ["ETH-USDT-SWAP": 0.1]
        let older = exchange("ETH-USDT-SWAP", tradeId: "9", billId: nil, clOrdId: clOrdId)
        #expect(ledger.ingest([older], knownStrategyIds: ["s"], venue: .okx, contractSizes: sizes) == 1)

        // Today's listing of the same execution, now with the venue's line id.
        let richer = exchange("ETH-USDT-SWAP", tradeId: "9", billId: "b9", clOrdId: clOrdId)
        #expect(ledger.ingest([richer], knownStrategyIds: ["s"], venue: .okx, contractSizes: sizes) == 0)
        #expect(ledger.fills.count == 1)
        // And the position counted it once, not twice: one contract, not two.
        #expect(ledger.position(for: "s")?.quantity == 1)
    }

    /// A book that has been replaced — a restart, a venue switch — re-derives
    /// its index from what it loaded. An index that outlived the `replace`
    /// would describe a book that no longer exists.
    @Test func aReplacedBookIndexesWhatItLoaded() {
        let ledger = StrategyLedger(mode: .demo)
        let fill = StrategyFill(
            id: "9", strategyId: "s", instId: "ETH-USDT-SWAP", side: .buy, price: 100,
            quantity: 1, feeQuote: 0, ts: Date(), clOrdId: nil, mode: .demo, venue: .okx)
        #expect(!ledger.bookedIdentities.holds(fill.kernelRecord))
        ledger.replace(fills: [fill], positions: [:])
        #expect(ledger.bookedIdentities.holds(fill.kernelRecord))
    }

    /// The order `recentFillRows` relies on: it takes `suffix(limit)` of the
    /// book as "the newest rows", which is only true if the book is
    /// chronological. A listing offered newest-first — which is the order the
    /// exchanges return — must not leave the array in that order.
    @Test func theBookStaysChronologicalWhateverOrderItIsFed() {
        let now = Date()
        let ledger = StrategyLedger(mode: .demo)
        let clOrdId = OrderTag.make(strategyId: "s")
        func fill(_ id: String, _ offset: TimeInterval) -> ExchangeFill {
            ExchangeFill(
                id: id, instId: "BTC-USDT", side: .buy, posSide: nil, price: 100, size: 1,
                fee: 0, feeCcy: "USDT", ordId: nil, clOrdId: clOrdId,
                ts: now.addingTimeInterval(offset), tradeId: id)
        }
        // Newest first, the way every exchange listing returns fills.
        ledger.ingest(
            [fill("3", 300), fill("2", 200), fill("1", 100)],
            knownStrategyIds: ["s"], venue: .okx)
        #expect(ledger.fills.map(\.id) == ["1", "2", "3"])
        #expect(ledger.fills.suffix(2).map(\.id) == ["2", "3"], "suffix is the newest")
    }
}

// MARK: - The merged feed

@Suite("最近成交的合并")
@MainActor
struct FillRowTests {
    private func bookFill(
        _ instId: String, id: String, ts: Date, advantage: Double? = nil,
        effect: PositionEffect? = nil
    ) -> StrategyFill {
        StrategyFill(
            id: id, strategyId: "s", instId: instId, side: .buy, price: 100, quantity: 1,
            feeQuote: 1, ts: ts, clOrdId: nil, mode: .demo,
            realisedQuote: advantage, positionEffect: effect, venue: .okx)
    }

    private func venueFill(
        _ instId: String, id: String, ts: Date, billId: String? = nil,
        side: OrderSide = .buy, posSide: PositionSide? = .long, pnl: Double? = nil
    ) -> ExchangeFill {
        ExchangeFill(
            id: id, instId: instId, side: side, posSide: posSide, price: 100, size: 2,
            fee: -0.2, feeCcy: "USDT", ordId: nil, clOrdId: nil, ts: ts,
            billId: billId, tradeId: id, pnl: pnl)
    }

    /// A row the app placed keeps the book's copy — its strategy name and its
    /// own realised figure — even though the venue also lists it.
    @Test func theBooksCopyWinsWhereBothHaveTheSameFill() {
        let ts = Date()
        let rows = TradingKernel.fillRows(
            ledger: [bookFill("ETH-USDT-SWAP", id: "9", ts: ts, advantage: 5, effect: .close)],
            venue: [venueFill("ETH-USDT-SWAP", id: "9", ts: ts, billId: "b9", pnl: 99)],
            on: .okx)
        #expect(rows.count == 1, "one execution, one row")
        #expect(rows[0].strategyId == "s")
        #expect(rows[0].realisedQuote == 5, "the book's own arithmetic, not the venue's")
        #expect(rows[0].action == "平空", "the book knows which leg the side closed")
        #expect(!rows[0].isExternal)
    }

    /// An execution no strategy booked still appears — that is the whole
    /// reason the listing is read — and it says so rather than being
    /// attributed to whichever strategy happens to be first.
    @Test func anExecutionTheAppDidNotPlaceIsShownAsExternal() {
        let ts = Date()
        let rows = TradingKernel.fillRows(
            ledger: [], venue: [venueFill("ETH-USDT-SWAP", id: "9", ts: ts, pnl: 3)], on: .okx)
        #expect(rows.count == 1)
        #expect(rows[0].strategyId == nil)
        #expect(rows[0].isExternal)
        #expect(rows[0].action == "开多", "a buy on a long leg grew it")
    }

    /// 操作 and 净益 for a foreign row come from what the venue actually
    /// supports: grew/shrank its leg, and a P&L only where one was realised.
    @Test func aForeignRowIsLabelledByWhatTheVenueCanSay() {
        let ts = Date()
        let closing = TradingKernel.fillRows(
            ledger: [],
            venue: [venueFill("ETH-USDT-SWAP", id: "1", ts: ts, side: .sell, posSide: .long, pnl: 3.5)],
            on: .okx)
        #expect(closing[0].action == "平多")
        #expect(closing[0].realisedQuote == 3.5)

        // A net-mode book reports no leg: the raw side is shown rather than an
        // invented one, and nothing claims to have been realised.
        let net = TradingKernel.fillRows(
            ledger: [], venue: [venueFill("ETH-USDT", id: "2", ts: ts, posSide: .net, pnl: 0)], on: .okx)
        #expect(net[0].action == "买入")
        #expect(net[0].realisedQuote == nil)
    }

    /// Newest first, and both books represented.
    @Test func theUnionIsNewestFirst() {
        let now = Date()
        let rows = TradingKernel.fillRows(
            ledger: [bookFill("ETH-USDT-SWAP", id: "old", ts: now.addingTimeInterval(-600))],
            venue: [venueFill("ETH-USDT", id: "new", ts: now)],
            on: .okx)
        #expect(rows.map(\.id) == ["new", "old"])
    }

    /// 净益 is net of the fill's own fee, on both sources, so a row from the
    /// book and a row from the venue mean the same thing in the same column.
    @Test func netRealisedTakesTheFeeOffBothSources() {
        let ts = Date()
        let rows = TradingKernel.fillRows(
            ledger: [bookFill("ETH-USDT-SWAP", id: "1", ts: ts, advantage: 10, effect: .close)],
            venue: [venueFill("ETH-USDT", id: "2", ts: ts, side: .sell, posSide: .long, pnl: 10)],
            on: .okx)
        #expect(rows[0].netRealisedQuote == 9, "10 realised less the book's 1 fee")
        #expect(rows[1].netRealisedQuote == 9.8, "10 less the venue's 0.2 fee")
    }

    /// An option fill's money arrives in its settlement coin, not in the
    /// book's currency, and the 净益 column is one column for every family —
    /// so the row must convert. This is the live fill of 2026-09-21 exactly:
    /// premium 0.006 ETH, the venue's own dollar reading 15.67878, index
    /// 2613.13, fee 0.00195 ETH.
    @Test func anOptionRowsMoneyIsConvertedOutOfItsSettlementCoin() throws {
        let ts = Date()
        let option = ExchangeFill(
            id: "1", instId: "ETH-USD-260919-2610-C", side: .buy, posSide: .net,
            price: 0.006, size: 1, fee: -0.00195, feeCcy: "ETH",
            ordId: nil, clOrdId: nil, ts: ts,
            priceUsd: 15.67878, indexPrice: 2_613.13,
            billId: "b1", tradeId: "1", pnl: 0)

        let row = try #require(FillRow(option, venue: .okx, legEffect: nil))
        #expect(abs(row.price - 15.67878) < 1e-9, "the venue's own dollar premium")
        #expect(abs(row.feeQuote - 0.00195 * 2_613.13) < 1e-6, "the ETH fee at the index")
        // And the same conversion the book applies, so the two agree.
        let booked = try #require(StrategyFill(
            exchange: option, strategyId: "s", mode: .demo, venue: .okx))
        #expect(abs(booked.price - row.price) < 1e-9)
        #expect(abs(booked.feeQuote - row.feeQuote) < 1e-9)
    }

    /// An option fill with no index anywhere cannot be converted. It is left
    /// out rather than shown at a guessed rate, and the book refuses it the
    /// same way — one rule, two readers.
    @Test func anUnconvertibleOptionFillIsLeftOutNotGuessed() {
        let bare = ExchangeFill(
            id: "1", instId: "ETH-USD-260919-2610-C", side: .buy, posSide: .net,
            price: 0.006, size: 1, fee: -0.00195, feeCcy: "ETH",
            ordId: nil, clOrdId: nil, ts: Date())
        #expect(FillRow(bare, venue: .okx, legEffect: nil) == nil)
        #expect(StrategyFill(exchange: bare, strategyId: "s", mode: .demo, venue: .okx) == nil)
        // A spot or perpetual fill needs no index and is never dropped.
        let spot = ExchangeFill(
            id: "2", instId: "ETH-USDT", side: .buy, posSide: nil, price: 2_500, size: 1,
            fee: -0.1, feeCcy: "USDT", ordId: nil, clOrdId: nil, ts: Date())
        #expect(FillRow(spot, venue: .okx, legEffect: nil) != nil)
    }
}
