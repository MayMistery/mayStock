import Foundation
import Testing
@testable import MayStockKit

// MARK: - Fixtures

private enum Fixture {
    static let quotes = """
    {"TSLA":{"assetMainType":"EQUITY","symbol":"TSLA",
      "quote":{"askPrice":410.12,"bidPrice":410.05,"closePrice":400.0,"highPrice":415.5,"lastPrice":410.1,
               "lowPrice":398.2,"openPrice":402.0,"totalVolume":81234567,"tradeTime":1757950200000,"securityStatus":"Normal"},
      "reference":{"description":"Tesla Inc","exchange":"Q","exchangeName":"NASDAQ"}},
     "QQQ":{"assetMainType":"EQUITY","symbol":"QQQ",
      "quote":{"askPrice":500.5,"bidPrice":500.4,"closePrice":495.0,"highPrice":502.0,"lastPrice":500.45,
               "lowPrice":494.1,"openPrice":496.0,"totalVolume":12345678,"tradeTime":1757950200000,"securityStatus":"Normal"}},
     "errors":{"invalid_symbols":["NOPE"]}}
    """

    /// Six half-hour bars of one session (09:30–12:30 New York on
    /// 2026-09-14) plus the first of the next day, as `pricehistory` spells
    /// them: `datetime` in milliseconds.
    static let halfHours: String = {
        var zone = Calendar(identifier: .gregorian)
        zone.timeZone = TimeZone(identifier: "America/New_York")!
        let day = zone.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 9, minute: 30))!
        let next = zone.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 9, minute: 30))!
        var rows: [String] = []
        for index in 0..<6 {
            let ts = day.addingTimeInterval(Double(index) * 1_800)
            rows.append("{\"datetime\":\(Int64(ts.timeIntervalSince1970 * 1000)),\"open\":\(100 + index),\"high\":\(110 + index),\"low\":\(90 + index),\"close\":\(105 + index),\"volume\":1000}")
        }
        rows.append("{\"datetime\":\(Int64(next.timeIntervalSince1970 * 1000)),\"open\":200,\"high\":210,\"low\":190,\"close\":205,\"volume\":500}")
        return "{\"candles\":[\(rows.joined(separator: ","))],\"symbol\":\"TSLA\",\"empty\":false,\"previousClose\":99.5}"
    }()

    static let hoursOpen = """
    {"equity":{"EQ":{"date":"2026-09-14","marketType":"EQUITY","exchange":"NULL","category":"NULL","product":"EQ",
      "productName":"equity","isOpen":true,"sessionHours":{
        "preMarket":[{"start":"2026-09-14T07:00:00-04:00","end":"2026-09-14T09:30:00-04:00"}],
        "regularMarket":[{"start":"2026-09-14T09:30:00-04:00","end":"2026-09-14T16:00:00-04:00"}],
        "postMarket":[{"start":"2026-09-14T16:00:00-04:00","end":"2026-09-14T20:00:00-04:00"}]}}}}
    """
    static let hoursClosed = """
    {"equity":{"equity":{"date":"2026-09-13","marketType":"EQUITY","product":"equity","isOpen":false}}}
    """

    static let account = """
    {"securitiesAccount":{"type":"MARGIN","accountNumber":"12345678","roundTrips":0,"isDayTrader":false,
      "positions":[
        {"shortQuantity":0,"averagePrice":380.5,"longQuantity":10,"instrument":{"assetType":"EQUITY","cusip":"88160R101","symbol":"TSLA"},"marketValue":4101.0,"currentDayProfitLoss":12.5},
        {"shortQuantity":5,"averagePrice":500.0,"longQuantity":0,"instrument":{"assetType":"EQUITY","symbol":"QQQ"},"marketValue":-2502.25},
        {"shortQuantity":0,"averagePrice":1.2,"longQuantity":2,"instrument":{"assetType":"OPTION","symbol":"TSLA  261218C00500000"},"marketValue":240.0}],
      "currentBalances":{"cashBalance":12000.5,"liquidationValue":13839.25,"availableFunds":9000,"buyingPower":18000,"maintenanceRequirement":1500}},
     "aggregatedBalance":{"currentLiquidationValue":13839.25,"liquidationValue":13839.25}}
    """

    static let orderFilled = """
    {"session":"NORMAL","duration":"DAY","orderType":"MARKET","quantity":3,"filledQuantity":3,"remainingQuantity":0,
     "orderLegCollection":[{"orderLegType":"EQUITY","legId":1,"instrument":{"assetType":"EQUITY","symbol":"TSLA"},"instruction":"BUY","positionEffect":"OPENING","quantity":3}],
     "orderStrategyType":"SINGLE","orderId":1003912104600,"cancelable":false,"editable":false,"status":"FILLED",
     "enteredTime":"2026-09-14T14:00:00+0000","closeTime":"2026-09-14T14:00:01+0000",
     "orderActivityCollection":[{"activityType":"EXECUTION","executionType":"FILL","quantity":3,"orderRemainingQuantity":0,
        "executionLegs":[{"legId":1,"price":410.0,"quantity":2,"time":"2026-09-14T14:00:01+0000"},{"legId":1,"price":411.5,"quantity":1,"time":"2026-09-14T14:00:01.500+0000"}]}]}
    """
    static let orderRejected = """
    {"orderType":"LIMIT","quantity":1,"filledQuantity":0,"remainingQuantity":1,"price":1.0,
     "orderLegCollection":[{"instrument":{"assetType":"EQUITY","symbol":"TSLA"},"instruction":"BUY","quantity":1}],
     "orderId":77,"status":"REJECTED","statusDescription":"Price is too far from the market"}
    """
    static let orderBracket = """
    {"orderType":"MARKET","quantity":2,"filledQuantity":2,"remainingQuantity":0,"orderId":1,"status":"FILLED",
     "orderLegCollection":[{"instrument":{"assetType":"EQUITY","symbol":"TSLA"},"instruction":"BUY","quantity":2}],
     "childOrderStrategies":[{"orderStrategyType":"OCO","childOrderStrategies":[
        {"orderType":"STOP","stopPrice":380.0,"quantity":2,"remainingQuantity":2,"orderId":2,"status":"WORKING","orderLegCollection":[{"instrument":{"assetType":"EQUITY","symbol":"TSLA"},"instruction":"SELL","quantity":2}]},
        {"orderType":"LIMIT","price":450.0,"quantity":2,"remainingQuantity":2,"orderId":3,"status":"WORKING","orderLegCollection":[{"instrument":{"assetType":"EQUITY","symbol":"TSLA"},"instruction":"SELL","quantity":2}]}]}]}
    """

    static let transactions = """
    [{"activityId":9001,"time":"2026-09-14T14:00:01+0000","type":"TRADE","status":"VALID","orderId":1003912104600,"netAmount":-1232.02,
      "transferItems":[
        {"instrument":{"assetType":"EQUITY","symbol":"TSLA"},"amount":3,"cost":-1230.0,"price":410.0,"positionEffect":"OPENING"},
        {"instrument":{"assetType":"CURRENCY","symbol":"CURRENCY_USD"},"amount":-0.02,"cost":-0.02,"feeType":"SEC_FEE"},
        {"instrument":{"assetType":"CURRENCY","symbol":"CURRENCY_USD"},"amount":-2.0,"cost":-2.0,"feeType":"COMMISSION"}]},
     {"activityId":9002,"time":"2026-09-14T15:00:00+0000","type":"TRADE","status":"VALID","orderId":55,"netAmount":2050.0,
      "transferItems":[{"instrument":{"assetType":"EQUITY","symbol":"QQQ"},"amount":-4,"cost":2050.0,"price":512.5,"positionEffect":"CLOSING"}]},
     {"activityId":9003,"time":"2026-09-14T15:30:00+0000","type":"DIVIDEND_OR_INTEREST","status":"VALID","netAmount":1.0,"transferItems":[]}]
    """
}

private func newYork(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

// MARK: - OAuth

@Suite("Schwab OAuth")
struct SchwabOAuthTests {
    @Test("授权地址带 state，回调解码 %40 与 state")
    func authorizeAndCallback() throws {
        let state = SchwabOAuth.makeState()
        #expect(state.count >= 40)
        let url = SchwabOAuth.authorizeURL(appKey: "KEY", callback: SchwabAPI.defaultCallback, state: state)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "state" }?.value == state)
        #expect(items.first { $0.name == "redirect_uri" }?.value == "https://127.0.0.1:8182")
        #expect(items.first { $0.name == "client_id" }?.value == "KEY")

        let pasted = try SchwabOAuth.parseCallback("https://127.0.0.1:8182/?code=C0.abc%40&state=\(state)&session=1")
        #expect(pasted.code == "C0.abc@")
        #expect(pasted.state == state)
        let target = try SchwabOAuth.parseCallback("/?code=C0.abc%40")
        #expect(target.code == "C0.abc@")
        #expect(target.state == nil)
        #expect(throws: SchwabOAuthError.self) { try SchwabOAuth.parseCallback("https://127.0.0.1:8182/?session=1") }
    }

    @Test("state 不符拒绝，缺失只在显式放行时接受")
    func stateVerification() {
        let echoed = SchwabOAuth.Callback(code: "c", state: "s")
        #expect(throws: Never.self) { try SchwabOAuth.verify(echoed, expectedState: "s", allowMissingState: false) }
        #expect(throws: SchwabOAuthError.self) { try SchwabOAuth.verify(echoed, expectedState: "other", allowMissingState: true) }
        let silent = SchwabOAuth.Callback(code: "c", state: nil)
        #expect(throws: SchwabOAuthError.self) { try SchwabOAuth.verify(silent, expectedState: "s", allowMissingState: false) }
        #expect(throws: Never.self) { try SchwabOAuth.verify(silent, expectedState: "s", allowMissingState: true) }
    }

    @Test("换 token 请求按表单编码，@ 不会漏过去")
    func tokenRequestEncoding() throws {
        let request = SchwabOAuth.tokenRequest(appKey: "k", appSecret: "s", code: "C0.x@", callback: "https://127.0.0.1:8182")
        let body = String(data: try #require(request.httpBody), encoding: .utf8)!
        #expect(body.contains("code=C0.x%40"))
        #expect(body.contains("redirect_uri=https%3A%2F%2F127.0.0.1%3A8182"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("k:s".utf8).base64EncodedString())
    }

    @Test("刷新不重置 7 天登录时钟，换新 refresh token 才重置")
    func refreshClock() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try SchwabOAuth.decodeTokenResponse(
            Data(#"{"access_token":"a","refresh_token":"r","expires_in":1800}"#.utf8), now: now, previous: nil)
        #expect(first.refreshIssuedAt == now)
        #expect(first.accessValid(at: now))
        #expect(!first.accessValid(at: now.addingTimeInterval(1_700)))
        let later = now.addingTimeInterval(5 * 3_600)
        let refreshed = try SchwabOAuth.decodeTokenResponse(
            Data(#"{"access_token":"b","expires_in":1800}"#.utf8), now: later, previous: first)
        #expect(refreshed.refreshToken == "r")
        #expect(refreshed.refreshIssuedAt == now)
        #expect(refreshed.refreshValid(at: now.addingTimeInterval(6 * 86_400)))
        #expect(!refreshed.refreshValid(at: now.addingTimeInterval(8 * 86_400)))
        let rotated = try SchwabOAuth.decodeTokenResponse(
            Data(#"{"access_token":"c","refresh_token":"r2"}"#.utf8), now: later, previous: first)
        #expect(rotated.refreshIssuedAt == later)
        #expect(throws: SchwabOAuthError.self) {
            try SchwabOAuth.decodeTokenResponse(Data(#"{"error":"invalid_grant","error_description":"bad"}"#.utf8), now: now, previous: nil)
        }
    }

    @Test("状态报告说得出为什么不能交易")
    func statusBlocker() {
        let fresh = SchwabCredentialStatus(configured: false, loggedIn: false, version: "t")
        #expect(fresh.blocker?.contains("configure") == true)
        let expired = SchwabCredentialStatus(
            configured: true, loggedIn: false, refreshExpiresAt: Date(timeIntervalSince1970: 0), version: "t")
        #expect(expired.blocker?.contains("过期") == true)
        let good = SchwabCredentialStatus(
            configured: true, loggedIn: true, refreshExpiresAt: Date().addingTimeInterval(86_400), version: "t")
        #expect(good.blocker == nil)
        #expect((good.remainingLogin() ?? 0) > 0)
    }
}

// MARK: - Wire

@Suite("Schwab wire")
struct SchwabWireTests {
    @Test("报价读成昨收基准的 Ticker，并按交易时段标阶段")
    func quotes() throws {
        let now = newYork(2026, 9, 14, 11, 0)
        let hours = try SchwabWire.sessionHours(from: Data(Fixture.hoursOpen.utf8), day: "2026-09-14")
        let tickers = try SchwabWire.tickers(from: Data(Fixture.quotes.utf8), hours: hours, now: now)
        let tesla = try #require(tickers["TSLA"])
        #expect(tesla.last == 410.1)
        #expect(tesla.reference == 400.0)
        #expect(tesla.basis == .previousClose)
        #expect(tesla.phase == .regular)
        #expect(tesla.open == 402.0)
        #expect(tesla.bid == 410.05 && tesla.ask == 410.12)
        #expect(abs(tesla.changePct - 2.525) < 1e-9)
        #expect(tickers["QQQ"] != nil)
        #expect(tickers["errors"] == nil)
        #expect(tickers["NOPE"] == nil)
    }

    @Test("交易时段：开市日三段，休市日全天 closed，兜底表也一样")
    func sessionHours() throws {
        let open = try SchwabWire.sessionHours(from: Data(Fixture.hoursOpen.utf8), day: "2026-09-14")
        #expect(open.isOpen)
        #expect(open.phase(at: newYork(2026, 9, 14, 8, 0)) == .preMarket)
        #expect(open.phase(at: newYork(2026, 9, 14, 12, 0)) == .regular)
        #expect(open.phase(at: newYork(2026, 9, 14, 17, 0)) == .afterHours)
        #expect(open.phase(at: newYork(2026, 9, 14, 22, 0)) == .closed)
        let closed = try SchwabWire.sessionHours(from: Data(Fixture.hoursClosed.utf8), day: "2026-09-13")
        #expect(!closed.isOpen)
        #expect(closed.phase(at: newYork(2026, 9, 13, 12, 0)) == .closed)
        let standard = USSessionHours.standard(on: newYork(2026, 9, 14, 12, 0), open: true)
        #expect(standard.phase(at: newYork(2026, 9, 14, 9, 29)) == .preMarket)
        #expect(standard.phase(at: newYork(2026, 9, 14, 9, 30)) == .regular)
        #expect(standard.phase(at: newYork(2026, 9, 14, 16, 0)) == .afterHours)
    }

    @Test("半小时 K 线按 09:30 锚定拼成小时线，跨日不串")
    func hourlyAggregation() throws {
        let now = newYork(2026, 9, 20, 12, 0)
        let bars = try SchwabWire.candles(from: Data(Fixture.halfHours.utf8), symbol: "TSLA", bar: .h1, now: now)
        // Six halves → three hours on the 14th, one half → one hour on the 15th.
        #expect(bars.count == 4)
        #expect(bars[0].ts == newYork(2026, 9, 14, 9, 30))
        #expect(bars[0].open == 100 && bars[0].close == 106 && bars[0].high == 111 && bars[0].low == 90)
        #expect(bars[0].volume == 2000)
        #expect(bars[1].ts == newYork(2026, 9, 14, 10, 30))
        #expect(bars[2].ts == newYork(2026, 9, 14, 11, 30))
        #expect(bars[3].ts == newYork(2026, 9, 15, 9, 30))
        #expect(bars.allSatisfy { $0.confirmed })
        // The finer bars keep their own timestamps and confirmation is the
        // calendar's: a bar whose close is still ahead is not confirmed.
        let live = try SchwabWire.candles(
            from: Data(Fixture.halfHours.utf8), symbol: "TSLA", bar: .m5, now: newYork(2026, 9, 14, 9, 31))
        #expect(live.count == 7)
        #expect(!live[0].confirmed)
    }

    @Test("账户：现金 + 每只股票一行（做空为负），非股票资产只报告不折算")
    func account() throws {
        let account = try SchwabWire.account(from: Data(Fixture.account.utf8))
        #expect(account.isMargin)
        #expect(account.cash == 12000.5)
        #expect(account.equity == 13839.25)
        #expect(account.positions.count == 2)
        #expect(account.untracked == ["TSLA  261218C00500000（OPTION）"])
        #expect(account.held("TSLA") == 10)
        #expect(account.held("QQQ") == -5)
        let balances = account.balances
        #expect(balances.first?.ccy == "USD")
        #expect(balances.first?.total == 12000.5)
        #expect(balances.contains { $0.ccy == "QQQ" && $0.total == -5 })
        let snapshot = account.snapshot
        #expect(snapshot.totalEquity == 13839.25)
        let positions = account.exchangePositions
        #expect(positions.first { $0.instId == "TSLA" }?.quantity == 10)
        #expect(positions.first { $0.instId == "QQQ" }?.quantity == -5)
    }

    @Test("订单状态按运行器的口径读：成交均价、拒绝、挂单、OCO 子单")
    func orders() throws {
        let filled = try SchwabWire.order(from: Data(Fixture.orderFilled.utf8))
        #expect(filled.id == "1003912104600")
        #expect(filled.symbol == "TSLA" && filled.instruction == "BUY")
        if case .filled(let size, let price) = filled.venueStatus {
            #expect(size == 3)
            #expect(abs(price - 410.5) < 1e-9)
        } else {
            Issue.record("expected filled, got \(filled.venueStatus)")
        }
        #expect(filled.enteredTime != nil)
        let rejected = try SchwabWire.order(from: Data(Fixture.orderRejected.utf8))
        #expect(rejected.venueStatus == .rejected("Price is too far from the market"))
        let bracket = try SchwabWire.order(from: Data(Fixture.orderBracket.utf8))
        #expect(bracket.children.count == 2)
        let stop = try #require(bracket.flattened.first { $0.isStop })
        #expect(stop.stopPrice == 380 && stop.isWorking && stop.venueStatus == .live)
        #expect(SchwabWire.orderId(fromLocation: "https://api.schwabapi.com/trader/v1/accounts/abc/orders/1003912104600") == "1003912104600")
        #expect(SchwabWire.orderId(fromLocation: nil) == nil)
    }

    @Test("成交流水：只取 TRADE，方向随数量正负，费用记负数")
    func fills() throws {
        let fills = try SchwabWire.fills(from: Data(Fixture.transactions.utf8))
        #expect(fills.count == 2)
        let buy = fills[0]
        #expect(buy.id == "9001" && buy.instId == "TSLA" && buy.side == .buy && buy.size == 3 && buy.price == 410)
        #expect(abs(buy.fee + 2.02) < 1e-9)
        #expect(buy.feeCcy == "USD" && buy.ordId == "1003912104600")
        let sell = fills[1]
        #expect(sell.side == .sell && sell.size == 4 && sell.price == 512.5 && sell.fee == 0 && sell.ordId == "55")
        // The ledger's converter sees a dollar fee on a dollar instrument.
        let booked = try #require(StrategyFill(exchange: buy, strategyId: "s", mode: .live, venue: .schwab))
        #expect(abs(booked.feeQuote - 2.02) < 1e-9)
        #expect(booked.venue == .schwab)
    }

    @Test("订单拼写：四种指令按持仓决定，括号单挂在开仓腿上")
    func orderSpec() throws {
        #expect(SchwabOrderSpec.instruction(side: .buy, held: 0) == "BUY")
        #expect(SchwabOrderSpec.instruction(side: .buy, held: -3) == "BUY_TO_COVER")
        #expect(SchwabOrderSpec.instruction(side: .sell, held: 3) == "SELL")
        #expect(SchwabOrderSpec.instruction(side: .sell, held: 0) == "SELL_SHORT")
        #expect(SchwabOrderSpec.priceString(410.126) == "410.13")
        #expect(SchwabOrderSpec.priceString(0.12345) == "0.1235")

        let request = OrderRequest(
            instId: "TSLA", instType: .stock, side: .buy, kind: .market, size: 2, sizeUnit: .base,
            stopTriggerPrice: 380, takeProfitTriggerPrice: 450, clOrdId: "tag")
        let specs = SchwabVenue.specs(for: request, held: 0)
        #expect(specs.count == 1)
        #expect(specs[0].instruction == "BUY" && specs[0].children.count == 2)
        let body = specs[0].body
        #expect(body["orderStrategyType"] as? String == "TRIGGER")
        let children = try #require(body["childOrderStrategies"] as? [[String: Any]])
        #expect(children.first?["orderStrategyType"] as? String == "OCO")
        let legs = try #require(children.first?["childOrderStrategies"] as? [[String: Any]])
        #expect(legs.map { $0["orderType"] as? String } == ["STOP", "LIMIT"])
        #expect(legs.map { $0["duration"] as? String } == ["GOOD_TILL_CANCEL", "GOOD_TILL_CANCEL"])
        #expect(!specs[0].bodyData.isEmpty)

        // A sell of 5 while long 3 crosses flat: SELL 3, then SELL_SHORT 2,
        // and the protection follows the short.
        let flip = OrderRequest(instId: "TSLA", instType: .stock, side: .sell, kind: .market, size: 5, sizeUnit: .base, stopTriggerPrice: 500)
        let legsOut = SchwabVenue.specs(for: flip, held: 3)
        #expect(legsOut.map(\.instruction) == ["SELL", "SELL_SHORT"])
        #expect(legsOut.map(\.quantity) == [3, 2])
        #expect(legsOut[0].children.isEmpty)
        #expect(legsOut[1].children.first?.instruction == "BUY_TO_COVER")

        // Reduce-only never carries protection, and a partial close is one SELL.
        let close = OrderRequest(instId: "TSLA", instType: .stock, side: .sell, kind: .market, size: 2, sizeUnit: .base, reduceOnly: true, stopTriggerPrice: 300)
        let closing = SchwabVenue.specs(for: close, held: 3)
        #expect(closing.count == 1 && closing[0].instruction == "SELL" && closing[0].children.isEmpty)
    }

    @Test("多张订单合成一个判定：有挂单算挂单，成交量相加")
    func combinedStatus() {
        #expect(SchwabVenue.combine([.filled(filledSize: 3, averagePrice: 100), .filled(filledSize: 2, averagePrice: 110)])
                == .filled(filledSize: 5, averagePrice: 104))
        #expect(SchwabVenue.combine([.filled(filledSize: 3, averagePrice: 100), .live]) == .live)
        #expect(SchwabVenue.combine([.canceled, .rejected("x")]) == .rejected("x"))
        #expect(SchwabVenue.combine([]) == .unknown)
    }

    @Test("schwabctl 的错误信封映射成运行器认识的错误")
    func bridgeFailures() {
        func failure(_ json: String) -> Error {
            SchwabBridge.failure(exitCode: 2, stdout: Data(json.utf8), stderr: "")
        }
        #expect(failure(#"{"error":{"code":"not_logged_in","message":"expired"}}"#) as? SchwabAPIError == .loggedOut("expired"))
        #expect(failure(#"{"error":{"code":"refused","message":"no --live"}}"#) as? TradeError != nil)
        let rejected = failure(#"{"error":{"code":"rejected","message":"insufficient buying power"}}"#) as? TradeError
        #expect(rejected?.refusal?.contains("insufficient buying power") == true)
        #expect(failure(#"{"error":{"code":"rate_limited","message":"429"}}"#) as? SchwabAPIError == .rateLimited)
        let http = failure(#"{"error":{"code":"http","status":503,"message":"down"}}"#) as? SchwabAPIError
        #expect(http == .http(status: 503, body: "down"))
        #expect(failure("garbage") as? SchwabBridgeError != nil)
    }

    @Test("历史窗口的天数随周期单调，永远够覆盖目标根数")
    func daysCovering() {
        for bar in Venue.schwab.supportedBars {
            let small = SchwabMarketDataSource.daysCovering(10, bar: bar)
            let large = SchwabMarketDataSource.daysCovering(1_000, bar: bar)
            #expect(large >= small)
            #expect(small >= 5)
        }
        #expect(SchwabMarketDataSource.daysCovering(7, bar: .h1) < SchwabMarketDataSource.daysCovering(7, bar: .d1))
    }
}

// MARK: - Shadow book

@Suite("Shadow book")
struct ShadowBookTests {
    private let economics = ShadowBook.Economics(fees: SchwabFeeSchedule().feeModel(for: .stock)!, slippageBps: 10, maxLeverage: 2)
    private let open = newYork(2026, 9, 14, 11, 0)      // Monday, regular session
    private let closed = newYork(2026, 9, 13, 11, 0)    // Sunday

    private func order(_ side: OrderSide, _ size: Double, kind: OrderKind = .market, limit: Double? = nil,
                       stop: Double? = nil, takeProfit: Double? = nil, tag: String = "ms-tag", reduceOnly: Bool = false) -> OrderRequest {
        OrderRequest(instId: "TSLA", instType: .stock, side: side, kind: kind, size: size, sizeUnit: .base,
                     limitPrice: limit, reduceOnly: reduceOnly, stopTriggerPrice: stop, takeProfitTriggerPrice: takeProfit, clOrdId: tag)
    }

    @Test("市价单在交易时段按盘口加滑点成交，扣嘉信费用")
    func marketFill() async throws {
        let book = ShadowBook(venue: .schwab, fileURL: nil, startingCash: 10_000)
        let quote = ShadowBook.Quote(last: 100, bid: 99.9, ask: 100.1, ts: open)
        let placed = try await book.place(order(.buy, 10), quote: quote, economics: economics, now: open)
        #expect(placed.status == .filled)
        #expect(abs((placed.averagePrice ?? 0) - 100.1 * 1.001) < 1e-9)
        let status = await book.status(clOrdId: "ms-tag")
        #expect(status.didExecute)
        let fills = await book.fills(instId: "TSLA")
        #expect(fills.count == 1 && fills[0].side == .buy && fills[0].size == 10 && fills[0].clOrdId == "ms-tag")
        // A buy pays no SEC/TAF; cash moved by the notional exactly:
        // 10 × 100.1 × 1.001 = 1002.001.
        let snapshot = await book.snapshot(marks: ["TSLA": 100])
        #expect(abs((snapshot.balances.first { $0.ccy == "USD" }?.total ?? 0) - (10_000 - 1002.001)) < 1e-6)
        #expect(snapshot.balances.contains { $0.ccy == "TSLA" && $0.total == 10 })

        // Selling pays the levies, booked as a negative fee on the fill.
        try await book.place(order(.sell, 10, tag: "ms-out"), quote: quote, economics: economics, now: open)
        let sale = await book.fills(instId: "TSLA").last!
        #expect(sale.side == .sell)
        #expect(sale.fee < 0)
        #expect(await book.positions().isEmpty)
    }

    @Test("休市时挂着，开盘再按当时行情成交")
    func waitsForTheOpen() async throws {
        let book = ShadowBook(venue: .schwab, fileURL: nil, startingCash: 10_000)
        let placed = try await book.place(order(.buy, 5), quote: ShadowBook.Quote(last: 100, ts: closed), economics: economics, now: closed)
        #expect(placed.status == .pending)
        #expect(await book.status(clOrdId: "ms-tag") == .live)
        await book.settle(quotes: ["TSLA": ShadowBook.Quote(last: 102, ts: open)], now: open, economics: economics)
        let status = await book.status(clOrdId: "ms-tag")
        if case .filled(let size, let price) = status {
            #expect(size == 5)
            #expect(abs(price - 102 * 1.001) < 1e-9)
        } else {
            Issue.record("expected a fill at the open, got \(status)")
        }
    }

    @Test("限价单只在盘口触及时成交；IOC 不能立即成交就撤")
    func limitAndIOC() async throws {
        let book = ShadowBook(venue: .schwab, fileURL: nil, startingCash: 10_000)
        try await book.place(order(.buy, 5, kind: .limit, limit: 95), quote: ShadowBook.Quote(last: 100, ask: 100.1, ts: open), economics: economics, now: open)
        #expect(await book.status(clOrdId: "ms-tag") == .live)
        await book.settle(quotes: ["TSLA": ShadowBook.Quote(last: 94, ask: 94.5, ts: open)], now: open, economics: economics)
        if case .filled(_, let price) = await book.status(clOrdId: "ms-tag") {
            #expect(price == 94.5)
        } else {
            Issue.record("limit should fill once the ask is inside it")
        }
        try await book.place(order(.buy, 1, kind: .ioc, limit: 90, tag: "ms-ioc"), quote: ShadowBook.Quote(last: 94, ask: 94.5, ts: open), economics: economics, now: open)
        #expect(await book.status(clOrdId: "ms-ioc") == .canceled)
    }

    @Test("从平仓卖出即做空；超过 Reg T 两倍购买力被拒，且拒绝是终局")
    func shortsAndRegT() async throws {
        let book = ShadowBook(venue: .schwab, fileURL: nil, startingCash: 10_000)
        let quote = ShadowBook.Quote(last: 100, bid: 100, ask: 100, ts: open)
        try await book.place(order(.sell, 50, tag: "ms-short"), quote: quote, economics: economics, now: open)
        #expect(await book.positions().first?.quantity == -50)
        let snapshot = await book.snapshot(marks: ["TSLA": 100])
        // Short proceeds sit in cash; equity is down only by the slippage
        // (10 bps of 5,000 = 5) and the sale levies.
        #expect((snapshot.totalEquity ?? 0) < 10_000)
        #expect(abs((snapshot.totalEquity ?? 0) - 10_000) < 6)
        do {
            try await book.place(order(.sell, 200, tag: "ms-too-much"), quote: quote, economics: economics, now: open)
            Issue.record("Reg T should have refused")
        } catch let error as TradeError {
            #expect(error.refusal?.contains("Reg T") == true)
        }
        #expect(await book.status(clOrdId: "ms-too-much").isTerminal)
        // Reducing is always allowed, even when exposure is at the cap.
        try await book.place(order(.buy, 50, tag: "ms-cover", reduceOnly: true), quote: quote, economics: economics, now: open)
        #expect(await book.positions().isEmpty)
    }

    @Test("附带止损/止盈：一腿触发另一腿撤销；移动止损可改价")
    func protection() async throws {
        let book = ShadowBook(venue: .schwab, fileURL: nil, startingCash: 10_000)
        try await book.place(order(.buy, 10, stop: 90, takeProfit: 120), quote: ShadowBook.Quote(last: 100, ts: open), economics: economics, now: open)
        var protective = await book.protectiveOrders(instId: "TSLA")
        #expect(protective.count == 2)
        let stop = try #require(protective.first { $0.stopTriggerPrice != nil })
        #expect(stop.stopTriggerPrice == 90)
        #expect(protective.contains { $0.takeProfitTriggerPrice == 120 })
        try await book.amendProtective(id: stop.algoId, stopPrice: 95)
        protective = await book.protectiveOrders(instId: "TSLA")
        #expect(protective.first { $0.algoId == stop.algoId }?.stopTriggerPrice == 95)

        // Price falls through the stop: it fills through the trigger, the
        // take profit is cancelled, and the position is flat.
        await book.settle(quotes: ["TSLA": ShadowBook.Quote(last: 94, ts: open.addingTimeInterval(60))], now: open.addingTimeInterval(60), economics: economics)
        #expect(await book.protectiveOrders(instId: "TSLA").isEmpty)
        #expect(await book.positions().isEmpty)
        let fills = await book.fills(instId: nil)
        #expect(fills.count == 2)
        #expect(fills[1].side == .sell && fills[1].price <= 94)
        #expect(await book.openOrders.isEmpty)
    }

    @Test("落盘后重启还在，重置后清空")
    func persistence() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("shadow.json")
        let book = ShadowBook(venue: .schwab, fileURL: file, startingCash: 5_000)
        try await book.place(order(.buy, 3), quote: ShadowBook.Quote(last: 50, ts: open), economics: economics, now: open)
        let reloaded = ShadowBook(venue: .schwab, fileURL: file, startingCash: 999)
        #expect(await reloaded.positions().first?.quantity == 3)
        #expect(await reloaded.fills(instId: nil).count == 1)
        #expect(await reloaded.startingCash == 5_000)
        await reloaded.reset(cash: 7_000)
        #expect(await reloaded.positions().isEmpty)
        #expect(await reloaded.cash == 7_000)
        let again = ShadowBook(venue: .schwab, fileURL: file, startingCash: 1)
        #expect(await again.cash == 7_000)
    }

    @Test("订单标签落盘，重启后成交仍能归到策略")
    func tags() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tags.json")
        let tags = SchwabOrderTags(fileURL: file)
        await tags.record(clOrdId: "ms-a", orderId: "1", instId: "TSLA")
        await tags.record(clOrdId: "ms-a", orderId: "2", instId: "TSLA")
        #expect(await tags.orderIds(for: "ms-a") == ["1", "2"])
        let reloaded = SchwabOrderTags(fileURL: file)
        #expect(await reloaded.clOrdId(forOrderId: "2") == "ms-a")
        #expect(await reloaded.clOrdId(forOrderId: "9") == nil)
    }
}

// MARK: - Portfolio per venue

@Suite("Portfolio per venue")
struct PortfolioPerVenueTests {
    @Test("两个池子互不相干：一边超配不影响另一边，scoped 只看自己的")
    func potsAreIndependent() {
        var portfolio = StrategyPortfolioPrefs(capital: [.okx: 1_000, .schwab: 10_000])
        portfolio.setCapital(800, for: "btc", on: .okx)
        portfolio.setCapital(9_000, for: "tsla", on: .schwab)
        #expect(portfolio.allocatedCapital(on: .okx) == 800)
        #expect(portfolio.allocatedCapital(on: .schwab) == 9_000)
        #expect(portfolio.capitalHeadroom(for: "eth", on: .okx) == 200)
        #expect(portfolio.capitalHeadroom(for: "qqq", on: .schwab) == 1_000)
        portfolio.setTotalCapital(400, for: .okx)
        #expect(portfolio.allocation(for: "btc")?.capital == 400)
        #expect(portfolio.allocation(for: "tsla")?.capital == 9_000, "the other pot is untouched")
        portfolio.allocations[0].capital = 1_000
        #expect(portfolio.overAllocatedVenues == [.okx])
        let scoped = portfolio.scoped(to: .schwab)
        #expect(scoped.allocations.map(\.strategyId) == ["tsla"])
        #expect(scoped.totalCapital(for: .schwab) == 10_000)
        #expect(scoped.isOverAllocated(on: .okx) == false, "a scoped view has no other venue to be over on")
    }

    @Test("旧文件的 totalCapital 落到 OKX 池；新文件按 venue 存，来回不丢")
    func codingRoundTrip() throws {
        let legacy = try JSONDecoder().decode(
            StrategyPortfolioPrefs.self, from: Data(#"{"mode":"demo","totalCapital":1234,"allocations":[{"strategyId":"a","capital":5}]}"#.utf8))
        #expect(legacy.totalCapital(for: .okx) == 1234)
        #expect(legacy.totalCapital(for: .schwab) == Venue.schwab.defaultPortfolioCapital)
        #expect(legacy.allocation(for: "a")?.venue == .okx)

        var fresh = StrategyPortfolioPrefs(capital: [.okx: 1, .schwab: 2])
        fresh.setCapital(2, for: "tsla", on: .schwab)
        let data = try JSONEncoder().encode(fresh)
        let text = String(data: data, encoding: .utf8)!
        #expect(text.contains("\"capital\":{") || text.contains("\"capital\" : {"))
        #expect(!text.contains("totalCapital"))
        let back = try JSONDecoder().decode(StrategyPortfolioPrefs.self, from: data)
        #expect(back == fresh)
    }

    @Test("每个 venue 都声明了账目时区、文件名与默认本金")
    func venueDeclarations() {
        var infixes: Set<String> = []
        for venue in Venue.allCases {
            #expect(venue.defaultPortfolioCapital > 0)
            #expect(infixes.insert(venue.stateFileInfix).inserted, "state files must not collide")
            #expect(venue.accountingTimeZone.identifier.isEmpty == false)
            let store = StrategyLedgerStore(directory: URL(fileURLWithPath: "/tmp"), mode: .demo, venue: venue)
            #expect(store.fileURL.lastPathComponent.hasSuffix("-demo.json"))
        }
        #expect(StrategyLedgerStore(directory: URL(fileURLWithPath: "/tmp"), mode: .live).fileURL.lastPathComponent == "ledger-live.json",
                "OKX keeps the names the app always wrote")
        #expect(HeartbeatStore(directory: URL(fileURLWithPath: "/tmp"), venue: .schwab).fileURL.lastPathComponent == "heartbeat-schwab.json")
        #expect(EquityWindow.day1.anchor(now: newYork(2026, 9, 14, 11, 0), venue: .schwab) == newYork(2026, 9, 14, 0, 0))
    }
}

// MARK: - Settlement currency

/// 一个持仓的计价币种由**合约**决定，不由 venue 决定。
///
/// 这组断言的依据是交易所自己的 instrument 清单实测：`settleCcy` 对 482 个
/// SWAP 与 1412 个 OPTION 全部符合下面这条规则，0 例外；现货那 1411 个 pair
/// 里有 275 个以裸 USD 计价，还有 EUR / TRY / SGD / AUD / AED / BRL，所以
/// 「OKX 就是 USDT」本身也是错的。
@Suite("持仓的计价币种来自合约，不来自 venue")
struct SettlementCurrencyTests {
    @Test("线性、反向、期权、现货、美股各自结算在什么币种上")
    func settlementFollowsTheInstrument() {
        #expect(Venue.okx.settlementCurrency(of: "BTC-USDT-SWAP") == "USDT")
        #expect(Venue.okx.settlementCurrency(of: "ETH-USDT-SWAP") == "USDT")
        // 反向合约：以美元标价，用币结算、用币做保证金。
        #expect(Venue.okx.settlementCurrency(of: "BTC-USD-SWAP") == "BTC")
        // 期权权利金付的是币，不是美元。
        #expect(Venue.okx.settlementCurrency(of: "BTC-USD-260921-71000-C") == "BTC")
        #expect(Venue.okx.settlementCurrency(of: "ETH-USD-260921-3000-P") == "ETH")
        // 现货结算在计价腿上，而它未必是 USDT。
        #expect(Venue.okx.settlementCurrency(of: "BTC-USDT") == "USDT")
        #expect(Venue.okx.settlementCurrency(of: "BTC-USDC") == "USDC")
        #expect(Venue.okx.settlementCurrency(of: "BTC-EUR") == "EUR")
        #expect(Venue.schwab.settlementCurrency(of: "AAPL") == "USD")
    }

    @Test("venue 的记账币种和合约的结算币种是两件事")
    func venueCurrencyIsNotInstrumentCurrency() {
        // 这正是旧代码把 USDT 当美元加进组合的那个洞：venue 说 USDT，
        // 而账户里同时可能躺着一个用 BTC 结算的期权。
        #expect(Venue.okx.quoteCurrency == "USDT")
        #expect(Venue.okx.settlementCurrency(of: "BTC-USD-260921-71000-C") != Venue.okx.quoteCurrency)
    }

    @Test("交易所报了 usdPx 才能折算成美元，没报就说不知道")
    func positionStatesItsOwnRate() {
        func position(ccy: String?, rate: Double?, upl: Double) -> ExchangePosition {
            ExchangePosition(
                instId: "BTC-USDT-SWAP", posSide: .long, quantity: 1, averagePrice: 100,
                markPrice: 100, unrealisedPnL: upl, leverage: nil, liquidationPrice: nil,
                settlementCurrency: ccy, usdRate: rate)
        }
        // 实测 usdPx = 0.99962：USDT 不是 1 美元，差的是真金白银。
        let usdt = position(ccy: "USDT", rate: 0.99962, upl: 289.27422)
        #expect(usdt.unrealisedPnLUsd != nil)
        #expect(abs((usdt.unrealisedPnLUsd ?? 0) - 289.27422 * 0.99962) < 1e-9)
        #expect(usdt.unrealisedPnLUsd != usdt.unrealisedPnL, "0.99962 ≠ 1")
        // 本来就是美元，不用换。
        #expect(position(ccy: "USD", rate: nil, upl: 12).unrealisedPnLUsd == 12)
        // 说了是别的币种、却没给汇率：只能说不知道，不能按面值混进美元总额。
        #expect(position(ccy: "BTC", rate: nil, upl: 0.5).unrealisedPnLUsd == nil)
        // 嘉信这种本币即组合币种、两个字段都不报的，照常可加。
        #expect(position(ccy: nil, rate: nil, upl: 7).unrealisedPnLUsd == 7)
    }

    @Test("快照里的汇率来自这次读数本身，读不到就返回 nil")
    func snapshotRateComesFromTheReading() {
        let snapshot = AccountSnapshot(
            balances: [
                AccountBalance(ccy: "USDT", available: 100, total: 100, valuationUsd: 99.962),
                AccountBalance(ccy: "ETH", available: 1, total: 1, valuationUsd: 2_575.23),
                AccountBalance(ccy: "DOGE", available: 5, total: 5, valuationUsd: nil),
            ],
            totalEquity: 2_675.192, equityCurrency: AccountSnapshot.usdCode)
        #expect(snapshot.usdRate(for: "USD") == 1)
        #expect(abs((snapshot.usdRate(for: "USDT") ?? 0) - 0.99962) < 1e-9)
        #expect(abs((snapshot.usdRate(for: "ETH") ?? 0) - 2_575.23) < 1e-9)
        #expect(snapshot.usdRate(for: "DOGE") == nil, "交易所没估值，就没有汇率可用")
        #expect(snapshot.usdRate(for: "SHIB") == nil, "余额里根本没有这条线")
    }
}

// MARK: - Hub source names

private actor NamedFeed: MarketFeed {
    nonisolated let venue: Venue
    private var handler: (@Sendable (MarketFeedEvent) -> Void)?
    init(venue: Venue) { self.venue = venue }
    func setHandler(_ handler: @escaping @Sendable (MarketFeedEvent) -> Void) { self.handler = handler }
    func subscribe(instId: String, bar: BarInterval) { handler?(.source("测试源")) }
    func unsubscribe(instId: String, bar: BarInterval) {}
    func switchBar(instId: String, from old: BarInterval, to new: BarInterval) {}
}

@Suite("Hub source names")
struct HubSourceNameTests {
    @Test("行情源报出的名字覆盖 venue 的设计名")
    @MainActor
    func sourceNameFollowsTheFeed() async throws {
        let hub = MarketHub(feeds: [NamedFeed(venue: .schwab)], sources: [MarketDataSources().schwab])
        #expect(hub.sourceName(for: .schwab) == Venue.schwab.marketDataSourceName)
        hub.setWatchlist([WatchItem(venue: .schwab, instId: "TSLA")])
        for _ in 0..<50 where hub.sourceName(for: .schwab) != "测试源" {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(hub.sourceName(for: .schwab) == "测试源")
        #expect(hub.sourceName(for: .okx) == Venue.okx.marketDataSourceName)
    }
}

/// A failed Schwab order call says what Schwab did — the terms every screen
/// and the runner read — and never less than what happened.
@Suite("Schwab order failures")
struct SchwabOrderFailureTests {

    @Test("没启动、限频是没送达；未登录、4xx 是拒绝；超时、5xx 和其余一律未确认")
    func eachFailureSaysWhatSchwabDid() throws {
        let standing = { (error: Error) in TradeError.standing(of: SchwabBridge.orderFailure(error)) }
        #expect(standing(SchwabBridgeError.cliNotFound) == .undelivered)
        #expect(standing(SchwabBridgeError.notLaunched("permission denied")) == .undelivered)
        #expect(standing(SchwabAPIError.rateLimited) == .undelivered)
        #expect(standing(SchwabAPIError.loggedOut("expired")) == .refused)
        #expect(standing(SchwabAPIError.unauthorised) == .refused)
        #expect(standing(SchwabAPIError.http(status: 400, body: "bad symbol")) == .refused)
        #expect(standing(TradeError.liveTradingLocked) == .refused)
        #expect(standing(TradeError.rejected(venue: "嘉信", reason: "insufficient buying power")) == .refused)
        #expect(standing(SchwabAPIError.http(status: 408, body: "timeout")) == .unknown)
        #expect(standing(SchwabAPIError.http(status: 503, body: "down")) == .unknown)
        #expect(standing(SchwabAPIError.transport("connection reset")) == .unknown)
        #expect(standing(SchwabBridgeError.cliFailed(exitCode: -1, detail: "schwabctl 超过 30 秒未返回，已终止")) == .unknown)
        #expect(standing(CancellationError()) == .unknown, "an error nobody classified may have been acted on")
        #expect(throws: TradeError.self) { try SchwabBridge.orderId(in: Data("{}".utf8)) }
        do {
            _ = try SchwabBridge.orderId(in: Data("{}".utf8))
        } catch {
            #expect(TradeError.standing(of: error) == .unknown, "taken, but under an id nobody has")
        }
    }

    @Test("反手的第二腿失败时第一腿已在簿上：整笔是未确认，不是拒绝")
    func aFailedSecondLegLeavesTheFirstOnTheBook() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maystock-schwab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let placed = dir.appendingPathComponent("placed")
        let cli = dir.appendingPathComponent("schwabctl")
        // Long 10; the first placement is taken, the second refused outright.
        try """
        #!/bin/sh
        case "$1" in
          account)
            echo '{"securitiesAccount":{"accountNumber":"1","type":"MARGIN","currentBalances":{"cashBalance":0},"positions":[{"instrument":{"symbol":"TSLA","assetType":"EQUITY"},"longQuantity":10,"shortQuantity":0,"averagePrice":100,"marketValue":1000}]}}' ;;
          place)
            cat > /dev/null
            if [ -f "\(placed.path)" ]; then
              echo '{"error":{"code":"rejected","message":"short sale not allowed"}}'; exit 2
            fi
            touch "\(placed.path)"; echo '{"orderId":"111"}' ;;
        esac
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let venue = SchwabVenue(
            data: SchwabMarketDataSource(schwab: SchwabRESTClient(tokens: SchwabStaticToken("x"))),
            bridge: SchwabBridge(explicitCLIPath: cli.path, commandTimeout: 5),
            shadow: ShadowBook(venue: .schwab, fileURL: nil, startingCash: 0),
            tags: SchwabOrderTags(fileURL: nil),
            economics: ShadowBook.Economics(schedule: SchwabFeeSchedule()))
        // Sell 25 while long 10: SELL the 10, then SELL_SHORT 15.
        let order = OrderRequest(instId: "TSLA", instType: .stock, side: .sell, kind: .market, size: 25, sizeUnit: .base,
                                 limitPrice: nil, reduceOnly: false, stopTriggerPrice: nil, takeProfitTriggerPrice: nil,
                                 clOrdId: "ms-flip")
        do {
            _ = try await venue.place(order, mode: .live, liveUnlocked: true)
            Issue.record("the second leg failed; the order must not read as placed")
        } catch {
            #expect(TradeError.standing(of: error) == .unknown, "\(error)")
            #expect((error as? TradeError)?.refusal == nil, "a refusal would say nothing is on the book")
            #expect(String(describing: error).contains("111"), "the leg that went through is named")
        }
    }
}
