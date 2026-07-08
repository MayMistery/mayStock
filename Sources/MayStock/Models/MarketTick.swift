import Foundation

struct MarketTick: Identifiable, Equatable, Sendable {
    let id = UUID()
    let timestamp: Date
    let price: Double
    let volume: Double
}
