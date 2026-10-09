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
    /// The server answered with a status other than 200.
    case http(status: Int)
    case api(code: String, message: String)
    case decoding(String)

    public var description: String {
        switch self {
        case .transport(let m): return "transport: \(m)"
        case .http(let status): return "HTTP \(status)"
        case .api(let code, let message): return "OKX api error \(code): \(message)"
        case .decoding(let m): return "decoding: \(m)"
        }
    }

    /// Worth asking again a moment later: a rate limit (HTTP 429, OKX 50011),
    /// a server that is busy or erring (5xx, 50001, 50013, 50026), a request
    /// that never got an answer. A refusal of the request itself, or an
    /// answer that does not decode, will be the same next time.
    public var isTransient: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return status == 429 || (500...599).contains(status)
        case .api(let code, _): return ["50011", "50001", "50013", "50026"].contains(code)
        case .decoding: return false
        }
    }
}

/// Spacing for the public market reads a long download is made of, one
/// schedule per endpoint for the whole process.
///
/// OKX limits each endpoint per IP — candles 40, history-candles 20,
/// funding-rate-history 10 requests per 2 seconds — and every download used
/// to pace only itself, 120 ms between its own pages. "Run all backtests"
/// starts one download per strategy at once, and three of them together are
/// already over the history limit: the 429 that followed failed the whole
/// backtest. Each slot here sits a little inside the limit, since the app's
/// other reads share the IP.
actor OKXPublicPacer {
    static let shared = OKXPublicPacer()

    private var nextSlot: [String: ContinuousClock.Instant] = [:]

    static func spacing(for path: String) -> Duration {
        switch path {
        case "api/v5/market/candles": return .milliseconds(60)
        case "api/v5/market/history-candles": return .milliseconds(110)
        case "api/v5/public/funding-rate-history": return .milliseconds(220)
        default: return .milliseconds(120)
        }
    }

    /// Wait for this endpoint's next free slot.
    func reserve(_ path: String) async {
        let clock = ContinuousClock()
        let slot = max(clock.now, nextSlot[path] ?? clock.now)
        nextSlot[path] = slot + Self.spacing(for: path)
        try? await clock.sleep(until: slot)
    }
}
