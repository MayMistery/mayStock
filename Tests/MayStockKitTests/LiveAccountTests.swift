import Foundation
import Testing
@testable import MayStockKit

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func at(_ minutes: Double) -> Date {
    epoch.addingTimeInterval(minutes * 60)
}

/// The account as the phone shows it: every figure from one reading, valued
/// at the mark as it streams, stated in the unit it is in, and a day's result
/// counted the way the exchange's own app counts it.
///
/// Measured on the live account (2026-10-08, 21.5 ETH long) before these:
/// the panel's floating profit came from a 300 s poll and its equity from a
/// 60 s one, and over ten minutes they sat $52 and $27 off the exchange on
/// average; the equity was dollars labelled USDT; and 「今日」 counted only
/// what the bills had realised, so it could never match 「今日盈亏」.
@Suite("Live account")
@MainActor
struct LiveAccountTests {

    // MARK: Units

    /// The live account's own reading: `totalEq` is dollars, its USDT line is
    /// valued at OKX's USDT price.
    private let reading = AccountSnapshot(
        balances: [AccountBalance(ccy: "USDT", available: 2871.338915974109, total: 8491.264868898954, valuationUsd: 8484.726594949901)],
        totalEquity: 8484.733987517242, equityCurrency: "USD")

    @Test("equity is stated in the quote at the reading's own rate, and labelled with the unit it is in")
    func equityInItsOwnUnit() throws {
        let usdt = try #require(reading.equity(in: "USDT"))
        let rate = 8484.726594949901 / 8491.264868898954
        #expect(abs(usdt - 8484.733987517242 / rate) < 1e-9)
        let shown = try #require(reading.displayEquity(in: "USDT"))
        #expect(shown.currency == "USDT" && shown.amount == usdt)
        // No rate into the asked unit: the venue's own unit, never a borrowed label.
        let noRate = AccountSnapshot(balances: [], totalEquity: 1000, equityCurrency: "USD")
        let fallback = try #require(noRate.displayEquity(in: "USDT"))
        #expect(fallback.currency == "USD" && fallback.amount == 1000)
        #expect(noRate.equity(in: "USDT") == nil)
    }

    @Test("a currency's rate is its equity's valuation over its equity, not over its cash")
    func rateIsEquityOverEquity() throws {
        // Cash 2,871 inside an equity of 8,491: the pair the venue values is
        // the equity. The old reading put cash under the valuation and got
        // 2.955 dollars per USDT.
        let rate = try #require(reading.usdRate(for: "USDT"))
        #expect(abs(rate - 0.99923) < 1e-5)
    }

    // MARK: One mapping for the stream and for REST

    @Test("a REST position document maps through the stream's one reader, return and mark time included")
    func restAndStreamShareOneMapping() throws {
        let document = """
        {"data":[{"instId":"ETH-USDT-SWAP","instType":"SWAP","posId":"1","posSide":"long","pos":"214.97","avgPx":"2558.0145621063081902",
        "markPx":"2535.78","upl":"-477.97638159930744","uplRatio":"-0.0869211709568996","lever":"10","liqPx":"2284.477497196275",
        "notionalUsd":"54470.2337963784","mgnMode":"isolated","margin":"6098.97","mmr":"218.04","mgnRatio":"23.172036702068194",
        "ccy":"USDT","usdPx":"0.99924"}]}
        """
        let readAt = Date(timeIntervalSince1970: 1_791_465_000)
        let position = try #require(KernelAccount.positions(document, readAt: readAt).first)
        #expect(position.quantity == 214.97 && position.posSide == .long)
        #expect(position.unrealisedPnL == -477.97638159930744)
        #expect(position.unrealisedRatio == -0.0869211709568996)
        #expect(position.marginRatio == 23.172036702068194)
        #expect(position.markAt == readAt, "a REST read is as of when it was read")
        #expect(!position.isValuedLive)
        #expect(position.unrealisedPnLUsd.map { abs($0 - -477.97638159930744 * 0.99924) < 1e-9 } == true)
    }

    // MARK: The live document, end to end

    private func layer() throws -> LiveKernel {
        try LiveKernel(config: LiveKernel.Config(
            instId: "ETH-USDT-SWAP", followsHeldPosition: true, mode: .live,
            okxProfile: nil, okxConfigPath: nil, schwabctlPath: nil,
            network: false, nowOverrideMs: 1_790_164_800_000, analytics: false))
    }

    @Test("the feed hands every screen the account valued at the streamed mark")
    func feedValuesAtTheStreamedMark() throws {
        let kernel = try layer()
        defer { kernel.stop() }
        let feed = LiveAccountFeed(kernel: kernel, venue: { nil }, mode: { .live })
        var delivered: [LiveAccount] = []
        feed.onChange = { delivered.append($0) }
        #expect(feed.pull(), "the first document")
        let first = try #require(feed.account)
        #expect(!first.wasRead, "nothing read is not flat")

        try kernel.ingest(topic: "rest.okx.positions", payload: """
            {"data":[{"instId":"ETH-USDT-SWAP","instType":"SWAP","posId":"1","posSide":"long","pos":"10","avgPx":"2500",
            "markPx":"2510","upl":"10","uplRatio":"0.08","lever":"10","notionalUsd":"2509.0","mgnMode":"isolated","margin":"125",
            "ccy":"USDT","usdPx":"0.9996"}]}
            """)
        try kernel.ingest(topic: "rest.okx.account", payload: """
            {"data":[{"totalEq":"999.6","details":[{"ccy":"USDT","eq":"1000","eqUsd":"999.6","upl":"10","availBal":"875"}]}]}
            """)
        try kernel.ingest(topic: "rest.okx.spec.ETH-USDT-SWAP", payload: """
            {"code":"0","data":[{"instId":"ETH-USDT-SWAP","instType":"SWAP","tickSz":"0.01","lotSz":"0.01","minSz":"0.01",
            "ctVal":"0.1","ctMult":"1","ctType":"linear","ctValCcy":"ETH","settleCcy":"USDT","state":"live"}]}
            """)
        try kernel.ingest(topic: "okx.marks", payload: """
            {"arg":{"channel":"mark-price","instId":"ETH-USDT-SWAP"},"data":[{"instId":"ETH-USDT-SWAP","markPx":"2530","ts":"1790164800050"}]}
            """)
        #expect(feed.pull())
        let account = try #require(feed.account)
        #expect(account.wasRead && account.source == "rest")
        let position = try #require(account.exchangePositions.first)
        // (2530 − 2500) × 10 contracts × 0.1 ETH.
        #expect(abs(position.unrealisedPnL - 30) < 1e-9)
        #expect(abs((position.unrealisedRatio ?? 0) - 0.24) < 1e-12, "the venue's ratio, scaled with the profit")
        #expect(position.isValuedLive && position.markPrice == 2530)
        let snapshot = try #require(account.snapshot)
        // 1000 − 10 + 30 USDT, valued at 0.9996.
        #expect(abs((snapshot.totalEquity ?? 0) - (999.6 + 20 * 0.9996)) < 1e-9)
        #expect(abs((snapshot.equity(in: "USDT") ?? 0) - 1020) < 1e-9)
        #expect(delivered.count == 2)
        #expect(!feed.pull(), "nothing moved: nothing handed out")
    }

    // MARK: A day's result, counted like the phone

    @Test("a window's result leaves out the money moved in, and is stated in the quote at each end's own rate")
    func resultLeavesOutTransfers() throws {
        let curve = AccountEquityCurve(mode: .live)
        // Dollars as the venue states them, with its USDT price at the time.
        curve.record(equity: 999.0, at: at(0), quoteUsd: 0.999)
        curve.record(equity: 1_999.0, at: at(30), quoteUsd: 0.9995)
        let change = try #require(curve.change(
            over: .hour1, now: at(40), latest: 2_048.975, quoteUsd: 0.9995,
            transfers: [(at(20), 1_000), (at(-5), 400)]))
        #expect(abs(change.startEquity - 1_000) < 1e-9, "999 dollars at 0.999 is 1,000 USDT")
        #expect(abs(change.endEquity - 2_050) < 1e-9)
        #expect(change.transfers == 1_000 && change.transferCount == 1, "only what landed after the reference")
        #expect(abs(change.changeQuote - 50) < 1e-9, "made 50; 1,000 was moved in")
        #expect(!change.rateApproximated)
        #expect(change.transfersNote.contains("1000.00"))
    }

    @Test("a point recorded before rates were kept is stated at the endpoint's rate, and says so")
    func legacyPointsSayTheirRateIsBorrowed() throws {
        let curve = AccountEquityCurve(mode: .live)
        curve.record(equity: 1_000, at: at(0))
        let change = try #require(curve.change(over: .hour1, now: at(10), latest: 1_010, quoteUsd: 0.999))
        #expect(change.rateApproximated)
        #expect(abs(change.changeQuote - 10 / 0.999) < 1e-9)
        #expect(change.coverageNote.contains("汇率"))
    }
}

/// A continuous market's day is a choice, and the phone made one: the change
/// shown must be measured from the same instant, or the two never agree.
@Suite("Change basis")
@MainActor
struct ChangeBasisTests {

    /// ETH-USDT's ticker on 2026-10-08 as OKX pushes it: three references.
    private let frame = """
        {"arg":{"channel":"tickers","instId":"ETH-USDT"},"data":[{"instType":"SPOT","instId":"ETH-USDT","last":"2540.24",
        "lastSz":"0.1","askPx":"2540.25","askSz":"1","bidPx":"2540.24","bidSz":"1","open24h":"2561.24","high24h":"2590",
        "low24h":"2510","volCcy24h":"1","vol24h":"100","sodUtc0":"2574.48","sodUtc8":"2571.10","ts":"1791466000000"}]}
        """

    @Test("an OKX ticker carries every reference, and is measured on the one asked for")
    func everyReferenceIsKept() throws {
        guard case .ticker(let ticker) = try OKXWireDecoder.decode(frame) else {
            Issue.record("not a ticker")
            return
        }
        #expect(ticker.basis == .rolling24h && ticker.rangeLabel == "24h")
        #expect(ticker.references[.sinceUtc8Midnight] == 2571.10)
        #expect(ticker.references[.sinceUtcMidnight] == 2574.48)
        let beijing = ticker.rebased(to: .sinceUtc8Midnight)
        #expect(beijing.basis == .sinceUtc8Midnight && beijing.reference == 2571.10)
        #expect(abs(beijing.changePct - (2540.24 / 2571.10 - 1) * 100) < 1e-9)
        #expect(beijing.rangeLabel == "24h", "the high, low and volume are still the venue's 24 hours")
        #expect(abs((beijing.changePct(on: .rolling24h) ?? 0) - (2540.24 / 2561.24 - 1) * 100) < 1e-9)
        // A reference the venue did not publish leaves the ticker as it was.
        #expect(ticker.rebased(to: .previousClose) == ticker)
    }

    @Test("a config written before the setting existed keeps every other setting and starts at Beijing midnight")
    func oldConfigsLoad() throws {
        let old = #"{"launchAtLogin":true,"hoverDelayMs":300,"hideDelayMs":700}"#
        let prefs = try JSONDecoder().decode(GeneralPrefs.self, from: Data(old.utf8))
        #expect(prefs.launchAtLogin && prefs.hoverDelayMs == 300 && prefs.hideDelayMs == 700)
        #expect(prefs.changeBasis == .sinceUtc8Midnight)
        // A basis a continuous market cannot be measured on is not taken.
        let stock = #"{"changeBasis":"previousClose"}"#
        #expect(try JSONDecoder().decode(GeneralPrefs.self, from: Data(stock.utf8)).changeBasis == .sinceUtc8Midnight)
        let rolling = #"{"changeBasis":"rolling24h"}"#
        #expect(try JSONDecoder().decode(GeneralPrefs.self, from: Data(rolling.utf8)).changeBasis == .rolling24h)
    }

    @Test("the intelligence runtime still gets a 24-hour change, whatever the screen measures from")
    func intelligenceKeepsItsDay() throws {
        guard case .ticker(let ticker) = try OKXWireDecoder.decode(frame) else { return }
        let quote = IntelligenceQuote(ticker: ticker.rebased(to: .sinceUtc8Midnight))
        #expect(abs((quote.change24h ?? 0) - (2540.24 / 2561.24 - 1) * 100) < 1e-9)
    }
}

/// A window measured from the last sample before an outage that spanned its
/// start is not that window — the week was measured from Saturday on
/// 2026-10-08, and nothing said so.
@Suite("Window anchoring")
@MainActor
struct WindowAnchoringTests {
    @Test("a reference far before the window's start is marked, and named")
    func anEarlyReferenceIsNotAnchored() throws {
        let curve = AccountEquityCurve(mode: .live)
        let anchor = EquityWindow.day1.anchor(now: at(24 * 60), venue: .okx)
        // The last sample before midnight is three hours before it; the next
        // one an hour after.
        curve.record(equity: 1_000, at: anchor.addingTimeInterval(-3 * 3_600))
        curve.record(equity: 1_050, at: anchor.addingTimeInterval(3_600))
        let change = try #require(curve.change(over: .day1, now: anchor.addingTimeInterval(2 * 3_600), latest: 1_060))
        #expect(change.startsEarly && !change.startsLate && !change.isAnchored)
        #expect(change.coverageNote.contains("算起"))
        // A sample a minute before midnight is midnight's.
        let close = AccountEquityCurve(mode: .live)
        close.record(equity: 1_000, at: anchor.addingTimeInterval(-60))
        let anchored = try #require(close.change(over: .day1, now: anchor.addingTimeInterval(600), latest: 1_010))
        #expect(anchored.isAnchored && !anchored.startsEarly)
    }
}

/// A venue with no stream is read as often as what it holds can move — on
/// the venue's own valuation every time.
@Suite("Polled account cadence")
struct PolledAccountCadenceTests {
    private let cash = AccountBalance(ccy: "USD", available: 1_000, total: 1_000, valuationUsd: 1_000)

    private func reading(
        _ balances: [AccountBalance], positions: [ExchangePosition]?, shares: [ExchangePosition] = []
    ) -> AccountReading {
        AccountReading(
            snapshot: AccountSnapshot(balances: balances, totalEquity: 1_000, equityCurrency: "USD"),
            equityAt: epoch, positions: positions, shareHoldings: shares,
            positionsAt: positions == nil ? nil : epoch, source: .polled)
    }

    private func holding(_ instId: String, quantity: Double) -> ExchangePosition {
        ExchangePosition(instId: instId, posSide: .net, quantity: quantity, averagePrice: 100, markPrice: 110,
                         unrealisedPnL: 10 * quantity, leverage: nil, liquidationPrice: nil)
    }

    @Test("只有现金一分钟读一次；持股、合约、其他币种、读不到的持仓都十秒一次")
    func intervalFollowsWhatTheAccountHolds() {
        #expect(AccountReading.pricedPollInterval < AccountReading.cashPollInterval)
        let usd = "USD"
        #expect(reading([cash], positions: []).pollInterval(quoteCurrency: usd) == AccountReading.cashPollInterval)
        let share = AccountBalance(ccy: "TSLA", available: 10, total: 10, valuationUsd: 1_100)
        #expect(reading([cash, share], positions: [], shares: [holding("TSLA", quantity: 10)])
            .pollInterval(quoteCurrency: usd) == AccountReading.pricedPollInterval)
        #expect(reading([cash], positions: [holding("ETH-USDT-SWAP", quantity: 2)])
            .pollInterval(quoteCurrency: usd) == AccountReading.pricedPollInterval)
        let coin = AccountBalance(ccy: "BTC", available: 0.1, total: 0.1, valuationUsd: 6_000)
        #expect(reading([cash, coin], positions: []).pollInterval(quoteCurrency: usd) == AccountReading.pricedPollInterval)
        #expect(reading([cash], positions: nil).pollInterval(quoteCurrency: usd) == AccountReading.pricedPollInterval,
                "positions that could not be read count as held")
        let emptied = AccountBalance(ccy: "BTC", available: 0, total: 0, valuationUsd: 0)
        #expect(reading([cash, emptied], positions: []).pollInterval(quoteCurrency: usd) == AccountReading.cashPollInterval,
                "a line at zero holds nothing")
    }
}

/// The combined view's per-account figure is the one that account's own
/// pages show, with its dollars beside it.
@Suite("Combined account shares")
struct CombinedShareTests {
    @Test("本币权益按各账户自己页面的币种显示，折合美元另列")
    func nativeIsWhatTheAccountsOwnPagesShow() throws {
        let okx = AccountSnapshot(
            balances: [AccountBalance(ccy: "USDT", available: 7_500, total: 7_500, valuationUsd: 7_494)],
            totalEquity: 7_494, equityCurrency: "USD")
        let schwab = AccountSnapshot(
            balances: [AccountBalance(ccy: "USD", available: 1_456.72, total: 1_456.72, valuationUsd: 1_456.72)],
            totalEquity: 1_456.72, equityCurrency: "USD")
        let combined = CombinedPortfolio.combine([
            .init(venue: .okx, snapshot: okx, error: nil, readAt: epoch),
            .init(venue: .schwab, snapshot: schwab, error: nil, readAt: epoch),
        ])
        for share in combined.shares {
            let snapshot = share.venue == .okx ? okx : schwab
            let shown = try #require(snapshot.displayEquity(in: share.venue.quoteCurrency))
            #expect(share.nativeCurrency == shown.currency && share.nativeEquity == shown.amount, "\(share.venue)")
            #expect(share.usdEquity == snapshot.totalEquity, "the total adds the venue's own dollars")
        }
        #expect(combined.shares.first { $0.venue == .okx }?.nativeCurrency == "USDT")
        #expect(combined.totalUsd == 7_494 + 1_456.72)
    }
}
