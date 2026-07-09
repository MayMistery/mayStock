import Foundation

/// OKX v5 endpoints, verified against docs (2026-07).
///
/// Since **2023-06-20** candlestick channels (`candle1m` …) are served from
/// the `/business` WebSocket URL; `tickers` and `books5` remain on `/public`.
public enum OKXEndpoints {
    public static let rest = URL(string: "https://www.okx.com")!
    public static let wsPublic = URL(string: "wss://ws.okx.com:8443/ws/v5/public")!
    public static let wsBusiness = URL(string: "wss://ws.okx.com:8443/ws/v5/business")!

    /// Demo-trading (paper) websocket hosts, kept for reference.
    public static let wsPublicDemo = URL(string: "wss://wspap.okx.com:8443/ws/v5/public")!
}

public enum OKXError: Error, CustomStringConvertible, Sendable {
    case transport(String)
    case api(code: String, message: String)
    case decoding(String)

    public var description: String {
        switch self {
        case .transport(let m): return "transport: \(m)"
        case .api(let code, let message): return "OKX api error \(code): \(message)"
        case .decoding(let m): return "decoding: \(m)"
        }
    }
}
