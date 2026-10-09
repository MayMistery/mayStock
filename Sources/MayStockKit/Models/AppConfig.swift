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
    /// Where the instrument trades, which decides which feed quotes it, how
    /// its id reads and how its day is framed. Files written before venues
    /// existed only ever meant OKX.
    public var venue: Venue
    public var instId: String
    /// Custom menu bar label; `nil` derives from instId (BTC-USDT → BTC).
    public var label: String?
    public var enabled: Bool
    public var style: MenuBarStyle
    /// Trailing window of the menu bar sparkline, in minutes. On a market
    /// with sessions, a day or more means sessions rather than clock hours —
    /// see `sparkWindow`.
    public var sparklineMinutes: Int
    /// Price fraction digits; `nil` = auto from exchange tick size.
    public var decimals: Int?
    /// Default candle interval when the hover panel opens.
    public var defaultBar: BarInterval

    public init(
        id: UUID = UUID(),
        venue: Venue = .okx,
        instId: String,
        label: String? = nil,
        enabled: Bool = true,
        style: MenuBarStyle = .full,
        sparklineMinutes: Int = 60,
        decimals: Int? = nil,
        defaultBar: BarInterval = .m1
    ) {
        self.id = id
        self.venue = venue
        self.instId = instId
        self.label = label
        self.enabled = enabled
        self.style = style
        self.sparklineMinutes = sparklineMinutes
        self.decimals = decimals
        self.defaultBar = defaultBar
    }

    private enum CodingKeys: String, CodingKey {
        case id, venue, instId, label, enabled, style, sparklineMinutes, decimals, defaultBar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        venue = try c.decodeIfPresent(Venue.self, forKey: .venue) ?? .okx
        instId = try c.decode(String.self, forKey: .instId)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        style = try c.decodeIfPresent(MenuBarStyle.self, forKey: .style) ?? .full
        sparklineMinutes = try c.decodeIfPresent(Int.self, forKey: .sparklineMinutes) ?? 60
        decimals = try c.decodeIfPresent(Int.self, forKey: .decimals)
        defaultBar = try c.decodeIfPresent(BarInterval.self, forKey: .defaultBar) ?? .m1
    }

    /// "BTC-USDT" → "BTC", "BTC-USDT-SWAP" → "BTC⚡︎", "TSLA" → "TSLA"
    public var displayLabel: String {
        if let label, !label.isEmpty { return label }
        return venue.shortLabel(for: instId)
    }

    /// Currency glyph shown before the price in `.full` style. Coins have
    /// one; a share does not.
    public var glyph: String? {
        guard venue == .okx else { return nil }
        switch venue.currencies(of: instId).base {
        case "BTC": return "₿"
        case "ETH": return "Ξ"
        case "LTC": return "Ł"
        default: return nil
        }
    }

    /// The stretch of history the menu bar sparkline draws.
    ///
    /// The minutes are read literally on a market that never closes. On one
    /// with sessions, a day means the session and a week means the last
    /// five sessions: an hour of a closed market is a flat line, and the
    /// figure the menu bar owes is "how did it trade today".
    public var sparkWindow: SparkWindow {
        if venue.tradesContinuously || sparklineMinutes < 1_440 {
            return .trailing(minutes: sparklineMinutes)
        }
        return sparklineMinutes >= 7 * 1_440 ? .days(7) : .session
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
    /// `okx --profile <name>` used for the demo account; `nil` = the CLI's
    /// default profile.
    ///
    /// One profile per environment, not one for both: OKX issues separate API
    /// keys for demo trading and for the live account, and either is refused
    /// by the other environment ("APIKey does not match current environment").
    /// A single profile field could therefore only ever reach one of the two
    /// accounts, which is what made switching a setting that did nothing.
    public var demoProfile: String?
    /// `okx --profile <name>` used for the live account; `nil` = CLI default.
    public var liveProfile: String?
    /// Explicit path to `schwabctl`; `nil` = the copy inside the app bundle,
    /// then the usual bin directories and PATH.
    public var schwabCLIPath: String?

    public init(
        enabled: Bool = true,
        cliPath: String? = nil,
        liveTradingUnlocked: Bool = false,
        demoProfile: String? = nil,
        liveProfile: String? = nil,
        schwabCLIPath: String? = nil
    ) {
        self.enabled = enabled
        self.cliPath = cliPath
        self.liveTradingUnlocked = liveTradingUnlocked
        self.demoProfile = demoProfile
        self.liveProfile = liveProfile
        self.schwabCLIPath = schwabCLIPath
    }

    /// The profile a mode's CLI calls run under. The one place this mapping
    /// lives; everything that shells out asks here.
    public func profile(for mode: TradingMode) -> String? {
        switch mode {
        case .demo: return demoProfile
        case .live: return liveProfile
        }
    }

    public mutating func setProfile(_ name: String?, for mode: TradingMode) {
        let cleaned = name?.trimmingCharacters(in: .whitespaces)
        let value = (cleaned?.isEmpty ?? true) ? nil : cleaned
        switch mode {
        case .demo: demoProfile = value
        case .live: liveProfile = value
        }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, cliPath, liveTradingUnlocked, demoProfile, liveProfile, schwabCLIPath
        /// Pre-2.2 files carried one profile for both environments.
        case legacyProfile = "profile"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        cliPath = try c.decodeIfPresent(String.self, forKey: .cliPath)
        liveTradingUnlocked = try c.decodeIfPresent(Bool.self, forKey: .liveTradingUnlocked) ?? false
        // A file written before the split named one profile for both. Keeping
        // it for both preserves exactly what that file did; the connection
        // check in the UI is what reveals whether the live half ever worked.
        let legacy = try c.decodeIfPresent(String.self, forKey: .legacyProfile)
        demoProfile = try c.decodeIfPresent(String.self, forKey: .demoProfile) ?? legacy
        liveProfile = try c.decodeIfPresent(String.self, forKey: .liveProfile) ?? legacy
        schwabCLIPath = try c.decodeIfPresent(String.self, forKey: .schwabCLIPath)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(cliPath, forKey: .cliPath)
        try c.encode(liveTradingUnlocked, forKey: .liveTradingUnlocked)
        try c.encodeIfPresent(demoProfile, forKey: .demoProfile)
        try c.encodeIfPresent(liveProfile, forKey: .liveProfile)
        try c.encodeIfPresent(schwabCLIPath, forKey: .schwabCLIPath)
    }
}

public struct GeneralPrefs: Codable, Sendable, Equatable {
    public var launchAtLogin: Bool
    /// Delay before the hover panel appears, in milliseconds.
    public var hoverDelayMs: Int
    /// Grace period before the panel hides after the pointer leaves.
    public var hideDelayMs: Int
    /// What a market that never closes measures its change from — one of
    /// `ChangeBasis.continuous` — so the menu bar reads the way the phone
    /// does. UTC+8 midnight unless set (May, 2026-10-08: 「不确定，做成开关」).
    public var changeBasis: ChangeBasis
    /// The IANA zone every displayed time is read in (`DisplayTime`).
    /// Singapore unless set (May, 2026-10-09: 「支持配置时区吧，默认sg」). Kept
    /// as written: one the system does not know is shown in the default and
    /// said so, not rewritten behind May's back.
    public var displayTimeZone: String

    public init(
        launchAtLogin: Bool = false, hoverDelayMs: Int = 150, hideDelayMs: Int = 350,
        changeBasis: ChangeBasis = .sinceUtc8Midnight,
        displayTimeZone: String = DisplayTime.defaultIdentifier
    ) {
        self.launchAtLogin = launchAtLogin
        self.hoverDelayMs = hoverDelayMs
        self.hideDelayMs = hideDelayMs
        self.changeBasis = changeBasis
        self.displayTimeZone = displayTimeZone
    }

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, hoverDelayMs, hideDelayMs, changeBasis, displayTimeZone
    }

    /// Every field has a default: a file written before a field existed must
    /// load — a failed decode here would replace the whole config with the
    /// defaults, watchlist and strategies included.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GeneralPrefs()
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        hoverDelayMs = try c.decodeIfPresent(Int.self, forKey: .hoverDelayMs) ?? defaults.hoverDelayMs
        hideDelayMs = try c.decodeIfPresent(Int.self, forKey: .hideDelayMs) ?? defaults.hideDelayMs
        let basis = (try? c.decodeIfPresent(ChangeBasis.self, forKey: .changeBasis)) ?? nil
        changeBasis = basis.flatMap { ChangeBasis.continuous.contains($0) ? $0 : nil } ?? defaults.changeBasis
        displayTimeZone = (try? c.decodeIfPresent(String.self, forKey: .displayTimeZone)) ?? nil ?? defaults.displayTimeZone
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

    /// v5 gives every watch item a `venue`; items written before it are OKX.
    /// v4 replaces `strategy.feeSchedule` (OKX only) with `strategy.feeSchedules`,
    /// one per venue; a v3 file's schedule is read into the OKX slot.
    /// v3 added `strategy` and dropped the manual order ticket's default size.
    /// v2 files still load — every field decodes with a default.
    public static let currentSchemaVersion = 5
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

// MARK: - Transition rules

extension AppConfig {
    /// Make `self` — the config just after a change — obey what every change
    /// has to, whoever made it: a page in the app, the unattended review, or
    /// a hand edit picked up from disk. Returns what had to be done, in words
    /// for the log; empty when nothing did.
    ///
    /// These used to be written inline in the two pages that crossed the
    /// boundary. The file has other writers, and the running app takes their
    /// changes in as they land, so a rule kept on one door was a rule a hand
    /// edit walked around.
    public mutating func enforceTransitionRules(from previous: AppConfig) -> [String] {
        var enforced: [String] = []
        // Locking live trading must not leave the app on the live account.
        if previous.trading.liveTradingUnlocked, !trading.liveTradingUnlocked, strategy.mode == .live {
            strategy.mode = .demo
            enforced.append("实盘已上锁，交易模式切回模拟盘")
        }
        // Crossing between demo and live disarms every strategy: arming one
        // was a decision about the other account. Positions are left alone —
        // stopping means stop deciding, not liquidate.
        if strategy.mode != previous.strategy.mode {
            let armed = strategy.allocations.indices.filter { strategy.allocations[$0].running }
            for index in armed { strategy.allocations[index].running = false }
            if !armed.isEmpty {
                enforced.append("交易模式 \(previous.strategy.mode.rawValue) → \(strategy.mode.rawValue)，停用 "
                                + armed.map { strategy.allocations[$0].strategyId }.joined(separator: ", "))
            }
        }
        return enforced
    }
}
