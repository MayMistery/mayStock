import Foundation

/// A price/movement alert attached to one instrument.
public struct AlertRule: Codable, Identifiable, Sendable, Equatable {
    /// What fires the alert.
    public enum Condition: Codable, Sendable, Equatable {
        /// Last price crosses above the threshold (requires having been below).
        case priceAbove(Double)
        /// Last price crosses below the threshold (requires having been above).
        case priceBelow(Double)
        /// The ticker's change (percent) rises to or above the threshold,
        /// e.g. `5` = +5%. What the change is measured from is the venue's
        /// business — the trailing day on OKX, the previous close on a stock
        /// exchange — so the case keeps its historical name on disk and the
        /// summary reads the period off the ticker's basis.
        case changePct24hAbove(Double)
        /// The ticker's change (percent) falls to or below the threshold, e.g. `-5`.
        case changePct24hBelow(Double)
        /// |price move| within the trailing window reaches `pct` percent.
        case movePctWithin(windowMinutes: Int, pct: Double)

        /// One-line description, with the change period named the way the
        /// instrument's venue frames it.
        public func summary(basis: ChangeBasis) -> String {
            switch self {
            case .priceAbove(let v): return "≥ \(PriceFormatter.plain(v))"
            case .priceBelow(let v): return "≤ \(PriceFormatter.plain(v))"
            case .changePct24hAbove(let v): return "\(basis.periodLabel) ≥ +\(PriceFormatter.plain(v))%"
            case .changePct24hBelow(let v): return "\(basis.periodLabel) ≤ \(PriceFormatter.plain(v))%"
            case .movePctWithin(let m, let p): return "±\(PriceFormatter.plain(p))% / \(m)m"
            }
        }
    }

    public var id: UUID
    public var instId: String
    public var condition: Condition
    public var note: String
    public var playSound: Bool
    /// Optional shell command executed on trigger. MayStock injects
    /// `MAYSTOCK_INSTID`, `MAYSTOCK_PRICE`, `MAYSTOCK_RULE` environment
    /// variables — handy for chaining the official `okx` CLI.
    public var shellHook: String?
    /// `nil` = one-shot (disables itself after firing); otherwise the rule
    /// re-arms after this many seconds.
    public var rearmAfterSeconds: TimeInterval?
    public var enabled: Bool
    public var lastTriggeredAt: Date?

    public init(
        id: UUID = UUID(),
        instId: String,
        condition: Condition,
        note: String = "",
        playSound: Bool = true,
        shellHook: String? = nil,
        rearmAfterSeconds: TimeInterval? = nil,
        enabled: Bool = true,
        lastTriggeredAt: Date? = nil
    ) {
        self.id = id
        self.instId = instId
        self.condition = condition
        self.note = note
        self.playSound = playSound
        self.shellHook = shellHook
        self.rearmAfterSeconds = rearmAfterSeconds
        self.enabled = enabled
        self.lastTriggeredAt = lastTriggeredAt
    }
}

/// Emitted by `AlertEngine` when a rule fires.
public struct AlertEvent: Sendable, Equatable {
    public let rule: AlertRule
    public let price: Double
    /// How the ticker that fired it frames a change, for the summary.
    public let basis: ChangeBasis
    public let firedAt: Date

    public init(rule: AlertRule, price: Double, basis: ChangeBasis, firedAt: Date = Date()) {
        self.rule = rule
        self.price = price
        self.basis = basis
        self.firedAt = firedAt
    }

    public var summary: String { rule.condition.summary(basis: basis) }
    public var title: String { "\(rule.instId)  \(summary)" }

    public var body: String {
        let p = "现价 \(PriceFormatter.plain(price))"
        return rule.note.isEmpty ? p : "\(rule.note) · \(p)"
    }
}
