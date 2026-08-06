import Foundation

// MARK: - Mandate

/// What the last walk-forward actually concluded about a strategy.
///
/// Recorded because a failed re-validation is not an event that fires once and
/// is gone — it is a standing condition, and a condition nobody is reminded of
/// quietly becomes the status quo. A strategy carrying `.failed` while armed is
/// re-reported on every pass until a person resolves it one way or the other.
public enum MandateVerdict: String, Codable, Sendable, CaseIterable {
    /// Out-of-sample folds were profitable and the efficiency ratio held up.
    case validated
    /// The protocol could not be run — usually the warmup does not fit inside
    /// a fold's out-of-sample segment. Not a pass; an inability to test.
    case inconclusive
    /// The protocol ran and the strategy lost out of sample.
    case failed

    public var label: String {
        switch self {
        case .validated: return "已验证"
        case .inconclusive: return "无法判定"
        case .failed: return "未通过"
        }
    }
}

/// What one strategy was allowed to do, decided *before* it started running.
///
/// The whole point of writing this down is that the numbers stop being
/// negotiable afterwards. A drawdown budget chosen while watching the position
/// lose money is not a risk limit, it is a rationalisation — so the limit is
/// recorded here with the date and the evidence it came from, and the review
/// only ever compares against it.
public struct StrategyMandate: Codable, Sendable, Equatable {
    public var strategyId: String
    /// The strategy's own decision cadence. A 1D strategy that is reviewed
    /// hourly is being looked at 23 times between two thoughts.
    public var barSeconds: TimeInterval
    /// Drawdown budget, from the Monte-Carlo resample's 95th percentile rather
    /// than the single backtest path. The backtest drew one ordering of the
    /// trades; the p95 says how bad a *different* ordering of the same trades
    /// gets, which is the number a live account actually has to survive.
    public var resampleP95DrawdownPct: Double
    /// What the backtest drew, kept for contrast — if live exceeds this but is
    /// inside p95, the strategy is behaving as designed and the backtest was
    /// simply a lucky ordering.
    public var backtestDrawdownPct: Double
    /// Expected round trips per week, from the same backtest. A strategy that
    /// has gone quiet is as broken as one that is losing.
    public var expectedTradesPerWeek: Double
    /// What the backtest says this strategy earns in a year, in percent.
    ///
    /// Not a promise — it is the denominator in "how long until an hour of P&L
    /// means anything", and that question needs a claimed edge to divide by.
    public var expectedAnnualReturnPct: Double
    /// When the walk-forward evidence behind this mandate was last refreshed.
    public var validatedAt: Date
    /// What that walk-forward concluded.
    public var verdict: MandateVerdict
    /// One line on what that evidence actually said, so a halt notice can quote
    /// the reason rather than a bare threshold.
    public var evidence: String

    public init(
        strategyId: String,
        barSeconds: TimeInterval,
        resampleP95DrawdownPct: Double,
        backtestDrawdownPct: Double,
        expectedTradesPerWeek: Double,
        expectedAnnualReturnPct: Double,
        validatedAt: Date,
        verdict: MandateVerdict = .inconclusive,
        evidence: String
    ) {
        self.strategyId = strategyId
        self.barSeconds = barSeconds
        self.resampleP95DrawdownPct = resampleP95DrawdownPct
        self.backtestDrawdownPct = backtestDrawdownPct
        self.expectedTradesPerWeek = expectedTradesPerWeek
        self.expectedAnnualReturnPct = expectedAnnualReturnPct
        self.validatedAt = validatedAt
        self.verdict = verdict
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case strategyId, barSeconds, resampleP95DrawdownPct, backtestDrawdownPct
        case expectedTradesPerWeek, expectedAnnualReturnPct, validatedAt, verdict, evidence
    }

    /// An absent verdict decodes as `.inconclusive`, never as `.validated`:
    /// a mandate written before this field existed carries no evidence that it
    /// passed, and the missing value must not be read as one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strategyId = try c.decode(String.self, forKey: .strategyId)
        barSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .barSeconds) ?? 86_400
        resampleP95DrawdownPct = try c.decodeIfPresent(
            Double.self, forKey: .resampleP95DrawdownPct) ?? 0
        backtestDrawdownPct = try c.decodeIfPresent(Double.self, forKey: .backtestDrawdownPct) ?? 0
        expectedTradesPerWeek = try c.decodeIfPresent(
            Double.self, forKey: .expectedTradesPerWeek) ?? 0
        expectedAnnualReturnPct = try c.decodeIfPresent(
            Double.self, forKey: .expectedAnnualReturnPct) ?? 0
        validatedAt = try c.decodeIfPresent(Date.self, forKey: .validatedAt)
            ?? Date(timeIntervalSince1970: 0)
        verdict = try c.decodeIfPresent(MandateVerdict.self, forKey: .verdict) ?? .inconclusive
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
    }

    /// Bars of new data since the mandate was last validated — the only honest
    /// measure of how much genuinely new evidence exists.
    public func barsSinceValidation(now: Date) -> Int {
        guard barSeconds > 0 else { return 0 }
        return Swift.max(Int(now.timeIntervalSince(validatedAt) / barSeconds), 0)
    }
}

// MARK: - Policy

/// The pre-registered rulebook the unattended review runs against.
///
/// Every threshold here is a decision made once, in advance, and then merely
/// *applied* on a schedule. That split is the entire design: an hourly job that
/// re-decides its own thresholds is not monitoring, it is 8,760 fresh chances a
/// year to talk itself into a trade — which is exactly the multiple-comparisons
/// failure the Deflated Sharpe machinery exists to punish.
///
/// It lives on disk beside the config so the numbers are auditable, and so
/// changing one is a visible edit with a date on it rather than a judgement
/// call made quietly at 3am.
public struct ReviewPolicy: Codable, Sendable, Equatable {
    /// Bumped when a field changes meaning, so an old file is never silently
    /// reinterpreted under new semantics.
    public var version: Int
    public var writtenAt: Date
    /// Free-text note on why this revision exists.
    public var note: String

    // MARK: Liveness

    /// No completed tick for this long, while something is armed, means the
    /// engine is not trading. Three times the runner's own 300s timeout: a
    /// laptop that slept through a few ticks is not an incident.
    public var heartbeatStaleAfter: TimeInterval
    /// A hole in the equity curve longer than this makes the chart lie — it
    /// draws a straight line across the gap, which reads as a calm market
    /// rather than as an engine that was not running.
    public var equityGapAlarm: TimeInterval

    // MARK: Exposure

    /// Allocated capital as a multiple of the pot. Above 1.0 the budgets are
    /// promises the account cannot keep.
    public var maxAllocationRatio: Double
    /// Warn at this fraction of the account drawdown breaker, so the breaker
    /// firing is never the first anyone hears of it.
    public var drawdownWarnFraction: Double
    /// Annualised funding cost, as a percentage of position notional, above
    /// which a carry position is bleeding faster than its edge can pay for.
    public var fundingBleedAnnualPct: Double

    // MARK: Acting on evidence

    /// A per-strategy drawdown halt needs at least this many of the strategy's
    /// own bars of live history behind it. Without a floor the rule fires on
    /// the first bad hour of a 1D strategy, which is noise wearing a threshold
    /// as a costume.
    public var minimumLiveBarsBeforeHalt: Int
    /// Bars of genuinely new data before re-running the walk-forward is worth
    /// anything. 63 daily bars ≈ one quarter: enough that the fit sees a
    /// window it has never seen, rather than the same window plus rounding.
    public var revalidateAfterBars: Int
    /// An armed strategy that has not traded for this many of its own bars has
    /// probably stopped receiving signals — a silence worth a look even though
    /// nothing errored.
    public var silentTradeAlarmBars: Int

    // MARK: Reference values

    /// Slippage measured from real fills. Config drifting away from it means
    /// backtests and live are being judged under different economics.
    public var measuredSlippageBps: Double
    /// How far the configured value may drift before that matters.
    public var slippageDriftBps: Double

    public var mandates: [StrategyMandate]

    public init(
        version: Int = ReviewPolicy.currentVersion,
        writtenAt: Date = Date(),
        note: String = "",
        heartbeatStaleAfter: TimeInterval = 900,
        equityGapAlarm: TimeInterval = 1_800,
        maxAllocationRatio: Double = 1.0,
        drawdownWarnFraction: Double = 0.6,
        fundingBleedAnnualPct: Double = 30,
        minimumLiveBarsBeforeHalt: Int = 20,
        revalidateAfterBars: Int = 63,
        silentTradeAlarmBars: Int = 10,
        measuredSlippageBps: Double = 1.0,
        slippageDriftBps: Double = 2.0,
        mandates: [StrategyMandate] = []
    ) {
        self.version = version
        self.writtenAt = writtenAt
        self.note = note
        self.heartbeatStaleAfter = heartbeatStaleAfter
        self.equityGapAlarm = equityGapAlarm
        self.maxAllocationRatio = maxAllocationRatio
        self.drawdownWarnFraction = drawdownWarnFraction
        self.fundingBleedAnnualPct = fundingBleedAnnualPct
        self.minimumLiveBarsBeforeHalt = minimumLiveBarsBeforeHalt
        self.revalidateAfterBars = revalidateAfterBars
        self.silentTradeAlarmBars = silentTradeAlarmBars
        self.measuredSlippageBps = measuredSlippageBps
        self.slippageDriftBps = slippageDriftBps
        self.mandates = mandates
    }

    public static let currentVersion = 1

    public func mandate(for strategyId: String) -> StrategyMandate? {
        mandates.first { $0.strategyId == strategyId }
    }

    private enum CodingKeys: String, CodingKey {
        case version, writtenAt, note
        case heartbeatStaleAfter, equityGapAlarm
        case maxAllocationRatio, drawdownWarnFraction, fundingBleedAnnualPct
        case minimumLiveBarsBeforeHalt, revalidateAfterBars, silentTradeAlarmBars
        case measuredSlippageBps, slippageDriftBps
        case mandates
    }

    /// Every field decodes with a default. A protective threshold that is
    /// absent has to mean "the default", never "off" — a policy file written
    /// before a check existed should gain the check, not opt out of it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ReviewPolicy()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        writtenAt = try c.decodeIfPresent(Date.self, forKey: .writtenAt) ?? Date(timeIntervalSince1970: 0)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        heartbeatStaleAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .heartbeatStaleAfter)
            ?? fallback.heartbeatStaleAfter
        equityGapAlarm = try c.decodeIfPresent(TimeInterval.self, forKey: .equityGapAlarm)
            ?? fallback.equityGapAlarm
        maxAllocationRatio = try c.decodeIfPresent(Double.self, forKey: .maxAllocationRatio)
            ?? fallback.maxAllocationRatio
        drawdownWarnFraction = try c.decodeIfPresent(Double.self, forKey: .drawdownWarnFraction)
            ?? fallback.drawdownWarnFraction
        fundingBleedAnnualPct = try c.decodeIfPresent(Double.self, forKey: .fundingBleedAnnualPct)
            ?? fallback.fundingBleedAnnualPct
        minimumLiveBarsBeforeHalt = try c.decodeIfPresent(Int.self, forKey: .minimumLiveBarsBeforeHalt)
            ?? fallback.minimumLiveBarsBeforeHalt
        revalidateAfterBars = try c.decodeIfPresent(Int.self, forKey: .revalidateAfterBars)
            ?? fallback.revalidateAfterBars
        silentTradeAlarmBars = try c.decodeIfPresent(Int.self, forKey: .silentTradeAlarmBars)
            ?? fallback.silentTradeAlarmBars
        measuredSlippageBps = try c.decodeIfPresent(Double.self, forKey: .measuredSlippageBps)
            ?? fallback.measuredSlippageBps
        slippageDriftBps = try c.decodeIfPresent(Double.self, forKey: .slippageDriftBps)
            ?? fallback.slippageDriftBps
        mandates = try c.decodeIfPresent([StrategyMandate].self, forKey: .mandates) ?? []
    }
}

// MARK: - Persistence

public struct ReviewPolicyStore: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("review-policy.json")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// Absent file means the defaults, not "no policy". Unattended code that
    /// finds no rulebook must not conclude it is unconstrained.
    public func load() -> ReviewPolicy {
        guard let data = try? Data(contentsOf: fileURL) else { return ReviewPolicy() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ReviewPolicy.self, from: data)) ?? ReviewPolicy()
    }

    public func save(_ policy: ReviewPolicy) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(policy).write(to: fileURL, options: .atomic)
    }
}
