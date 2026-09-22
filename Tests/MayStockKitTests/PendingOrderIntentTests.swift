import Foundation
import Testing
@testable import MayStockKit

/// The gate in front of a real order, so the tests that matter most are the
/// ones where a malformed URL must be *refused* rather than guessed at.
@Suite("Pending order intent")
struct PendingOrderIntentTests {

    private func url(_ query: String) -> URL {
        URL(string: "maystock://order?\(query)")!
    }

    /// The live hedge this feature was built for: 73 contracts of a 2600 call
    /// against a short, priced in ETH.
    private let optionQuery = """
        instId=ETH-USD-260919-2600-C&instType=OPTION&side=buy&kind=ioc\
        &size=73&limitPrice=0.0043&mode=live&nonce=hedge-1\
        &maxLossUSD=146.4&rationale=%E5%AF%B9%E5%86%B2%E7%A9%BA%E5%A4%B4&tolerancePct=5
        """

    // MARK: - Accepting a well-formed proposal

    @Test("parses an option hedge")
    func parsesOptionHedge() throws {
        let intent = try PendingOrderIntent.parse(url(optionQuery))
        #expect(intent.instId == "ETH-USD-260919-2600-C")
        #expect(intent.instType == .option)
        #expect(intent.side == .buy)
        #expect(intent.kind == .ioc)
        #expect(intent.size == 73)
        #expect(intent.priceBasis == .absolute(0.0043))
        #expect(intent.statedLimitPrice == 0.0043)
        #expect(intent.mode == .live)
        #expect(intent.nonce == "hedge-1")
        #expect(intent.maxLossUSD == 146.4)
        #expect(intent.rationale == "对冲空头")
        #expect(intent.priceTolerancePct == 5)
        #expect(intent.reduceOnly == false)
        #expect(intent.posSide == nil)
    }

    @Test("tolerance defaults when the URL omits it")
    func toleranceDefaults() throws {
        let intent = try PendingOrderIntent.parse(url(
            "instId=ETH-USDT-SWAP&instType=SWAP&side=sell&kind=limit&size=10"
            + "&limitPrice=2600&mode=demo&nonce=n1"))
        #expect(intent.priceTolerancePct == PendingOrderIntent.defaultTolerancePct)
    }

    @Test("accepts a perpetual with a leg and reduce-only")
    func parsesPerpetualLeg() throws {
        let intent = try PendingOrderIntent.parse(url(
            "instId=ETH-USDT-SWAP&instType=SWAP&side=buy&kind=market&size=72.69"
            + "&posSide=short&reduceOnly=true&mode=live&nonce=close-1"))
        #expect(intent.posSide == .short)
        #expect(intent.reduceOnly == true)
        #expect(intent.kind == .market)
        #expect(intent.priceBasis == nil)
        #expect(intent.statedLimitPrice == nil)
    }

    @Test("case is not significant for enum-valued fields")
    func enumsAreCaseInsensitive() throws {
        let intent = try PendingOrderIntent.parse(url(
            "instId=ETH-USDT-SWAP&instType=swap&side=BUY&kind=Limit&size=1"
            + "&limitPrice=2600&mode=LIVE&nonce=n1"))
        #expect(intent.instType == .swap)
        #expect(intent.side == .buy)
        #expect(intent.kind == .limit)
        #expect(intent.mode == .live)
    }

    // MARK: - Refusing what it cannot trust

    @Test("refuses an unknown parameter rather than ignoring it")
    func refusesUnknownParameter() {
        // A typo in a size or price must fail loudly: skipping the field would
        // place an order that differs from the one that was written.
        #expect(throws: PendingOrderIntent.ParseError.unknownParameters(["sizee"])) {
            try PendingOrderIntent.parse(url(
                "instId=ETH-USDT-SWAP&instType=SWAP&side=buy&kind=market"
                + "&size=1&sizee=99&mode=demo&nonce=n1"))
        }
    }

    @Test("refuses a duplicated parameter")
    func refusesDuplicate() {
        #expect(throws: PendingOrderIntent.ParseError.duplicateParameter("size")) {
            try PendingOrderIntent.parse(url(
                "instId=ETH-USDT-SWAP&instType=SWAP&side=buy&kind=market"
                + "&size=1&size=999&mode=demo&nonce=n1"))
        }
    }

    @Test("requires mode to be stated outright", arguments: ["mode", "nonce", "instId", "size"])
    func requiresField(_ field: String) {
        var parts = [
            "instId=ETH-USDT-SWAP", "instType=SWAP", "side=buy", "kind=market",
            "size=1", "mode=demo", "nonce=n1",
        ]
        parts.removeAll { $0.hasPrefix("\(field)=") }
        #expect(throws: PendingOrderIntent.ParseError.missing(field)) {
            try PendingOrderIntent.parse(url(parts.joined(separator: "&")))
        }
    }

    @Test("refuses a non-positive size", arguments: ["0", "-5"])
    func refusesNonPositiveSize(_ size: String) {
        #expect(throws: (any Error).self) {
            try PendingOrderIntent.parse(url(
                "instId=ETH-USDT-SWAP&instType=SWAP&side=buy&kind=market"
                + "&size=\(size)&mode=demo&nonce=n1"))
        }
    }

    @Test("refuses a non-finite number", arguments: ["nan", "inf", "abc"])
    func refusesNonFiniteSize(_ size: String) {
        // `Double("nan")` and `Double("inf")` both succeed, and either would
        // reach the exchange as garbage.
        #expect(throws: (any Error).self) {
            try PendingOrderIntent.parse(url(
                "instId=ETH-USDT-SWAP&instType=SWAP&side=buy&kind=market"
                + "&size=\(size)&mode=demo&nonce=n1"))
        }
    }

    @Test("refuses a priced kind with no price")
    func refusesUnpricedLimit() {
        #expect(throws: PendingOrderIntent.ParseError.unpricedLimit) {
            try PendingOrderIntent.parse(url(
                "instId=ETH-USDT-SWAP&instType=SWAP&side=buy&kind=limit"
                + "&size=1&mode=demo&nonce=n1"))
        }
    }

    @Test("refuses a market order carrying a price")
    func refusesPricedMarket() {
        #expect(throws: PendingOrderIntent.ParseError.pricedMarket) {
            try PendingOrderIntent.parse(url(
                "instId=ETH-USDT-SWAP&instType=SWAP&side=buy&kind=market"
                + "&size=1&limitPrice=2600&mode=demo&nonce=n1"))
        }
    }

    @Test("refuses an unparseable enum value")
    func refusesBadEnum() {
        #expect(throws: (any Error).self) {
            try PendingOrderIntent.parse(url(
                "instId=ETH-USDT-SWAP&instType=SWAP&side=long&kind=market"
                + "&size=1&mode=demo&nonce=n1"))
        }
        #expect(throws: (any Error).self) {
            try PendingOrderIntent.parse(url(
                "instId=ETH-USDT-SWAP&instType=SWAP&side=buy&kind=market"
                + "&size=1&mode=paper&nonce=n1"))
        }
    }

    @Test("refuses the wrong scheme or host")
    func refusesWrongTarget() {
        #expect(throws: (any Error).self) {
            try PendingOrderIntent.parse(URL(string: "other://order?nonce=n1")!)
        }
        #expect(throws: (any Error).self) {
            try PendingOrderIntent.parse(URL(string: "maystock://unlock?nonce=n1")!)
        }
    }

    @Test("refuses a query-less URL")
    func refusesEmptyQuery() {
        #expect(throws: PendingOrderIntent.ParseError.noQuery) {
            try PendingOrderIntent.parse(URL(string: "maystock://order")!)
        }
    }

    // MARK: - Handing it to the exchange

    @Test("maps onto an order request, with tdMode from the account")
    func mapsToOrderRequest() throws {
        let intent = try PendingOrderIntent.parse(url(optionQuery))
        let order = intent.toOrderRequest(
            limitPrice: 0.0043, tradeMode: "isolated", clOrdId: "tag-1")
        #expect(order.instId == "ETH-USD-260919-2600-C")
        #expect(order.instType == .option)
        #expect(order.side == .buy)
        #expect(order.kind == .ioc)
        #expect(order.size == 73)
        // Contracts, never quote: quote sizing only means anything for spot.
        #expect(order.sizeUnit == .base)
        #expect(order.limitPrice == 0.0043)
        #expect(order.tradeMode == "isolated")
        #expect(order.clOrdId == "tag-1")
        #expect(order.reduceOnly == false)
    }

    @Test("a single-currency margin account isolates an option")
    func optionTradeModeFollowsAccountLevel() {
        // The URL must not get to pick its own margin treatment; the account
        // level decides. May's live account is acctLv=2.
        #expect(AccountTradingConfig(positionMode: nil, accountLevel: 1).optionTradeMode == "cash")
        #expect(AccountTradingConfig(positionMode: nil, accountLevel: 2).optionTradeMode == "isolated")
        #expect(AccountTradingConfig(positionMode: nil, accountLevel: 3).optionTradeMode == "cross")
        #expect(AccountTradingConfig(positionMode: nil, accountLevel: nil).optionTradeMode == "cross")
    }

    // MARK: - Drift against the live book

    @Test("a buy drifts when the ask rises above the limit")
    func buyDriftIsUnfavourableWhenAskRises() throws {
        let intent = try PendingOrderIntent.parse(url(optionQuery))  // buy @ 0.0043
        let drift = intent.priceDrift(limit: 0.0043, bid: 0.0044, ask: 0.00473)
        // (0.00473 - 0.0043) / 0.0043 = +10%
        #expect(abs((drift ?? 0) - 10) < 0.001)
        #expect(intent.exceedsTolerance(limit: 0.0043, bid: 0.0044, ask: 0.00473))
    }

    @Test("a buy shows favourable drift when the ask falls")
    func buyDriftIsFavourableWhenAskFalls() throws {
        let intent = try PendingOrderIntent.parse(url(optionQuery))
        let drift = intent.priceDrift(limit: 0.0043, bid: 0.0040, ask: 0.0041)
        #expect((drift ?? 0) < 0)
        #expect(!intent.exceedsTolerance(limit: 0.0043, bid: 0.0040, ask: 0.0041))
    }

    @Test("a sell reads the bid, and the sign still means the same thing")
    func sellDriftUsesBid() throws {
        let intent = try PendingOrderIntent.parse(url(
            "instId=ETH-USDT-SWAP&instType=SWAP&side=sell&kind=limit&size=1"
            + "&limitPrice=2600&mode=demo&nonce=n1&tolerancePct=2"))
        // Bid below the limit is unfavourable for a seller.
        let unfavourable = intent.priceDrift(limit: 2600, bid: 2548, ask: 2550)
        #expect(abs((unfavourable ?? 0) - 2) < 0.001)
        #expect(!intent.exceedsTolerance(limit: 2600, bid: 2548, ask: 2550))  // at tolerance
        #expect(intent.exceedsTolerance(limit: 2600, bid: 2500, ask: 2502))   // past it
        // Bid above the limit is favourable.
        #expect((intent.priceDrift(limit: 2600, bid: 2650, ask: 2652) ?? 0) < 0)
    }

    @Test("no drift to report without a comparable quote")
    func driftNeedsAQuote() throws {
        let intent = try PendingOrderIntent.parse(url(optionQuery))
        #expect(intent.priceDrift(limit: 0.0043, bid: nil, ask: nil) == nil)
        // A buy needs the ask specifically.
        #expect(intent.priceDrift(limit: 0.0043, bid: 0.004, ask: nil) == nil)
        #expect(!intent.exceedsTolerance(limit: 0.0043, bid: nil, ask: nil))

        let market = try PendingOrderIntent.parse(url(
            "instId=ETH-USDT-SWAP&instType=SWAP&side=buy&kind=market&size=1"
            + "&mode=demo&nonce=n2"))
        #expect(market.priceDrift(limit: nil, bid: 2600, ask: 2601) == nil)
    }

    // MARK: - Relative pricing

    /// The tick and contract value of the real contract this was built for.
    private let tick = 0.0001
    private let contractValue = 0.1

    private func relative(
        _ mode: String, slip: String, side: String = "buy", cap: String? = nil
    ) throws -> PendingOrderIntent {
        var q = "instId=ETH-USD-260919-2600-C&instType=OPTION&side=\(side)&kind=ioc"
            + "&size=73&mode=live&nonce=rel-1&priceMode=\(mode)&maxSlipPct=\(slip)"
        if let cap { q += "&maxPremiumUSD=\(cap)" }
        return try PendingOrderIntent.parse(url(q))
    }

    @Test("parses a relative basis")
    func parsesRelativeBasis() throws {
        let intent = try relative("ask", slip: "3", cap: "200")
        #expect(intent.priceBasis == .relative(anchor: .ask, slipPct: 3, capUSD: 200))
        // There is no price yet — that is the point.
        #expect(intent.statedLimitPrice == nil)
    }

    /// A price typed into a URL is no more likely to sit on the tick than a
    /// computed one, and the exchange refuses one that does not — so the
    /// absolute basis is snapped like every other limit, crossing the book in
    /// the same direction so rounding never lands on the wrong side of what
    /// was authorised.
    @Test("URL 里写死的限价也要对齐到 tick")
    func anAbsoluteLimitIsSnappedToTheTick() throws {
        let buy = try PendingOrderIntent.parse(url(
            "instId=ETH-USD-260919-2600-C&instType=OPTION&side=buy&kind=ioc"
            + "&size=73&mode=live&nonce=abs-1&limitPrice=0.006653"))
        #expect(buy.resolveLimit(
            bid: 0.006, ask: 0.0065, mark: 0.00625, tick: tick,
            contractValue: contractValue, indexPrice: 2604) == .price(0.0067),
            "买单向上对齐，够得着卖一")

        let sell = try PendingOrderIntent.parse(url(
            "instId=ETH-USD-260919-2600-C&instType=OPTION&side=sell&kind=ioc"
            + "&size=73&mode=live&nonce=abs-2&limitPrice=0.005827"))
        #expect(sell.resolveLimit(
            bid: 0.006, ask: 0.0065, mark: 0.00625, tick: tick,
            contractValue: contractValue, indexPrice: 2604) == .price(0.0058),
            "卖单向下对齐")
    }

    @Test("a buy crosses up from the ask and snaps up")
    func buyCrossesUpFromAsk() throws {
        let intent = try relative("ask", slip: "3")
        // 0.0065 × 1.03 = 0.006695 → snapped up to the 0.0001 grid = 0.0067
        let resolved = intent.resolveLimit(
            bid: 0.006, ask: 0.0065, mark: 0.00625, tick: tick,
            contractValue: contractValue, indexPrice: 2604)
        #expect(resolved == .price(0.0067))
    }

    @Test("a sell crosses down from the bid and snaps down")
    func sellCrossesDownFromBid() throws {
        let intent = try relative("bid", slip: "3", side: "sell")
        // 0.006 × 0.97 = 0.00582 → snapped down = 0.0058
        let resolved = intent.resolveLimit(
            bid: 0.006, ask: 0.0065, mark: 0.00625, tick: tick,
            contractValue: contractValue, indexPrice: 2604)
        #expect(resolved == .price(0.0058))
    }

    @Test("every anchor reads the value it names", arguments: [
        ("ask", 0.0065), ("bid", 0.006), ("mid", 0.00625), ("mark", 0.0061),
    ])
    func anchorsReadTheirOwnValue(_ name: String, _ expected: Double) throws {
        let anchor = PriceAnchor(rawValue: name)!
        let value = anchor.value(bid: 0.006, ask: 0.0065, mark: 0.0061)
        #expect(abs((value ?? 0) - expected) < 1e-9)
    }

    @Test("zero slip sits exactly on the anchor")
    func zeroSlipSitsOnAnchor() throws {
        let intent = try relative("ask", slip: "0")
        let resolved = intent.resolveLimit(
            bid: 0.006, ask: 0.0065, mark: nil, tick: tick,
            contractValue: contractValue, indexPrice: 2604)
        #expect(resolved == .price(0.0065))
    }

    @Test("the premium cap refuses a book that ran away")
    func capRefusesRunawayBook() throws {
        // 73 × 0.1 × 0.0067 × 2604 ≈ 127 USD, so a 100 USD cap must refuse.
        let intent = try relative("ask", slip: "3", cap: "100")
        let resolved = intent.resolveLimit(
            bid: 0.006, ask: 0.0065, mark: nil, tick: tick,
            contractValue: contractValue, indexPrice: 2604)
        guard case .aboveCap(let limit, let premium, let cap) = resolved else {
            Issue.record("expected aboveCap, got \(resolved)")
            return
        }
        #expect(limit == 0.0067)
        #expect(premium > cap)
        #expect(cap == 100)
    }

    @Test("a cap that the premium fits under lets it through")
    func capAllowsAffordablePremium() throws {
        let intent = try relative("ask", slip: "3", cap: "200")
        let resolved = intent.resolveLimit(
            bid: 0.006, ask: 0.0065, mark: nil, tick: tick,
            contractValue: contractValue, indexPrice: 2604)
        #expect(resolved == .price(0.0067))
    }

    @Test("an unquoted anchor is reported, not guessed")
    func unquotedAnchorIsReported() throws {
        let intent = try relative("ask", slip: "3")
        #expect(intent.resolveLimit(
            bid: 0.006, ask: nil, mark: 0.0061, tick: tick,
            contractValue: contractValue, indexPrice: 2604) == .noQuote(anchor: .ask))
        // Mid needs both sides.
        let mid = try relative("mid", slip: "3")
        #expect(mid.resolveLimit(
            bid: nil, ask: 0.0065, mark: nil, tick: tick) == .noQuote(anchor: .mid))
    }

    @Test("an absolute basis resolves to itself, ignoring the book")
    func absoluteResolvesToItself() throws {
        let intent = try PendingOrderIntent.parse(url(optionQuery))
        #expect(intent.resolveLimit(
            bid: 0.009, ask: 0.01, mark: nil, tick: tick) == .price(0.0043))
    }

    @Test("a market order resolves to no price at all")
    func marketResolvesToMarket() throws {
        let intent = try PendingOrderIntent.parse(url(
            "instId=ETH-USDT-SWAP&instType=SWAP&side=buy&kind=market&size=1"
            + "&mode=demo&nonce=m1"))
        #expect(intent.resolveLimit(bid: 2600, ask: 2601, mark: nil, tick: 0.01)
                == .marketOrder)
    }

    @Test("a relative basis is never called stale")
    func relativeBasisIsNeverStale() throws {
        // It was priced off this very book a moment ago, so the tolerance
        // warning that exists for absolute limits must not fire.
        let intent = try relative("ask", slip: "3")
        #expect(!intent.exceedsTolerance(limit: 0.0067, bid: 0.01, ask: 0.02))
    }

    // MARK: - Refusing bad price specifications

    @Test("limitPrice and priceMode are mutually exclusive")
    func priceSpecsAreExclusive() {
        #expect(throws: PendingOrderIntent.ParseError.conflictingPrice) {
            try PendingOrderIntent.parse(url(
                "instId=ETH-USD-260919-2600-C&instType=OPTION&side=buy&kind=ioc"
                + "&size=73&mode=live&nonce=x&limitPrice=0.0043&priceMode=ask&maxSlipPct=3"))
        }
    }

    @Test("priceMode without maxSlipPct is refused")
    func relativeNeedsSlip() {
        #expect(throws: PendingOrderIntent.ParseError.relativeNeedsSlip) {
            try PendingOrderIntent.parse(url(
                "instId=ETH-USD-260919-2600-C&instType=OPTION&side=buy&kind=ioc"
                + "&size=73&mode=live&nonce=x&priceMode=ask"))
        }
    }

    @Test("slip and cap without a priceMode are refused")
    func slipWithoutModeIsRefused() {
        #expect(throws: (any Error).self) {
            try PendingOrderIntent.parse(url(
                "instId=ETH-USD-260919-2600-C&instType=OPTION&side=buy&kind=ioc"
                + "&size=73&mode=live&nonce=x&limitPrice=0.0043&maxSlipPct=3"))
        }
    }

    @Test("a negative slip would price away from the book")
    func negativeSlipIsRefused() {
        #expect(throws: (any Error).self) {
            try relative("ask", slip: "-3")
        }
    }

    @Test("an unknown anchor is refused")
    func unknownAnchorIsRefused() {
        #expect(throws: (any Error).self) {
            try relative("last", slip: "3")
        }
    }

    @Test("a market order may carry neither price form")
    func marketRejectsBothPriceForms() {
        #expect(throws: PendingOrderIntent.ParseError.pricedMarket) {
            try PendingOrderIntent.parse(url(
                "instId=ETH-USDT-SWAP&instType=SWAP&side=buy&kind=market&size=1"
                + "&mode=demo&nonce=x&priceMode=ask&maxSlipPct=3"))
        }
    }

    // MARK: - Surviving a restart

    @Test("round-trips through JSON, so a crash cannot lose it")
    func codableRoundTrip() throws {
        for intent in [try PendingOrderIntent.parse(url(optionQuery)),
                       try relative("mid", slip: "2.5", cap: "150")] {
            let data = try JSONEncoder().encode(intent)
            let back = try JSONDecoder().decode(PendingOrderIntent.self, from: data)
            #expect(back == intent)
        }
    }
}
