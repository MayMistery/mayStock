import Foundation

// MARK: - Windows

public enum BacktestWindow: String, CaseIterable, Sendable, Identifiable, Codable, Hashable {
    case d1, d7, d30, d90, d365

    public var id: String { rawValue }

    public var days: Int {
        switch self {
        case .d1: return 1
        case .d7: return 7
        case .d30: return 30
        case .d90: return 90
        case .d365: return 365
        }
    }

    public var displayName: String {
        switch self {
        case .d1: return "1 日"
        case .d7: return "7 日"
        case .d30: return "30 日"
        case .d90: return "90 日"
        case .d365: return "1 年"
        }
    }

    /// The three windows the user asked to see up front; the longer two exist
    /// to give the robustness grade something statistically meaningful to chew on.
    public var isHeadline: Bool { self == .d1 || self == .d7 || self == .d30 }

    public static let headline: [BacktestWindow] = [.d1, .d7, .d30]
}

// MARK: - Robustness

public enum RobustnessGrade: String, Sendable, Codable, Equatable {
    case insufficientData
    case overfitSuspect
    case indicative
    case robust

    public var displayName: String {
        switch self {
        case .insufficientData: return "样本不足"
        case .overfitSuspect: return "疑似过拟合"
        case .indicative: return "可参考"
        case .robust: return "稳健"
        }
    }

    public var explanation: String {
        switch self {
        case .insufficientData:
            return "交易笔数不足以支撑统计判断，回测数字此时更像噪声而非证据。"
        case .overfitSuspect:
            return "样本外表现显著弱于样本内，或夏普高得不合常理 —— 典型的参数拟合历史。"
        case .indicative:
            return "样本量达标且未见明显过拟合迹象，可作为参考，但仍需小仓位验证。"
        case .robust:
            return "样本充足、样本外衰减可控、各窗口方向一致 —— 在可检验的范围内表现稳健。"
        }
    }
}

/// Why a strategy earned its grade, in numbers the user can argue with.
public struct RobustnessAssessment: Sendable, Equatable {
    public let grade: RobustnessGrade
    public let observedTrades: Int
    public let requiredTrades: Int
    public let inSampleSharpe: Double
    public let outOfSampleSharpe: Double
    /// `OOS Sharpe / IS Sharpe`; below 0.5 means the edge did not survive
    /// leaving the data it was fitted on.
    public let outOfSampleEfficiency: Double
    /// Share of evaluated windows whose return sign matches the longest window.
    public let windowAgreement: Double
    public let notes: [String]

    public init(
        grade: RobustnessGrade, observedTrades: Int, requiredTrades: Int,
        inSampleSharpe: Double, outOfSampleSharpe: Double,
        outOfSampleEfficiency: Double, windowAgreement: Double, notes: [String]
    ) {
        self.grade = grade
        self.observedTrades = observedTrades
        self.requiredTrades = requiredTrades
        self.inSampleSharpe = inSampleSharpe
        self.outOfSampleSharpe = outOfSampleSharpe
        self.outOfSampleEfficiency = outOfSampleEfficiency
        self.windowAgreement = windowAgreement
        self.notes = notes
    }

    public var sampleAdequacy: Double {
        requiredTrades > 0 ? Double(observedTrades) / Double(requiredTrades) : 0
    }

    public static let unavailable = RobustnessAssessment(
        grade: .insufficientData, observedTrades: 0, requiredTrades: 30,
        inSampleSharpe: 0, outOfSampleSharpe: 0, outOfSampleEfficiency: 0,
        windowAgreement: 0, notes: ["尚未回测"])

    /// Thresholds follow the published consensus on backtest validation:
    /// ≥30 independent trades per free parameter, Sharpe > 3 as a red flag,
    /// and out-of-sample efficiency ≥ 0.5.
    public static func evaluate(
        results: [BacktestWindow: BacktestResult], bar: BarInterval, freeParameterCount: Int
    ) -> RobustnessAssessment {
        let ranked = BacktestWindow.allCases.sorted { $0.days > $1.days }
        guard let primaryWindow = ranked.first(where: { results[$0] != nil }),
              let primary = results[primaryWindow] else { return .unavailable }

        let required = Swift.max(freeParameterCount, 1) * 30
        let observed = primary.trades.count
        var notes: [String] = []

        // --- Out-of-sample split: fit on the first 70%, judge on the last 30%.
        let curve = primary.equityCurve
        let splitIndex = Int(Double(curve.count) * 0.7)
        let inSample = Array(curve.prefix(splitIndex))
        let outOfSample = Array(curve.suffix(from: Swift.min(splitIndex, curve.count)))
        let isSharpe = Self.sharpe(of: inSample, bar: bar)
        let oosSharpe = Self.sharpe(of: outOfSample, bar: bar)
        let efficiency: Double
        if isSharpe > 0.01 {
            efficiency = oosSharpe / isSharpe
        } else if oosSharpe > 0 {
            efficiency = 1        // no in-sample edge to lose
        } else {
            efficiency = 0
        }

        // --- Direction agreement across the windows that actually traded.
        let traded = results.filter { $0.value.trades.count > 0 }
        let reference = primary.metrics.totalReturnPct >= 0
        let agreeing = traded.values.filter { ($0.metrics.totalReturnPct >= 0) == reference }.count
        let agreement = traded.isEmpty ? 0 : Double(agreeing) / Double(traded.count)

        // --- Grade, most severe finding first.
        var grade: RobustnessGrade
        if observed == 0 {
            grade = .insufficientData
            notes.append("最长窗口内没有产生任何交易 —— 无法判断这套规则是否有效。")
        } else if observed < required {
            grade = .insufficientData
            notes.append("交易 \(observed) 笔，\(freeParameterCount) 个自由参数需要至少 \(required) 笔才有统计意义。")
        } else if isSharpe > 3 {
            grade = .overfitSuspect
            notes.append("样本内夏普 \(PriceFormatter.decimals(isSharpe, 2)) > 3，真实策略罕有此表现。")
        } else if efficiency < 0.5 {
            grade = .overfitSuspect
            notes.append("样本外夏普仅为样本内的 \(PriceFormatter.percent(efficiency * 100))，衰减过大。")
        } else if agreement >= 0.6 {
            grade = .robust
        } else {
            grade = .indicative
            notes.append("各窗口收益方向不一致（\(PriceFormatter.percent(agreement * 100)) 同向），结论对区间选择敏感。")
        }

        if primary.liquidations > 0 {
            notes.append("回测期内发生 \(primary.liquidations) 次强平 —— 杠杆或止损设置需要复核。")
        }
        if primary.fundingUnmodelled {
            notes.append("未取到资金费率历史，永续的持仓成本被低估。")
        }
        if grade == .robust, notes.isEmpty {
            notes.append("样本 \(observed) 笔（阈值 \(required)），样本外效率 \(PriceFormatter.decimals(efficiency, 2))。")
        }

        return RobustnessAssessment(
            grade: grade, observedTrades: observed, requiredTrades: required,
            inSampleSharpe: isSharpe, outOfSampleSharpe: oosSharpe,
            outOfSampleEfficiency: efficiency, windowAgreement: agreement, notes: notes)
    }

    private static func sharpe(of curve: [EquityPoint], bar: BarInterval) -> Double {
        guard curve.count > 2 else { return 0 }
        var returns: [Double] = []
        returns.reserveCapacity(curve.count - 1)
        for index in 1..<curve.count where curve[index - 1].equity > 0 {
            returns.append(curve[index].equity / curve[index - 1].equity - 1)
        }
        let mean = Statistics.mean(returns)
        let deviation = Statistics.standardDeviation(returns, mean: mean)
        guard deviation > 0 else { return 0 }
        return mean / deviation * (365.25 * 86_400 / bar.seconds).squareRoot()
    }
}

// MARK: - Report

public struct StrategyBacktestReport: Sendable, Identifiable {
    public let strategyId: String
    public let strategyName: String
    public let instId: String
    public let instType: InstrumentType
    public let bar: BarInterval
    public let initialCapital: Double
    public let generatedAt: Date
    public let results: [BacktestWindow: BacktestResult]
    public let robustness: RobustnessAssessment
    /// Set when the exchange could not supply the full requested history.
    public let coverageNote: String?

    public init(
        strategyId: String, strategyName: String, instId: String, instType: InstrumentType,
        bar: BarInterval, initialCapital: Double, generatedAt: Date,
        results: [BacktestWindow: BacktestResult], robustness: RobustnessAssessment,
        coverageNote: String?
    ) {
        self.strategyId = strategyId
        self.strategyName = strategyName
        self.instId = instId
        self.instType = instType
        self.bar = bar
        self.initialCapital = initialCapital
        self.generatedAt = generatedAt
        self.results = results
        self.robustness = robustness
        self.coverageNote = coverageNote
    }

    public var id: String { strategyId }

    public func result(for window: BacktestWindow) -> BacktestResult? { results[window] }

    /// Longest window that produced data — the one the grade is based on.
    public var primaryResult: BacktestResult? {
        BacktestWindow.allCases.sorted { $0.days > $1.days }.compactMap { results[$0] }.first
    }

    public var availableWindows: [BacktestWindow] {
        BacktestWindow.allCases.filter { results[$0] != nil }
    }
}
