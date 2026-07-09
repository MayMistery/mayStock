import Foundation
import Observation

/// Evaluates alert rules against live ticks.
///
/// Correctness details:
/// - Cross rules (`priceAbove`/`priceBelow`) only fire on an actual *cross*:
///   the previous evaluated price must have been on the other side, with a
///   0.05% hysteresis band so jitter around the threshold can't machine-gun.
/// - One-shot rules disable themselves after firing; recurring rules re-arm
///   after `rearmAfterSeconds`.
@Observable
@MainActor
public final class AlertEngine {
    public private(set) var rules: [AlertRule] = []
    /// Recent fired events, newest first (bounded).
    public private(set) var recentEvents: [AlertEvent] = []

    /// Delivery — notifications, sounds, shell hooks (wired by the app/CLI).
    public var onAlert: ((AlertEvent) -> Void)?
    /// Persist rule state changes (fired timestamps, auto-disable).
    public var onRulesChanged: (([AlertRule]) -> Void)?

    private var lastPrice: [String: Double] = [:]
    private static let hysteresisPct = 0.05

    public init() {}

    public func setRules(_ new: [AlertRule]) {
        rules = new
    }

    public func rules(for instId: String) -> [AlertRule] {
        rules.filter { $0.instId == instId }
    }

    public func add(_ rule: AlertRule) {
        rules.append(rule)
        onRulesChanged?(rules)
    }

    public func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        onRulesChanged?(rules)
    }

    public func update(_ rule: AlertRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
        onRulesChanged?(rules)
    }

    /// Feed one tick. `spark` powers window-move conditions.
    public func evaluate(instId: String, ticker: Ticker, spark: SparklineBuffer, now: Date = Date()) {
        defer { lastPrice[instId] = ticker.last }
        let previous = lastPrice[instId]

        for idx in rules.indices where rules[idx].instId == instId {
            guard rules[idx].enabled else { continue }
            if let fired = rules[idx].lastTriggeredAt {
                guard let rearm = rules[idx].rearmAfterSeconds,
                      now.timeIntervalSince(fired) >= rearm else { continue }
                // Re-armed: clear and keep evaluating this tick.
                rules[idx].lastTriggeredAt = nil
            }

            guard shouldFire(rules[idx].condition, ticker: ticker, previous: previous, spark: spark, now: now) else {
                continue
            }

            rules[idx].lastTriggeredAt = now
            if rules[idx].rearmAfterSeconds == nil {
                rules[idx].enabled = false // one-shot
            }
            let event = AlertEvent(rule: rules[idx], price: ticker.last, firedAt: now)
            recentEvents.insert(event, at: 0)
            if recentEvents.count > 50 { recentEvents.removeLast() }
            onAlert?(event)
        }
        onRulesChanged?(rules)
    }

    private func shouldFire(
        _ condition: AlertRule.Condition,
        ticker: Ticker,
        previous: Double?,
        spark: SparklineBuffer,
        now: Date
    ) -> Bool {
        let price = ticker.last
        switch condition {
        case .priceAbove(let threshold):
            let band = threshold * Self.hysteresisPct / 100
            guard let previous else { return false }
            return previous < threshold - band && price >= threshold

        case .priceBelow(let threshold):
            let band = threshold * Self.hysteresisPct / 100
            guard let previous else { return false }
            return previous > threshold + band && price <= threshold

        case .changePct24hAbove(let pct):
            return ticker.changePct24h >= pct

        case .changePct24hBelow(let pct):
            return ticker.changePct24h <= pct

        case .movePctWithin(let minutes, let pct):
            guard let move = spark.movePct(minutes: minutes, now: now) else { return false }
            return abs(move) >= abs(pct)
        }
    }
}
