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

    private func startedModel() throws -> CheckupModel {
        let model = CheckupModel(
            venue: FakeVenue(), mode: .live, instId: "ETH-USDT-SWAP",
            okxConfigPath: nil, network: false, nowOverrideMs: now)
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
        // The account: a long with a position-attached stop, plus a standalone stop.
        try model.ingest(topic: "okx.private", payload: json([
            "arg": ["channel": "positions", "instType": "ANY"], "eventType": "snapshot", "curPage": 1, "lastPage": true,
            "data": [["instId": "ETH-USDT-SWAP", "instType": "SWAP", "posId": "1", "posSide": "net", "pos": "187.75",
                      "avgPx": "2687.5", "markPx": "2721.0", "upl": "630", "lever": "20", "liqPx": "2564.69",
                      "notionalUsd": "51090", "margin": "", "imr": "2554", "mmr": "204", "mgnRatio": "31",
                      "fundingFee": "-1.2", "uTime": "\(now - 60_000)",
                      "closeOrderAlgo": [["algoId": "p1", "slTriggerPx": "2600", "tpTriggerPx": "", "closeFraction": "1"]]]],
        ]))
        try model.ingest(topic: "okx.private", payload: json(["arg": ["channel": "account"], "data": [["totalEq": "6773.9", "uTime": "\(now - 100)"]]]))
        try model.ingest(topic: "rest.okx.stops", payload: json(["code": "0", "data": [
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
        let position = try #require(risk.position)
        #expect(risk.source == "okx.private" && risk.wasRead)
        #expect(position.markSource == "okx.mark-price" && position.markPrice == 2721.3)
        #expect(Set(position.protective.map(\.kind)) == ["仓位止盈止损", "条件单"])
        let standalone = try #require(position.protective.first { $0.algoId == "s1" })
        #expect(standalone.stopPrice == 2580 && standalone.takeProfitPrice == nil && standalone.size == 187.75)
        #expect(risk.liquidationOdds.count == 3)
        #expect(risk.liquidationOdds.allSatisfy { $0.touching >= $0.atHorizon })
        #expect(abs((risk.exposure?.effectiveLeverage ?? 0) - 51_090 / 6773.9) < 1e-9)

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

    @Test("an unchanged snapshot is not handed out twice")
    func unchangedSnapshotIsNotRepublished() throws {
        let model = try startedModel()
        defer { model.stop() }
        #expect(!model.pull(), "nothing moved since the last ingest")
    }
}
