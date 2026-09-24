import Foundation
import Testing
@testable import MayStockKit

/// The CLI's account documents, parsed without a CLI or a network. Orders no
/// longer go through the CLI; the kernel's own tests pin those.
@Suite("Trade bridge")
struct TradeBridgeTests {
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
        let positions = KernelAccount.positions(json)
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
            _ = try await bridge.runCLI(["account", "bills"], mode: .demo)
        }
        #expect(Date().timeIntervalSince(started) < bridge.commandTimeout + 10,
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
            _ = try await bridge.runCLI(["account", "bills"], mode: .demo)
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

        let output = try await bridge.runCLI(["account", "bills"], mode: .demo)
        let balances = TradeBridge.parseBalances(json: output)
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
        let balances = TradeBridge.parseBalances(json: try await bridge.runCLI(["account", "bills"], mode: .demo))
        #expect(balances.count > 100)
        #expect(balances.first { $0.ccy == "USDT" }?.available == 9)
    }
}


@Suite("OKX account readings and fees")
struct TradeBridgeOptionTests {
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


@Suite("The exchange's verdict in CLI output")
struct FailureTextTests {
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
