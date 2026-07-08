import Foundation

struct OHLC: Identifiable, Equatable, Sendable {
    let id = UUID()
    let timestamp: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
    let confirmed: Bool

    var isBullish: Bool { close >= open }
}
