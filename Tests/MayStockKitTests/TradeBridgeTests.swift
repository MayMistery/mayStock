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

        let order = OrderRequest(instId: "BTC-USDT", side: .buy, kind: .market,
                                 size: 100, sizeUnit: .quote, clOrdId: "ms0123abcd0000000001")
        let result = try await stub.bridge.place(order, mode: .demo)

        #expect(result.ordId == "123456")
        let args = recordedArgs(stub.argsFile)
        #expect(args.contains("spot") && args.contains("place"))
        #expect(args.contains("--instId") && args.contains("BTC-USDT"))
        #expect(args.contains("--side") && args.contains("buy"))
        #expect(args.contains("--ordType") && args.contains("market"))
        #expect(args.contains("--sz") && args.contains("100"))
        #expect(args.contains("--tgtCcy") && args.contains("quote_ccy"))
        #expect(args.contains("--clOrdId") && args.contains("ms0123abcd0000000001"),
                "every order must carry its strategy tag")
        #expect(args.contains("--demo"), "demo orders must carry --demo")
        #expect(args.contains("--json"))
    }

    @Test func swapOrderUsesSwapModule() async throws {
        let stub = try makeStubCLI(stdout: #"{"code":"0","data":[{"ordId":"55","sCode":"0"}]}"#)
        defer { try? FileManager.default.removeItem(at: stub.dir) }

        let order = OrderRequest(instId: "BTC-USDT-SWAP", instType: .swap, side: .sell,
                                 kind: .market, size: 3, sizeUnit: .base)
        _ = try await stub.bridge.place(order, mode: .demo)

        let args = recordedArgs(stub.argsFile)
        #expect(args.contains("swap") && args.contains("place"))
        #expect(!args.contains("--tgtCcy"), "tgtCcy is spot-only")
    }

    @Test func limitSellIncludesPrice() async throws {
        let stub = try makeStubCLI(stdout: #"{"code":"0","data":[{"ordId":"789","sCode":"0"}]}"#)
        defer { try? FileManager.default.removeItem(at: stub.dir) }

        let order = OrderRequest(instId: "ETH-USDT", side: .sell, kind: .limit,
                                 size: 0.5, sizeUnit: .base, limitPrice: 4000)
        _ = try await stub.bridge.place(order, mode: .demo)

        let args = recordedArgs(stub.argsFile)
        #expect(args.contains("--px") && args.contains("4000"))
        #expect(!args.contains("--tgtCcy"), "limit orders must not send tgtCcy")
    }

    @Test func liveOrderRefusedWhenLocked() async throws {
        let stub = try makeStubCLI(stdout: "{}")
        defer { try? FileManager.default.removeItem(at: stub.dir) }

        let order = OrderRequest(instId: "BTC-USDT", side: .buy, kind: .market, size: 10)
        await #expect(throws: TradeError.self) {
            _ = try await stub.bridge.place(order, mode: .live, liveUnlocked: false)
        }
        // The stub must never have been invoked.
        #expect(!FileManager.default.fileExists(atPath: stub.argsFile.path))
    }

    @Test func liveOrderSendsLiveFlagWhenUnlocked() async throws {
        let stub = try makeStubCLI(stdout: #"{"code":"0","data":[{"ordId":"1","sCode":"0"}]}"#)
        defer { try? FileManager.default.removeItem(at: stub.dir) }

        let order = OrderRequest(instId: "BTC-USDT", side: .buy, kind: .market, size: 10)
        _ = try await stub.bridge.place(order, mode: .live, liveUnlocked: true)
        let args = recordedArgs(stub.argsFile)
        #expect(!args.contains("--demo"))
        #expect(args.contains("--live"))
    }

    @Test func cliFailureSurfacesStderr() async throws {
        let stub = try makeStubCLI(stdout: #"{"code":"51000","msg":"Parameter sz error"}"#, exitCode: 2)
        defer { try? FileManager.default.removeItem(at: stub.dir) }

        let order = OrderRequest(instId: "BTC-USDT", side: .buy, kind: .market, size: 0)
        await #expect(throws: TradeError.self) {
            _ = try await stub.bridge.place(order, mode: .demo)
        }
    }

    @Test func missingOrdIdIsNotSilentlyAccepted() async throws {
        let stub = try makeStubCLI(stdout: #"{"code":"0","data":[{"sCode":"51008","sMsg":"insufficient"}]}"#)
        defer { try? FileManager.default.removeItem(at: stub.dir) }

        let order = OrderRequest(instId: "BTC-USDT", side: .buy, kind: .market, size: 10)
        await #expect(throws: TradeError.self) {
            _ = try await stub.bridge.place(order, mode: .demo)
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

    @Test func parsesPositionsSigningShortLegs() {
        let json = """
        {"code":"0","data":[
          {"instId":"BTC-USDT-SWAP","posSide":"short","pos":"3","avgPx":"60000",
           "markPx":"59000","upl":"30","lever":"2","liqPx":"88000"},
          {"instId":"ETH-USDT-SWAP","posSide":"net","pos":"-2","avgPx":"3000","upl":"-5"}]}
        """
        let positions = TradeBridge.parsePositions(json: json)
        #expect(positions.count == 2)
        #expect(positions.first?.quantity == -3, "a short leg is negative exposure")
        #expect(positions.first?.leverage == 2)
        #expect(positions.last?.quantity == -2)
    }

    @Test func parsesFillsWithClientOrderIds() {
        let json = """
        {"code":"0","data":[
          {"instId":"BTC-USDT","tradeId":"t1","ordId":"o1","clOrdId":"ms0123abcd0000000001",
           "side":"buy","fillPx":"100","fillSz":"0.5","fee":"-0.05","feeCcy":"USDT","ts":"1700000000000"},
          {"instId":"BTC-USDT","tradeId":"t2","ordId":"o2","clOrdId":"",
           "side":"sell","fillPx":"110","fillSz":"0.5","fee":"-0.06","feeCcy":"USDT","ts":"1700000600000"}]}
        """
        let fills = TradeBridge.parseFills(json: json)
        #expect(fills.count == 2)
        #expect(fills.first?.clOrdId == "ms0123abcd0000000001")
        #expect(fills.last?.clOrdId == nil, "empty clOrdId must not become an empty-string tag")
        #expect(fills.first!.ts < fills.last!.ts, "fills are returned oldest first")
    }

    @Test func missingCLIThrowsCliNotFound() async {
        let bridge = TradeBridge(explicitCLIPath: "/nonexistent/okx-\(UUID().uuidString)")
        // explicit path invalid + nothing in search paths ⇒ depends on machine;
        // so only assert when truly absent:
        if bridge.resolveCLIPath() == nil {
            let order = OrderRequest(instId: "BTC-USDT", side: .buy, kind: .market, size: 1)
            await #expect(throws: TradeError.self) {
                _ = try await bridge.place(order, mode: .demo)
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

@Suite("CLI robustness")
struct TradeBridgeRobustnessTests {
    private func makeStub(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-robust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("okx")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func aHangingCliDoesNotHangTheCaller() async throws {
        // Without a watchdog this wedges the strategy runner permanently: the
        // tick never returns, `isTicking` stays true, and trading stops silently.
        let stub = try makeStub("sleep 120")
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
        let bridge = TradeBridge(explicitCLIPath: stub.path, commandTimeout: 2)

        let started = Date()
        await #expect(throws: TradeError.self) {
            _ = try await bridge.balances(mode: .demo)
        }
        // `balances` falls back to a second command when the first fails, so
        // the worst case is two timeouts — still far short of the child's 120s.
        #expect(Date().timeIntervalSince(started) < bridge.commandTimeout * 2 + 10,
                "the watchdog must fire well before the child would finish")
    }

    @Test func aCliThatExitsLeavingAChildOnStdoutStillReturns() async throws {
        // The one that actually took the engine down. The CLI exits at once,
        // but a child it spawned inherited stdout and keeps the pipe open, so
        // nothing ever reaches EOF. The old watchdog asked `process.isRunning`,
        // saw `false`, concluded there was nothing to kill — and returned
        // without resuming the caller. The tick never came back, and the panel
        // went on showing the last numbers it had while nobody managed the
        // positions. A node CLI's update check does exactly this.
        let stub = try makeStub("""
        sleep 120 &
        echo '{"code":"0","data":[{"details":[{"ccy":"USDT","availBal":"5"}]}]}'
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
        let bridge = TradeBridge(explicitCLIPath: stub.path, commandTimeout: 2)

        let started = Date()
        await #expect(throws: TradeError.self) {
            _ = try await bridge.positions(mode: .demo)
        }
        #expect(Date().timeIntervalSince(started) < 20,
                "the deadline must fire even though the child has already exited")
    }

    @Test func heavyStderrDoesNotDeadlockTheReader() async throws {
        // Draining stdout to completion before touching stderr deadlocks once
        // the child fills the stderr buffer — and the real okx CLI writes an
        // update banner there. Both pipes must be read concurrently.
        let stub = try makeStub("""
        i=0
        while [ $i -lt 4000 ]; do
          echo "warning line $i padding padding padding padding padding" >&2
          i=$((i+1))
        done
        echo '{"code":"0","data":[{"details":[{"ccy":"USDT","availBal":"5"}]}]}'
        """)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
        let bridge = TradeBridge(explicitCLIPath: stub.path)

        let balances = try await bridge.balances(mode: .demo)
        #expect(balances.first?.ccy == "USDT")
        #expect(balances.first?.available == 5)
    }

    @Test func heavyStdoutAlsoSurvives() async throws {
        let stub = try makeStub("""
        printf '{"code":"0","data":[{"details":['
        i=0
        while [ $i -lt 800 ]; do
          printf '{"ccy":"C%s","availBal":"1"},' "$i"
          i=$((i+1))
        done
        printf '{"ccy":"USDT","availBal":"9"}]}]}'
        """)
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
        let bridge = TradeBridge(explicitCLIPath: stub.path)
        let balances = try await bridge.balances(mode: .demo)
        #expect(balances.count > 100)
        #expect(balances.first { $0.ccy == "USDT" }?.available == 9)
    }
}

@Suite("Order status resolution")
struct OrderStatusTests {
    /// A request that timed out may well have reached the exchange and filled.
    /// Absent from the listing is the only answer that makes a retry safe —
    /// everything else means the exchange acted and the ledger must catch up.
    @Test func anAbsentOrderIsTheOnlySafeRetry() {
        let json = #"{"data":[{"clOrdId":"msother","state":"filled","accFillSz":"1"}]}"#
        #expect(TradeBridge.parseOrderStatus(json: json, clOrdId: "msmine") == .unknown)
        #expect(TradeBridge.parseOrderStatus(json: "[]", clOrdId: "msmine") == .unknown)
    }

    @Test func aFilledOrderReportsItsSizeAndPrice() {
        let json = #"""
        {"data":[{"clOrdId":"msmine","state":"filled","accFillSz":"11.65","avgPx":"64769.39"}]}
        """#
        guard case .filled(let size, let price) =
            TradeBridge.parseOrderStatus(json: json, clOrdId: "msmine") else {
            Issue.record("expected a fill"); return
        }
        #expect(abs(size - 11.65) < 1e-9)
        #expect(abs(price - 64_769.39) < 1e-6)
    }

    /// A cancel that followed a partial fill still left a position behind.
    /// Reporting it as merely "canceled" would lose those coins.
    @Test func aPartiallyFilledCancelIsStillAFill() {
        let json = #"""
        {"data":[{"clOrdId":"msmine","state":"canceled","accFillSz":"3","avgPx":"100"}]}
        """#
        #expect(TradeBridge.parseOrderStatus(json: json, clOrdId: "msmine").didExecute)
    }

    @Test func aCleanCancelIsTerminalAndDidNotExecute() {
        let json = #"{"data":[{"clOrdId":"msmine","state":"canceled","accFillSz":"0"}]}"#
        let status = TradeBridge.parseOrderStatus(json: json, clOrdId: "msmine")
        #expect(status == .canceled)
        #expect(status.isTerminal)
        #expect(!status.didExecute)
    }

    @Test func aWorkingOrderIsNotTerminal() {
        let json = #"{"data":[{"clOrdId":"msmine","state":"live","accFillSz":"0"}]}"#
        let status = TradeBridge.parseOrderStatus(json: json, clOrdId: "msmine")
        #expect(status == .live)
        #expect(!status.isTerminal)
    }

    @Test func garbageIsUnknownRatherThanACrash() {
        #expect(TradeBridge.parseOrderStatus(json: "not json", clOrdId: "x") == .unknown)
        #expect(TradeBridge.parseOrderStatus(json: "", clOrdId: "x") == .unknown)
    }
}

@Suite("Option orders through the bridge")
struct TradeBridgeOptionTests {
    private func makeStubCLI(stdout: String) throws -> (bridge: TradeBridge, argsFile: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-option-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cli = dir.appendingPathComponent("okx")
        let argsFile = dir.appendingPathComponent("args.txt")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argsFile.path)"
        cat <<'JSON'
        \(stdout)
        JSON
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (TradeBridge(explicitCLIPath: cli.path), argsFile, dir)
    }

    private func recordedArgs(_ url: URL) -> [String] {
        (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    @Test("期权单走 option 模块，带 tdMode、IOC 限价、reduceOnly 裸标志，不带 posSide/tgtCcy")
    func anOptionOrderIsShapedForItsModule() async throws {
        let stub = try makeStubCLI(stdout: #"{"code":"0","data":[{"ordId":"9","sCode":"0"}]}"#)
        defer { try? FileManager.default.removeItem(at: stub.dir) }

        let order = OrderRequest(
            instId: "BTC-USD-260926-80000-C", instType: .option, side: .sell, kind: .ioc,
            size: 3, sizeUnit: .base, limitPrice: 0.0214, reduceOnly: true,
            clOrdId: "ms0123abcd0000000001", tradeMode: "cross")
        _ = try await stub.bridge.place(order, mode: .demo)

        let args = recordedArgs(stub.argsFile)
        #expect(args.prefix(2) == ["option", "place"])
        #expect(args.contains("--tdMode") && args.contains("cross"))
        #expect(args.contains("--ordType") && args.contains("ioc"))
        #expect(args.contains("--px") && args.contains("0.0214"))
        #expect(args.contains("--sz") && args.contains("3"))
        let reduce = try #require(args.firstIndex(of: "--reduceOnly"))
        #expect(args.indices.contains(reduce + 1) ? args[reduce + 1] != "true" : true,
                "the CLI documents a bare flag")
        #expect(!args.contains("--posSide"), "options have no legs")
        #expect(!args.contains("--tgtCcy"), "tgtCcy is spot-only")
        #expect(args.contains("--demo"))
    }

    @Test("永续 reduceOnly 也是裸标志")
    func aSwapReduceOnlyIsABareFlag() async throws {
        let stub = try makeStubCLI(stdout: #"{"code":"0","data":[{"ordId":"9","sCode":"0"}]}"#)
        defer { try? FileManager.default.removeItem(at: stub.dir) }
        let order = OrderRequest(
            instId: "BTC-USDT-SWAP", instType: .swap, side: .sell, kind: .market,
            size: 2, sizeUnit: .base, posSide: .long, reduceOnly: true)
        _ = try await stub.bridge.place(order, mode: .demo)
        let args = recordedArgs(stub.argsFile)
        #expect(args.contains("--reduceOnly"))
        #expect(!args.contains("true"))
        #expect(args.contains("--posSide") && args.contains("long"))
    }

    @Test("期权成交带上美元价和指数价")
    func optionFillStampsAreRead() {
        let json = """
        {"data":[{"instId":"BTC-USD-260926-80000-C","tradeId":"t9","ordId":"o9",
                  "clOrdId":"ms0123abcd0000000001","side":"buy","fillPx":"0.02","fillSz":"5",
                  "fee":"-0.0001","feeCcy":"BTC","ts":"1700000000000",
                  "fillPxUsd":"1600.5","fillIdxPx":"80025","fillPxVol":"0.55"}]}
        """
        let fills = TradeBridge.parseFills(json: json)
        #expect(fills.count == 1)
        #expect(fills.first?.priceUsd == 1_600.5)
        #expect(fills.first?.indexPrice == 80_025)
        // A spot fill carries neither, and empty strings must not become zero.
        let spot = TradeBridge.parseFills(json: """
        {"data":[{"instId":"BTC-USDT","tradeId":"t1","side":"buy","fillPx":"100","fillSz":"1",
                  "ts":"1700000000000","fillPxUsd":"","fillIdxPx":""}]}
        """)
        #expect(spot.first?.priceUsd == nil)
        #expect(spot.first?.indexPrice == nil)
    }

    @Test("账户配置读出持仓模式和账户等级")
    func accountConfigIsRead() {
        let json = """
        [{"acctLv":"3","posMode":"long_short_mode","uid":"1"}]
        """
        let config = TradeBridge.parseAccountTradingConfig(json: json)
        #expect(config?.positionMode == .longShort)
        #expect(config?.accountLevel == 3)
        #expect(config?.optionTradeMode == "cross")
        let net = TradeBridge.parseAccountTradingConfig(json: #"[{"acctLv":"1","posMode":"net_mode"}]"#)
        #expect(net?.positionMode == .net)
        #expect(net?.optionTradeMode == "cash")
        #expect(TradeBridge.parseAccountTradingConfig(json: "[]") == nil)
    }

    @Test("合约面值是 ctVal × ctMult，期权的 0.01 在 ctMult 里")
    func contractValueMultipliesBothFields() {
        #expect(InstrumentMeta.contractValue(ctVal: 1, ctMult: 0.01) == 0.01)
        #expect(InstrumentMeta.contractValue(ctVal: 0.01, ctMult: 1) == 0.01)
        #expect(InstrumentMeta.contractValue(ctVal: 0.1, ctMult: nil) == 0.1)
        #expect(InstrumentMeta.contractValue(ctVal: nil, ctMult: 0.01) == nil)
        #expect(InstrumentMeta.contractValue(ctVal: 0, ctMult: 1) == nil)
    }

    @Test("期权费率也能同步")
    func optionFeesSync() {
        var schedule = OKXFeeSchedule()
        #expect(schedule.feeBps(for: .option) == 3)
        schedule.apply(AccountFeeRates(instType: .option, makerBps: 2, takerBps: 2.5))
        #expect(schedule.feeBps(for: .option) == 2.5)
        #expect(schedule.feeBps(for: .option, style: .maker) == 2)
        #expect(schedule.summary.contains("期权"))
        schedule.clearSync()
        #expect(schedule.feeBps(for: .option) == 3)
        // Every family has a fee, taker and maker, on every tier.
        for tier in OKXFeeTier.allCases {
            for family in InstrumentType.allCases {
                for style in FeeExecutionStyle.allCases {
                    let bps = OKXFeeSchedule(tier: tier).feeBps(for: family, style: style)
                    #expect(bps.isFinite, "\(tier) \(family) \(style)")
                }
            }
        }
    }
}

@Suite("Order status asks both listings")
struct OrderStatusListingTests {
    /// A stub whose answer depends on whether `--history` was asked for: the
    /// working book is empty, the finished book holds the order.
    private func makeStub() throws -> (bridge: TradeBridge, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-status-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cli = dir.appendingPathComponent("okx")
        let script = """
        #!/bin/sh
        case "$*" in
          *--history*) echo '{"data":[{"clOrdId":"msmine","state":"filled","accFillSz":"2","avgPx":"100"}]}' ;;
          *) echo '[]' ;;
        esac
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (TradeBridge(explicitCLIPath: cli.path), dir)
    }

    @Test("成交了的订单在历史单里，不在挂单里；只问挂单会把它当成从未送达")
    func aFilledOrderIsFoundInTheHistoryListing() async throws {
        let stub = try makeStub()
        defer { try? FileManager.default.removeItem(at: stub.dir) }
        let status = try await stub.bridge.orderStatus(
            instId: "BTC-USDT", instType: .spot, clOrdId: "msmine", mode: .demo)
        #expect(status.didExecute)
        guard case .filled(let size, _) = status else { Issue.record("expected a fill"); return }
        #expect(size == 2)
        // An order in neither listing is the one case that is safe to retry.
        let absent = try await stub.bridge.orderStatus(
            instId: "BTC-USDT", instType: .spot, clOrdId: "msother", mode: .demo)
        #expect(absent == .unknown)
    }
}
