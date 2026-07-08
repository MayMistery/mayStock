import Foundation
import Observation

@Observable
@MainActor
final class MarketDataProvider {
    private let webSocket = OKXWebSocketService()

    private(set) var currentPrice: Double = 0.0
    private(set) var priceChange24h: Double = 0.0
    private(set) var candles: [OHLC] = []
    private(set) var orderBook: OrderBook = OrderBook(bids: [], asks: [], timestamp: Date())
    private(set) var ticks: [MarketTick] = []
    private(set) var isConnected: Bool = false

    private let maxCandles = 500
    private let maxTicks = 300

    init() {
        webSocket.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }
    }

    func start(instId: String, candleChannel: String) {
        webSocket.connect()
        webSocket.subscribe(channel: "tickers", instId: instId)
        webSocket.subscribe(channel: candleChannel, instId: instId)
        webSocket.subscribe(channel: "books5", instId: instId)
        isConnected = true
    }

    func stop() {
        webSocket.disconnect()
        isConnected = false
    }

    func switchTimeSpan(instId: String, newChannel: String, oldChannel: String) {
        webSocket.unsubscribe(channel: oldChannel, instId: instId)
        webSocket.subscribe(channel: newChannel, instId: instId)
        candles = []
    }

    private func handleMessage(_ message: OKXMessage) {
        switch message {
        case .ticker(let tick):
            currentPrice = tick.price
            ticks.append(tick)
            if ticks.count > maxTicks { ticks.removeFirst() }
        case .candle(let ohlc):
            if let lastIndex = candles.indices.last,
               !candles[lastIndex].confirmed,
               candles[lastIndex].timestamp == ohlc.timestamp {
                candles[lastIndex] = ohlc
            } else {
                candles.append(ohlc)
                if candles.count > maxCandles { candles.removeFirst() }
            }
        case .orderBook(let book):
            orderBook = book
        case .subscribed:
            break
        case .error(let msg):
            print("OKX error: \(msg)")
        case .ping:
            break
        }
    }

    var formattedPrice: String {
        if currentPrice >= 10000 {
            return String(format: "%.0f", currentPrice)
        } else if currentPrice >= 100 {
            return String(format: "%.2f", currentPrice)
        }
        return String(format: "%.4f", currentPrice)
    }

    var priceChangePercent: String {
        guard priceChange24h != 0 else { return "" }
        let sign = priceChange24h > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", priceChange24h))%"
    }
}
