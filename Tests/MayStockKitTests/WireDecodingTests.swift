import Foundation
import Testing
@testable import MayStockKit

@Suite("OKX wire decoding")
struct WireDecodingTests {
    @Test func decodesTickerFrame() throws {
        let frame = """
        {"arg":{"channel":"tickers","instId":"BTC-USDT"},"data":[{"instType":"SPOT","instId":"BTC-USDT",\
        "last":"118234.5","lastSz":"0.01","askPx":"118234.6","askSz":"1","bidPx":"118234.4","bidSz":"2",\
        "open24h":"116800.0","high24h":"119102.3","low24h":"116500.1","volCcy24h":"1000000","vol24h":"12400.5",\
        "sodUtc0":"117000","sodUtc8":"117100","ts":"1783500000000"}]}
        """
        guard case .ticker(let t) = try OKXWireDecoder.decode(frame) else {
            Issue.record("expected ticker"); return
        }
        #expect(t.instId == "BTC-USDT")
        #expect(t.last == 118234.5)
        #expect(t.bid == 118234.4)
        #expect(t.ask == 118234.6)
        #expect(abs(t.changePct24h - (118234.5 - 116800.0) / 116800.0 * 100) < 1e-9)
        #expect(t.ts == Date(timeIntervalSince1970: 1_783_500_000))
    }

    @Test func decodesCandleFrame() throws {
        let frame = """
        {"arg":{"channel":"candle1m","instId":"BTC-USDT"},"data":[\
        ["1783500000000","118200","118300","118100","118250","10.5","1241625","1241625","0"],\
        ["1783499940000","118100","118220","118050","118200","8.2","968040","968040","1"]]}
        """
        guard case .candles(let instId, let bar, let candles) = try OKXWireDecoder.decode(frame) else {
            Issue.record("expected candles"); return
        }
        #expect(instId == "BTC-USDT")
        #expect(bar == .m1)
        #expect(candles.count == 2)
        #expect(candles[0].confirmed == false)
        #expect(candles[1].confirmed == true)
        #expect(candles[0].open == 118_200)
        #expect(candles[0].volume == 10.5)
    }

    @Test func decodesBooks5Frame() throws {
        let frame = """
        {"arg":{"channel":"books5","instId":"BTC-USDT"},"data":[{\
        "asks":[["118234.6","1.5","0","3"],["118235.0","2.0","0","5"]],\
        "bids":[["118234.4","0.8","0","2"],["118234.0","1.2","0","4"]],\
        "instId":"BTC-USDT","ts":"1783500000000","seqId":123}]}
        """
        guard case .book(let book) = try OKXWireDecoder.decode(frame) else {
            Issue.record("expected book"); return
        }
        #expect(book.bestBid == 118234.4)
        #expect(book.bestAsk == 118234.6)
        #expect(book.mid == (118234.4 + 118234.6) / 2)
        #expect(book.cumulativeBids.last?.size == 2.0) // 0.8 + 1.2
        #expect(book.cumulativeAsks.last?.size == 3.5) // 1.5 + 2.0
    }

    @Test func decodesEventFrames() throws {
        let sub = #"{"event":"subscribe","arg":{"channel":"tickers","instId":"BTC-USDT"},"connId":"a"}"#
        guard case .subscribed(let channel, let instId) = try OKXWireDecoder.decode(sub) else {
            Issue.record("expected subscribed"); return
        }
        #expect(channel == "tickers" && instId == "BTC-USDT")

        let err = #"{"event":"error","code":"60018","msg":"channel doesn't exist","connId":"a"}"#
        guard case .error(let code, _) = try OKXWireDecoder.decode(err) else {
            Issue.record("expected error"); return
        }
        #expect(code == "60018")

        #expect(try OKXWireDecoder.decode("pong") == .pong)
    }

    @Test func ignoresUnknownChannels() throws {
        let frame = #"{"arg":{"channel":"channel-conn-count"},"data":[]}"#
        #expect(try OKXWireDecoder.decode(frame) == .ignored)
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            _ = try OKXWireDecoder.decode("\u{FFFF}{{not json")
        }
    }
}

@Suite("Candle merging")
struct CandleMergeTests {
    private func candle(_ minute: Int, close: Double, confirmed: Bool = true) -> Candle {
        Candle(ts: Date(timeIntervalSince1970: Double(minute) * 60),
               open: close - 1, high: close + 1, low: close - 2, close: close,
               volume: 1, confirmed: confirmed)
    }

    @Test func mergeReplacesInProgressBar() {
        var candles = [candle(1, close: 100), candle(2, close: 101, confirmed: false)]
        candles.mergeCandles([candle(2, close: 105, confirmed: false)])
        #expect(candles.count == 2)
        #expect(candles.last?.close == 105)
    }

    @Test func mergeAppendsAndSorts() {
        var candles = [candle(1, close: 100)]
        candles.mergeCandles([candle(3, close: 103), candle(2, close: 102)])
        #expect(candles.map(\.close) == [100, 102, 103])
    }

    @Test func mergeRespectsCap() {
        var candles: [Candle] = []
        candles.mergeCandles((0..<600).map { candle($0, close: Double($0)) }, cap: 500)
        #expect(candles.count == 500)
        #expect(candles.first?.close == 100) // oldest 100 dropped
        #expect(candles.last?.close == 599)
    }

    @Test func restBackfillMergesWithLiveBars() {
        // Live WS bar arrives first, then REST backfill lands — no duplicates.
        var candles: [Candle] = []
        candles.mergeCandles([candle(10, close: 110, confirmed: false)])
        candles.mergeCandles((1...10).map { candle($0, close: 100 + Double($0)) })
        #expect(candles.count == 10)
        #expect(candles.last?.ts == Date(timeIntervalSince1970: 600))
    }
}

// Sparkline buffer coverage lives in ChartDataTests.swift alongside the rest
// of the charting data path.
