import Foundation

/// One working order as the kernel lists it — read by the trading client
/// and in the live account document alike, through this one mapping.
struct WorkingOrderRow: Decodable, Sendable, Equatable {
    let id: String
    let book: String
    let instId: String
    let instType: String?
    let ordType: String
    let side: String
    let posSide: String?
    let price: Double?
    let triggerPrice: Double?
    let stopTriggerPrice: Double?
    let takeProfitTriggerPrice: Double?
    let size: Double?
    let closeFraction: Double?
    let filledSize: Double?
    let state: String?
    let reduceOnly: Bool?
    let clientId: String?
    let createdMs: Double?

    var order: ExchangeOpenOrder? {
        guard let side = OrderSide(rawValue: side) else { return nil }
        return ExchangeOpenOrder(
            id: id, book: book == "algo" ? .algo : .order, instId: instId, ordType: ordType, side: side,
            posSide: posSide.flatMap(PositionSide.init(rawValue:)), price: price, triggerPrice: triggerPrice,
            stopTriggerPrice: stopTriggerPrice, takeProfitTriggerPrice: takeProfitTriggerPrice, size: size,
            closeFraction: closeFraction, filledSize: filledSize ?? 0, state: state ?? "",
            reduceOnly: reduceOnly ?? false, clOrdId: clientId,
            createdAt: createdMs.map { Date(timeIntervalSince1970: $0 / 1_000) })
    }
}
