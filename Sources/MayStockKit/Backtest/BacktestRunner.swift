import Foundation
import CMayStockKernel

public enum BacktestPhase: Sendable, Equatable {
    case fetchingCandles(loaded: Int, target: Int)
    case fetchingFunding
    case fetchingAlternativeData
    case simulating(BacktestWindow)
    case finished

    public var displayText: String {
        switch self {
        case .fetchingCandles(let loaded, let target):
            return "拉取历史 K 线 \(loaded)/\(target)"
        case .fetchingFunding: return "拉取资金费率历史"
        case .fetchingAlternativeData: return "拉取另类数据"
        case .simulating(let window): return "回测 \(window.displayName)"
        case .finished: return "完成"
        }
    }
}

/// Fetches history once and replays the strategy across every window.
///
/// One download serves all five windows: the longest window's candles are
/// sliced for the shorter ones, so a five-window report costs the same network
/// as a single 365-day run.
/// Why a report could not be produced.
public enum BacktestRunnerError: Error, CustomStringConvertible, Sendable, Equatable {
    /// The venue's source served no history for the instrument.
    case noHistory(instId: String, venue: Venue)

    public var description: String {
        switch self {
        case .noHistory(let instId, let venue):
            return "\(venue.displayName)的行情源取不到 \(instId) 的历史 K 线"
        }
    }
}

public struct BacktestRunner: Sendable {
    /// Ceiling on candles per report: the kernel's (`expr::MAX_BARS`), so a
    /// manifest the compiler accepts always fits. 200 000 is all of a
    /// perpetual's hourly history and 139 days of 1m; past it the report says
    /// what it covered rather than lying about coverage.
    public static let maxBars = Int(ms_max_bars())

    /// History comes from the strategy's own venue; funding and the
    /// alternative-data feeds are OKX's and only ever asked for OKX markets.
    public let sources: MarketDataSources
    /// Nil takes the instrument's documented default.
    public let maintenanceMarginRate: Double?
    public let feeSchedules: FeeSchedules

    public init(
        sources: MarketDataSources = MarketDataSources(),
        maintenanceMarginRate: Double? = nil,
        feeSchedules: FeeSchedules = FeeSchedules()
    ) {
        self.sources = sources
        self.maintenanceMarginRate = maintenanceMarginRate
        self.feeSchedules = feeSchedules
    }

    public func run(
        strategy: CompiledStrategy,
        capital: Double = 10_000,
        windows: [BacktestWindow] = BacktestWindow.allCases,
        /// Upper bound on the `.full` window, in days. Nil means "as much as
        /// the exchange will serve". Callers that offer the user a `--days`
        /// flag should pass it here, or the report silently covers a different
        /// period from the backtest printed beside it.
        maxDays: Int? = nil,
        /// History the caller already holds for this request — the lab fetches
        /// it for its own run first. Given, nothing is downloaded: at minute
        /// bars a second download of the same window takes minutes.
        preloaded: BacktestHistory? = nil,
        onPhase: (@Sendable (BacktestPhase) -> Void)? = nil
    ) async throws -> StrategyBacktestReport {
        let market = strategy.market
        let calendar = market.calendar
        // Bars per calendar day on this market — 24 for hourly crypto, 7 for
        // hourly stocks — so a window of days is sized by what the venue
        // actually trades rather than by the clock.
        let barsPerCalendarDay = Swift.max(calendar.barsPerYear / 365.25, 1e-9)
        // `.full` means "everything the caller asked for", which is the bar
        // cap when they asked for no limit.
        let capDays = Int(Double(Self.maxBars) / barsPerCalendarDay) + 1
        let longestDays = windows.contains(where: \.coversEverything)
            ? Swift.min(maxDays ?? capDays, capDays)
            : (windows.map(\.days).max() ?? 30)
        let warmup = strategy.warmupBars

        let wantedBars = calendar.barCount(days: longestDays) + warmup
        let targetBars = Swift.min(wantedBars, Self.maxBars)

        let history: BacktestHistory
        if let preloaded {
            history = preloaded.suffix(targetBars)
        } else {
            history = try await assemble(
                strategy: strategy, targetBars: targetBars, longestDays: longestDays, onPhase: onPhase)
        }
        let candles = history.candles
        guard let firstCandle = candles.first, let lastCandle = candles.last else {
            throw BacktestRunnerError.noHistory(instId: market.instId, venue: market.venue)
        }

        let config = BacktestConfig(
            initialCapital: capital,
            maintenanceMarginRate: maintenanceMarginRate,
            fundingRates: history.fundingRates,
            feeSchedules: feeSchedules,
            externalSeries: history.series)

        var results: [BacktestWindow: BacktestResult] = [:]
        for window in windows.sorted(by: { $0.days < $1.days }) {
            onPhase?(.simulating(window))
            let range = window.coversEverything
                ? 0..<candles.count
                : Self.sliceRange(candles, days: window.days,
                                  warmup: warmup, end: lastCandle.ts)
            let slice = Array(candles[range])
            // A window needs at least the warm-up plus a couple of tradeable
            // bars before the simulation can say anything at all.
            guard slice.count > warmup + 1 else { continue }
            let windowConfig = config.slicing(range)
            results[window] = try BacktestEngine(strategy: strategy, config: windowConfig)
                .run(candles: slice)
        }
        onPhase?(.finished)

        let coveredDays = lastCandle.ts.timeIntervalSince(firstCandle.ts) / 86_400
        var coverageNote: String?
        if wantedBars > Self.maxBars {
            coverageNote = "\(market.bar.rawValue) 周期下 \(longestDays) 天需要 \(wantedBars) 根 K 线，"
                + "超出单次 \(Self.maxBars) 根上限，实际覆盖约 \(Int(coveredDays)) 天。"
        } else if coveredDays < Double(longestDays) * 0.9 {
            coverageNote = "交易所仅提供约 \(Int(coveredDays)) 天历史，长窗口结果按实际覆盖计算。"
        }

        let fundingNote = history.fundingFailure.map { "资金费率历史取不到（\($0)），永续的持仓成本没有计入。" }
            ?? FundingCoverage.note(
                instType: market.instType, candles: candles, warmup: warmup, fundingRates: history.fundingRates)
        if let fundingNote {
            coverageNote = [coverageNote, fundingNote].compactMap { $0 }.joined(separator: " ")
        }

        // A series that only covers part of the window makes the long windows
        // untestable; say so rather than silently backtesting on NaNs.
        for entry in history.coverage where !entry.isUsable {
            let limit = entry.spec.source.historyLimitDays(bar: market.bar)
            let note = "另类数据 \(entry.summary)"
                + (limit.map { "；该接口最多只提供约 \($0) 天历史" } ?? "")
            coverageNote = [coverageNote, note].compactMap { $0 }.joined(separator: " ")
        }

        let robustness = RobustnessAssessment.evaluate(
            results: results, market: market, freeParameterCount: strategy.freeParameterCount)

        return StrategyBacktestReport(
            strategyId: strategy.id,
            strategyName: strategy.name,
            instId: market.instId,
            instType: market.instType,
            bar: market.bar,
            initialCapital: capital,
            generatedAt: Date(),
            results: results,
            robustness: robustness,
            coverageNote: coverageNote)
    }

    /// Download what a report replays: the candles — shared with any report
    /// running alongside on the same market (`BacktestHistoryMemo`) — the
    /// funding a perpetual paid over them, and the manifest's declared series
    /// aligned to them.
    private func assemble(
        strategy: CompiledStrategy, targetBars: Int, longestDays: Int,
        onPhase: (@Sendable (BacktestPhase) -> Void)?
    ) async throws -> BacktestHistory {
        let market = strategy.market
        let source = sources.source(for: market.venue)
        let rest = sources.okx
        onPhase?(.fetchingCandles(loaded: 0, target: targetBars))
        let candles = try await BacktestHistoryMemo.shared.candles(
            venue: market.venue, instId: market.instId, bar: market.bar, target: targetBars,
            progress: { loaded in onPhase?(.fetchingCandles(loaded: loaded, target: targetBars)) },
            fetch: { progress in
                try await source.historyCandles(
                    instId: market.instId, bar: market.bar, target: targetBars, progress: progress)
            })
        var history = BacktestHistory(candles: candles)
        guard let first = candles.first else { return history }

        if market.instType == .swap {
            onPhase?(.fetchingFunding)
            do {
                // Three settlements a day, plus slack for gaps.
                history.fundingRates = try await rest.fundingRateHistory(
                    instId: market.instId, since: first.ts, limit: longestDays * 3 + 10)
            } catch {
                // Said, not swallowed: an empty list reads as "no funding was
                // due", the cheapest answer there is.
                Log.warn("backtest: \(market.instId) 资金费率历史取不到：\(error)")
                history.fundingFailure = String(describing: error)
            }
        }
        if strategy.usesAlternativeData {
            onPhase?(.fetchingAlternativeData)
            let loaded = await AlternativeDataProvider(rest: rest).load(
                specs: strategy.manifest.data, market: market, candles: candles, days: longestDays)
            history.series = loaded.series
            history.coverage = loaded.coverage
        }
        return history
    }

    /// Index range for the trailing `days` of candles, preceded by exactly
    /// `warmup` bars so the engine's cut-off lands on the window boundary.
    /// Returned as a range so aligned external series can be sliced identically.
    static func sliceRange(_ candles: [Candle], days: Int, warmup: Int, end: Date) -> Range<Int> {
        let cutoff = end.addingTimeInterval(-Double(days) * 86_400)
        guard let windowStart = candles.firstIndex(where: { $0.ts >= cutoff }) else {
            return candles.count..<candles.count
        }
        return Swift.max(0, windowStart - warmup)..<candles.count
    }

    static func slice(_ candles: [Candle], days: Int, warmup: Int, end: Date) -> [Candle] {
        Array(candles[sliceRange(candles, days: days, warmup: warmup, end: end)])
    }
}

/// How much of a perpetual's history its funding record covers.
///
/// OKX serves about three months of funding settlements and nothing older, so
/// a full-history backtest of a perpetual charges no funding at all before
/// that — its carry cost is understated by however long it held positions
/// there. The kernel only flags a record that is empty; a record that starts
/// late is this note, in the report and the lab alike.
public enum FundingCoverage {
    /// Nil when there is nothing to say: not a perpetual, or the record
    /// reaches back to the first bar that trades (within a settlement
    /// interval). The warm-up before it holds no position and owes nothing.
    public static func note(
        instType: InstrumentType, candles: [Candle], warmup: Int, fundingRates: [FundingRate]
    ) -> String? {
        guard instType == .swap, !candles.isEmpty, let last = candles.last?.ts else { return nil }
        let first = candles[Swift.min(warmup, candles.count - 1)].ts
        guard let earliest = fundingRates.map(\.ts).min() else {
            return "没有资金费率记录，永续的持仓成本没有计入。"
        }
        let uncovered = earliest.timeIntervalSince(first)
        guard uncovered > 8 * 3_600 else { return nil }
        let span = last.timeIntervalSince(first)
        return "资金费率记录只从 \(earliest.formatted(.iso8601.year().month().day())) 起（OKX 只提供约三个月），"
            + "此前 \(Int(uncovered / 86_400)) 天（回测区间的 \(Int((uncovered / span * 100).rounded()))%）"
            + "的持仓没有计资金费，永续成本被低估。"
    }
}

/// What a report replays: the candles, the funding a perpetual paid over
/// them, and the manifest's declared series aligned to them. The runner
/// assembles one; the lab hands over the one it fetched for its own run.
public struct BacktestHistory: Sendable {
    public var candles: [Candle]
    public var fundingRates: [FundingRate] = []
    /// Why the funding record could not be read, when it could not.
    public var fundingFailure: String?
    /// Aligned to `candles`, index for index.
    public var series: [String: [Double]] = [:]
    public var coverage: [SeriesCoverage] = []

    public init(
        candles: [Candle], fundingRates: [FundingRate] = [], fundingFailure: String? = nil,
        series: [String: [Double]] = [:], coverage: [SeriesCoverage] = []
    ) {
        self.candles = candles
        self.fundingRates = fundingRates
        self.fundingFailure = fundingFailure
        self.series = series
        self.coverage = coverage
    }

    /// The newest `count` bars, with every aligned series cut to match.
    func suffix(_ count: Int) -> BacktestHistory {
        guard candles.count > count else { return self }
        var trimmed = self
        trimmed.candles = Array(candles.suffix(count))
        trimmed.series = series.mapValues { Array($0.suffix(count)) }
        return trimmed
    }
}

