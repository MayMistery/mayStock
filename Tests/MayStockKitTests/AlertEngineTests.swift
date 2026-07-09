import Foundation
import Testing
@testable import MayStockKit

@Suite("Alert engine")
@MainActor
struct AlertEngineTests {
    private func tick(_ price: Double, at ts: Date) -> Ticker {
        Ticker(instId: "T-USDT", last: price, bid: nil, ask: nil,
               open24h: 100, high24h: 120, low24h: 80, vol24h: 0, ts: ts)
    }

    @Test func priceAboveFiresOnCrossOnly() {
        let engine = AlertEngine()
        var fired: [AlertEvent] = []
        engine.onAlert = { fired.append($0) }
        engine.setRules([AlertRule(instId: "T-USDT", condition: .priceAbove(105), rearmAfterSeconds: 10)])

        let spark = SparklineBuffer()
        let t0 = Date(timeIntervalSince1970: 0)
        // Starting already above the threshold must NOT fire (no cross seen).
        engine.evaluate(instId: "T-USDT", ticker: tick(106, at: t0), spark: spark, now: t0)
        #expect(fired.isEmpty)
        // Dip below, then cross up → fires exactly once.
        engine.evaluate(instId: "T-USDT", ticker: tick(104, at: t0 + 1), spark: spark, now: t0 + 1)
        engine.evaluate(instId: "T-USDT", ticker: tick(105.5, at: t0 + 2), spark: spark, now: t0 + 2)
        #expect(fired.count == 1)
        #expect(fired.first?.price == 105.5)
        // Still above: no re-fire during cooldown.
        engine.evaluate(instId: "T-USDT", ticker: tick(107, at: t0 + 3), spark: spark, now: t0 + 3)
        #expect(fired.count == 1)
        // After rearm window: needs another full cross.
        engine.evaluate(instId: "T-USDT", ticker: tick(104, at: t0 + 20), spark: spark, now: t0 + 20)
        engine.evaluate(instId: "T-USDT", ticker: tick(106, at: t0 + 21), spark: spark, now: t0 + 21)
        #expect(fired.count == 2)
    }

    @Test func hysteresisSuppressesJitter() {
        let engine = AlertEngine()
        var fired: [AlertEvent] = []
        engine.onAlert = { fired.append($0) }
        engine.setRules([AlertRule(instId: "T-USDT", condition: .priceAbove(100_000), rearmAfterSeconds: 0)])

        let spark = SparklineBuffer()
        let t0 = Date(timeIntervalSince1970: 0)
        engine.evaluate(instId: "T-USDT", ticker: tick(99_990, at: t0), spark: spark, now: t0)
        // 99,990 is inside the 0.05% band (99,950): micro-jitter must not fire.
        engine.evaluate(instId: "T-USDT", ticker: tick(100_001, at: t0 + 1), spark: spark, now: t0 + 1)
        #expect(fired.isEmpty)
        // A move from clearly below does fire.
        engine.evaluate(instId: "T-USDT", ticker: tick(99_900, at: t0 + 2), spark: spark, now: t0 + 2)
        engine.evaluate(instId: "T-USDT", ticker: tick(100_050, at: t0 + 3), spark: spark, now: t0 + 3)
        #expect(fired.count == 1)
    }

    @Test func oneShotDisablesItself() {
        let engine = AlertEngine()
        var fired = 0
        engine.onAlert = { _ in fired += 1 }
        engine.setRules([AlertRule(instId: "T-USDT", condition: .priceBelow(95), rearmAfterSeconds: nil)])

        let spark = SparklineBuffer()
        let t0 = Date(timeIntervalSince1970: 0)
        engine.evaluate(instId: "T-USDT", ticker: tick(100, at: t0), spark: spark, now: t0)
        engine.evaluate(instId: "T-USDT", ticker: tick(94, at: t0 + 1), spark: spark, now: t0 + 1)
        #expect(fired == 1)
        #expect(engine.rules.first?.enabled == false)
        // Even a fresh cross cannot re-fire a disabled one-shot.
        engine.evaluate(instId: "T-USDT", ticker: tick(100, at: t0 + 2), spark: spark, now: t0 + 2)
        engine.evaluate(instId: "T-USDT", ticker: tick(94, at: t0 + 3), spark: spark, now: t0 + 3)
        #expect(fired == 1)
    }

    @Test func movePctWithinWindow() {
        let engine = AlertEngine()
        var fired = 0
        engine.onAlert = { _ in fired += 1 }
        engine.setRules([AlertRule(
            instId: "T-USDT",
            condition: .movePctWithin(windowMinutes: 5, pct: 1.0),
            rearmAfterSeconds: 600)])

        var spark = SparklineBuffer(capacity: 1000, minInterval: 1)
        let t0 = Date(timeIntervalSince1970: 100_000)
        // Flat for 4 minutes…
        for i in 0..<240 {
            spark.sample(price: 100, at: t0.addingTimeInterval(Double(i)))
        }
        let flatNow = t0.addingTimeInterval(239)
        engine.evaluate(instId: "T-USDT", ticker: tick(100, at: flatNow), spark: spark, now: flatNow)
        #expect(fired == 0)
        // …then a 1.5% pop inside the window.
        let popAt = t0.addingTimeInterval(250)
        spark.sample(price: 101.5, at: popAt)
        engine.evaluate(instId: "T-USDT", ticker: tick(101.5, at: popAt), spark: spark, now: popAt)
        #expect(fired == 1)
    }

    @Test func rulesAreScopedPerInstrument() {
        let engine = AlertEngine()
        var fired = 0
        engine.onAlert = { _ in fired += 1 }
        engine.setRules([AlertRule(instId: "OTHER-USDT", condition: .priceAbove(1))])
        let spark = SparklineBuffer()
        let t0 = Date()
        engine.evaluate(instId: "T-USDT", ticker: tick(0.5, at: t0), spark: spark, now: t0)
        engine.evaluate(instId: "T-USDT", ticker: tick(2, at: t0 + 1), spark: spark, now: t0 + 1)
        #expect(fired == 0)
    }
}
