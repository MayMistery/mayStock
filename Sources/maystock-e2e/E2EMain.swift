import Foundation
import MayStockKit

/// MayStock end-to-end driver & diagnostics CLI.
///
///   maystock-e2e doctor [instId]       full pipeline check against live OKX
///   maystock-e2e watch <instId> [sec]  stream live ticks to stdout
///   maystock-e2e alert-sim             alert engine simulation (offline)
///   maystock-e2e trade-doctor          okx CLI detection + public call
///   maystock-e2e strategy-doctor       compile presets + real multi-window backtest
///   maystock-e2e option-demo           buy and sell one option on the DEMO account,
///                                      through the runner's own order path
///
/// Exit code 0 = pass. Non-zero = failure (CI-friendly).
@main
struct E2EMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "doctor"
        let ok: Bool
        switch command {
        case "option-demo":
            ok = await optionDemo(Array(args.dropFirst()))
        case "doctor":
            ok = await doctor(instId: args.count > 1 ? args[1] : "BTC-USDT")
        case "watch":
            ok = await watch(instId: args.count > 1 ? args[1] : "BTC-USDT",
                             seconds: args.count > 2 ? Int(args[2]) ?? 15 : 15)
        case "alert-sim":
            ok = await alertSim()
        case "trade-doctor":
            ok = await tradeDoctor()
        case "strategy-doctor":
            ok = await strategyDoctor(instId: args.count > 1 ? args[1] : nil)
        default:
            print("unknown command: \(command)")
            ok = false
        }
        exit(ok ? 0 : 1)
    }

    // MARK: Pretty output

    static func pass(_ label: String, _ detail: String = "") {
        print("  ✓ \(label)\(detail.isEmpty ? "" : "  —  \(detail)")")
    }

    static func fail(_ label: String, _ detail: String = "") {
        print("  ✗ \(label)\(detail.isEmpty ? "" : "  —  \(detail)")")
    }

    // MARK: doctor

    /// The real E2E: REST reachability → metadata → 300-candle backfill →
    /// both websockets (public + business) → live ticks, candles, book →
    /// keepalive round-trip. Exercises exactly the code paths the app uses.
    static func doctor(instId: String) async -> Bool {
        print("MayStock E2E doctor · \(instId) · \(Date())")
        var allOK = true
        let rest = OKXRESTClient()

        // 1. REST ticker
        var restTicker: Ticker?
        do {
            let t0 = Date()
            let ticker = try await rest.ticker(instId: instId)
            restTicker = ticker
            pass("REST ticker", "last=\(PriceFormatter.auto(ticker.last)) " +
                 "\(ticker.basis.periodLabel)=\(PriceFormatter.signedPercent(ticker.changePct)) " +
                 "(\(Int(Date().timeIntervalSince(t0) * 1000))ms)")
        } catch {
            fail("REST ticker", String(describing: error)); allOK = false
        }

        // 2. Instrument metadata
        do {
            if let meta = try await rest.instrumentMeta(instId: instId) {
                pass("REST instrument meta", "tickSz=\(meta.tickSize) → \(meta.priceDecimals) decimals")
            } else {
                fail("REST instrument meta", "instrument not found"); allOK = false
            }
        } catch {
            fail("REST instrument meta", String(describing: error)); allOK = false
        }

        // 3. Candle backfill with pagination
        do {
            let candles = try await rest.candles(instId: instId, bar: .m1, target: 300)
            let sorted = zip(candles, candles.dropFirst()).allSatisfy { $0.ts < $1.ts }
            if candles.count >= 200 && sorted {
                pass("REST candle backfill", "\(candles.count) bars, strictly ascending")
            } else {
                fail("REST candle backfill", "count=\(candles.count) sorted=\(sorted)"); allOK = false
            }
        } catch {
            fail("REST candle backfill", String(describing: error)); allOK = false
        }

        // 4. Live websockets — the 1.x killer bug was candles on the wrong URL.
        let counter = EventCounter()
        let wsPublic = OKXWSClient(url: OKXEndpoints.wsPublic)
        let wsBusiness = OKXWSClient(url: OKXEndpoints.wsBusiness)
        await wsPublic.setHandler { event in Task { await counter.record(event, socket: "public") } }
        await wsBusiness.setHandler { event in Task { await counter.record(event, socket: "business") } }
        await wsPublic.subscribe([
            OKXChannelArg(channel: "tickers", instId: instId),
            OKXChannelArg(channel: "books5", instId: instId),
        ])
        await wsBusiness.subscribe([
            OKXChannelArg(channel: BarInterval.m1.wsChannel, instId: instId),
        ])

        // Collect for up to 25s; candle pushes can take a few seconds.
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await counter.satisfied() { break }
        }
        let summary = await counter.summary()
        let stats = await counter.stats()

        if stats.ticks >= 5 { pass("WS tickers (public)", summary.ticker) }
        else { fail("WS tickers (public)", summary.ticker); allOK = false }

        if stats.books >= 3 { pass("WS books5 (public)", summary.book) }
        else { fail("WS books5 (public)", summary.book); allOK = false }

        if stats.candles >= 1 { pass("WS candles (business)", summary.candle) }
        else { fail("WS candles (business)", summary.candle + "  ← wrong-endpoint regression?"); allOK = false }

        if stats.errors == 0 { pass("WS error frames", "none") }
        else { fail("WS error frames", summary.errors); allOK = false }

        // 5. Cross-check: WS last price vs REST last price within 2%.
        if let restLast = restTicker?.last, let wsLast = stats.lastPrice, restLast > 0 {
            let drift = abs(wsLast - restLast) / restLast * 100
            if drift < 2 { pass("REST/WS price coherence", String(format: "drift %.3f%%", drift)) }
            else { fail("REST/WS price coherence", String(format: "drift %.2f%%", drift)); allOK = false }
        }

        await wsPublic.disconnect()
        await wsBusiness.disconnect()
        print(allOK ? "\nE2E PASS" : "\nE2E FAIL")
        return allOK
    }

    // MARK: watch

    static func watch(instId: String, seconds: Int) async -> Bool {
        print("watching \(instId) for \(seconds)s …")
        let ws = OKXWSClient(url: OKXEndpoints.wsPublic)
        await ws.setHandler { event in
            if case .message(.ticker(let t)) = event {
                let arrow = t.changePct >= 0 ? "↑" : "↓"
                print("\(t.ts)  \(t.instId)  \(PriceFormatter.auto(t.last))  " +
                      "\(arrow)\(PriceFormatter.signedPercent(t.changePct))")
            }
        }
        await ws.subscribe([OKXChannelArg(channel: "tickers", instId: instId)])
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        await ws.disconnect()
        return true
    }

    // MARK: alert-sim (offline, deterministic)

    static func alertSim() async -> Bool {
        print("alert engine simulation (synthetic ticks)")
        let engine = await MainActor.run { AlertEngine() }
        let fired = FiredBox()

        let setupOK: Bool = await MainActor.run {
            engine.onAlert = { event in Task { await fired.append(event.summary) } }
            engine.setRules([
                AlertRule(instId: "SIM-USDT", condition: .priceAbove(105)),
                AlertRule(instId: "SIM-USDT", condition: .priceBelow(95)),
            ])
            var spark = SparklineBuffer()
            let t0 = Date()
            // Ramp 100 → 110 → 90: should fire above-105 once, below-95 once.
            var step = 0
            for price in [100.0, 102, 104, 106, 108, 110, 100, 96, 94, 90] {
                let ts = t0.addingTimeInterval(Double(step) * 2)
                step += 1
                spark.sample(price: price, at: ts)
                let ticker = Ticker(instId: "SIM-USDT", last: price, bid: nil, ask: nil,
                                    reference: 100, high: 110, low: 90, volume: 0,
                                    basis: .rolling24h, ts: ts)
                engine.evaluate(instId: "SIM-USDT", ticker: ticker, spark: spark, now: ts)
            }
            return true
        }
        let firedOK = await checkFired(fired)
        return setupOK && firedOK
    }

    static func checkFired(_ fired: FiredBox) async -> Bool {
        // Give the async append tasks a beat to land.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let events = await fired.events
        let okAbove = events.contains { $0.contains("≥ 105") }
        let okBelow = events.contains { $0.contains("≤ 95") }
        let okCount = events.count == 2
        okAbove ? pass("priceAbove crossed once") : fail("priceAbove", "events=\(events)")
        okBelow ? pass("priceBelow crossed once") : fail("priceBelow", "events=\(events)")
        okCount ? pass("no duplicate firing") : fail("duplicate firing", "count=\(events.count)")
        return okAbove && okBelow && okCount
    }

    // MARK: trade-doctor

    static func tradeDoctor() async -> Bool {
        print("trade bridge doctor")
        let bridge = TradeBridge()
        guard let cli = await bridge.detectCLI() else {
            fail("okx CLI", "not found — install: npm install -g @okx_ai/okx-trade-cli")
            print("(trading features stay hidden in-app until the CLI is installed)")
            return true // absence of the optional CLI is not an E2E failure
        }
        pass("okx CLI", "\(cli.path) (\(cli.version))")
        do {
            let out = try await bridge.marketTicker(instId: "BTC-USDT")
            pass("okx market ticker", "\(out.prefix(80))…")
            return true
        } catch {
            fail("okx market ticker", String(describing: error))
            return false
        }
    }

    // MARK: strategy-doctor

    /// The strategy E2E: every preset compiles, deep history paginates without
    /// gaps or duplicates, swap contract sizing resolves, and a full five-window
    /// report comes back internally consistent. Needs no API key — backtesting
    /// only ever reads public market data.
    static func strategyDoctor(instId: String?) async -> Bool {
        print("MayStock strategy doctor · \(Date())")
        var allOK = true
        let rest = OKXRESTClient()

        // 1. Every shipped preset must compile.
        var compiled: [CompiledStrategy] = []
        for preset in StrategyLibrary.presets {
            do {
                compiled.append(try preset.compile())
            } catch {
                fail("compile \(preset.id)", String(describing: error)); allOK = false
            }
        }
        if compiled.count == StrategyLibrary.presets.count {
            pass("presets compile", "\(compiled.count) 个内置策略")
        }
        if !OrderTag.collisions(among: StrategyLibrary.presets.map(\.id)).isEmpty {
            fail("clOrdId 归因", "策略短 ID 冲突"); allOK = false
        } else {
            pass("clOrdId 归因", "无短 ID 冲突")
        }

        // 2. Deep history pagination — the part that only breaks against the
        //    real API, where page caps and cursors actually apply.
        let probe = instId ?? "BTC-USDT"
        do {
            let candles = try await rest.historyCandles(instId: probe, bar: .h1, target: 900)
            let ascending = zip(candles, candles.dropFirst()).allSatisfy { $0.ts < $1.ts }
            let unique = Set(candles.map(\.ts)).count == candles.count
            if candles.count >= 700, ascending, unique {
                pass("history 分页", "\(candles.count) 根 1H，时间严格递增且无重复")
            } else {
                fail("history 分页",
                     "count=\(candles.count) ascending=\(ascending) unique=\(unique)")
                allOK = false
            }
        } catch {
            fail("history 分页", String(describing: error)); allOK = false
        }

        // 3. Swap sizing needs ctVal — without it every perp order is 100× wrong.
        do {
            if let meta = try await rest.instrumentMeta(instId: "BTC-USDT-SWAP"),
               let contractValue = meta.contractValue, contractValue > 0 {
                pass("永续合约面值", "ctVal=\(contractValue) → 0.5 BTC = "
                     + "\(PriceFormatter.plain(meta.exchangeSize(forBaseQuantity: 0.5))) 张")
            } else {
                fail("永续合约面值", "缺少 ctVal"); allOK = false
            }
        } catch {
            fail("永续合约面值", String(describing: error)); allOK = false
        }

        // 3b. An option is sized by ctVal × ctMult — the 0.01 lives in the
        //     multiplier, so a chain that read only ctVal would size every
        //     order a hundredfold.
        do {
            let chain = try await rest.optionChain(underlying: "BTC-USD")
            if let sample = chain.first, chain.count > 10 {
                let ok = abs(sample.contractValue - 0.01) < 1e-12
                (ok ? pass : fail)("期权链",
                     "\(chain.count) 张合约，\(sample.instId) 每张 \(PriceFormatter.plain(sample.contractValue)) BTC")
                if !ok { allOK = false }
                let quote = try await rest.optionQuote(instId: sample.instId)
                pass("期权报价", "标记 \(quote.mark.map(PriceFormatter.plain) ?? "—") BTC · 指数 "
                     + PriceFormatter.plain(quote.indexPrice))
            } else {
                fail("期权链", "只拿到 \(chain.count) 张合约"); allOK = false
            }
        } catch {
            fail("期权链", String(describing: error)); allOK = false
        }

        // 4. A real five-window report.
        guard let strategy = compiled.first else { return false }
        do {
            let report = try await BacktestRunner().run(strategy: strategy, capital: 10_000)
            var previousBars = 0
            var monotonic = true
            for window in BacktestWindow.allCases {
                guard let result = report.result(for: window) else { continue }
                if result.barCount < previousBars { monotonic = false }
                previousBars = result.barCount
                let metrics = result.metrics
                pass("回测 \(window.displayName)",
                     "收益 \(PriceFormatter.signedPercent(metrics.totalReturnPct))"
                     + " · 回撤 \(PriceFormatter.percent(metrics.maxDrawdownPct, decimals: 1))"
                     + " · \(metrics.tradeCount) 笔"
                     + " · 对标持有 \(PriceFormatter.signedPercent(metrics.buyHoldReturnPct))")
            }
            if monotonic {
                pass("窗口嵌套", "长窗口覆盖的 K 线不少于短窗口")
            } else {
                fail("窗口嵌套", "长窗口 K 线数少于短窗口"); allOK = false
            }
            pass("稳健性徽章", report.robustness.grade.displayName
                 + "（\(report.robustness.observedTrades)/\(report.robustness.requiredTrades) 笔）")
        } catch {
            fail("多窗口回测", String(describing: error)); allOK = false
        }

        print(allOK ? "\nstrategy doctor: PASS" : "\nstrategy doctor: FAIL")
        return allOK
    }
}

// MARK: - option-demo

/// A real round trip on the **demo** account: the runner reads the chain,
/// picks a contract by the kernel's rule, buys it with an IOC limit, books the
/// fill in the ledger, and is then asked to flatten. Every number printed is
/// read back from the exchange, not from what the code intended to do.
///
/// Demo only, by construction: the host reports live as locked, the mode is
/// `.demo`, and `TradeBridge` refuses a live order without the unlock. There
/// is no flag that changes that.
///
///   option-demo [--underlying BTC-USD] [--budget 60] [--min-days 2]
///               [--moneyness 0] [--capital 500]
extension E2EMain {
    static func optionDemo(_ raw: [String]) async -> Bool {
        var flags: [String: String] = [:]
        var index = 0
        while index < raw.count {
            if raw[index].hasPrefix("--"), index + 1 < raw.count {
                flags[String(raw[index].dropFirst(2))] = raw[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        let underlying = flags["underlying"] ?? "BTC-USD"
        let budget = Double(flags["budget"] ?? "") ?? 60
        let minDays = Double(flags["min-days"] ?? "") ?? 2
        let moneyness = Double(flags["moneyness"] ?? "") ?? 0
        let capital = Double(flags["capital"] ?? "") ?? 500
        let base = String(underlying.split(separator: "-").first ?? "BTC")

        print("MayStock option demo · \(underlying) · 模拟盘 · \(Date())")
        let bridge = TradeBridge()
        guard await bridge.detectCLI() != nil, bridge.hasCredentials() else {
            fail("okx CLI", "未安装或未配置凭证"); return false
        }
        let venue = OKXVenue(bridge: bridge)

        // A strategy whose long signal is always on, so the first tick opens,
        // sized as a fixed premium spend so the contract count is predictable.
        let manifest = StrategyManifest(
            id: "e2e-option-demo",
            name: "模拟盘期权验收",
            market: StrategyMarket(instId: "\(base)-USDT", instType: .option, bar: .h1),
            signals: StrategySignals(longEntry: "close > 0"),
            sizing: StrategySizing(mode: .fixedQuote, value: budget),
            risk: StrategyRisk(stopLossPct: 50, takeProfitPct: 150, volLookbackBars: 24),
            options: StrategyOptionsSpec(
                uly: underlying, minDaysToExpiry: minDays, moneynessPct: moneyness))
        let strategy: CompiledStrategy
        do {
            strategy = try manifest.compile()
        } catch {
            fail("compile", String(describing: error)); return false
        }
        pass("清单", "买入 \(underlying) 到期 ≥ \(PriceFormatter.plain(minDays)) 天、偏离 "
             + "\(PriceFormatter.plain(moneyness))% 的看涨，权利金预算 \(PriceFormatter.money(budget)) USDT")
        var allOK = true

        // The premium is paid in the settlement coin, not the USDT the budget
        // is stated in. Say up front what the account holds and whether it
        // may borrow, so a refusal below reads as the account's state rather
        // than the code's.
        do {
            let config = try await venue.accountTradingConfig(mode: .demo)
            let held = try await venue.accountSnapshot(mode: .demo).balance(of: base)?.available ?? 0
            let level = config.accountLevel.map(String.init) ?? "—"
            let loan = config.autoLoan.map { $0 ? "开" : "关" } ?? "未知"
            let fundable = held > 0 || config.borrowsMissingCoin
            (fundable ? pass : fail)("结算币",
                "\(base) 可用 \(PriceFormatter.plain(held)) · 账户等级 \(level) · 自动借币 \(loan)"
                + (fundable ? "" : " —— 没有 \(base) 也不能借，运行器会在下单前拒绝并说明缺口"))
        } catch {
            fail("结算币", String(describing: error)); allOK = false
        }

        let host = await MainActor.run {
            DemoOptionHost(strategy: strategy, capital: capital, venue: venue)
        }
        let runner = await MainActor.run { StrategyRunner(host: host) }

        // --- 1. Open.
        await runner.tick()
        let entryState = await runner.state(for: strategy.id)
        print("  · 运行器：\(entryState.status.displayName) · \(entryState.message ?? "—")")
        let opened = await host.ledger.position(for: strategy.id)
        guard let opened, !opened.isFlat else {
            fail("开仓", "台账没有仓位：\(entryState.message ?? "无说明")")
            return false
        }
        pass("开仓入账", "\(opened.instId) \(PriceFormatter.plain(opened.quantity)) 张 · 权利金均价 "
             + "\(PriceFormatter.money(opened.averagePrice)) USDT/单位 · 手续费 "
             + "\(PriceFormatter.money(opened.feesPaid, decimals: 4)) USDT · 面值 "
             + "\(PriceFormatter.plain(opened.multiplier))")

        // The exchange's own view of the same position.
        do {
            let positions = try await venue.positions(mode: .demo, instType: .option)
            if let mine = positions.first(where: { $0.instId == opened.instId }) {
                let agree = abs(mine.quantity - opened.quantity) < 1e-9
                (agree ? pass : fail)("交易所持仓",
                    "\(mine.instId) \(PriceFormatter.plain(mine.quantity)) 张 · 均价 "
                    + "\(PriceFormatter.plain(mine.averagePrice)) \(base) · 标记 "
                    + "\(mine.markPrice.map(PriceFormatter.plain) ?? "—") · 浮盈 "
                    + "\(PriceFormatter.plain(mine.unrealisedPnL))")
                if !agree { allOK = false }
            } else {
                fail("交易所持仓", "交易所没有 \(opened.instId) 的仓位"); allOK = false
            }
        } catch {
            fail("交易所持仓", String(describing: error)); allOK = false
        }
        if let mark = try? await venue.valuationPrice(instId: opened.instId, mode: .demo) {
            pass("标记价（计价币/单位）", PriceFormatter.money(mark)
                 + " · 浮动盈亏 \(PriceFormatter.signedMoney(opened.unrealisedPnL(mark: mark)))")
        }

        // --- 2. Close, through the same path the studio's 平仓 button takes.
        await runner.flatten(strategyId: strategy.id, reason: "模拟盘验收平仓")
        let exitState = await runner.state(for: strategy.id)
        print("  · 运行器：\(exitState.status.displayName) · \(exitState.message ?? "—")")
        let closed = await host.ledger.position(for: strategy.id)
        if let closed, closed.isFlat {
            pass("平仓入账", "已实现 \(PriceFormatter.signedMoney(closed.realisedPnL)) USDT · 手续费合计 "
                 + "\(PriceFormatter.money(closed.feesPaid, decimals: 4)) · 净 "
                 + "\(PriceFormatter.signedMoney(closed.netPnL(mark: nil)))")
        } else {
            fail("平仓入账", "台账仍持有 \(PriceFormatter.plain(closed?.quantity ?? 0)) 张："
                 + (exitState.message ?? "无说明"))
            allOK = false
        }
        do {
            let positions = try await venue.positions(mode: .demo, instType: .option)
            if let left = positions.first(where: { $0.instId == opened.instId }), left.quantity != 0 {
                fail("交易所持仓", "仍有 \(PriceFormatter.plain(left.quantity)) 张 \(left.instId)，请到模拟盘手动处理")
                allOK = false
            } else {
                pass("交易所持仓", "已无 \(opened.instId) 仓位")
            }
        } catch {
            fail("交易所持仓", String(describing: error)); allOK = false
        }

        let fills = await host.ledger.fills(for: strategy.id)
        for fill in fills.reversed() {
            print("  · 成交 \(fill.actionLabel) \(PriceFormatter.plain(fill.quantity)) 张 @ "
                  + "\(PriceFormatter.money(fill.price)) USDT/单位 · 费 "
                  + "\(PriceFormatter.money(fill.feeQuote, decimals: 4)) · \(fill.clOrdId ?? "—")")
        }
        let halts = await host.halts
        for halt in halts { fail("熔断", halt) }
        if !halts.isEmpty { allOK = false }
        print(allOK ? "\noption demo: PASS" : "\noption demo: FAIL")
        return allOK
    }
}

/// An in-memory host for the demo round trip: one armed option strategy,
/// demo mode, live locked, nothing persisted.
@MainActor
final class DemoOptionHost: StrategyRunnerHost {
    var portfolio: StrategyPortfolioPrefs
    let liveTradingUnlocked = false
    var runnableStrategies: [CompiledStrategy]
    let ledger = StrategyLedger(mode: .demo)
    let venue: any ExchangeVenue
    var halts: [String] = []

    init(strategy: CompiledStrategy, capital: Double, venue: any ExchangeVenue) {
        var portfolio = StrategyPortfolioPrefs(mode: .demo, totalCapital: capital)
        portfolio.setCapital(capital, for: strategy.id)
        portfolio.setRunning(true, for: strategy.id)
        self.portfolio = portfolio
        self.runnableStrategies = [strategy]
        self.venue = venue
    }

    func runnerDidChange() {}
    func runnerDidCompleteTick(at ts: Date) {}
    func runnerDidHalt(strategyId: String, reason: String) { halts.append("\(strategyId)：\(reason)") }
    func runnerDidSampleEquity(_ equity: Double, at ts: Date) {}
    func runnerDidSampleStrategyEquity(_ strategyId: String, equity: Double, basis: Double, at ts: Date) {}
}

// MARK: - Helpers

/// Thread-safe event counter for the doctor run.
actor EventCounter {
    private(set) var ticks = 0
    private(set) var candles = 0
    private(set) var books = 0
    private(set) var errors = 0
    private(set) var errorDetail = ""
    private(set) var lastPrice: Double?

    func record(_ event: OKXWSEvent, socket: String) {
        guard case .message(let message) = event else { return }
        switch message {
        case .ticker(let t):
            ticks += 1
            lastPrice = t.last
        case .candles: candles += 1
        case .book: books += 1
        case .error(let code, let msg):
            errors += 1
            errorDetail += "[\(socket)] \(code): \(msg)  "
        default: break
        }
    }

    func satisfied() -> Bool { ticks >= 5 && candles >= 1 && books >= 3 }

    struct Stats {
        let ticks: Int, candles: Int, books: Int, errors: Int
        let lastPrice: Double?
    }

    func stats() -> Stats {
        Stats(ticks: ticks, candles: candles, books: books, errors: errors, lastPrice: lastPrice)
    }

    struct Summary {
        let ticker: String, candle: String, book: String, errors: String
    }

    func summary() -> Summary {
        Summary(
            ticker: "\(ticks) updates" + (lastPrice.map { ", last=\(PriceFormatter.auto($0))" } ?? ""),
            candle: "\(candles) pushes",
            book: "\(books) snapshots",
            errors: errorDetail)
    }
}

actor FiredBox {
    private(set) var events: [String] = []
    func append(_ s: String) { events.append(s) }
}
