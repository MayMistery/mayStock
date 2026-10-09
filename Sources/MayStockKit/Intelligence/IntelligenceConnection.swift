import Foundation

/// The route the intelligence runtime would take, as its `--doctor` reports
/// it: where the route came from, the service origin and the header *names* —
/// never a credential.
public struct IntelligenceRoute: Decodable, Sendable, Equatable {
    /// `connection` (the connection file), `environment` (what launched the
    /// app), `claude_settings` or `native` — first match wins
    /// (docs/INTELLIGENCE.md).
    public let source: String
    public let origin: String?
    public let headerNames: [String]
    public let ignoredEnvironmentKeys: [String]
    public let routingConfigured: Bool

    public var sourceName: String {
        switch source {
        case "connection": return "连接文件"
        case "environment": return "启动 App 的环境"
        case "claude_settings": return "Claude 用户设置"
        case "native": return "Claude 原生登录"
        default: return source
        }
    }
}

/// The protected file the intelligence runtime reads its model route from:
/// one JSON object of variable names to values, mode 0600, outside the
/// repository and the app bundle. The runtime decides where it is and what is
/// valid; the app asks it for both (`IntelligenceBridge.connectionFile`,
/// `doctor(connectionFile:)`), so the settings page and the runtime cannot
/// disagree about which file, or about what it may contain.
public struct IntelligenceConnectionFile: Sendable, Equatable {
    public static let baseURLKey = "ANTHROPIC_BASE_URL"
    public static let customHeadersKey = "ANTHROPIC_CUSTOM_HEADERS"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The two values the settings page edits, as stored; nil where unset.
    public func route() throws -> (baseURL: String?, headers: String?) {
        let object = try contents()
        return (object[Self.baseURLKey] as? String, object[Self.customHeadersKey] as? String)
    }

    /// Set the base URL and the headers — nil leaves one as it is, an empty
    /// string removes it — and return the route the runtime then takes.
    ///
    /// Every other entry stays exactly as stored, whatever its type. The new
    /// file is written beside the old one, read by the runtime's own rules
    /// (`--doctor` against the candidate), and only then put in place in one
    /// rename; a rejected one leaves the old file untouched and says why.
    /// Emptied entirely, the file is removed rather than written as `{}`: an
    /// empty connection file is a route of its own — the native login, with
    /// the environment's and Claude settings' routes set aside — and nobody
    /// clearing two fields means that.
    public func update(baseURL: String?, headers: String?, using bridge: IntelligenceBridge) async throws -> IntelligenceRoute {
        var object = try contents()
        for (key, value) in [(Self.baseURLKey, baseURL), (Self.customHeadersKey, headers)] {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { object.removeValue(forKey: key) } else { object[key] = trimmed }
        }
        let files = FileManager.default
        if object.isEmpty {
            if exists { try files.removeItem(at: url) }
            Log.warn("intelligence: 连接文件的路由已清空，文件已移除")
            return try await bridge.doctor()
        }
        let directory = url.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let candidate = directory.appendingPathComponent(".connection-candidate-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard files.createFile(atPath: candidate.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw IntelligenceBridgeError.failed("无法写入候选连接文件：\(directory.path)")
        }
        defer { try? files.removeItem(at: candidate) }
        let route = try await bridge.doctor(connectionFile: candidate)
        guard rename(candidate.path, url.path) == 0 else {
            throw IntelligenceBridgeError.failed("无法替换连接文件：\(String(cString: strerror(errno)))")
        }
        Log.warn("intelligence: 连接文件已更新，来源 \(route.source)，服务 \(route.origin ?? "—")，header \(route.headerNames.joined(separator: "、"))")
        return route
    }

    /// The stored object, every entry as it is; empty when there is no file.
    private func contents() throws -> [String: Any] {
        guard exists else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntelligenceBridgeError.failed("连接文件不是 JSON 对象：\(url.path)")
        }
        return object
    }

    /// Header lines with every value masked down to its last four characters —
    /// what the page shows in place of the secret it holds.
    public static func maskedHeaders(_ headers: String) -> String {
        headers.split(separator: "\n", omittingEmptySubsequences: true).map { line -> String in
            let text = String(line)
            guard let colon = text.firstIndex(of: ":") else { return "••••" }
            let name = text[..<colon].trimmingCharacters(in: .whitespaces)
            let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return "\(name): ••••" + (value.count > 8 ? String(value.suffix(4)) : "")
        }.joined(separator: "\n")
    }
}
