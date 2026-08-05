import Foundation

// MARK: - Watchlist

/// One instrument shown in the menu bar.
public struct WatchItem: Codable, Identifiable, Sendable, Equatable {
    /// How the item renders in the menu bar.
    public enum MenuBarStyle: String, Codable, CaseIterable, Sendable {
        case priceOnly       // 118,234
        case priceAndChange  // 118,234 ↑1.2%
        case sparkline       // 118,234 ▁▂▄▆
        case full            // ₿ 118,234 ↑1.2% ▁▂▄▆

        public var displayName: String {
            switch self {
            case .priceOnly: return "价格"
            case .priceAndChange: return "价格 + 涨跌"
            case .sparkline: return "价格 + 趋势图"
            case .full: return "完整"
            }
        }
    }

    public var id: UUID
    public var instId: String
    /// Custom menu bar label; `nil` derives from instId (BTC-USDT → BTC).
    public var label: String?
    public var enabled: Bool
    public var style: MenuBarStyle
    /// Trailing window of the menu bar sparkline, in minutes.
    public var sparklineMinutes: Int
    /// Price fraction digits; `nil` = auto from exchange tick size.
    public var decimals: Int?
    /// Default candle interval when the hover panel opens.
    public var defaultBar: BarInterval

    public init(
        id: UUID = UUID(),
        instId: String,
        label: String? = nil,
        enabled: Bool = true,
        style: MenuBarStyle = .full,
        sparklineMinutes: Int = 60,
        decimals: Int? = nil,
        defaultBar: BarInterval = .m1
    ) {
        self.id = id
        self.instId = instId
        self.label = label
        self.enabled = enabled
        self.style = style
        self.sparklineMinutes = sparklineMinutes
        self.decimals = decimals
        self.defaultBar = defaultBar
    }

    /// "BTC-USDT" → "BTC", "BTC-USDT-SWAP" → "BTC⚡︎"
    public var displayLabel: String {
        if let label, !label.isEmpty { return label }
        let parts = instId.split(separator: "-")
        let base = parts.first.map(String.init) ?? instId
        return instId.hasSuffix("-SWAP") ? base + "⚡︎" : base
    }

    /// Currency glyph shown before the price in `.full` style.
    public var glyph: String? {
        let base = instId.split(separator: "-").first.map(String.init) ?? ""
        switch base {
        case "BTC": return "₿"
        case "ETH": return "Ξ"
        case "LTC": return "Ł"
        default: return nil
        }
    }
}

// MARK: - Trading / General

public struct TradingPrefs: Codable, Sendable, Equatable {
    /// Show the position & return strip in the hover panel.
    public var enabled: Bool
    /// Explicit path to the official `okx` CLI; `nil` = search PATH & common dirs.
    public var cliPath: String?
    /// Orders go to OKX demo trading unless this is explicitly unlocked.
    public var liveTradingUnlocked: Bool
    /// `okx --profile <name>`; `nil` = CLI default profile.
    public var profile: String?

    public init(
        enabled: Bool = true,
        cliPath: String? = nil,
        liveTradingUnlocked: Bool = false,
        profile: String? = nil
    ) {
        self.enabled = enabled
        self.cliPath = cliPath
        self.liveTradingUnlocked = liveTradingUnlocked
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, cliPath, liveTradingUnlocked, profile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        cliPath = try c.decodeIfPresent(String.self, forKey: .cliPath)
        liveTradingUnlocked = try c.decodeIfPresent(Bool.self, forKey: .liveTradingUnlocked) ?? false
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
    }
}

public struct GeneralPrefs: Codable, Sendable, Equatable {
    public var launchAtLogin: Bool
    /// Delay before the hover panel appears, in milliseconds.
    public var hoverDelayMs: Int
    /// Grace period before the panel hides after the pointer leaves.
    public var hideDelayMs: Int

    public init(launchAtLogin: Bool = false, hoverDelayMs: Int = 150, hideDelayMs: Int = 350) {
        self.launchAtLogin = launchAtLogin
        self.hoverDelayMs = hoverDelayMs
        self.hideDelayMs = hideDelayMs
    }
}

// MARK: - Root config

public struct AppConfig: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var watchlist: [WatchItem]
    public var alerts: [AlertRule]
    public var trading: TradingPrefs
    public var general: GeneralPrefs
    /// Strategy portfolio: mode, capital and per-strategy allocations.
    public var strategy: StrategyPortfolioPrefs

    /// v3 adds `strategy` and drops the manual order ticket's default size.
    /// v2 files still load — every field decodes with a default.
    public static let currentSchemaVersion = 3
    public static let minimumSupportedSchemaVersion = 2

    public init(
        schemaVersion: Int = AppConfig.currentSchemaVersion,
        watchlist: [WatchItem] = [WatchItem(instId: "BTC-USDT")],
        alerts: [AlertRule] = [],
        trading: TradingPrefs = TradingPrefs(),
        general: GeneralPrefs = GeneralPrefs(),
        strategy: StrategyPortfolioPrefs = StrategyPortfolioPrefs()
    ) {
        self.schemaVersion = schemaVersion
        self.watchlist = watchlist
        self.alerts = alerts
        self.trading = trading
        self.general = general
        self.strategy = strategy
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, watchlist, alerts, trading, general, strategy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        watchlist = try c.decodeIfPresent([WatchItem].self, forKey: .watchlist) ?? []
        alerts = try c.decodeIfPresent([AlertRule].self, forKey: .alerts) ?? []
        trading = try c.decodeIfPresent(TradingPrefs.self, forKey: .trading) ?? TradingPrefs()
        general = try c.decodeIfPresent(GeneralPrefs.self, forKey: .general) ?? GeneralPrefs()
        strategy = try c.decodeIfPresent(StrategyPortfolioPrefs.self, forKey: .strategy)
            ?? StrategyPortfolioPrefs()
    }

    public static let `default` = AppConfig()
}

// MARK: - Persistence + v1 migration

/// Loads/saves `AppConfig` as JSON. Migrates MayStock 1.x configs
/// (a bare `[MonitorItem]` array) by keeping crypto items and dropping
/// the removed CPU/MEM/NET monitors.
public struct ConfigIO: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("config.json")
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("MayStock")
    }

    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return .default }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if var config = try? decoder.decode(AppConfig.self, from: data),
           config.schemaVersion >= AppConfig.minimumSupportedSchemaVersion,
           !config.watchlist.isEmpty {
            config.schemaVersion = AppConfig.currentSchemaVersion
            return config
        }
        if let migrated = Self.migrateV1(data: data) { return migrated }
        return .default
    }

    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: fileURL, options: .atomic)
    }

    /// Best-effort v1 migration via loose JSON inspection (the old schema was
    /// an array of enum-encoded `MonitorItem`s).
    static func migrateV1(data: Data) -> AppConfig? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        var items: [WatchItem] = []
        for entry in array where (entry["type"] as? String) == "crypto" {
            var instId = "BTC-USDT"
            if let source = entry["source"] as? [String: Any],
               let okx = source["okx"] as? [String: Any],
               let v = okx["instId"] as? String, !v.isEmpty {
                instId = v
            }
            if !items.contains(where: { $0.instId == instId }) {
                items.append(WatchItem(instId: instId))
            }
        }
        guard !items.isEmpty else { return nil }
        var config = AppConfig.default
        config.watchlist = items
        return config
    }
}
