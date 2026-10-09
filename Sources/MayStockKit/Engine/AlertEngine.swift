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
    /// Recent fired events, newest first: the newest `recentLimit`, and every
    /// older one still pending — the list never drops an alert nobody has seen.
    public private(set) var recentEvents: [AlertEvent] = []
    /// How far each instrument's alerts have been acknowledged, in firing
    /// order (`AlertEvent.sequence`) — by a left click on its menu bar item,
    /// or 全部确认 on the alerts page. Runtime only, like the events: a
    /// restart does not resurrect alerts nobody saw fire.
    public private(set) var acknowledgedThrough: [String: Int] = [:]
    /// Alerts fired since launch; each event carries the count at its firing.
    private var fired = 0

    public static let recentLimit = 50

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

    // MARK: Attention

    /// Whether `event` fired after its instrument's alerts were last
    /// acknowledged. The one rule the menu bar's red state, its count and the
    /// alerts page's marks all read. Firing order, not clock time: an event
    /// stamped by a tick's own clock (a replay, a simulation) is acknowledged
    /// by the click that came after it, whatever its stamp says.
    public func isPending(_ event: AlertEvent) -> Bool {
        event.sequence > (acknowledgedThrough[event.rule.instId] ?? 0)
    }

    /// How many alerts on `instId` nobody has acknowledged yet.
    public func pendingCount(for instId: String) -> Int {
        recentEvents.reduce(0) { $0 + ($1.rule.instId == instId && isPending($1) ? 1 : 0) }
    }

    /// Every alert nobody has acknowledged yet, newest first.
    public var pendingEvents: [AlertEvent] { recentEvents.filter(isPending) }

    /// Acknowledge every alert fired on `instId` so far; one fired later is a
    /// new alert. Returns how many it cleared.
    @discardableResult
    public func acknowledge(instId: String) -> Int {
        let cleared = pendingCount(for: instId)
        guard cleared > 0 else { return 0 }
        acknowledgedThrough[instId] = fired
        trimRecent()
        Log.warn("alert: 已确认 \(instId) 的 \(cleared) 条告警")
        return cleared
    }

    /// Acknowledge every pending alert, whatever the instrument.
    @discardableResult
    public func acknowledgeAll() -> Int {
        Set(pendingEvents.map(\.rule.instId)).reduce(0) { $0 + acknowledge(instId: $1) }
    }

    /// The newest `recentLimit` events, and every older one still pending.
    private func trimRecent() {
        guard recentEvents.count > Self.recentLimit else { return }
        recentEvents = recentEvents.enumerated()
            .filter { $0.offset < Self.recentLimit || isPending($0.element) }
            .map(\.element)
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
            fired += 1
            let event = AlertEvent(rule: rules[idx], price: ticker.last, basis: ticker.basis, firedAt: now, sequence: fired)
            recentEvents.insert(event, at: 0)
            trimRecent()
            Log.warn("alert: 触发 \(event.title) · \(event.body)")
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
            return ticker.changePct >= pct

        case .changePct24hBelow(let pct):
            return ticker.changePct <= pct

        case .movePctWithin(let minutes, let pct):
            guard let move = spark.movePct(minutes: minutes, now: now) else { return false }
            return abs(move) >= abs(pct)
        }
    }
}
