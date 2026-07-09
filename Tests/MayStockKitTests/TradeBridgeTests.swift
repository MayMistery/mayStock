import Foundation
import Testing
@testable import MayStockKit

/// TradeBridge tests run against a *fake* `okx` executable written to a temp
/// dir — verifying argument construction, JSON parsing and the live-trading
/// safety interlock without ever touching the network or a real account.
@Suite("Trade bridge")
struct TradeBridgeTests {
    /// Writes a stub `okx` script that echoes its args and emits canned JSON.
    private func makeStubCLI(stdout: String, exitCode: Int = 0) throws -> (bridge: TradeBridge, argsFile: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cli = dir.appendingPathComponent("okx")
        let argsFile = dir.appendingPathComponent("args.txt")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argsFile.path)"
        cat <<'JSON'
        \(stdout)
        JSON
        exit \(exitCode)
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (TradeBridge(explicitCLIPath: cli.path), argsFile, dir)
    }

    private func recordedArgs(_ url: URL) -> [String] {
        (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    @Test func demoMarketBuyBuildsCorrectCommand() async throws {
        let stub = try makeStubCLI(stdout: #"{"code":"0","data":[{"ordId":"123456","sCode":"0"}]}"#)
        defer { try? FileManager.default.removeItem(at: stub.dir) }

        let order = SpotOrderRequest(instId: "BTC-USDT", side: .buy, kind: .market, size: 100, sizeUnit: .quote)
        let result = try await stub.bridge.placeSpotOrder(order, demo: true)

        #expect(result.ordId == "123456")
        let args = recordedArgs(stub.argsFile)
        #expect(args.contains("spot") && args.contains("place"))
        #expect(args.contains("--instId") && args.contains("BTC-USDT"))
        #expect(args.contains("--side") && args.contains("buy"))
        #expect(args.contains("--ordType") && args.contains("market"))
        #expect(args.contains("--sz") && args.contains("100"))
        #expect(args.contains("--tgtCcy") && args.contains("quote_ccy"))
        #expect(args.contains("--demo"), "demo orders must carry --demo")
        #expect(args.contains("--json"))
    }

    @Test func limitSellIncludesPrice() async throws {
        let stub = try makeStubCLI(stdout: #"{"code":"0","data":[{"ordId":"789","sCode":"0"}]}"#)
        defer { try? FileManager.default.removeItem(at: stub.dir) }

        let order = SpotOrderRequest(instId: "ETH-USDT", side: .sell, kind: .limit,
                                     size: 0.5, sizeUnit: .base, limitPrice: 4000)
        _ = try await stub.bridge.placeSpotOrder(order, demo: true)

        let args = recordedArgs(stub.argsFile)
        #expect(args.contains("--px") && args.contains("4000"))
        #expect(!args.contains("--tgtCcy"), "limit orders must not send tgtCcy")
    }

    @Test func liveOrderRefusedWhenLocked() async throws {
        let stub = try makeStubCLI(stdout: "{}")
        defer { try? FileManager.default.removeItem(at: stub.dir) }

        let order = SpotOrderRequest(instId: "BTC-USDT", side: .buy, kind: .market, size: 10)
        await #expect(throws: TradeError.self) {
            _ = try await stub.bridge.placeSpotOrder(order, demo: false, liveUnlocked: false)
        }
        // The stub must never have been invoked.
        #expect(!FileManager.default.fileExists(atPath: stub.argsFile.path))
    }

    @Test func liveOrderOmitsDemoFlagWhenUnlocked() async throws {
        let stub = try makeStubCLI(stdout: #"{"code":"0","data":[{"ordId":"1","sCode":"0"}]}"#)
        defer { try? FileManager.default.removeItem(at: stub.dir) }

        let order = SpotOrderRequest(instId: "BTC-USDT", side: .buy, kind: .market, size: 10)
        _ = try await stub.bridge.placeSpotOrder(order, demo: false, liveUnlocked: true)
        let args = recordedArgs(stub.argsFile)
        #expect(!args.contains("--demo"))
    }

    @Test func cliFailureSurfacesStderr() async throws {
        let stub = try makeStubCLI(stdout: #"{"code":"51000","msg":"Parameter sz error"}"#, exitCode: 2)
        defer { try? FileManager.default.removeItem(at: stub.dir) }

        let order = SpotOrderRequest(instId: "BTC-USDT", side: .buy, kind: .market, size: 0)
        await #expect(throws: TradeError.self) {
            _ = try await stub.bridge.placeSpotOrder(order, demo: true)
        }
    }

    @Test func parsesBalances() {
        let json = """
        {"code":"0","data":[{"details":[
            {"ccy":"USDT","availBal":"1500.5","cashBal":"1500.5"},
            {"ccy":"BTC","availBal":"0.25"},
            {"ccy":"DUST","availBal":"0"}]}]}
        """
        let balances = TradeBridge.parseBalances(json: json)
        #expect(balances.count == 2)
        #expect(balances.first?.ccy == "BTC")
        #expect(balances.last?.available == 1500.5)
    }

    @Test func missingCLIThrowsCliNotFound() async {
        let bridge = TradeBridge(explicitCLIPath: "/nonexistent/okx-\(UUID().uuidString)")
        // explicit path invalid + nothing in search paths ⇒ depends on machine;
        // so only assert when truly absent:
        if bridge.resolveCLIPath() == nil {
            let order = SpotOrderRequest(instId: "BTC-USDT", side: .buy, kind: .market, size: 1)
            await #expect(throws: TradeError.self) {
                _ = try await bridge.placeSpotOrder(order, demo: true)
            }
        }
    }
}

@Suite("Config persistence & migration")
struct ConfigTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-config-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func roundTrips() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let io = ConfigIO(directory: dir)

        var config = AppConfig.default
        config.watchlist = [
            WatchItem(instId: "BTC-USDT", style: .full, sparklineMinutes: 240),
            WatchItem(instId: "ETH-USDT", enabled: false, style: .priceOnly),
        ]
        config.alerts = [AlertRule(instId: "BTC-USDT", condition: .priceAbove(120_000), note: "moon")]
        config.trading.liveTradingUnlocked = false
        try io.save(config)

        let loaded = io.load()
        #expect(loaded == config)
    }

    @Test func migratesV1DroppingSystemMonitors() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let v1 = """
        [
          {"id":"7C0A6E2A-0000-0000-0000-000000000000","type":"crypto","label":"BTC",
           "source":{"okx":{"instId":"BTC-USDT"}},"isEnabled":true,"sortOrder":0,
           "chartConfig":{"chartType":"candlestick","timeSpan":{"minutes":{"_0":5}},"showVolume":true,"colorScheme":"standard"}},
          {"id":"7C0A6E2A-0000-0000-0000-000000000001","type":"cpu","label":"CPU",
           "source":{"system":{}},"isEnabled":true,"sortOrder":1,
           "chartConfig":{"chartType":"line","timeSpan":{"minutes":{"_0":1}},"showVolume":false,"colorScheme":"standard"}}
        ]
        """
        try v1.data(using: .utf8)!.write(to: dir.appendingPathComponent("config.json"))
        let loaded = ConfigIO(directory: dir).load()
        #expect(loaded.schemaVersion == AppConfig.currentSchemaVersion)
        #expect(loaded.watchlist.count == 1)
        #expect(loaded.watchlist.first?.instId == "BTC-USDT")
    }

    @Test func corruptFileFallsBackToDefault() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{{{garbage".data(using: .utf8)!.write(to: dir.appendingPathComponent("config.json"))
        let loaded = ConfigIO(directory: dir).load()
        #expect(loaded == .default)
        #expect(loaded.watchlist.first?.instId == "BTC-USDT")
    }
}

@Suite("Formatting")
struct FormatterTests {
    @Test func priceGroupsAndPads() {
        #expect(PriceFormatter.price(118234.5, decimals: 1) == "118,234.5")
        #expect(PriceFormatter.price(118234.5, decimals: 0) == "118,235")
        #expect(PriceFormatter.price(0.12345, decimals: 4) == "0.1235")
    }

    @Test func signedPercent() {
        #expect(PriceFormatter.signedPercent(1.234) == "+1.23%")
        #expect(PriceFormatter.signedPercent(-0.5) == "-0.50%")
    }

    @Test func tickSizeDecimals() {
        #expect(InstrumentMeta(instId: "X", tickSize: 0.1, lotSize: 0, minSize: 0).priceDecimals == 1)
        #expect(InstrumentMeta(instId: "X", tickSize: 0.001, lotSize: 0, minSize: 0).priceDecimals == 3)
        #expect(InstrumentMeta(instId: "X", tickSize: 1, lotSize: 0, minSize: 0).priceDecimals == 0)
    }

    @Test func compactVolume() {
        #expect(PriceFormatter.compact(12_400) == "12.4K")
        #expect(PriceFormatter.compact(3_400_000) == "3.40M")
    }
}
