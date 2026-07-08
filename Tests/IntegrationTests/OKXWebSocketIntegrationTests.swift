import Foundation
@testable import MayStock

/// Integration tests for OKX WebSocket connection.
/// These tests require network access and connect to the real OKX WebSocket API.
/// Run with: swift test (requires Xcode) or invoke directly in a test harness.
@MainActor
enum OKXWebSocketIntegrationTests {
    static func runAll() async throws {
        try await testConnectsAndReceivesTickerData()
        try await testReceivesCandleData()
        try await testReceivesOrderBookData()
    }

    static func testConnectsAndReceivesTickerData() async throws {
        let service = OKXWebSocketService()
        var receivedTicker = false

        service.onMessage = { message in
            if case .ticker = message {
                receivedTicker = true
            }
        }

        service.connect()
        service.subscribe(channel: "tickers", instId: "BTC-USDT")

        for _ in 0..<100 {
            if receivedTicker { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        assert(receivedTicker, "Should receive at least one ticker within 10 seconds")
        service.disconnect()
    }

    static func testReceivesCandleData() async throws {
        let service = OKXWebSocketService()
        var receivedCandle = false

        service.onMessage = { message in
            if case .candle = message {
                receivedCandle = true
            }
        }

        service.connect()
        service.subscribe(channel: "candle1s", instId: "BTC-USDT")

        for _ in 0..<50 {
            if receivedCandle { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        assert(receivedCandle, "Should receive candle data within 10 seconds")
        service.disconnect()
    }

    static func testReceivesOrderBookData() async throws {
        let service = OKXWebSocketService()
        var receivedBook = false

        service.onMessage = { message in
            if case .orderBook = message {
                receivedBook = true
            }
        }

        service.connect()
        service.subscribe(channel: "books5", instId: "BTC-USDT")

        for _ in 0..<50 {
            if receivedBook { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        assert(receivedBook, "Should receive order book within 10 seconds")
        service.disconnect()
    }
}
