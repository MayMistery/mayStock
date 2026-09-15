import Foundation
import Testing
@testable import MayStockKit

/// The demo/live split: each environment has its own CLI profile, the bridge
/// sends the right one, the config file migrates, and the CLI's profile
/// catalogue is read without ever touching key material.
@Suite("Trading environments")
struct TradingEnvironmentTests {

    // MARK: Profile per mode

    /// Walks the mode enum rather than naming demo and live: a third
    /// environment added tomorrow is covered the day it is declared.
    @Test func bridgeSendsTheProfileOfTheModeItIsCalledWith() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("okx")
        let argsFile = dir.appendingPathComponent("args.txt")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argsFile.path)"
        echo '{"code":"0","data":[{"details":[{"ccy":"USDT","availBal":"1","cashBal":"1"}]}]}'
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        var prefs = TradingPrefs()
        for mode in TradingMode.allCases {
            prefs.setProfile("profile-for-\(mode.rawValue)", for: mode)
        }
        let bridge = TradeBridge(prefs: prefs)
        // Only the CLI path differs from what the app would build.
        let underTest = TradeBridge(
            explicitCLIPath: cli.path, demoProfile: bridge.demoProfile, liveProfile: bridge.liveProfile)

        for mode in TradingMode.allCases {
            _ = try await underTest.balances(mode: mode)
            let args = (try String(contentsOf: argsFile, encoding: .utf8))
                .split(separator: "\n").map(String.init)
            let flag = mode == .demo ? "--demo" : "--live"
            #expect(args.contains(flag), "\(mode) must carry \(flag)")
            #expect(args.contains("--profile"))
            #expect(args.contains("profile-for-\(mode.rawValue)"),
                    "\(mode) must run under its own profile, got \(args)")
            for other in TradingMode.allCases where other != mode {
                #expect(!args.contains("profile-for-\(other.rawValue)"),
                        "\(mode) must never borrow \(other)'s profile")
            }
        }
    }

    @Test func noProfileMeansNoProfileFlag() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("okx")
        let argsFile = dir.appendingPathComponent("args.txt")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argsFile.path)"
        echo '{"code":"0","data":[]}'
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        _ = try await TradeBridge(explicitCLIPath: cli.path).balances(mode: .demo)
        let args = (try String(contentsOf: argsFile, encoding: .utf8))
            .split(separator: "\n").map(String.init)
        #expect(!args.contains("--profile"))
    }

    @Test func setProfileNormalisesBlankToNil() {
        var prefs = TradingPrefs()
        prefs.setProfile("  ", for: .live)
        #expect(prefs.liveProfile == nil)
        prefs.setProfile(" main ", for: .live)
        #expect(prefs.profile(for: .live) == "main")
        #expect(prefs.profile(for: .demo) == nil)
    }

    // MARK: Config migration

    @Test func legacySingleProfileFillsBothEnvironments() throws {
        let json = #"{"enabled":true,"liveTradingUnlocked":false,"profile":"mayStock"}"#
        let prefs = try JSONDecoder().decode(TradingPrefs.self, from: Data(json.utf8))
        for mode in TradingMode.allCases {
            #expect(prefs.profile(for: mode) == "mayStock",
                    "a pre-split file must keep doing what it did for \(mode)")
        }
    }

    @Test func explicitProfilesWinOverLegacy() throws {
        let json = #"{"profile":"old","demoProfile":"paper","liveProfile":"real"}"#
        let prefs = try JSONDecoder().decode(TradingPrefs.self, from: Data(json.utf8))
        #expect(prefs.demoProfile == "paper")
        #expect(prefs.liveProfile == "real")
    }

    @Test func roundTripDropsTheLegacyKey() throws {
        let prefs = TradingPrefs(demoProfile: "paper", liveProfile: nil)
        let data = try JSONEncoder().encode(prefs)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"profile\""), "the old key must not be written back")
        let decoded = try JSONDecoder().decode(TradingPrefs.self, from: data)
        #expect(decoded == prefs)
    }

    // MARK: Profile catalogue

    static let sampleTOML = """
    # OKX Trade Kit Configuration
    default_profile = "paper"

    [profiles.paper]
    api_key = "AAAA-SECRET-AAAA"
    secret_key = 'BBBB-SECRET-BBBB'
    passphrase = '''pass#word'''
    demo = true

    [profiles."real account"]
    api_key = "CCCC-SECRET-CCCC"   # trailing comment
    secret_key = "DDDD"
    passphrase = "x#y"
    demo = false

    [profiles.unflagged]
    api_key = "EEEE"
    """

    @Test func catalogueReadsNamesFlagsAndDefault() {
        let catalog = OKXProfileCatalog.parse(Self.sampleTOML)
        #expect(catalog.defaultProfile == "paper")
        #expect(catalog.profiles.map(\.name) == ["paper", "real account", "unflagged"])
        #expect(catalog.profile(named: "paper")?.isDemo == true)
        #expect(catalog.profile(named: "real account")?.isDemo == false)
        #expect(catalog.profile(named: "unflagged")?.isDemo == nil)
        #expect(catalog.resolved(nil)?.name == "paper", "nil resolves to the CLI default")
        #expect(catalog.resolved("real account")?.isDemo == false)
    }

    @Test func catalogueNeverCapturesKeyMaterial() throws {
        let catalog = OKXProfileCatalog.parse(Self.sampleTOML)
        // Whatever the type holds, none of it may be a secret from the file.
        let dump = String(describing: catalog)
        for secret in ["AAAA-SECRET-AAAA", "BBBB-SECRET-BBBB", "pass#word", "CCCC", "DDDD", "x#y", "EEEE"] {
            #expect(!dump.contains(secret), "\(secret) leaked into the catalogue")
        }
    }

    @Test func missingFileIsReportedAsMissing() {
        let catalog = OKXProfileCatalog.load(
            from: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/config.toml"))
        #expect(!catalog.fileExists)
        #expect(catalog.profiles.isEmpty)
    }

    @Test func hashInsideQuotesIsNotAComment() {
        #expect(OKXProfileCatalog.stripComment(#"passphrase = "a#b" # real comment"#)
                == #"passphrase = "a#b" "#)
    }

    /// The catalogue is a snapshot of the file; it must know when the file
    /// has moved on, or a profile added while the app is open stays invisible
    /// until a restart.
    @Test func catalogueKnowsWhenTheFileChanged() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-okx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")

        let missing = OKXProfileCatalog.load(from: url)
        #expect(!missing.fileExists)
        #expect(!missing.isStale(against: url), "no file then, no file now")

        try Self.sampleTOML.write(to: url, atomically: true, encoding: .utf8)
        #expect(missing.isStale(against: url), "a file appeared")

        let loaded = OKXProfileCatalog.load(from: url)
        #expect(loaded.fileExists)
        #expect(!loaded.isStale(against: url))

        // Rewrite with a later timestamp: a same-second rewrite must still count.
        try (Self.sampleTOML + "\n[profiles.added]\ndemo = false\n")
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(loaded.isStale(against: url), "the file was rewritten")
        #expect(OKXProfileCatalog.load(from: url).profile(named: "added")?.isDemo == false)

        try FileManager.default.removeItem(at: url)
        #expect(loaded.isStale(against: url), "the file is gone")
    }

    // MARK: Connection diagnostics

    @Test func environmentMismatchGetsAnActionableHint() {
        let error = TradeError.cliFailed(
            exitCode: 1, stderr: "Error: HTTP 401 from OKX: APIKey does not match current environment.")
        #expect(error.hint?.contains("另一个环境") == true)
        #expect(error.exchangeRejection == nil, "an auth failure is not an order rejection")
    }

    @Test func codedFailuresGetHints() {
        #expect(TradeError.hint(forCLIOutput: #"{"code":"50111","msg":"Invalid OK-ACCESS-KEY"}"#)?
            .contains("API Key 无效") == true)
        #expect(TradeError.hint(forCLIOutput: #"{"code":"50113","msg":"Invalid Sign"}"#)?
            .contains("签名") == true)
        #expect(TradeError.hint(forCLIOutput: "okx CLI 超过 15 秒未返回，已终止")?
            .contains("网络") == true)
        #expect(TradeError.hint(forCLIOutput: "something else entirely") == nil)
    }

    @Test func parsesAccountConfig() {
        let json = """
        {"code":"0","data":[{"acctLv":"3","posMode":"long_short_mode","perm":"read_only,trade",
          "label":"mayStock","uid":"1234567890"}]}
        """
        let info = TradeBridge.parseAccountConfig(json: json)
        #expect(info?.accountLevel == "3")
        #expect(info?.positionMode == "long_short_mode")
        #expect(info?.canTrade == true)
        #expect(info?.supportsPerpetuals == true)
        #expect(info?.label == "mayStock")
        #expect(TradeBridge.parseAccountConfig(json: #"{"code":"0","data":[]}"#) == nil)
    }

    @Test func simpleAccountLevelCannotTradePerpetuals() {
        let info = AccountConfigInfo(
            accountLevel: "1", positionMode: "net_mode", permissions: "read_only",
            label: nil, uid: nil)
        #expect(!info.supportsPerpetuals)
        #expect(!info.canTrade)
    }
}

extension TradingEnvironmentTests {
    @Test func cliVersionIsTheVersionLineWhateverSurroundsIt() {
        let banner = """

        Update available for @okx_ai/okx-trade-cli: 1.4.1 -> 1.4.5
        Run: npm install -g @okx_ai/okx-trade-cli

        1.4.1 (41c012ba)
        Pilot: installed (darwin-arm64)
        """
        #expect(TradeBridge.parseVersion(banner) == "1.4.1 (41c012ba)")
        #expect(TradeBridge.parseVersion("1.2.0\n") == "1.2.0")
        #expect(TradeBridge.parseVersion("") == "unknown")
        // Nothing version-shaped: the last line is still better than nothing.
        #expect(TradeBridge.parseVersion("okx\nsomething odd") == "something odd")
    }
}
