import Foundation
import Testing
@testable import MayStockKit

/// The live layer end to end, offline: recorded-shape frames go into the
/// kernel down the path live frames take, and the whole snapshot comes back
/// out through `LiveSnapshot`.
///
/// The point is the seam. The kernel writes the snapshot in Rust, the app
/// reads it in Swift, and nothing but this test says the two agree: a field
/// renamed on one side decodes as a failure here instead of as a dash on the
/// screen.
@Suite("Live kernel golden")
@MainActor
struct LiveKernelGoldenTests {

    /// 2026-09-23 12:00:00 UTC; the 25SEP26 expiry settles 44 hours later.
    private let now: Int64 = 1_790_164_800_000
    private let expiry: Int64 = 1_790_323_200_000
    private let forward = 2720.0

    private func json(_ object: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func normalCDF(_ x: Double) -> Double { 0.5 * erfc(-x / 2.0.squareRoot()) }

    /// Black–Scholes on the forward with no rates, in dollars.
    private func price(call: Bool, strike: Double, iv: Double, years: Double) -> Double {
        let v = iv * years.squareRoot()
        let d1 = (log(forward / strike) + v * v / 2) / v
        let d2 = d1 - v
        return call ? forward * normalCDF(d1) - strike * normalCDF(d2)
            : strike * normalCDF(-d2) - forward * normalCDF(-d1)
    }

    /// Deribit's surface frame for 25SEP26, priced off a put-skewed smile so
    /// parity recovers `forward` exactly.
    private func surfaceFrame() -> String {
        let years = Double(expiry - now) / (365 * 86_400_000)
        var rows: [[String: Any]] = []
        for strike in stride(from: 2300.0, through: 3200.0, by: 50.0) {
            let k = log(strike / forward)
            let iv = 0.47 - 0.8 * k + 3 * k * k
            for call in [true, false] {
                rows.append([
                    "timestamp": now - 500, "iv": iv,
                    "instrument_name": "ETH-25SEP26-\(Int(strike))-\(call ? "C" : "P")",
                    "mark_price": price(call: call, strike: strike, iv: iv, years: years) / forward,
                ])
            }
        }
        return json(["jsonrpc": "2.0", "method": "subscription",
                     "params": ["channel": "markprice.options.eth_usd", "data": rows]])
    }

    private func okx(_ channel: String, _ row: [String: Any], instId: String = "ETH-USDT-SWAP") -> String {
        json(["arg": ["channel": channel, "instId": instId], "data": [row]])
    }

    private func rubik(_ rows: [[String]]) -> String { json(["code": "0", "data": rows]) }

    /// The account as pushed, and the mark the account's stream carries
    /// after the push.
    private let usdtUsd = 0.9996
    private let accountUsdt = 6776.61
    private var accountUsd: Double { accountUsdt * usdtUsd }
    private let streamedMark = 2721.3

    private func startedModel() throws -> CheckupModel {
        let kernel = try LiveKernel(config: LiveKernel.Config(
            instId: "ETH-USDT-SWAP", followsHeldPosition: true, mode: .live,
            okxProfile: nil, okxConfigPath: nil, schwabctlPath: nil,
            network: false, nowOverrideMs: now, analytics: false))
        let model = CheckupModel(kernel: kernel, instId: "ETH-USDT-SWAP")
        model.start()
        try model.ingest(topic: "rest.clock", payload: json([
            "server": json(["code": "0", "data": [["ts": "\(now - 40)"]]]), "sentMs": now - 100, "receivedMs": now + 100,
        ]))
        // OKX index ticks either side of the smile's quote time, so its forward
        // is carried exactly.
        for (offset, price) in [(-800, 2719.0), (-100, 2721.0)] {
            try model.ingest(topic: "okx.public", payload: okx("index-tickers", ["instId": "ETH-USD", "idxPx": "\(price)", "ts": "\(now + Int64(offset))"], instId: "ETH-USD"))
        }
        try model.ingest(topic: "deribit", payload: surfaceFrame())
        try model.ingest(topic: "deribit", payload: json(["jsonrpc": "2.0", "method": "subscription", "params": [
            "channel": "deribit_price_index.eth_usd", "data": ["timestamp": now - 200, "price": 2720.5, "index_name": "eth_usd"]]]))
        try model.ingest(topic: "rest.deribit.book", payload: json(["result": [
            ["instrument_name": "ETH-25SEP26-2400-P", "open_interest": 30_000.0, "mark_price": 0.0003, "underlying_price": forward],
            ["instrument_name": "ETH-25SEP26-2600-P", "open_interest": 20_000.0, "mark_price": 0.002, "underlying_price": forward],
            ["instrument_name": "ETH-25SEP26-3000-C", "open_interest": 40_000.0, "mark_price": 0.001, "underlying_price": forward],
        ]]))
        try model.ingest(topic: "rest.bybit.options", payload: json(["retCode": 0, "result": ["list": [
            ["symbol": "ETH-25SEP26-2600-P-USDT", "openInterest": "5000", "markPrice": "5.2"],
        ]]]))
        try model.ingest(topic: "okx.public", payload: okx("mark-price", ["instId": "ETH-USDT-SWAP", "markPx": "2721.3", "ts": "\(now - 300)"]))
        try model.ingest(topic: "okx.public", payload: okx("tickers", ["instId": "ETH-USDT-SWAP", "last": "2721.1", "ts": "\(now - 50)"]))
        try model.ingest(topic: "okx.public", payload: okx("funding-rate", ["instId": "ETH-USDT-SWAP", "fundingRate": "0.0001", "fundingTime": "\(now + 3_600_000)", "ts": "\(now - 20_000)"]))
        try model.ingest(topic: "okx.public", payload: okx("open-interest", ["instId": "ETH-USDT-SWAP", "oi": "6300000", "oiCcy": "630000", "oiUsd": "1714000000", "ts": "\(now - 2_000)"]))
        for (index, side) in ["buy", "sell", "sell"].enumerated() {
            try model.ingest(topic: "okx.public", payload: okx("trades", ["instId": "ETH-USDT-SWAP", "px": "2721", "sz": "\(10 + index)", "side": side, "ts": "\(now - 1_000 + Int64(index))"]))
        }
        // Five-minute history: open interest an hour and four hours back.
        let buckets = (0..<60).map { i -> [String] in
            let ms = now - Int64(i) * 300_000
            return ["\(ms)", "6000000", "\(600_000 + Double(i) * 500)", "1600000000"]
        }
        try model.ingest(topic: "rest.okx.history.oi", payload: rubik(buckets))
        try model.ingest(topic: "rest.okx.history.accounts", payload: rubik([["\(now - 300_000)", "1.32"]]))
        try model.ingest(topic: "rest.okx.history.top-positions", payload: rubik([["\(now - 300_000)", "0.95"]]))
        try model.ingest(topic: "rest.binance.history.accounts", payload: json([["longShortRatio": "2.52", "timestamp": now - 300_000]]))
        try model.ingest(topic: "rest.binance.oi", payload: json(["openInterest": "2341129", "time": now - 1_500]))
        try model.ingest(topic: "binance.stream", payload: json(["e": "markPriceUpdate", "E": now - 700, "p": "2720.9", "i": "2721.2", "r": "0.00004745", "T": now + 3_600_000]))
        // The account: a long with a position-attached stop, plus a standalone
        // stop, settled in USDT at OKX's own USDT price.
        try model.ingest(topic: "okx.private", payload: json([
            "arg": ["channel": "positions", "instType": "ANY"], "eventType": "snapshot", "curPage": 1, "lastPage": true,
            "data": [["instId": "ETH-USDT-SWAP", "instType": "SWAP", "posId": "1", "posSide": "net", "pos": "187.75",
                      "avgPx": "2687.5", "markPx": "2721.0", "upl": "630", "uplRatio": "0.2467", "lever": "20", "liqPx": "2564.69",
                      "notionalUsd": "51090", "margin": "", "imr": "2554", "mmr": "204", "mgnRatio": "31",
                      "fundingFee": "-1.2", "uTime": "\(now - 60_000)", "ccy": "USDT", "usdPx": "\(usdtUsd)",
                      "closeOrderAlgo": [["algoId": "p1", "slTriggerPx": "2600", "tpTriggerPx": "", "closeFraction": "1"]]]],
        ]))
        try model.ingest(topic: "okx.private", payload: json(["arg": ["channel": "account"], "eventType": "snapshot", "data": [[
            "totalEq": "\(accountUsd)", "uTime": "\(now - 100)",
            "details": [["ccy": "USDT", "eq": "\(accountUsdt)", "eqUsd": "\(accountUsd)", "upl": "630", "availBal": "4219.9"]],
        ]]]))
        // The account environment's own mark stream, and the terms that
        // value the position at it.
        try model.ingest(topic: "rest.okx.spec.ETH-USDT-SWAP", payload: json(["code": "0", "data": [[
            "instId": "ETH-USDT-SWAP", "instType": "SWAP", "tickSz": "0.01", "lotSz": "0.01", "minSz": "0.01",
            "ctVal": "0.1", "ctMult": "1", "ctType": "linear", "ctValCcy": "ETH", "settleCcy": "USDT", "state": "live",
        ]]]))
        try model.ingest(topic: "okx.marks", payload: okx("mark-price", ["instId": "ETH-USDT-SWAP", "markPx": "\(streamedMark)", "ts": "\(now - 10)"]))
        try model.ingest(topic: "rest.okx.orders", payload: json(["code": "0", "data": [
            ["algoId": "s1", "instId": "ETH-USDT-SWAP", "instType": "SWAP", "ordType": "conditional", "side": "sell", "posSide": "net",
             "sz": "187.75", "slTriggerPx": "2580", "slOrdPx": "-1", "tpTriggerPx": "", "reduceOnly": "true", "state": "live"],
        ]]))
        // Schwab: two instruments and the six FX pairs the dollar index is built from.
        var content: [[String: Any]] = [["key": "TLT", "delayed": false, "1": 80.72, "2": 80.74, "3": 80.73, "12": 81.75, "34": now - 900, "35": now - 1_200]]
        for (pair, mid) in [("EUR/USD", 1.12), ("USD/JPY", 150.0), ("GBP/USD", 1.30), ("USD/CAD", 1.38), ("USD/SEK", 10.4), ("USD/CHF", 0.86)] {
            content.append(["key": pair, "1": mid * 0.9999, "2": mid * 1.0001, "12": mid, "8": now - 400])
        }
        try model.ingest(topic: "schwab", payload: json(["data": [
            ["service": "LEVELONE_EQUITIES", "content": [content[0]]],
            ["service": "LEVELONE_FOREX", "content": Array(content.dropFirst())],
        ]]))
        return model
    }

    @Test("a full snapshot decodes, section by section")
    func fullSnapshotDecodes() throws {
        let model = try startedModel()
        defer { model.stop() }
        #expect(model.failure == nil, "decode failure: \(model.failure ?? "")")
        let snapshot = try #require(model.snapshot)

        #expect(abs((snapshot.clock?.offsetMs ?? 0) - 40) < 1e-9)
        #expect(!snapshot.feeds.isEmpty && snapshot.feeds.allSatisfy { $0.staleAfterMs > 0 }, "every feed says when its age turns stale")
        #expect(snapshot.gravity.bookStaleAfterMs > 0 && snapshot.risk.stopsStaleAfterMs > 0)
        #expect(snapshot.spot?.value == 2721.0)

        let probability = snapshot.probability
        let column = try #require(probability.columns.first)
        #expect(probability.columns.count == 1)
        #expect(probability.forwardAnchor == "exact")
        #expect(probability.spotBucket != nil)
        #expect(column.probabilities.count == probability.edges.count + 1)
        #expect(abs(column.probabilities.reduce(0, +) - 1) < 1e-6)
        #expect(column.clamped.isEmpty)
        #expect(abs(column.forward - 2720.0 * 2721.0 / 2719.0) < 0.05, "carried by the index since the quote")

        let row = try #require(snapshot.gravity.expiries.first)
        #expect(row.oiBase == 95_000)
        #expect(row.venueShares.map(\.venue) == ["Deribit", "Bybit"])
        #expect(row.maxPain != nil && row.pBeyondMaxPain != nil)

        let risk = snapshot.risk
        #expect(risk.positions.count == 1)
        let position = try #require(risk.positions.first)
        #expect(risk.source == "okx.private" && risk.wasRead)
        // Valued at the account environment's streamed mark, by the venue's
        // rule, and the buffer read at the same mark.
        #expect(risk.mark?.source == "okx.mark-price" && risk.mark?.price == streamedMark)
        let upl = (streamedMark - 2687.5) * 187.75 * 0.1
        #expect(position.remarked)
        #expect(abs((position.unrealisedPnl ?? 0) - upl) < 1e-9)
        #expect(abs((position.unrealisedRatio ?? 0) - upl * 0.2467 / 630) < 1e-12, "the venue's own denominator")
        let notional = 187.75 * 0.1 * streamedMark * usdtUsd
        #expect(abs((position.notionalUsd ?? 0) - notional) < 1e-6)
        // The account document says the same, with the equity valued at it.
        let account = snapshot.account
        let holding = try #require(account.positions.first)
        #expect(holding.unrealisedPnl == position.unrealisedPnl && holding.remarked)
        let equity = try #require(account.equity)
        let equityUsd = accountUsd + (upl - 630) * usdtUsd
        #expect(abs(equity.usd - equityUsd) < 1e-6)
        #expect(equity.pushedUsd == accountUsd && equity.unmarked.isEmpty)
        let reading = try #require(account.snapshot)
        #expect(abs((reading.equity(in: "USDT") ?? 0) - equityUsd / usdtUsd) < 1e-6, "stated in USDT at the push's own rate")
        #expect(Set(position.protective.map(\.kind)) == ["仓位止盈止损", "条件单"])
        let standalone = try #require(position.protective.first { $0.algoId == "s1" })
        #expect(standalone.stopPrice == 2580 && standalone.takeProfitPrice == nil && standalone.size == 187.75)
        #expect(risk.unattachedOrders.isEmpty)
        #expect(position.liquidationOdds.count == 3)
        #expect(position.liquidationOdds.allSatisfy { $0.touching >= $0.atHorizon })
        #expect(abs((risk.exposure?.effectiveLeverage ?? 0) - notional / equityUsd) < 1e-9)
        #expect(abs((risk.exposure?.netNotional ?? 0) - notional) < 1e-6 && risk.exposure?.grossNotional == risk.exposure?.netNotional)

        let okxVenue = try #require(snapshot.structure.first { $0.venue == "OKX" })
        #expect(okxVenue.fundingRate?.value == 0.0001)
        #expect(okxVenue.openInterest?.base == 630_000)
        #expect(okxVenue.oiChange1h?.referenceMs == now - 13 * 300_000, "the newest bucket at or before an hour before the live reading")
        #expect(okxVenue.liveTaker?.trades == 3)
        let binance = try #require(snapshot.structure.first { $0.venue == "Binance" })
        #expect(binance.price?.value == 2720.9)
        #expect(binance.allAccounts?.value == 2.52)

        #expect(snapshot.macro.source == "schwab")
        #expect(abs((snapshot.macro.rows.first { $0.id == "TLT" }?.price ?? 0) - 80.73) < 1e-9, "mid of the standing bid and ask")
        let dollar = try #require(snapshot.macro.rows.first { $0.id == "DXY" }?.price)
        // ICE's formula on the mids above.
        let expected = 50.14348112 * pow(1.12, -0.576) * pow(150.0, 0.136) * pow(1.30, -0.119)
            * pow(1.38, 0.091) * pow(10.4, 0.042) * pow(0.86, 0.036)
        #expect(abs(dollar - expected) / expected < 1e-6)
    }

    /// Walks every field of the decoded snapshot rather than naming them, so
    /// a stamped value added later is held to the same rule the day it lands:
    /// its stale age is the kernel's, and a real one.
    @Test("every stale age in the snapshot is one the kernel declared, and positive")
    func everyStaleAgeIsDeclared() throws {
        let model = try startedModel()
        defer { model.stop() }
        let found = staleAges(in: try #require(model.snapshot))
        for section in ["structure", "probability", "risk", "macro", "account", "feeds", "gravity"] {
            #expect(found.contains { $0.hasPrefix("snapshot.\(section)") }, "the fixture ages nothing under \(section)")
        }
        // A US review ages what only it carries: an option's quote, and the
        // venue's own figures for a leg.
        let us = try startedUSModel()
        defer { us.stop() }
        let usFound = staleAges(in: try #require(us.snapshot))
        for path in ["option.quote.staleAfterMs", "venueFigures.staleAfterMs", "risk.positionsStaleAfterMs", "risk.stopsStaleAfterMs"] {
            #expect(usFound.contains { $0.hasSuffix(path) }, "the US fixture ages nothing at \(path): \(usFound)")
        }
    }

    /// Every `…staleAfterMs` in a decoded snapshot, held to being positive.
    private func staleAges(in snapshot: LiveSnapshot) -> [String] {
        var found: [String] = []
        func walk(_ value: Any, path: String) {
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                if let inner = mirror.children.first { walk(inner.value, path: path) }
                return
            }
            for child in mirror.children {
                let here = path + "." + (child.label ?? "[]")
                guard let label = child.label, label == "staleAfterMs" || label.hasSuffix("StaleAfterMs") else {
                    walk(child.value, path: here)
                    continue
                }
                let inner = Mirror(reflecting: child.value)
                let age = inner.displayStyle == .optional ? inner.children.first?.value as? Double : child.value as? Double
                guard let age else { continue }
                found.append(here)
                #expect(age > 0, "\(here) is \(age)")
            }
        }
        walk(snapshot, path: "snapshot")
        return found
    }

    // MARK: A US share and its options

    /// 2026-10-09 07:00 UTC, a Friday before New York opens; MU's 20NOV26
    /// contracts stop trading 2026-11-20 16:00 EST.
    private let usNow: Int64 = 1_791_529_200_000
    private let usExpiry: Int64 = 1_795_208_400_000
    private let mu = 1035.84
    private let call = "MU    261120C01040000"
    private let put = "MU    261120P01000000"

    /// Schwab's chain for MU's 20NOV26 expiry, priced off a skewed smile on
    /// the forward its rate gives.
    private func chainBody() -> String {
        let years = Double(usExpiry - usNow) / (365 * 86_400_000)
        let growth = exp(0.04043 * years)
        let forward = mu * growth
        func value(_ isCall: Bool, _ strike: Double) -> Double {
            let k = log(strike / forward)
            let iv = 0.45 - 0.3 * k + 0.6 * k * k
            let v = iv * years.squareRoot()
            let d1 = (log(forward / strike) + v * v / 2) / v
            let d2 = d1 - v
            let undiscounted = isCall ? forward * normalCDF(d1) - strike * normalCDF(d2) : strike * normalCDF(-d2) - forward * normalCDF(-d1)
            return undiscounted / growth
        }
        func side(_ isCall: Bool) -> [String: Any] {
            var strikes: [String: Any] = [:]
            for strike in stride(from: 800.0, through: 1300.0, by: 20.0) {
                let price = value(isCall, strike)
                strikes[String(format: "%.1f", strike)] = [[
                    "putCall": isCall ? "CALL" : "PUT",
                    "symbol": String(format: "MU    261120%@%08d", isCall ? "C" : "P", Int(strike * 1000)),
                    "bid": max(price - 0.05, 0), "ask": price + 0.05, "last": price, "mark": price,
                    "openInterest": 100 + Int(strike) % 300, "totalVolume": 3,
                    "delta": isCall ? 0.5 : -0.5, "gamma": 0.002, "theta": -0.7, "vega": 1.4, "volatility": -999.0,
                    "quoteTimeInLong": usNow - 40_000_000, "strikePrice": strike,
                    "expirationDate": "2026-11-20T21:00:00.000+00:00", "multiplier": 100.0, "nonStandard": false, "pennyPilot": true,
                    "optionDeliverablesList": [["symbol": "MU", "assetType": "STOCK", "deliverableUnits": 100.0]],
                ] as [String: Any]]
            }
            return ["2026-11-20:42": strikes]
        }
        return json([
            "symbol": "MU", "status": "SUCCESS", "isDelayed": false, "interestRate": 4.043, "underlyingPrice": mu,
            "underlying": ["symbol": "MU", "last": mu, "quoteTime": usNow - 39_000_000],
            "callExpDateMap": side(true), "putExpDateMap": side(false),
        ])
    }

    /// The account holds a call and a written put on MU; the page follows it
    /// there. Everything arrives down the paths the app and the stream use.
    private func startedUSModel() throws -> CheckupModel {
        let kernel = try LiveKernel(config: LiveKernel.Config(
            instId: "ETH-USDT-SWAP", followsHeldPosition: true, mode: .live,
            okxProfile: nil, okxConfigPath: nil, schwabctlPath: nil,
            network: false, nowOverrideMs: usNow, analytics: false))
        let model = CheckupModel(kernel: kernel)
        model.start()
        let document = json(["securitiesAccount": [
            "type": "MARGIN", "accountNumber": "42324703",
            "currentBalances": ["cashBalance": 10_000.0, "liquidationValue": 20_815.0, "availableFunds": 9_000.0],
            "positions": [
                ["longQuantity": 2, "shortQuantity": 0, "averagePrice": 60.5, "marketValue": 13_625.0, "longOpenProfitLoss": 1_525.0,
                 "instrument": ["assetType": "OPTION", "symbol": call, "putCall": "CALL", "underlyingSymbol": "MU", "optionMultiplier": 100]],
                ["longQuantity": 0, "shortQuantity": 1, "averagePrice": 31.0, "marketValue": -2_810.0, "shortOpenProfitLoss": 290.0,
                 "maintenanceRequirement": 20_500.0,
                 "instrument": ["assetType": "OPTION", "symbol": put, "putCall": "PUT", "underlyingSymbol": "MU"]],
            ],
        ]])
        let account = try SchwabAccount.read(Data(document.utf8))
        try model.ingest(topic: SchwabVenue.accountTopic, payload: "{\"source\":\"schwab\",\"account\":\(account.document)}")
        try model.ingest(topic: SchwabVenue.ordersTopic, payload: json(["orders": [
            ["id": "9", "instId": call, "ordType": "stop", "side": "sell", "stopPrice": 50.0, "size": 2, "filledSize": 0, "state": "working", "reduceOnly": true],
        ]]))
        try model.ingest(topic: "rest.schwab.chain.MU", payload: chainBody())
        try model.ingest(topic: "schwab", payload: json(["data": [
            ["service": "LEVELONE_EQUITIES", "content": [["key": "MU", "1": mu - 0.05, "2": mu + 0.05, "3": mu, "34": usNow - 1_000]]],
            ["service": "LEVELONE_OPTIONS", "content": [["key": call, "2": 67.2, "3": 69.05, "4": 68.0, "37": 68.125, "8": 660, "9": 2778,
                                                         "10": 45.48, "28": 0.525, "29": 0.0025, "30": -0.77, "31": 1.42, "38": usNow - 2_000]]],
        ]]))
        return model
    }

    @Test("a US share and its options decode, leg by leg, off Schwab's account, chain and stream")
    func usReviewDecodes() throws {
        let model = try startedUSModel()
        defer { model.stop() }
        #expect(model.failure == nil, "decode failure: \(model.failure ?? "")")
        let snapshot = try #require(model.snapshot)
        #expect(snapshot.instrument.instId == "MU" && snapshot.instrument.isUSEquity && snapshot.instrument.followsHeld)
        #expect(snapshot.reviewable.first?.label == "MU · 3 张期权")
        #expect(snapshot.structure.isEmpty, "a share has no perpetual positioning")
        #expect(abs((snapshot.spot?.value ?? 0) - mu) < 1e-9 && snapshot.spot?.source == "嘉信报价推送", "mid of the streamed quote")

        let risk = snapshot.risk
        #expect(risk.venue == "schwab" && risk.source == "schwab" && risk.wasRead)
        #expect(risk.equity?.value == 20_815)
        #expect(risk.exposureNote?.contains("Delta") == true)
        let long = try #require(risk.positions.first { $0.instId == call })
        let option = try #require(long.option)
        #expect(long.family == "OPTION" && long.venue == "schwab" && !long.isShort)
        #expect(option.label == "MU 2026-11-20 1040 C" && option.call && option.strike == 1040 && option.expiryMs == usExpiry)
        let quote = try #require(option.quote)
        #expect(quote.source == "schwab.stream" && abs(quote.mark - (67.2 + 69.05) / 2) < 1e-9)
        #expect(quote.volume == 660 && quote.openInterest == 2778)
        #expect(abs((long.unrealisedPnl ?? 0) - (quote.mark - 60.5) * 200) < 1e-6 && long.remarked)
        #expect(long.venueFigures?.openProfitLoss == 1_525)
        #expect(option.delta == 0.525 && abs((option.positionDelta ?? 0) - 105) < 1e-9)
        #expect(option.iv == 45.48 && option.greeksSource == "stream")
        #expect(option.breakeven == 1_100.5 && option.maxLoss == 12_100 && option.assignment == nil)
        #expect(option.oddsBasis?.exact == true)
        let pItm = try #require(option.pItm)
        #expect(pItm > 0.3 && pItm < 0.6 && (option.pProfit ?? 1) < pItm)
        #expect(long.protective.first?.stopPrice == 50 && long.protective.first?.kind == "止损单")

        let written = try #require(risk.positions.first { $0.instId == put })
        #expect(written.isShort && written.margin == 20_500)
        let writtenOption = try #require(written.option)
        #expect(writtenOption.quote?.source == "schwab.chain", "not streamed: the chain's quote")
        #expect((writtenOption.pTouchStrike ?? 0) > (writtenOption.pItm ?? 1))
        #expect(writtenOption.maxLoss == 96_900)
        #expect(written.protective.isEmpty)

        let probability = snapshot.probability
        #expect(probability.smileVenue == "嘉信期权链" && probability.smileFeed == "schwab.chain")
        #expect(probability.columns.contains { $0.expiryMs == usExpiry }, "the held expiry is a column")
        #expect(!probability.notes.isEmpty)
        let gravity = snapshot.gravity
        #expect(gravity.venues.map(\.venue) == ["嘉信（全美合并）"] && gravity.oiUnit == "张" && gravity.oiPerUnit == 100)
        #expect(gravity.bookFeed == "schwab.chain")
        let row = try #require(gravity.expiries.first)
        #expect(row.expiryMs == usExpiry && row.maxPain != nil)
    }

    @Test("choosing what to review moves the page there, and following goes back to what is held")
    func reviewIsChosen() throws {
        let model = try startedUSModel()
        defer { model.stop() }
        let eth = LiveSnapshot.Reviewable(market: LiveSnapshot.Reviewable.crypto, instId: "ETH-USDT-SWAP", label: "ETH-USDT-SWAP", held: false)
        model.review(eth)
        #expect(model.snapshot?.instrument.instId == "ETH-USDT-SWAP" && model.snapshot?.instrument.market == "crypto")
        #expect(model.snapshot?.instrument.followsHeld == false)
        #expect(model.snapshot?.risk.venue == "okx")
        model.review(nil)
        #expect(model.snapshot?.instrument.instId == "MU", "following the held options again")
    }

    @Test("an unchanged snapshot is not handed out twice")
    func unchangedSnapshotIsNotRepublished() throws {
        let model = try startedModel()
        defer { model.stop() }
        #expect(!model.pull(), "nothing moved since the last ingest")
    }

    @Test("Polymarket topics decode with their book, and a topic not yet read says so")
    func predictionsDecode() throws {
        let model = try startedModel()
        defer { model.stop() }
        let unread = try #require(model.snapshot?.predictions)
        #expect(!unread.topics.isEmpty && unread.topics.allSatisfy { $0.fetchedMs == nil && $0.lines.isEmpty })
        let topic = try #require(unread.topics.first).id
        try model.ingest(topic: "rest.polymarket.\(topic)", payload: json([[
            "title": "Fed Decision in October?", "endDate": "2026-10-29T03:59:00Z", "volume24hr": 572_701.0, "liquidity": 2_252_949.0,
            "markets": [
                ["groupItemTitle": "25 bps increase", "bestBid": 0.66, "bestAsk": 0.67, "lastTradePrice": 0.67,
                 "oneHourPriceChange": 0.01, "oneDayPriceChange": -0.03, "oneWeekPriceChange": 0.14, "volume24hr": 146_586.8,
                 "endDate": "2026-10-29T03:59:00Z"],
                ["groupItemTitle": "No change", "bestBid": 0.01, "bestAsk": 0.89, "endDate": "2026-10-29T03:59:00Z"],
            ],
        ]]))
        let predictions = try #require(model.snapshot?.predictions)
        let read = try #require(predictions.topics.first { $0.id == topic })
        #expect(read.fetchedMs != nil && read.error == nil)
        let cells = read.lines.flatMap(\.cells)
        let hike = try #require(cells.first { $0.label == "25 bps increase" })
        #expect(abs((hike.probability ?? 0) - 0.665) < 1e-9 && hike.bid == 0.66 && hike.ask == 0.67 && hike.lastTrade == 0.67)
        #expect(hike.change1h == 0.01 && hike.change1d == -0.03 && hike.change1w == 0.14)
        #expect(cells.first { $0.label == "No change" }?.probability == nil, "an untraded 0.01/0.89 book has no price")
        #expect(predictions.topics.filter { $0.id != topic }.allSatisfy { $0.fetchedMs == nil })
    }

    @Test("every width the kernel offers cuts the probability table to that width")
    func everyOfferedWidthApplies() throws {
        let model = try startedModel()
        defer { model.stop() }
        let choices = try #require(model.snapshot?.probability.gridChoices)
        #expect(choices.count > 1 && choices.first?.divisor == 1, "the automatic width first, finer ones after")
        for choice in choices.reversed() + choices {
            model.gridDivisor = choice.divisor
            let probability = try #require(model.snapshot?.probability)
            #expect(probability.gridDivisor == choice.divisor && probability.gridStep == choice.step)
            let gaps = zip(probability.edges.dropFirst(), probability.edges).map { $0 - $1 }
            #expect(!gaps.isEmpty && gaps.allSatisfy { abs($0 - choice.step) < 1e-9 }, "edges \(probability.edges)")
            let column = try #require(probability.columns.first)
            #expect(abs(column.probabilities.reduce(0, +) - 1) < 1e-6)
        }
    }
}
