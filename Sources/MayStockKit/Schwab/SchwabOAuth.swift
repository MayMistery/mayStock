import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The authorisation-code flow, as pure functions.
///
/// `schwabctl` is the only process that runs it — it holds the app secret —
/// but the URL building, callback parsing and token decoding live here so
/// they can be tested without a keychain or a browser. Nothing in this file
/// stores anything.
public enum SchwabOAuth {
    /// Where the browser is sent. `state` is a nonce the callback must echo:
    /// a redirect that arrives without the nonce this login minted was not
    /// caused by this login, whatever else it carries.
    public static func authorizeURL(appKey: String, callback: String, state: String) -> URL {
        var components = URLComponents(url: SchwabAPI.oauthBase.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "scope", value: "readonly"),
            URLQueryItem(name: "redirect_uri", value: callback),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// 32 random bytes, URL-safe.
    public static func makeState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// What the browser brought back.
    public struct Callback: Sendable, Equatable {
        public let code: String
        public let state: String?

        public init(code: String, state: String?) {
            self.code = code
            self.state = state
        }
    }

    /// Read the code out of the redirect — the whole URL as pasted from the
    /// address bar, the request target the loopback listener saw, or a bare
    /// query string. Percent-decoding is the parser's: Schwab's codes end in
    /// `@`, which arrives as `%40`, and a code sent back still encoded is
    /// refused by the token endpoint.
    public static func parseCallback(_ text: String) throws -> Callback {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SchwabOAuthError.noCode }
        let candidates = [trimmed, "https://127.0.0.1/" + trimmed, "https://127.0.0.1/?" + trimmed]
        for candidate in candidates {
            guard let components = URLComponents(string: candidate),
                  let items = components.queryItems,
                  let code = items.first(where: { $0.name == "code" })?.value,
                  !code.isEmpty else { continue }
            let state = items.first(where: { $0.name == "state" })?.value
            return Callback(code: code, state: state.flatMap { $0.isEmpty ? nil : $0 })
        }
        throw SchwabOAuthError.noCode
    }

    /// Check the echoed nonce. A missing one is refused unless the caller
    /// explicitly accepts that weaker guarantee — and says so in the log.
    public static func verify(_ callback: Callback, expectedState: String, allowMissingState: Bool) throws {
        guard let state = callback.state else {
            if allowMissingState {
                Log.warn("schwab oauth: 回调没有回传 state，按 --allow-missing-state 放行；本次只靠一次性 code 与本机监听保护")
                return
            }
            throw SchwabOAuthError.missingState
        }
        guard state == expectedState else { throw SchwabOAuthError.stateMismatch }
    }

    // MARK: Token endpoint

    public static func tokenRequest(appKey: String, appSecret: String, code: String, callback: String) -> URLRequest {
        form(appKey: appKey, appSecret: appSecret, fields: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", callback),
        ])
    }

    public static func refreshRequest(appKey: String, appSecret: String, refreshToken: String) -> URLRequest {
        form(appKey: appKey, appSecret: appSecret, fields: [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
    }

    private static func form(appKey: String, appSecret: String, fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: SchwabAPI.oauthBase.appendingPathComponent("token"), timeoutInterval: 20)
        request.httpMethod = "POST"
        let credentials = Data("\(appKey):\(appSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(fields.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }

    /// `application/x-www-form-urlencoded` escaping: everything outside the
    /// unreserved set, `@` and `/` included, which `urlQueryAllowed` leaves
    /// alone and the token endpoint then misreads.
    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Decode a token response. On a refresh the refresh token usually comes
    /// back unchanged and its seven-day clock keeps running from the login,
    /// so `previous` supplies the issue time; a code exchange starts it now.
    public static func decodeTokenResponse(
        _ data: Data, now: Date, previous: SchwabTokenSet?
    ) throws -> SchwabTokenSet {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SchwabAPIError.decoding("token 响应不是 JSON 对象")
        }
        if let error = object["error"] as? String {
            let detail = object["error_description"] as? String
            throw SchwabOAuthError.refused([error, detail].compactMap { $0 }.joined(separator: "："))
        }
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            throw SchwabAPIError.decoding("token 响应没有 access_token")
        }
        let expiresIn = (object["expires_in"] as? Double) ?? 1_800
        let refresh = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? previous?.refreshToken
        guard let refresh else {
            throw SchwabAPIError.decoding("token 响应没有 refresh_token")
        }
        let issuedAt = (previous?.refreshToken == refresh ? previous?.refreshIssuedAt : nil) ?? now
        return SchwabTokenSet(
            accessToken: access,
            accessExpiresAt: now.addingTimeInterval(expiresIn),
            refreshToken: refresh,
            refreshIssuedAt: issuedAt,
            idToken: object["id_token"] as? String)
    }
}

public enum SchwabOAuthError: Error, CustomStringConvertible, Sendable, Equatable {
    case noCode
    case missingState
    case stateMismatch
    case refused(String)

    public var description: String {
        switch self {
        case .noCode: return "回调里没有 code 参数"
        case .missingState: return "回调没有回传 state，无法确认它来自本次登录（可用 --allow-missing-state 重试）"
        case .stateMismatch: return "回调的 state 与本次登录不符，已拒绝"
        case .refused(let reason): return "嘉信拒绝换取 token：\(reason)"
        }
    }
}

/// Both tokens and their clocks. Lives in `schwabctl`'s keychain and nowhere
/// else; the app only ever sees `SchwabAccessToken`.
public struct SchwabTokenSet: Codable, Sendable, Equatable {
    public var accessToken: String
    public var accessExpiresAt: Date
    public var refreshToken: String
    /// When the refresh token was minted by a browser login. Schwab expires
    /// it seven days later regardless of use, and there is no way to extend
    /// it short of logging in again.
    public var refreshIssuedAt: Date
    public var idToken: String?

    public static let refreshLifetime: TimeInterval = 7 * 86_400

    public init(accessToken: String, accessExpiresAt: Date, refreshToken: String, refreshIssuedAt: Date, idToken: String? = nil) {
        self.accessToken = accessToken
        self.accessExpiresAt = accessExpiresAt
        self.refreshToken = refreshToken
        self.refreshIssuedAt = refreshIssuedAt
        self.idToken = idToken
    }

    public var refreshExpiresAt: Date { refreshIssuedAt.addingTimeInterval(Self.refreshLifetime) }

    /// Usable for at least `margin` more seconds.
    public func accessValid(at now: Date, margin: TimeInterval = 120) -> Bool {
        accessExpiresAt.timeIntervalSince(now) > margin
    }

    public func refreshValid(at now: Date) -> Bool {
        now < refreshExpiresAt
    }
}

/// What `schwabctl token --json` hands the app: the short-lived token and
/// when it stops working. The app never sees a refresh token.
public struct SchwabAccessToken: Codable, Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date

    public init(accessToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    public func valid(at now: Date = Date(), margin: TimeInterval = 120) -> Bool {
        expiresAt.timeIntervalSince(now) > margin
    }
}

/// What `schwabctl status --json` reports. No secret appears in it: the app
/// shows this on the account page, and a status line is not a place to leak
/// from.
public struct SchwabCredentialStatus: Codable, Sendable, Equatable {
    /// App key and secret are in the keychain.
    public var configured: Bool
    /// A refresh token exists and has not passed its seven days.
    public var loggedIn: Bool
    public var refreshIssuedAt: Date?
    public var refreshExpiresAt: Date?
    public var accessExpiresAt: Date?
    /// The callback the login listens on.
    public var callback: String
    /// The account orders go to, as its last three digits — enough to tell
    /// two accounts apart, not enough to name one.
    public var accountSuffix: String?
    public var accountCount: Int
    /// The `schwabctl` binary answering, so the app can say which one.
    public var version: String

    public init(
        configured: Bool, loggedIn: Bool, refreshIssuedAt: Date? = nil, refreshExpiresAt: Date? = nil,
        accessExpiresAt: Date? = nil, callback: String = SchwabAPI.defaultCallback,
        accountSuffix: String? = nil, accountCount: Int = 0, version: String
    ) {
        self.configured = configured
        self.loggedIn = loggedIn
        self.refreshIssuedAt = refreshIssuedAt
        self.refreshExpiresAt = refreshExpiresAt
        self.accessExpiresAt = accessExpiresAt
        self.callback = callback
        self.accountSuffix = accountSuffix
        self.accountCount = accountCount
        self.version = version
    }

    /// Why nothing authenticated will work, in words. Nil when it will.
    public var blocker: String? {
        if !configured { return "schwabctl 还没有 App Key/Secret（运行 schwabctl configure）" }
        if !loggedIn {
            if let expired = refreshExpiresAt {
                return "嘉信登录已于 \(Self.stamp(expired)) 过期（refresh token 只有 7 天），运行 schwabctl login"
            }
            return "尚未登录嘉信（运行 schwabctl login）"
        }
        return nil
    }

    /// How long the login has left, for the account page.
    public func remainingLogin(now: Date = Date()) -> TimeInterval? {
        guard loggedIn, let expires = refreshExpiresAt else { return nil }
        return expires.timeIntervalSince(now)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
