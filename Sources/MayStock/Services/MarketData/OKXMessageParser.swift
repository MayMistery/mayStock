import Foundation

enum OKXParseError: Error {
    case invalidJSON
    case unknownMessage
    case missingField(String)
}

enum OKXMessage: Sendable {
    case ticker(MarketTick)
    case candles([OHLC])
    case orderBook(OrderBook)
    case ping
    case subscribed
    case error(String)
}

struct OKXMessageParser {
    static func parse(_ text: String) throws -> OKXMessage {
        if text == "ping" { return .ping }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OKXParseError.invalidJSON
        }

        if let event = json["event"] as? String {
            if event == "subscribe" { return .subscribed }
            if event == "error" {
                let msg = json["msg"] as? String ?? "unknown"
                return .error(msg)
            }
        }

        guard let arg = json["arg"] as? [String: Any],
              let channel = arg["channel"] as? String,
              let dataArray = json["data"] as? [Any] else {
            throw OKXParseError.unknownMessage
        }

        if channel == "tickers" {
            return try parseTicker(dataArray)
        } else if channel.hasPrefix("candle") {
            return try parseCandle(dataArray)
        } else if channel.hasPrefix("books") {
            return try parseOrderBook(dataArray)
        }

        throw OKXParseError.unknownMessage
    }

    private static func parseTicker(_ dataArray: [Any]) throws -> OKXMessage {
        guard let first = dataArray.first as? [String: Any],
              let lastStr = first["last"] as? String,
              let last = Double(lastStr),
              let tsStr = first["ts"] as? String,
              let tsMs = Double(tsStr) else {
            throw OKXParseError.missingField("last or ts")
        }
        let vol = (first["vol24h"] as? String).flatMap(Double.init) ?? 0
        let tick = MarketTick(
            timestamp: Date(timeIntervalSince1970: tsMs / 1000.0),
            price: last,
            volume: vol
        )
        return .ticker(tick)
    }

    private static func parseCandle(_ dataArray: [Any]) throws -> OKXMessage {
        var ohlcList: [OHLC] = []
        for item in dataArray {
            guard let arr = item as? [Any],
                  arr.count >= 9,
                  let tsStr = arr[0] as? String, let tsMs = Double(tsStr),
                  let openStr = arr[1] as? String, let open = Double(openStr),
                  let highStr = arr[2] as? String, let high = Double(highStr),
                  let lowStr = arr[3] as? String, let low = Double(lowStr),
                  let closeStr = arr[4] as? String, let close = Double(closeStr),
                  let volStr = arr[5] as? String, let vol = Double(volStr),
                  let confirmStr = arr[8] as? String else { continue }
            ohlcList.append(OHLC(
                timestamp: Date(timeIntervalSince1970: tsMs / 1000.0),
                open: open, high: high, low: low, close: close,
                volume: vol,
                confirmed: confirmStr == "1"
            ))
        }
        guard !ohlcList.isEmpty else { throw OKXParseError.missingField("candle fields") }
        return .candles(ohlcList)
    }

    private static func parseOrderBook(_ dataArray: [Any]) throws -> OKXMessage {
        guard let first = dataArray.first as? [String: Any],
              let asksRaw = first["asks"] as? [[Any]],
              let bidsRaw = first["bids"] as? [[Any]],
              let tsStr = first["ts"] as? String,
              let tsMs = Double(tsStr) else {
            throw OKXParseError.missingField("asks/bids/ts")
        }

        let asks = asksRaw.compactMap { entry -> OrderBookEntry? in
            guard entry.count >= 2,
                  let priceStr = entry[0] as? String, let price = Double(priceStr),
                  let sizeStr = entry[1] as? String, let size = Double(sizeStr) else { return nil }
            return OrderBookEntry(price: price, size: size, side: .ask)
        }
        let bids = bidsRaw.compactMap { entry -> OrderBookEntry? in
            guard entry.count >= 2,
                  let priceStr = entry[0] as? String, let price = Double(priceStr),
                  let sizeStr = entry[1] as? String, let size = Double(sizeStr) else { return nil }
            return OrderBookEntry(price: price, size: size, side: .bid)
        }

        let book = OrderBook(
            bids: bids, asks: asks,
            timestamp: Date(timeIntervalSince1970: tsMs / 1000.0)
        )
        return .orderBook(book)
    }
}
