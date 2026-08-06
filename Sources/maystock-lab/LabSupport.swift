import Foundation
import MayStockKit

// MARK: - Argument parsing

/// Minimal flag parser. Everything after the subcommand that is not a
/// `--flag` is treated as a positional argument.
struct Arguments {
    let positionals: [String]
    private let flags: [String: String]
    private let switches: Set<String>

    init(_ raw: [String]) {
        var positionals: [String] = []
        var flags: [String: String] = [:]
        var switches: Set<String> = []
        var index = 0
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    flags[name] = raw[index + 1]
                    index += 2
                    continue
                }
                switches.insert(name)
            } else {
                positionals.append(token)
            }
            index += 1
        }
        self.positionals = positionals
        self.flags = flags
        self.switches = switches
    }

    func string(_ name: String, default fallback: String? = nil) -> String? {
        flags[name] ?? fallback
    }

    func double(_ name: String, default fallback: Double) -> Double {
        flags[name].flatMap(Double.init) ?? fallback
    }

    func int(_ name: String, default fallback: Int) -> Int {
        flags[name].flatMap(Int.init) ?? fallback
    }

    func has(_ name: String) -> Bool {
        switches.contains(name) || flags[name] != nil
    }
}

// MARK: - Output

enum Out {
    static func heading(_ text: String) {
        print("\n\u{001B}[1m\(text)\u{001B}[0m")
    }

    static func rule(_ width: Int = 78) {
        print(String(repeating: "─", count: width))
    }

    static func kv(_ key: String, _ value: String, width: Int = 16) {
        print("  \(pad(key, width))\(value)")
    }

    static func note(_ text: String) {
        print("  · \(text)")
    }

    static func warn(_ text: String) {
        print("  \u{001B}[33m⚠\u{001B}[0m \(text)")
    }

    static func good(_ text: String) {
        print("  \u{001B}[32m✓\u{001B}[0m \(text)")
    }

    static func bad(_ text: String) {
        print("  \u{001B}[31m✗\u{001B}[0m \(text)")
    }

    /// Left-pad to a display width that counts CJK characters as two columns,
    /// so mixed Chinese/ASCII tables actually line up in a terminal.
    static func pad(_ text: String, _ width: Int) -> String {
        let used = displayWidth(text)
        return used >= width ? text + " " : text + String(repeating: " ", count: width - used)
    }

    static func padLeft(_ text: String, _ width: Int) -> String {
        let used = displayWidth(text)
        return used >= width ? text : String(repeating: " ", count: width - used) + text
    }

    static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
                 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6:
                return total + 2
            case 0x001B:
                return total   // escape sequences are invisible
            default:
                return total + 1
            }
        }
    }

    static func row(_ cells: [(String, Int)]) {
        var line = "  "
        for (text, width) in cells {
            line += width < 0 ? padLeft(text, -width) + " " : pad(text, width)
        }
        print(line)
    }

    static func signed(_ value: Double, decimals: Int = 2) -> String {
        let text = PriceFormatter.signedPercent(value)
        guard decimals != 2 else { return text }
        return (value >= 0 ? "+" : "") + PriceFormatter.decimals(value, decimals) + "%"
    }

    /// Green for gains, red for losses — the only colour convention here.
    static func tinted(_ value: Double, _ text: String) -> String {
        let colour = value >= 0 ? "32" : "31"
        return "\u{001B}[\(colour)m\(text)\u{001B}[0m"
    }
}

// MARK: - Shared loading

enum Lab {
    /// Resolve a manifest path, accepting a bare strategy id from `Strategies/`.
    static func loadManifest(_ path: String) throws -> StrategyManifest {
        let fm = FileManager.default
        var candidates = [path]
        if !path.hasSuffix(".json") { candidates.append(path + ".json") }
        candidates += ["Strategies/\(path)", "Strategies/\(path).json",
                       "Strategies/examples/\(path)", "Strategies/examples/\(path).json"]
        for candidate in candidates where fm.fileExists(atPath: candidate) {
            return try StrategyManifest.load(from: URL(fileURLWithPath: candidate))
        }
        // Fall back to a built-in preset so the tool is useful before the user
        // has written anything.
        if let preset = StrategyLibrary.presets.first(where: { $0.id == path }) {
            return preset
        }
        throw LabError.notFound(path)
    }

    static func feeSchedule(from arguments: Arguments) -> OKXFeeSchedule {
        var schedule = OKXFeeSchedule()
        if let raw = arguments.string("tier"), let tier = OKXFeeTier(rawValue: raw.lowercased()) {
            schedule.tier = tier
        }
        if let raw = arguments.string("style"), let style = FeeExecutionStyle(rawValue: raw) {
            schedule.executionStyle = style
        }
        schedule.slippageBps = arguments.double("slippage", default: schedule.slippageBps)
        return schedule
    }

    /// Enough candles for `days` of the strategy's interval, plus warm-up.
    static func fetchCandles(
        strategy: CompiledStrategy, days: Int, rest: OKXRESTClient = OKXRESTClient()
    ) async throws -> [Candle] {
        let bars = Int((Double(days) * 86_400 / strategy.market.bar.seconds).rounded(.up))
        let target = Swift.min(bars + strategy.warmupBars, BacktestRunner.maxBars)
        if let cached = CandleCache.load(
            instId: strategy.market.instId, bar: strategy.market.bar, atLeast: target) {
            return cached
        }
        let fetched = try await rest.historyCandles(
            instId: strategy.market.instId, bar: strategy.market.bar, target: target)
        CandleCache.save(
            fetched, instId: strategy.market.instId, bar: strategy.market.bar,
            requested: target)
        return fetched
    }

    /// Candles plus every series the manifest declares, aligned and reported.
    static func fetchMarketData(
        strategy: CompiledStrategy, days: Int, rest: OKXRESTClient = OKXRESTClient()
    ) async throws -> (candles: [Candle], series: [String: [Double]], coverage: [SeriesCoverage]) {
        let candles = try await fetchCandles(strategy: strategy, days: days, rest: rest)
        guard strategy.usesAlternativeData else { return (candles, [:], []) }
        let loaded = await AlternativeDataProvider(rest: rest).load(
            specs: strategy.manifest.data, market: strategy.market,
            candles: candles, days: days)
        return (candles, loaded.series, loaded.coverage)
    }

    /// Run a script-engine strategy to get its target positions, or nil for a
    /// declarative one. `--allow-scripts` is the explicit unlock; without it the
    /// engine refuses rather than executing an imported file's code.
    static func scriptTargets(
        strategy: CompiledStrategy, candles: [Candle], series: [String: [Double]],
        arguments: Arguments
    ) async throws -> [TradeDirection?]? {
        guard let spec = strategy.scriptSpec else { return nil }
        guard arguments.has("allow-scripts") else { throw ScriptEngineError.disabled }
        let engine = ScriptStrategyEngine(
            spec: spec, workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        Out.warn("正在执行外部脚本：\(engine.resolvedCommand())")
        return try await engine.targets(
            candles: candles, params: strategy.parameterValues, series: series,
            instId: strategy.market.instId, bar: strategy.market.bar, enabled: true)
    }

    /// Reshape a raw series before scoring it.
    ///
    /// On-chain volumes, hash rate and macro indices are **levels**, and levels
    /// trend for years. Correlating a trending level against forward returns
    /// mostly measures whether both happened to drift the same way, not whether
    /// one predicts the other. Differencing or z-scoring makes the series
    /// roughly stationary, which is the specification these signals deserve.
    static func applyTransform(_ spec: String, to series: [Double]) throws -> [Double] {
        if spec == "raw" { return series }

        // The transforms are expressed in the kernel's own DSL and evaluated by
        // the kernel, so `roc` and `stdev` here mean exactly what they mean in
        // a strategy manifest. The series is carried in as the `close` of a
        // synthetic candle array — the DSL's window functions are defined over
        // candles, and inventing a second Swift implementation of `sma` for
        // research use is how the two drift apart.
        func evaluate(_ expression: String) throws -> [Double] {
            let candles = series.enumerated().map { index, value in
                Candle(ts: Date(timeIntervalSince1970: Double(index) * 86_400),
                       open: value, high: value, low: value, close: value,
                       volume: 0, confirmed: true)
            }
            return try TradingKernel.evaluate(expression, candles: candles)
        }

        if spec == "diff" { return try evaluate("close - ref(close, 1)") }

        let parts = spec.split(separator: ":")
        guard parts.count == 2, let window = Int(parts[1]), window > 1 else {
            throw LabError.usage("无效的 --transform：\(spec)（可选 raw / diff / roc:N / z:N）")
        }
        switch parts[0] {
        case "roc":
            return try evaluate("roc(close, \(window))")
        case "z":
            // stdev of 0 would divide by zero; the DSL yields NaN there, which
            // is the right answer — a flat window has no z-score.
            return try evaluate(
                "(close - sma(close, \(window))) / stdev(close, \(window))")
        default:
            throw LabError.usage("未知变换：\(parts[0])（可选 raw / diff / roc:N / z:N）")
        }
    }

    /// Print what each declared series could actually cover, and warn when a
    /// window is longer than the endpoint's fixed history.
    static func reportCoverage(_ coverage: [SeriesCoverage], bar: BarInterval, days: Int) {
        guard !coverage.isEmpty else { return }
        Out.heading("另类数据覆盖")
        for entry in coverage {
            let limit = entry.spec.source.historyLimitDays(bar: bar)
            if entry.isUsable, limit == nil || (limit ?? 0) >= days {
                Out.good(entry.summary)
            } else {
                Out.warn(entry.summary
                         + (limit.map { "；接口最多约 \($0) 天历史，本次请求 \(days) 天" } ?? ""))
            }
        }
        if coverage.contains(where: { !$0.isUsable }) {
            Out.note("覆盖不足的区间信号恒为「未知」，策略在那段时间不会开仓 —— "
                     + "结论只对有数据的那部分成立。")
        }
    }

    static func objective(from arguments: Arguments) -> OptimizationObjective {
        var objective = OptimizationObjective()
        if let raw = arguments.string("objective"),
           let kind = OptimizationObjective.Kind(rawValue: raw) {
            objective.kind = kind
        }
        if arguments.has("max-dd") { objective.maxDrawdownPct = arguments.double("max-dd", default: 0) }
        objective.minTrades = arguments.int("min-trades", default: objective.minTrades)
        if arguments.has("min-daily") {
            objective.minDailyReturnPct = arguments.double("min-daily", default: 0)
        }
        objective.mustBeatBuyHold = arguments.has("beat-hold")
        return objective
    }

    /// The metric block printed under every backtest.
    static func printMetrics(_ metrics: BacktestMetrics, capital: Double, quote: String = "USDT") {
        let daily = metrics.dailyReturnPct
        Out.kv("日均收益", Out.tinted(daily, Out.signed(daily, decimals: 3))
               + "   (目标 0.5% 是 \(PriceFormatter.percent(0.5, decimals: 1)))")
        Out.kv("总收益", Out.tinted(metrics.totalReturnPct, Out.signed(metrics.totalReturnPct))
               + "   \(PriceFormatter.signedMoney(capital * metrics.totalReturnPct / 100)) \(quote)")
        Out.kv("最大回撤", "\u{001B}[31m-\(PriceFormatter.percent(metrics.maxDrawdownPct, decimals: 2))\u{001B}[0m"
               + "   持续 \(metrics.maxDrawdownBars) 根")
        Out.kv("买入持有", Out.tinted(metrics.buyHoldReturnPct, Out.signed(metrics.buyHoldReturnPct))
               + "   超额 " + Out.tinted(metrics.excessReturnPct, Out.signed(metrics.excessReturnPct)))
        Out.kv("夏普 / 索提诺", "\(PriceFormatter.ratio(metrics.sharpe)) / \(PriceFormatter.ratio(metrics.sortino))")
        Out.kv("卡玛", PriceFormatter.ratio(metrics.calmar))
        Out.kv("交易", "\(metrics.tradeCount) 笔 · 胜率 \(PriceFormatter.percent(metrics.winRate, decimals: 1))"
               + " · 盈亏比 \(PriceFormatter.ratio(metrics.profitFactor))"
               + " · 期望 \(Out.signed(metrics.expectancyPct, decimals: 3))")
        Out.kv("持仓", "平均 \(PriceFormatter.decimals(metrics.averageHoldBars, 1)) 根"
               + " · 占比 \(PriceFormatter.percent(metrics.exposurePct, decimals: 0))"
               + " · 最长连亏 \(metrics.maxConsecutiveLosses) 笔")
        Out.kv("成本", "手续费 \(PriceFormatter.money(metrics.feesPaid)) \(quote)"
               + (metrics.fundingPaid != 0
                  ? " · 资金费 \(PriceFormatter.signedMoney(metrics.fundingPaid)) \(quote)" : ""))
    }
}

/// Throttled progress line on stderr, so piping stdout to a file stays clean.
final class ProgressTicker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1

    func report(done: Int, total: Int) {
        let percent = done * 100 / Swift.max(total, 1)
        lock.lock()
        defer { lock.unlock() }
        guard percent != lastPercent, percent % 5 == 0 else { return }
        lastPercent = percent
        FileHandle.standardError.write(Data("  评估 \(percent)%\r".utf8))
    }

    func clear() {
        FileHandle.standardError.write(Data("               \r".utf8))
    }
}

enum LabError: Error, CustomStringConvertible {
    case notFound(String)
    case usage(String)

    var description: String {
        switch self {
        case .notFound(let path): return "找不到策略清单：\(path)"
        case .usage(let text): return text
        }
    }
}

// MARK: - Candle cache

/// On-disk candle cache for the research bench.
///
/// Research means running the same window past dozens of strategy variants, and
/// without this every one of them refetches identical history — slow, and enough
/// concurrent optimisation runs will rate-limit the account against itself
/// (HTTP 429), which is how a sweep comes back with half its grid missing.
///
/// Deliberately not in `MayStockKit`: the trading runner must never read a
/// candle from disk. It needs to know the feed is live, and a cache is exactly
/// the thing that would hide a dead one.
enum CandleCache {
    /// How long a window may be reused. Long enough to cover a research
    /// session, short enough that "today's backtest" means today.
    static let maxAge: TimeInterval = 3_600

    static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maystock-lab-candles", isDirectory: true)
    }

    private static func url(instId: String, bar: BarInterval) -> URL {
        directory.appendingPathComponent("\(instId)-\(bar.rawValue).json")
    }

    private struct Payload: Codable {
        var fetchedAt: Date
        /// How many bars were *asked* for, not how many came back.
        ///
        /// The exchange routinely returns fewer than requested — its history
        /// simply ends. Keying the hit on the delivered count would mean a
        /// window fetched for 11 520 bars that yielded 9 000 never satisfies a
        /// request for 11 520, and the cache would miss every single time while
        /// looking like it worked.
        var requested: Int
        var candles: [Cached]
        struct Cached: Codable {
            var ts: Date
            var open: Double
            var high: Double
            var low: Double
            var close: Double
            var volume: Double
            var confirmed: Bool
        }
    }

    /// A cached window, but only when it is fresh *and* long enough. A shorter
    /// window silently truncates a longer backtest, which would look like a
    /// coverage problem in the data rather than a cache miss.
    static func load(instId: String, bar: BarInterval, atLeast: Int) -> [Candle]? {
        guard !ProcessInfo.processInfo.environment.keys.contains("MAYSTOCK_NO_CACHE"),
              let data = try? Data(contentsOf: url(instId: instId, bar: bar)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data),
              Date().timeIntervalSince(payload.fetchedAt) < maxAge,
              payload.requested >= atLeast else { return nil }
        // Truncated to what was actually asked for, keeping the most recent
        // bars — `historyCandles(target:)` returns the newest N.
        //
        // Returning the whole cached window instead would silently widen every
        // shorter request: `--days 20` served from a 124-day cache runs 124
        // days and labels the result twenty. That is worse than having no
        // cache, because the number looks right while answering a different
        // question, and a validation run on a short window would quietly be
        // re-testing the very history the strategy was fitted on.
        return payload.candles.suffix(atLeast).map {
            Candle(ts: $0.ts, open: $0.open, high: $0.high, low: $0.low,
                   close: $0.close, volume: $0.volume, confirmed: $0.confirmed)
        }
    }

    static func save(
        _ candles: [Candle], instId: String, bar: BarInterval, requested: Int
    ) {
        guard !candles.isEmpty else { return }
        // Never shrink a cached window: a 500-day fetch must not be replaced by
        // a 30-day one just because that ran second.
        if let existing = try? Data(contentsOf: url(instId: instId, bar: bar)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let previous = try? decoder.decode(Payload.self, from: existing),
               previous.requested > requested,
               Date().timeIntervalSince(previous.fetchedAt) < maxAge {
                return
            }
        }
        let payload = Payload(
            fetchedAt: Date(),
            requested: requested,
            candles: candles.map {
                .init(ts: $0.ts, open: $0.open, high: $0.high, low: $0.low,
                      close: $0.close, volume: $0.volume, confirmed: $0.confirmed)
            })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? encoder.encode(payload).write(
            to: url(instId: instId, bar: bar), options: .atomic)
    }
}
