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

    @Test("账户配置读出持仓模式、账户等级和自动借币开关")
    func accountConfigIsRead() {
        let json = """
        [{"acctLv":"3","posMode":"long_short_mode","uid":"1","autoLoan":false}]
        """
        let config = TradeBridge.parseAccountTradingConfig(json: json)
        #expect(config?.positionMode == .longShort)
        #expect(config?.accountLevel == 3)
        #expect(config?.optionTradeMode == "cross")
        #expect(config?.autoLoan == false)
        let net = TradeBridge.parseAccountTradingConfig(
            json: #"[{"acctLv":"1","posMode":"net_mode","autoLoan":"true"}]"#)
        #expect(net?.positionMode == .net)
        #expect(net?.optionTradeMode == "cash")
        #expect(net?.autoLoan == true, "the string spelling counts too")
        let silent = TradeBridge.parseAccountTradingConfig(json: #"[{"acctLv":"2"}]"#)
        #expect(silent?.autoLoan == nil, "not reported is not off")
        #expect(TradeBridge.parseAccountTradingConfig(json: "[]") == nil)
    }

    @Test("只有跨币种 / 组合保证金账户开了自动借币才算能借")
    func borrowingNeedsBothTheModeAndTheSwitch() {
        for level in [nil, 1, 2, 3, 4] {
            for loan in [nil, false, true] {
                let config = AccountTradingConfig(positionMode: nil, accountLevel: level, autoLoan: loan)
                let expected = (level ?? 0) >= 3 && loan == true
                #expect(config.borrowsMissingCoin == expected, "acctLv \(level.map(String.init) ?? "nil") autoLoan \(loan.map(String.init) ?? "nil")")
            }
        }
    }

    @Test("拒单文案用交易所的话，不用原始 JSON")
    func aRejectionSpeaksTheExchangesWords() {
        let perOrder = TradeError.cliFailed(exitCode: 1, stderr: """
            [
              {
                "clOrdId": "ms3c9ace0fmtrcq2h4e4",
                "ordId": "",
                "sCode": "51008",
                "sMsg": "Order failed. Insufficient BTC margin in account ",
                "tag": ""
              }
            ]
            """)
        #expect(perOrder.exchangeRejection == "OKX 51008：Order failed. Insufficient BTC margin in account")

        let envelope = TradeError.cliFailed(
            exitCode: 1, stderr: #"{"code":"51000","msg":"Parameter slTriggerPx error","data":[]}"#)
        #expect(envelope.exchangeRejection == "OKX 51000：Parameter slTriggerPx error")

        let formatted = TradeError.cliFailed(
            exitCode: 1, stderr: "Error: Parameter ordType error\nCode: 51000\nVersion: 1.4.1")
        #expect(formatted.exchangeRejection == "OKX 51000：Parameter ordType error")

        // An envelope whose `msg` is empty falls through to the raw payload
        // rather than to an empty verdict.
        let wordless = TradeError.cliFailed(exitCode: 1, stderr: #"{"code":"51119","msg":""}"#)
        #expect(wordless.exchangeRejection == #"OKX 51119：{"code":"51119","msg":""}"#)
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
        // Every family OKX lists has a fee, taker and maker, on every tier —
        // and every family it does not list has none, rather than a zero that
        // would read as "free".
        for tier in OKXFeeTier.allCases {
            for family in InstrumentType.allCases {
                for style in FeeExecutionStyle.allCases {
                    let bps = OKXFeeSchedule(tier: tier).feeBps(for: family, style: style)
                    #expect((bps?.isFinite ?? false) == Venue.okx.trades(family),
                            "\(tier) \(family) \(style)")
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

@Suite("A refusal on stdout is still a refusal")
struct FailureTextTests {
    @Test("非零退出时 stdout 里的 sCode 不能被 stderr 的更新横幅盖掉")
    func theVerdictOnStdoutSurvivesTheNagOnStderr() async throws {
        // Exactly what the demo account returned for an option order before
        // options trading was activated: the verdict as JSON on stdout, the
        // update nag on stderr, exit code 1.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cli = dir.appendingPathComponent("okx")
        try """
        #!/bin/sh
        echo 'Update available for @okx_ai/okx-trade-cli: 1.4.1 -> 1.4.5' >&2
        echo 'Run: npm install -g @okx_ai/okx-trade-cli' >&2
        echo '[{"clOrdId":"x","ordId":"","sCode":"51198","sMsg":"activate options trading first"}]'
        exit 1
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bridge = TradeBridge(explicitCLIPath: cli.path)
        let order = OrderRequest(
            instId: "BTC-USD-261225-100000-C", instType: .option, side: .buy, kind: .ioc,
            size: 3, sizeUnit: .base, limitPrice: 0.021, tradeMode: "cross")
        do {
            _ = try await bridge.place(order, mode: .demo)
            Issue.record("a non-zero exit must throw")
        } catch let error as TradeError {
            let rejection = try #require(error.exchangeRejection,
                                         "the exchange's own verdict is final, not an unconfirmed order")
            #expect(rejection.contains("51198"))
            #expect(rejection.contains("activate"))
            #expect(!error.description.contains("Update available"), "the nag is noise, not the reason")
        }
    }

    @Test("CLI 自己格式化的 Code: 行也算裁决，HTTP 状态码不算")
    func plainTextCodesCountAndHttpStatusesDoNot() {
        #expect(TradeError.okxCode(in: "Error: Parameter ordType error\nCode: 51000\nVersion: 1.4.1") == "51000")
        #expect(TradeError.okxCode(in: "Error: HTTP 400 from OKX\nCode: 400\nHint: retry") == nil)
        #expect(TradeError.okxCode(in: #"{"code":"0","data":[{"sCode":"51119"}]}"#) == "51119")
    }

    @Test("失败文本合并两路输出并去掉横幅")
    func failureTextKeepsBothStreamsMinusTheNag() {
        let text = TradeBridge.failureText(
            stdout: #"[{"sCode":"51198","sMsg":"activate"}]"#,
            stderr: "\nUpdate available for @okx_ai/okx-trade-cli: 1.4.1 -> 1.4.5\nRun: npm install -g @okx_ai/okx-trade-cli\nsocket hang up\n")
        #expect(text.contains("51198"))
        #expect(text.contains("socket hang up"))
        #expect(!text.contains("Update available"))
        #expect(TradeBridge.failureText(stdout: "", stderr: "  \n") == "")
    }
}

// MARK: - Open orders

/// The exchange's open-order books, read as they come off the CLI: the algo
/// fixture is the shape OKX actually returns for a close-all take-profit.
@Suite("Open orders")
struct OpenOrderParsingTests {
    static let algoBook = """
    [{"algoId":"3902370090634240000","instId":"SOL-USDT-SWAP","instType":"SWAP","ordType":"conditional",
      "side":"sell","posSide":"long","sz":"","closeFraction":"1","tpTriggerPx":"107.2","tpOrdPx":"-1",
      "slTriggerPx":"","slOrdPx":"","triggerPx":"","state":"live","reduceOnly":"true","cTime":"1788802091517",
      "clOrdId":"","tag":"","tdMode":"isolated","linkedOrd":{"ordId":""},"attachAlgoOrds":[]},
     {"algoId":"777","instId":"BTC-USDT-SWAP","ordType":"conditional","side":"sell","posSide":"long",
      "sz":"10","slTriggerPx":"58000","slOrdPx":"57900","state":"canceled","cTime":"1788800000000"}]
    """

    static let orderBook = """
    {"data":[{"ordId":"1001","instId":"ETH-USDT","ordType":"limit","side":"buy","px":"2400","sz":"0.5",
              "fillSz":"0.1","state":"partially_filled","reduceOnly":"false","cTime":"1788801000000",
              "clOrdId":"MSemaTrend1a2b3c"},
             {"ordId":"1002","instId":"ETH-USDT","ordType":"limit","side":"sell","px":"2600","sz":"0.5",
              "fillSz":"0.5","state":"filled","cTime":"1788800500000"}]}
    """

    @Test("全平止盈条件单：读出触发价、方向、全平，且 -1 不当成价格")
    func aCloseAllTakeProfitIsRead() throws {
        let orders = TradeBridge.parseOpenOrders(json: Self.algoBook, book: .algo)
        #expect(orders.count == 1, "the cancelled one is history, not an open order")
        let order = try #require(orders.first)
        #expect(order.id == "3902370090634240000")
        #expect(order.book == .algo)
        #expect(order.kindLabel == "止盈")
        #expect(order.side == .sell)
        #expect(order.posSide == .long)
        #expect(order.reduceOnly)
        #expect(order.triggerPrice == 107.2)
        #expect(order.takeProfitTriggerPrice == 107.2)
        #expect(order.stopTriggerPrice == nil)
        #expect(order.price == nil, "tpOrdPx -1 means market")
        #expect(order.size == nil)
        #expect(order.closeFraction == 1)
        #expect(order.clOrdId == nil)
        #expect(order.createdAt == Date(timeIntervalSince1970: 1_788_802_091.517))
    }

    @Test("普通挂单：只保留还在簿上的，部分成交计入已成交")
    func onlyOpenOrdersAreKept() throws {
        let orders = TradeBridge.parseOpenOrders(json: Self.orderBook, book: .order)
        #expect(orders.map(\.id) == ["1001"])
        let order = try #require(orders.first)
        #expect(order.kindLabel == "限价")
        #expect(order.price == 2_400)
        #expect(order.size == 0.5)
        #expect(order.filledSize == 0.1)
        #expect(order.triggerPrice == nil)
        #expect(order.clOrdId == "MSemaTrend1a2b3c")
    }

    @Test("每个可用模块的两本簿都会被问到，读不到的簿按名字报出来而不是当成空")
    func everyBookIsAskedAndFailuresAreNamed() async throws {
        // A stub that answers every listing with the same open algo order —
        // enough to prove each book is asked, and that the listing is one list.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("okx")
        let log = dir.appendingPathComponent("calls.txt")
        let script = """
        #!/bin/sh
        printf '%s ' "$@" >> "\(log.path)"; printf '\\n' >> "\(log.path)"
        case "$*" in
          *"option algo orders"*) echo 'Error: HTTP 400 from OKX: Parameter instType error' >&2; exit 1 ;;
        esac
        cat <<'JSON'
        \(Self.algoBook.replacingOccurrences(of: "\n", with: " "))
        JSON
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let bridge = TradeBridge(explicitCLIPath: cli.path)

        let listing = try await bridge.openOrders(mode: .demo)

        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        let books = Set(InstrumentType.allCases.compactMap(\.cliModule))
            .flatMap { ["\($0) orders", "\($0) algo orders"] }
        for book in books {
            #expect(calls.contains { $0.contains(book) }, "\(book) was never asked")
        }
        #expect(listing.unavailable == ["期权策略委托"])
        // The fixture is an algo-book record (it carries an algoId, no ordId),
        // so it is an order only when read as an algo book: one per algo book
        // that answered — spot's and swap's — and none from the order books.
        #expect(listing.orders.count == 2)
        #expect(listing.orders.allSatisfy { $0.book == .algo && $0.id == "3902370090634240000" })
    }
}
