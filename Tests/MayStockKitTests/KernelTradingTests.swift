import Foundation
import Testing
@testable import MayStockKit

/// The seam between Swift and the kernel's trading path: every action Swift
/// can build reaches the kernel as the kernel reads it, the runner's orders
/// become the bodies they always were, refusals happen before the network,
/// and a failure says what is now true. No network: the kernel refuses
/// before connecting, or only describes.
@Suite("Kernel trading path")
struct KernelTradingTests {

    static func body(_ action: TradeAction) throws -> [String: Any] {
        let wire = try KernelTradeClient.describe(action)
        return try #require(try JSONSerialization.jsonObject(with: Data(wire.body.utf8)) as? [String: Any])
    }

    /// One of every action, with every optional part set somewhere.
    static let everyAction: [TradeAction] = [
        .place(TradeOrderSpec(
            instId: "ETH-USDT-SWAP", instType: .swap, side: .sell, kind: .limit, size: 187.75, price: 2700.01,
            tradeMode: "isolated", posSide: .long, reduceOnly: true, clientId: "ms1",
            stopTrigger: 2500, takeProfitTrigger: 2900)),
        .place(TradeOrderSpec(instId: "BTC-USDT", instType: .spot, side: .buy, kind: .market, size: 20, sizeInQuote: true)),
        .placeAlgo(TradeAlgoSpec(
            instId: "ETH-USDT-SWAP", instType: .swap, side: .sell, posSide: .long, size: 10, tradeMode: "cross",
            reduceOnly: true, cancelWithPosition: false, clientId: "ms2", kind: .chase(maxChaseRatio: 0.002))),
        .placeAlgo(TradeAlgoSpec(
            instId: "ETH-USDT-SWAP", instType: .swap, side: .buy, posSide: .short, size: 10, tradeMode: "cross",
            reduceOnly: true, cancelWithPosition: true, kind: .protection(takeProfit: 2500, stopLoss: 2900))),
        .placeAlgo(TradeAlgoSpec(
            instId: "ETH-USDT", instType: .spot, side: .sell, posSide: nil, size: 0.04, tradeMode: "cash",
            reduceOnly: false, cancelWithPosition: false, kind: .protection(takeProfit: nil, stopLoss: 2500))),
        .cancel(instId: "ETH-USDT-SWAP", orderId: "123"),
        .cancelAlgo(instId: "ETH-USDT-SWAP", algoId: "9"),
        .amendStop(instId: "ETH-USDT-SWAP", algoId: "9", stop: 2610.5),
        .precheck(TradeOrderSpec(instId: "BTC-USDT-SWAP", instType: .swap, side: .buy, kind: .market, size: 0.01,
                                 tradeMode: "cross", posSide: .short)),
    ]

    @Test("every action round-trips through Swift and is read by the kernel")
    func everyActionReachesTheKernel() throws {
        for action in Self.everyAction {
            let data = try JSONEncoder().encode(action)
            #expect(try JSONDecoder().decode(TradeAction.self, from: data) == action, "\(action)")
            let wire = try KernelTradeClient.describe(action)
            #expect(wire.method == "POST")
            #expect(wire.path.hasPrefix("/api/v5/trade/"), "the closed set: \(wire.path)")
        }
    }

    @Test("the runner's orders become the bodies the exchange has always read")
    func runnerOrders() throws {
        // A spot market buy sized in the quote currency.
        let buy = try Self.body(.place(TradeOrderSpec(OrderRequest(
            instId: "BTC-USDT", side: .buy, kind: .market, size: 20, clOrdId: "msbuy"))))
        #expect(buy["tgtCcy"] as? String == "quote_ccy")
        #expect(buy["tdMode"] as? String == "cash")
        #expect(buy["px"] == nil)
        #expect(buy["clOrdId"] as? String == "msbuy")

        // A perpetual entry on a long/short account, protection attached.
        let entry = try Self.body(.place(TradeOrderSpec(OrderRequest(
            instId: "ETH-USDT-SWAP", instType: .swap, side: .buy, kind: .market, size: 3, sizeUnit: .base,
            posSide: .long, stopTriggerPrice: 2500, takeProfitTriggerPrice: 2900, clOrdId: "msent"))))
        #expect(entry["tdMode"] as? String == "cross", "the default the runner has always opened with")
        #expect(entry["posSide"] as? String == "long")
        #expect(entry["tgtCcy"] == nil, "a size unit means nothing off spot market orders")
        let attached = try #require((entry["attachAlgoOrds"] as? [[String: Any]])?.first)
        #expect(attached["slTriggerPx"] as? String == "2500" && attached["slOrdPx"] as? String == "-1")
        #expect(attached["tpTriggerPx"] as? String == "2900")

        // A reduce-only close: kept on net mode, dropped on a leg (51205).
        for (leg, sent) in [(PositionSide.net, true), (.long, false), (.short, false)] {
            let close = try Self.body(.place(TradeOrderSpec(OrderRequest(
                instId: "ETH-USDT-SWAP", instType: .swap, side: .sell, kind: .market, size: 3, sizeUnit: .base,
                posSide: leg, reduceOnly: true))))
            #expect((close["reduceOnly"] as? String == "true") == sent, "\(leg)")
        }

        // An option: IOC at a limit, the account's margin mode, reduce-only
        // kept, no leg and no currency switch.
        let option = try Self.body(.place(TradeOrderSpec(OrderRequest(
            instId: "BTC-USD-261225-100000-C", instType: .option, side: .sell, kind: .ioc, size: 3,
            sizeUnit: .base, limitPrice: 0.021, reduceOnly: true, tradeMode: "cross"))))
        #expect(option["ordType"] as? String == "ioc" && option["px"] as? String == "0.021")
        #expect(option["tdMode"] as? String == "cross")
        #expect(option["reduceOnly"] as? String == "true")
        #expect(option["posSide"] == nil && option["tgtCcy"] == nil)

        // A size goes out as it is, never rounded up past the lot.
        let exact = try Self.body(.place(TradeOrderSpec(OrderRequest(
            instId: "ETH-USDT", instType: .spot, side: .sell, kind: .limit, size: 0.01234567, sizeUnit: .base,
            limitPrice: 2700))))
        #expect(exact["sz"] as? String == "0.01234567")
    }

    @Test("an order the kernel cannot send as written is refused before the network")
    func malformedOrdersAreRefused() {
        // A priced kind without a price, an option without a margin mode.
        #expect(throws: KernelError.self) {
            try KernelTradeClient.describe(.place(TradeOrderSpec(
                instId: "ETH-USDT-SWAP", instType: .swap, side: .sell, kind: .limit, size: 1)))
        }
        #expect(throws: KernelError.self) {
            try KernelTradeClient.describe(.place(TradeOrderSpec(
                instId: "ETH-USD-261009-2750-P", instType: .option, side: .sell, kind: .limit, size: 1, price: 0.05)))
        }
        #expect(throws: KernelError.self) {
            try KernelTradeClient.describe(.place(TradeOrderSpec(
                instId: "MU", instType: .stock, side: .sell, kind: .market, size: 1)))
        }
    }

    /// A config file with one key per environment, as the okx CLI writes it.
    static func config() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maystock-kernel-\(UUID().uuidString).toml")
        try """
        default_profile = "paper"
        [profiles.paper]
        api_key = "k"
        secret_key = "s"
        passphrase = "p"
        demo = true
        [profiles.real]
        api_key = "k"
        secret_key = "s"
        passphrase = "p"
        demo = false
        """.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("a live order with the lock closed, or a key for the other environment, never leaves")
    func refusalsHappenBeforeTheNetwork() async throws {
        let client = KernelTradeClient(configPath: try Self.config(), demoProfile: "paper", liveProfile: "real")
        let cancel = TradeAction.cancel(instId: "ETH-USDT-SWAP", orderId: "1")
        await #expect(throws: TradeError.self) {
            _ = try await client.send(cancel, mode: .live, liveUnlocked: false)
        }
        do {
            _ = try await client.send(cancel, mode: .live, liveUnlocked: false)
        } catch let error as TradeError {
            guard case .liveTradingLocked = error else { Issue.record("\(error)"); return }
        }
        let crossed = KernelTradeClient(configPath: try Self.config(), demoProfile: "real", liveProfile: "paper")
        do {
            _ = try await crossed.send(cancel, mode: .demo, liveUnlocked: false)
            Issue.record("a live key was sent to the demo")
        } catch let error as TradeError {
            guard case .refused(let reason) = error else { Issue.record("\(error)"); return }
            #expect(reason.contains("real") && error.refusal != nil)
            #expect(error.hint?.contains("不能互用") == true)
        }
    }

    @Test("a failure says what is now true: refused, not delivered, or unknown")
    func failuresSayWhatIsTrue() {
        let cases: [(TradeError, refusal: Bool, undelivered: Bool, unknown: Bool)] = [
            (.rejected(venue: "OKX", reason: "51008 Insufficient margin"), true, false, false),
            (.refused("profile 不能用于实盘"), true, false, false),
            (.liveTradingLocked, true, false, false),
            (.unsupportedInstrument(.stock), true, false, false),
            (.notDelivered("试了 3 次都没送达 OKX"), false, true, false),
            (.unconfirmed("发出后没有回音"), false, false, true),
            (.readFailed("超时"), false, false, false),
            (.cliFailed(exitCode: 1, stderr: "x"), false, false, false),
        ]
        for (error, refusal, undelivered, unknown) in cases {
            #expect((error.refusal != nil) == refusal, "\(error)")
            #expect((error.undelivered != nil) == undelivered, "\(error)")
            #expect(error.outcomeUnknown == unknown, "\(error)")
            // No failure is both final and unknown.
            #expect(!(error.refusal != nil && error.outcomeUnknown), "\(error)")
            // Every screen reads the same standing off it: refused or
            // undelivered only when it says so, unknown otherwise.
            let standing = TradeError.standing(of: error)
            #expect(standing == (undelivered ? .undelivered : refusal ? .refused : .unknown), "\(error)")
        }
        #expect(TradeError.rejected(venue: "OKX", reason: "51169 no positions").hint?.contains("刷新持仓") == true)
        #expect(TradeError.okxCode(in: "51169 Order failed") == "51169", "the kernel's rejection leads with the code")
    }

    @Test("every outcome the kernel writes is read as what it is; one it never wrote is unknown")
    func kernelRepliesAreReadAsWhatTheySay() throws {
        let receipt = try KernelTradeClient.receipt(from: #"""
            {"outcome":"accepted","id":"77","clientId":"ms1","elapsedMs":250,"raw":"{}","retries":1,"retryReason":"OKX 限频（50011 Too Many Requests）","pacedMs":0}
            """#)
        #expect(receipt.id == "77" && receipt.clientId == "ms1")
        let cases: [(String, (TradeError) -> Bool)] = [
            (#"{"outcome":"rejected","code":"51169","message":"no positions","elapsedMs":1}"#,
             { $0.refusal?.contains("51169") == true }),
            (#"{"outcome":"notDelivered","reason":"试了 3 次都没送达 OKX"}"#, { $0.undelivered != nil }),
            (#"{"outcome":"unconfirmed","reason":"发出后没有回音","elapsedMs":10000}"#, { $0.outcomeUnknown }),
            (#"{"outcome":"refused","code":"liveLocked","reason":"实盘交易未解锁"}"#,
             { if case .liveTradingLocked = $0 { true } else { false } }),
            (#"{"outcome":"refused","code":"credentials","reason":"profile real 是实盘的 key"}"#,
             { if case .refused = $0 { true } else { false } }),
            // An outcome this side has never heard of says nothing about
            // whether the order was acted on.
            (#"{"outcome":"somethingNew","reason":"?"}"#, { $0.outcomeUnknown }),
            ("not json", { $0.outcomeUnknown }),
        ]
        for (text, expected) in cases {
            do {
                _ = try KernelTradeClient.receipt(from: text)
                Issue.record("\(text) must throw")
            } catch let error as TradeError {
                #expect(expected(error), "\(text) → \(error)")
            }
        }
    }

    @Test("the kernel's offline book publishes the document the ticket draws and the planner reads")
    func kernelBookPublishes() throws {
        let book = try KernelBook(instId: "ETH-USDT-SWAP", instType: .swap, mode: .demo, network: false)
        defer { book.stop() }
        let spec = BookDocument.Spec(instType: "SWAP", tickSz: "0.01", lotSz: "0.01", minSz: "0.01",
                                     ctVal: "0.1", ctMult: "1", ctType: "linear", ctValCcy: "ETH", settleCcy: "USDT")
        try book.ingest(String(decoding: try JSONEncoder().encode(["spec": spec]), as: UTF8.self))
        try book.ingest(TicketVenue.snapshot(
            instId: "ETH-USDT-SWAP", asks: [("2653.30", "4"), ("2653.40", "5")], bids: [("2653.20", "8")]))
        try book.ingest(#"{"arg":{"channel":"bbo-tbt","instId":"ETH-USDT-SWAP"},"data":[{"asks":[["2653.35","2","0","1"]],"bids":[["2653.20","8","0","3"]],"ts":"1790000000100","seqId":101}]}"#)
        let (_, json) = try #require(book.snapshot(since: 0))
        let document = try JSONDecoder().decode(BookDocument.self, from: json)
        #expect(document.isLive)
        #expect(document.asks.map(\.px) == ["2653.35", "2653.40"], "the newer top replaces what it passed")
        #expect(document.seqId == 101)
        #expect(document.spec == spec)
        #expect(document.spec?.priceDecimals == 2)
        #expect(document.spec?.contractValue == 0.1)
        // A frame that does not follow is a lost book, rebuilt, and counted.
        try book.ingest(#"{"arg":{"channel":"books","instId":"ETH-USDT-SWAP"},"action":"update","data":[{"asks":[],"bids":[],"ts":"1","prevSeqId":5,"seqId":6}]}"#)
        let (_, after) = try #require(book.snapshot(since: 0))
        let rebuilt = try JSONDecoder().decode(BookDocument.self, from: after)
        #expect(rebuilt.stats?.resyncs == 1)
        #expect(rebuilt.asks.isEmpty && rebuilt.bids.isEmpty, "a lost book is shown gone, not as it was")
    }

    @Test("a position's margin mode is read from the exchange's own document")
    func marginModeIsParsed() {
        let json = #"{"data":[{"instId":"ETH-USDT-SWAP","instType":"SWAP","pos":"122.04","posSide":"long","mgnMode":"isolated","avgPx":"2680"},{"instId":"BTC-USDT-SWAP","instType":"SWAP","pos":"-1","posSide":"net","mgnMode":"cross","avgPx":"60000"}]}"#
        let positions = KernelAccount.positions(json)
        #expect(positions.first { $0.instId == "ETH-USDT-SWAP" }?.marginMode == .isolated)
        #expect(positions.first { $0.instId == "BTC-USDT-SWAP" }?.marginMode == .cross)
    }
}
