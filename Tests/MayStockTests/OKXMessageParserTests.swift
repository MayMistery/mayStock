import Foundation
@testable import MayStock

/// Unit tests for OKXMessageParser.
/// Verifies parsing of ticker, candle, order book, ping, and malformed messages.
enum OKXMessageParserTests {
    static func runAll() throws {
        try testParsesTickerMessage()
        try testParsesCandleMessage()
        try testParsesOrderBookMessage()
        try testHandlesPingMessage()
        testThrowsOnMalformedJSON()
    }

    static func testParsesTickerMessage() throws {
        let json = """
        {"arg":{"channel":"tickers","instId":"BTC-USDT"},"data":[{"instId":"BTC-USDT","last":"62213.5","vol24h":"1234.56","open24h":"61000.0","high24h":"63000.0","low24h":"60500.0","ts":"1720000000000"}]}
        """
        let result = try OKXMessageParser.parse(json)
        guard case .ticker(let tick) = result else {
            assertionFailure("Expected ticker, got \(result)")
            return
        }
        assert(tick.price == 62213.5, "Expected price 62213.5, got \(tick.price)")
        assert(tick.volume == 1234.56, "Expected volume 1234.56, got \(tick.volume)")
    }

    static func testParsesCandleMessage() throws {
        let json = """
        {"arg":{"channel":"candle1m","instId":"BTC-USDT"},"data":[["1720000000000","62000","62500","61800","62300","100.5","6230000","6230000","1"]]}
        """
        let result = try OKXMessageParser.parse(json)
        guard case .candles(let ohlcList) = result, let ohlc = ohlcList.first else {
            assertionFailure("Expected candles, got \(result)")
            return
        }
        assert(ohlc.open == 62000.0, "Expected open 62000.0, got \(ohlc.open)")
        assert(ohlc.high == 62500.0, "Expected high 62500.0, got \(ohlc.high)")
        assert(ohlc.low == 61800.0, "Expected low 61800.0, got \(ohlc.low)")
        assert(ohlc.close == 62300.0, "Expected close 62300.0, got \(ohlc.close)")
        assert(ohlc.volume == 100.5, "Expected volume 100.5, got \(ohlc.volume)")
        assert(ohlc.confirmed == true, "Expected confirmed to be true")
    }

    static func testParsesOrderBookMessage() throws {
        let json = """
        {"arg":{"channel":"books5","instId":"BTC-USDT"},"data":[{"asks":[["62300","1.5","0","3"],["62310","2.0","0","5"]],"bids":[["62290","0.8","0","2"],["62280","1.2","0","4"]],"ts":"1720000000000"}]}
        """
        let result = try OKXMessageParser.parse(json)
        guard case .orderBook(let book) = result else {
            assertionFailure("Expected orderBook, got \(result)")
            return
        }
        assert(book.asks.count == 2, "Expected 2 asks, got \(book.asks.count)")
        assert(book.bids.count == 2, "Expected 2 bids, got \(book.bids.count)")
        assert(book.asks[0].price == 62300.0, "Expected first ask price 62300.0, got \(book.asks[0].price)")
        assert(book.bids[0].price == 62290.0, "Expected first bid price 62290.0, got \(book.bids[0].price)")
    }

    static func testHandlesPingMessage() throws {
        let result = try OKXMessageParser.parse("ping")
        guard case .ping = result else {
            assertionFailure("Expected ping, got \(result)")
            return
        }
    }

    static func testThrowsOnMalformedJSON() {
        do {
            _ = try OKXMessageParser.parse("{{invalid")
            assertionFailure("Expected OKXParseError to be thrown")
        } catch let error as OKXParseError {
            // Expected - verify it's the right error type
            switch error {
            case .invalidJSON:
                break // correct
            default:
                assertionFailure("Expected .invalidJSON, got \(error)")
            }
        } catch {
            assertionFailure("Expected OKXParseError, got \(type(of: error))")
        }
    }
}
