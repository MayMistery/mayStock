import Foundation

enum OrderSide: String, Codable, Sendable {
    case bid
    case ask
}

struct OrderBookEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let price: Double
    let size: Double
    let side: OrderSide
}

struct OrderBook: Equatable, Sendable {
    var bids: [OrderBookEntry]
    var asks: [OrderBookEntry]
    let timestamp: Date
}
