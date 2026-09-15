import Foundation
import Testing
@testable import MayStockKit

/// The exchange's ledger, read as it comes off the CLI, and the window sums
/// taken from it. The fixtures are the shapes OKX actually returns.
@Suite("Billed P&L")
struct BilledPnLTests {
    /// Real bill shapes: an isolated-margin funding settlement (balance
    /// unchanged, P&L booked to the position), an opening trade (fee only),
    /// a closing trade (P&L and fee), and a transfer (balance moves, no P&L).
    static let ledger = """
    [{"billId":"f1","ts":"1788854401550","type":"8","subType":"174","instId":"SOL-USDT-SWAP","ccy":"USDT",
      "bal":"3968.74","balChg":"0.0000000000000000","pnl":"0.6798147560681625","fee":"0","interest":"0",
      "posBal":"2005.76","posBalChg":"0.6798147560681625","mgnMode":"isolated"},
     {"billId":"t1","ts":"1788848720681","type":"2","subType":"3","instId":"SOL-USDT-SWAP","ccy":"USDT",
      "balChg":"-695.4598815","pnl":"0","fee":"-2.7707565","interest":"0","posBalChg":"692.689125"},
     {"billId":"c1","ts":"1788798433496","type":"2","subType":"5","instId":"ETH-USDT-SWAP","ccy":"USDT",
      "balChg":"1200","pnl":"-33.73932","fee":"-14.155849626","interest":"0"},
     {"billId":"x1","ts":"1788790000000","type":"1","subType":"11","instId":"","ccy":"USDT",
      "balChg":"5000","pnl":"0","fee":"0","interest":"0"},
     {"billId":"f1","ts":"1788854401550","type":"8","subType":"174","instId":"SOL-USDT-SWAP","ccy":"USDT",
      "balChg":"0","pnl":"0.6798147560681625","fee":"0"}]
    """

    @Test("账单按类型读出盈亏、手续费；转账不产生结果；同一账单不重复")
    func billsAreParsedAndDeduplicated() throws {
        let bills = TradeBridge.parseBills(json: Self.ledger)
        #expect(bills.map(\.id) == ["f1", "t1", "c1", "x1"], "newest first, one per id")

        let funding = try #require(bills.first { $0.id == "f1" })
        #expect(funding.isFunding)
        #expect(abs(funding.result - 0.6798147560681625) < 1e-12,
                "isolated funding leaves the cash balance alone; the P&L field is the settlement")

        let opening = try #require(bills.first { $0.id == "t1" })
        #expect(abs(opening.result + 2.7707565) < 1e-12, "an opening trade costs its fee")

        let closing = try #require(bills.first { $0.id == "c1" })
        #expect(abs(closing.result - (-33.73932 - 14.155849626)) < 1e-9)

        let transfer = try #require(bills.first { $0.id == "x1" })
        #expect(transfer.result == 0, "moving money in is not making it")
        #expect(transfer.instId == nil)
    }

    /// 2026-09-08 12:00 Singapore. Today began at 2026-09-07T16:00Z; the week
    /// (Monday 2026-09-07) began at 2026-09-06T16:00Z.
    static let noon = ISO8601DateFormatter().date(from: "2026-09-08T04:00:00Z")!

    private func bill(_ id: String, at iso: String, type: Int = 2, pnl: Double = 0, fee: Double = 0) -> ExchangeBill {
        ExchangeBill(
            id: id, ts: ISO8601DateFormatter().date(from: iso)!, type: type, subType: nil,
            instId: "ETH-USDT-SWAP", ccy: "USDT", pnl: pnl, fee: fee, interest: 0,
            balanceChange: 0, positionBalanceChange: 0)
    }

    @Test("三个窗口各自只汇总自己时段内的账单")
    func windowsSumOnlyTheirOwnBills() {
        let listing = ExchangeBillListing(bills: [
            bill("a", at: "2026-09-08T03:50:00Z", type: 8, pnl: 1),        // 10 minutes ago: funding
            bill("b", at: "2026-09-08T01:00:00Z", pnl: 10, fee: -1),      // this morning: a close
            bill("c", at: "2026-09-07T10:00:00Z", pnl: 100, fee: -5),     // yesterday evening (SGT)
            bill("d", at: "2026-09-05T10:00:00Z", pnl: 1000),             // last week
        ], exhausted: true)

        let hour = BilledPnL.over(.hour1, listing: listing, now: Self.noon)
        #expect(hour.total == 1 && hour.funding == 1 && hour.billCount == 1)

        let day = BilledPnL.over(.day1, listing: listing, now: Self.noon)
        #expect(day.closedTradePnL == 10 && day.fees == -1 && day.funding == 1)
        #expect(day.total == 10 && day.billCount == 2)

        let week = BilledPnL.over(.day7, listing: listing, now: Self.noon)
        #expect(week.total == 10 - 1 + 100 - 5 + 1 && week.billCount == 3)
        #expect(hour.coversWindow && day.coversWindow && week.coversWindow)
    }

    @Test("账单没翻到窗口起点时标记为未覆盖，翻完了就算覆盖")
    func coverageFollowsWhatTheListingReached() {
        let inside = [bill("a", at: "2026-09-08T01:00:00Z", pnl: 10)]
        let truncated = ExchangeBillListing(bills: inside, exhausted: false)
        #expect(BilledPnL.over(.hour1, listing: truncated, now: Self.noon).coversWindow,
                "the hour's anchor is later than the oldest bill")
        #expect(!BilledPnL.over(.day1, listing: truncated, now: Self.noon).coversWindow,
                "a full page whose oldest bill is inside the window may be missing older ones")
        #expect(!BilledPnL.over(.day7, listing: truncated, now: Self.noon).coversWindow)

        let complete = ExchangeBillListing(bills: inside, exhausted: true)
        #expect(BilledPnL.over(.day7, listing: complete, now: Self.noon).coversWindow,
                "nothing older exists, so the window is fully summed")
        #expect(BilledPnL.over(.day7, listing: ExchangeBillListing(bills: [], exhausted: false), now: Self.noon)
                    .coversWindow == false, "no bills and no end reached says nothing")
    }
}

@Suite("Funding settlements")
struct FundingAmountTests {
    /// Isolated margin books funding to the position: `balChg` is "0" and the
    /// settlement is `pnl`. Cross margin is the other way round. Reading
    /// `balChg` first booked every isolated settlement as nothing.
    @Test("逐仓资金费在 pnl 里，全仓在 balChg 里，两种都读得到")
    func isolatedAndCrossFundingAreBothRead() {
        let json = """
        [{"billId":"iso","instId":"SOL-USDT-SWAP","type":"8","subType":"174","pnl":"0.6798147560681625",
          "fee":"0","balChg":"0.0000000000000000","posBalChg":"0.6798147560681625","ts":"1788854401550"},
         {"billId":"cross","instId":"ETH-USDT-SWAP","type":"8","subType":"173","pnl":"-32.237933",
          "fee":"0","balChg":"-32.237933","ts":"1786320000000"}]
        """
        let payments = TradeBridge.parseFundingPayments(json: json, instId: nil)
        #expect(abs((payments.first { $0.id == "iso" }?.amount ?? 0) - 0.6798147560681625) < 1e-12)
        #expect(abs((payments.first { $0.id == "cross" }?.amount ?? 0) + 32.237933) < 1e-9)

        let totals = TradeBridge.parseBookTotals(json: [json])
        #expect(abs((totals["SOL-USDT-SWAP"]?.funding ?? 0) - 0.6798147560681625) < 1e-12)
        #expect(abs((totals["ETH-USDT-SWAP"]?.funding ?? 0) + 32.237933) < 1e-9)
    }
}

@Suite("Positions across families")
struct AllPositionsTests {
    @Test("交易所返回的族原样带上，交割期货不会被当成现货")
    func theExchangesFamilyIsRead() throws {
        let json = """
        [{"instId":"BTC-USDT-250926","instType":"FUTURES","pos":"3","posSide":"long","avgPx":"80000",
          "markPx":"80100","upl":"3","lever":"5","notionalUsd":"2403"},
         {"instId":"BTC-USD-260917-80000-C","instType":"OPTION","pos":"-2","posSide":"net","avgPx":"0.02",
          "markPx":"0.021","upl":"-1"}]
        """
        let positions = TradeBridge.parsePositions(json: json)
        let future = try #require(positions.first { $0.instId == "BTC-USDT-250926" })
        #expect(future.instType == "FUTURES" && future.familyLabel == "交割" && !future.isOption)
        #expect(future.notionalUsd == 2403)
        let option = try #require(positions.first { $0.instId.hasSuffix("-C") })
        #expect(option.isOption && option.familyLabel == "期权")
    }

    @Test("没有全量接口的交易所按族合并，同一仓位只算一次")
    @MainActor func theDefaultUnionCountsEachPositionOnce() async throws {
        let fake = FakeVenue()
        fake.positionsResult = .success([ExchangePosition(
            instId: "BTC-USDT-SWAP", posSide: .long, quantity: 4, averagePrice: 100,
            markPrice: 100, unrealisedPnL: 0, leverage: 1, liquidationPrice: nil)])
        let all = try await fake.allPositions(mode: .demo)
        #expect(all.count == 1, "answered for every family asked, counted once")
    }
}
