import Foundation

// MARK: - Typed OKX wire decoding (shared by WS client, REST client and tests)

/// A decoded OKX WebSocket frame.
public enum OKXWSMessage: Sendable, Equatable {
    case pong
    case subscribed(channel: String, instId: String)
    case unsubscribed(channel: String, instId: String)
    case error(code: String, message: String)
    case ticker(Ticker)
    case candles(instId: String, bar: BarInterval, candles: [Candle])
    case book(OrderBook)
    /// Valid JSON we deliberately don't handle (e.g. `channel-conn-count`).
    case ignored
}

public enum OKXWireDecoder {
    // OKX numeric fields arrive as strings; candle rows are string arrays:
    // [ts, o, h, l, c, vol, volCcy, volCcyQuote, confirm]

    struct Arg: Decodable {
        let channel: String
        let instId: String?
    }

    struct EventFrame: Decodable {
        let event: String?
        let code: String?
        let msg: String?
        let arg: Arg?
    }

    struct TickerRow: Decodable {
        let instId: String
        let last: String
        let bidPx: String?
        let askPx: String?
        let open24h: String
        let high24h: String
        let low24h: String
        let vol24h: String
        let ts: String
    }

    struct BookRow: Decodable {
        let asks: [[String]]
        let bids: [[String]]
        let ts: String
    }

    struct DataFrame<Row: Decodable>: Decodable {
        let arg: Arg
        let data: [Row]
    }

    /// Decode one raw WebSocket text frame.
    public static func decode(_ text: String) throws -> OKXWSMessage {
        if text == "pong" { return .pong }
        guard let data = text.data(using: .utf8) else {
            throw OKXError.decoding("non-utf8 frame")
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw OKXError.decoding("invalid JSON frame")
        }
        let decoder = JSONDecoder()

        // Event frames: subscribe/unsubscribe/error/notice.
        if let event = try? decoder.decode(EventFrame.self, from: data), let name = event.event {
            switch name {
            case "subscribe":
                return .subscribed(channel: event.arg?.channel ?? "?", instId: event.arg?.instId ?? "?")
            case "unsubscribe":
                return .unsubscribed(channel: event.arg?.channel ?? "?", instId: event.arg?.instId ?? "?")
            case "error":
                return .error(code: event.code ?? "?", message: event.msg ?? "unknown")
            default:
                return .ignored
            }
        }

        // Data frames: dispatch on channel name.
        guard let probe = try? decoder.decode(EventFrame.self, from: data), let arg = probe.arg else {
            return .ignored
        }

        switch arg.channel {
        case "tickers":
            let frame = try decodeFrame(TickerRow.self, decoder: decoder, data: data)
            guard let row = frame.data.first else { return .ignored }
            return .ticker(try ticker(from: row))

        case let channel where channel.hasPrefix("candle"):
            let barRaw = String(channel.dropFirst("candle".count))
            guard let bar = BarInterval(rawValue: barRaw) else { return .ignored }
            let frame = try decodeFrame([String].self, decoder: decoder, data: data)
            let candles = frame.data.compactMap(candle(fromRow:))
            guard let instId = frame.arg.instId, !candles.isEmpty else { return .ignored }
            return .candles(instId: instId, bar: bar, candles: candles)

        case let channel where channel.hasPrefix("books"):
            let frame = try decodeFrame(BookRow.self, decoder: decoder, data: data)
            guard let row = frame.data.first, let instId = frame.arg.instId else { return .ignored }
            return .book(book(from: row, instId: instId))

        default:
            return .ignored
        }
    }

    private static func decodeFrame<Row: Decodable>(
        _ type: Row.Type, decoder: JSONDecoder, data: Data
    ) throws -> DataFrame<Row> {
        do {
            return try decoder.decode(DataFrame<Row>.self, from: data)
        } catch {
            throw OKXError.decoding(String(describing: error))
        }
    }

    // MARK: Row → model

    static func ticker(from row: TickerRow) throws -> Ticker {
        guard let last = Double(row.last),
              let open = Double(row.open24h),
              let high = Double(row.high24h),
              let low = Double(row.low24h),
              let tsMs = Double(row.ts) else {
            throw OKXError.decoding("ticker numeric fields")
        }
        return Ticker(
            instId: row.instId,
            last: last,
            bid: row.bidPx.flatMap(Double.init),
            ask: row.askPx.flatMap(Double.init),
            open24h: open,
            high24h: high,
            low24h: low,
            vol24h: Double(row.vol24h) ?? 0,
            ts: Date(timeIntervalSince1970: tsMs / 1000)
        )
    }

    /// Candle row: [ts, o, h, l, c, vol, volCcy, volCcyQuote, confirm]
    public static func candle(fromRow row: [String]) -> Candle? {
        guard row.count >= 9,
              let tsMs = Double(row[0]),
              let open = Double(row[1]),
              let high = Double(row[2]),
              let low = Double(row[3]),
              let close = Double(row[4]),
              let vol = Double(row[5]) else { return nil }
        return Candle(
            ts: Date(timeIntervalSince1970: tsMs / 1000),
            open: open, high: high, low: low, close: close,
            volume: vol,
            confirmed: row[8] == "1"
        )
    }

    static func book(from row: BookRow, instId: String) -> OrderBook {
        func levels(_ raw: [[String]]) -> [BookLevel] {
            raw.compactMap { entry in
                guard entry.count >= 2,
                      let price = Double(entry[0]),
                      let size = Double(entry[1]) else { return nil }
                return BookLevel(price: price, size: size)
            }
        }
        let tsMs = Double(row.ts) ?? 0
        return OrderBook(
            instId: instId,
            bids: levels(row.bids),
            asks: levels(row.asks),
            ts: Date(timeIntervalSince1970: tsMs / 1000)
        )
    }
}
