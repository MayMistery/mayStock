import Foundation
import MayStockKit

/// MayStock end-to-end driver & diagnostics CLI.
///
///   maystock-e2e doctor [instId]       full pipeline check against live OKX
///   maystock-e2e watch <instId> [sec]  stream live ticks to stdout
///   maystock-e2e alert-sim             alert engine simulation (offline)
///   maystock-e2e trade-doctor          okx CLI detection + public call
///
/// Exit code 0 = pass. Non-zero = failure (CI-friendly).
@main
struct E2EMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "doctor"
        let ok: Bool
        switch command {
        case "doctor":
            ok = await doctor(instId: args.count > 1 ? args[1] : "BTC-USDT")
        case "watch":
            ok = await watch(instId: args.count > 1 ? args[1] : "BTC-USDT",
                             seconds: args.count > 2 ? Int(args[2]) ?? 15 : 15)
        case "alert-sim":
            ok = await alertSim()
        case "trade-doctor":
            ok = await tradeDoctor()
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
                 "24h=\(PriceFormatter.signedPercent(ticker.changePct24h)) " +
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
                let arrow = t.changePct24h >= 0 ? "↑" : "↓"
                print("\(t.ts)  \(t.instId)  \(PriceFormatter.auto(t.last))  " +
                      "\(arrow)\(PriceFormatter.signedPercent(t.changePct24h))")
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
            engine.onAlert = { event in Task { await fired.append(event.rule.condition.summary) } }
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
                                    open24h: 100, high24h: 110, low24h: 90, vol24h: 0, ts: ts)
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
