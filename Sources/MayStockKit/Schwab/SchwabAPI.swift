import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Schwab's Trader API, as URLs.
///
/// Three hosts' worth of paths — OAuth, `/trader/v1` for the account and
/// `/marketdata/v1` for prices — written once here so that `schwabctl` (which
/// holds the credentials) and the app (which holds a thirty-minute access
/// token) build exactly the same requests. Nothing in this file sends
/// anything; `SchwabRESTClient` does, with whatever token its source hands it.
public enum SchwabAPI {
    public static let oauthBase = URL(string: "https://api.schwabapi.com/v1/oauth")!
    public static let traderBase = URL(string: "https://api.schwabapi.com/trader/v1")!
    public static let marketDataBase = URL(string: "https://api.schwabapi.com/marketdata/v1")!

    /// The subscription's order limit and the request budget per minute, as
    /// the developer portal states them for an individual app.
    public static let requestsPerMinute = 120

    /// The loopback callback registered on the app. Schwab insists on
    /// `https`, refuses `localhost` by name, and allows the loopback address
    /// — so this is what `schwabctl login` listens on.
    public static let defaultCallback = "https://127.0.0.1:8182"

    /// Every family the venue's positions endpoint can report that this app
    /// treats as a stock. Anything else — an option, a bond, a mutual fund —
    /// is reported back as untracked rather than folded into a share count.
    public static let equityAssetTypes: Set<String> = ["EQUITY", "ETF", "COLLECTIVE_INVESTMENT"]

    // MARK: Market data

    public static func quotes(symbols: [String]) -> URL {
        var components = URLComponents(url: marketDataBase.appendingPathComponent("quotes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "symbols", value: symbols.joined(separator: ",")),
            URLQueryItem(name: "fields", value: "quote,reference,regular,extended"),
            URLQueryItem(name: "indicative", value: "false"),
        ]
        return components.url!
    }

    /// The `frequencyType` / `frequency` pair Schwab serves for a bar. There
    /// is no hourly frequency: an hour is two half-hour bars, aggregated by
    /// `SchwabWire.aggregateHourly`. Nil for a bar the venue does not serve.
    public static func frequency(for bar: BarInterval) -> (type: String, value: Int)? {
        switch bar {
        case .m1: return ("minute", 1)
        case .m5: return ("minute", 5)
        case .m15: return ("minute", 15)
        case .h1: return ("minute", 30)
        case .h4: return nil
        case .d1: return ("daily", 1)
        case .w1: return ("weekly", 1)
        }
    }

    public static func priceHistory(
        symbol: String, bar: BarInterval, start: Date, end: Date,
        extendedHours: Bool = false, previousClose: Bool = true
    ) -> URL? {
        guard let frequency = frequency(for: bar) else { return nil }
        var components = URLComponents(url: marketDataBase.appendingPathComponent("pricehistory"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "periodType", value: frequency.type == "minute" ? "day" : "year"),
            URLQueryItem(name: "frequencyType", value: frequency.type),
            URLQueryItem(name: "frequency", value: String(frequency.value)),
            URLQueryItem(name: "startDate", value: String(millis(start))),
            URLQueryItem(name: "endDate", value: String(millis(end))),
            URLQueryItem(name: "needExtendedHoursData", value: extendedHours ? "true" : "false"),
            URLQueryItem(name: "needPreviousClose", value: previousClose ? "true" : "false"),
        ]
        return components.url!
    }

    /// Session hours for the equity market on a New York calendar day
    /// (`yyyy-MM-dd`); today when nil.
    public static func marketHours(date: String?) -> URL {
        var components = URLComponents(url: marketDataBase.appendingPathComponent("markets"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "markets", value: "equity")]
        if let date { items.append(URLQueryItem(name: "date", value: date)) }
        components.queryItems = items
        return components.url!
    }

    public enum InstrumentProjection: String, Sendable {
        case symbolSearch = "symbol-search"
        case symbolRegex = "symbol-regex"
        case descriptionSearch = "desc-search"
        case fundamental = "fundamental"
    }

    public static func instruments(_ query: String, projection: InstrumentProjection) -> URL {
        var components = URLComponents(url: marketDataBase.appendingPathComponent("instruments"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: query),
            URLQueryItem(name: "projection", value: projection.rawValue),
        ]
        return components.url!
    }

    // MARK: Accounts and orders

    public static var accountNumbers: URL {
        traderBase.appendingPathComponent("accounts/accountNumbers")
    }

    /// Every account with its positions; the hash is what every other
    /// account endpoint is keyed by.
    public static func account(hash: String) -> URL {
        var components = URLComponents(url: traderBase.appendingPathComponent("accounts/\(hash)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fields", value: "positions")]
        return components.url!
    }

    public static func orders(hash: String, from: Date, to: Date, status: String? = nil) -> URL {
        var components = URLComponents(url: traderBase.appendingPathComponent("accounts/\(hash)/orders"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "fromEnteredTime", value: stamp(from)),
            URLQueryItem(name: "toEnteredTime", value: stamp(to)),
            URLQueryItem(name: "maxResults", value: "500"),
        ]
        if let status { items.append(URLQueryItem(name: "status", value: status)) }
        components.queryItems = items
        return components.url!
    }

    public static func order(hash: String, id: String) -> URL {
        traderBase.appendingPathComponent("accounts/\(hash)/orders/\(id)")
    }

    public static func placeOrder(hash: String) -> URL {
        traderBase.appendingPathComponent("accounts/\(hash)/orders")
    }

    /// Trades settled on the account, oldest first as Schwab lists them.
    public static func transactions(hash: String, from: Date, to: Date, symbol: String? = nil) -> URL {
        var components = URLComponents(url: traderBase.appendingPathComponent("accounts/\(hash)/transactions"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "startDate", value: stamp(from)),
            URLQueryItem(name: "endDate", value: stamp(to)),
            URLQueryItem(name: "types", value: "TRADE"),
        ]
        if let symbol { items.append(URLQueryItem(name: "symbol", value: symbol)) }
        components.queryItems = items
        return components.url!
    }

    // MARK: Formatting

    /// Schwab's timestamp for query parameters: ISO-8601 with milliseconds,
    /// in UTC, e.g. `2026-09-15T13:30:00.000Z`.
    public static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    private static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The New York calendar day a timestamp falls on, as the markets
    /// endpoint spells it.
    public static func newYorkDay(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Venue.schwab.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// What a Schwab call can fail with, whichever process made it.
public enum SchwabAPIError: Error, CustomStringConvertible, Sendable, Equatable {
    /// No usable access token: `schwabctl login` has never run, or its
    /// refresh token has expired. Carries the reason the token source gave.
    case loggedOut(String)
    /// The token was refused. Distinct from `loggedOut` so a caller can
    /// refresh once and retry before giving up.
    case unauthorised
    case rateLimited
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)
    /// A request this venue cannot serve — a bar it has no frequency for.
    case unsupported(String)

    public var description: String {
        switch self {
        case .loggedOut(let reason): return "嘉信未登录：\(reason)"
        case .unauthorised: return "嘉信拒绝了 access token（401）"
        case .rateLimited: return "嘉信限频（429）：超过每分钟 \(SchwabAPI.requestsPerMinute) 次"
        case .http(let status, let body): return "嘉信 HTTP \(status)：\(Self.message(in: body))"
        case .transport(let detail): return "嘉信网络错误：\(detail)"
        case .decoding(let detail): return "嘉信返回无法解析：\(detail)"
        case .unsupported(let what): return "嘉信不提供\(what)"
        }
    }

    /// The `message` Schwab's error envelope carries, when it carries one.
    static func message(in body: String) -> String {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["message"] as? String { return message }
            if let errors = object["errors"] as? [[String: Any]],
               let first = errors.first {
                let parts = [first["title"] as? String, first["detail"] as? String].compactMap { $0 }
                if !parts.isEmpty { return parts.joined(separator: "：") }
            }
            if let error = object["error"] as? String {
                let detail = object["error_description"] as? String
                return [error, detail].compactMap { $0 }.joined(separator: "：")
            }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "无正文" : String(trimmed.prefix(300))
    }
}

/// The one HTTP call every Schwab request goes through.
///
/// Status handling is the whole job: a 401 is reported as such so the caller
/// can refresh and retry exactly once, a 429 names the budget, and anything
/// else carries Schwab's own message rather than a bare code.
public struct SchwabHTTP: Sendable {
    public var session: URLSession
    public var timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 20) {
        self.session = session
        self.timeout = timeout
    }

    /// Send with a bearer token and return the body plus the response.
    public func send(
        _ method: String, _ url: URL, token: String, body: Data? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SchwabAPIError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw SchwabAPIError.transport("非 HTTP 响应")
        }
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            throw SchwabAPIError.unauthorised
        case 429:
            throw SchwabAPIError.rateLimited
        default:
            throw SchwabAPIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Send without a bearer token — the OAuth token endpoint, which
    /// authenticates with the app key and secret instead.
    public func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SchwabAPIError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw SchwabAPIError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SchwabAPIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }
}
