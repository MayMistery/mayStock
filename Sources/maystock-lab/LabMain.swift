import Foundation
import MayStockKit

/// MayStock strategy research bench.
///
/// The app's studio is for choosing and running strategies; this is for
/// *building* them. Everything here reads public market data only — no API key
/// is needed to backtest, optimise or walk-forward anything.
@main
struct LabMain {
    static func main() async {
        let raw = Array(CommandLine.arguments.dropFirst())
        let command = raw.first ?? "help"
        let arguments = Arguments(Array(raw.dropFirst()))

        do {
            switch command {
            case "backtest": try await backtest(arguments)
            case "optimize", "optimise": try await optimize(arguments)
            case "walkforward", "wf": try await walkForward(arguments)
            case "portfolio": try await portfolio(arguments)
            case "fees": try await fees(arguments)
            case "new": try newStrategy(arguments)
            case "signals": try await signals(arguments)
            case "ic": try await informationCoefficient(arguments)
            case "factors": try await factors(arguments)
            case "oracle": try await oracle(arguments)
            case "list": list()
            case "help", "--help", "-h": usage()
            default:
                print("未知命令：\(command)\n")
                usage()
                exit(2)
            }
        } catch {
            Out.bad(String(describing: error))
            exit(1)
        }
    }

    static func usage() {
        print("""
        maystock-lab — 策略研究台（只读公开行情，无需 API Key）

          backtest <策略> [--days 365] [--capital 30000] [--tier lv1] [--slippage 5]
                          [--allow-scripts]
              单策略回测，输出完整绩效表。脚本策略需 --allow-scripts 显式解锁。

          optimize <策略> [--days 365] [--objective calmar] [--max-dd 10]
                          [--min-trades 30] [--min-daily 0.5] [--top 10] [--limit 20000]
              网格寻优。会同时报告「纯运气下的期望最好夏普」，用于识别过拟合。
              目标可选：dailyReturn sharpe sortino calmar totalReturn profitFactor returnOverDrawdown

          walkforward <策略> [--days 365] [--folds 4] [--in-sample 0.7] [--objective calmar]
              滚动「样本内寻优 → 样本外实盘」验证。这是唯一能回答
              「这套参数在没见过的数据上还灵不灵」的命令。

          portfolio <策略A> <策略B> ... [--weights 0.5,0.5] [--capital 30000] [--days 365]
              多策略组合回测：合并净值、组合回撤、腿间相关性、分散化收益。

          fees [--tier lv1] [--sync]
              查看费率档位表；--sync 从已配置的 okx CLI 拉取本账户真实费率。

          new <名称> [--template trend|reversion|breakout|grid] [--instId BTC-USDT] [--bar 1H]
              生成一份策略清单脚手架到 Strategies/。

          signals [--ccy BTC] [--bar 1H]
              列出可用的另类数据源，实测每个接口现在能给多少历史。

          ic <source> [--ccy BTC] [--bar 4H] [--days 90] [--horizons 1,3,6,12]
                      [--transform raw|diff|roc:N|z:N]
              信息系数分析：该信号与未来收益的秩相关、t 值、分位收益。
              用全部 K 线而不是几笔交易来判断信号有没有信息，统计力高出一个量级。
              --transform 很关键：链上量、美元指数这类是**非平稳的水平值**，
              直接做相关会被慢趋势主导；roc:N（N 日变化率）或 z:N（N 日 z 分数）
              才是它们该有的形式。

          factors [--size 40] [--days 365] [--rebalance 7] [--lookback 28] [--skip 7]
                  [--leg 0.2] [--capital 30000]
              **横截面**三因子研究（市场 / 规模 / 动量）—— 在几十个币之间排序做多空，
              而不是给单个币择时。这是学术界对加密市场唯一有稳健证据的方向。
              会强制列出幸存者偏差等已知缺陷。

          oracle [--instId BTC-USDT] [--bar 1D] [--days 1400] [--swings 5,10,20]
              **上帝视角上限**：假设你能预知未来、完美抓住每一个波段，能赚多少？
              同时统计「前高前低」在真实数据里到底有多少次挡住了价格。
              这是唯一刻意使用未来函数的地方，用来给一切策略划出天花板。

          list
              列出内置策略与 Strategies/ 下的清单。

        策略参数可以写成路径、文件名，或 Strategies/ 下的 id。
        """)
    }

    // MARK: backtest

    static func backtest(_ arguments: Arguments) async throws {
        guard let path = arguments.positionals.first else {
            throw LabError.usage("用法：maystock-lab backtest <策略>")
        }
        let manifest = try Lab.loadManifest(path)
        let strategy = try manifest.compile()
        let capital = arguments.double("capital", default: 30_000)
        let days = arguments.int("days", default: 365)
        let schedule = Lab.feeSchedule(from: arguments)

        Out.heading("回测 · \(strategy.name)")
        Out.kv("标的", "\(strategy.market.instId) · \(strategy.market.instType.displayName)"
               + " · \(strategy.market.bar.rawValue)")
        Out.kv("费率", schedule.summary)
        Out.kv("单边成本", "\(PriceFormatter.decimals(schedule.feeBps(for: strategy.market.instType), 2)) bps"
               + " + 滑点 \(PriceFormatter.plain(schedule.slippageBps)) bps"
               + " → 往返 \(PriceFormatter.percent(schedule.roundTripCostPct(for: strategy.market.instType), decimals: 3))")

        let data = try await Lab.fetchMarketData(strategy: strategy, days: days)
        let candles = data.candles
        Lab.reportCoverage(data.coverage, bar: strategy.market.bar, days: days)
        var config = BacktestConfig(initialCapital: capital, feeSchedule: schedule,
                                    externalSeries: data.series)
        config.scriptTargets = try await Lab.scriptTargets(
            strategy: strategy, candles: candles, series: data.series, arguments: arguments)
        if strategy.market.instType == .swap, let first = candles.first {
            config.fundingRates = (try? await OKXRESTClient().fundingRateHistory(
                instId: strategy.market.instId, since: first.ts, limit: days * 3 + 10)) ?? []
        }

        let result = try BacktestEngine(strategy: strategy, config: config).run(candles: candles)
        Out.kv("区间", "\(result.start.formatted(date: .numeric, time: .shortened))"
               + " → \(result.end.formatted(date: .numeric, time: .shortened))"
               + "  (\(result.barCount) 根，预热 \(result.warmupBars) 根)")
        Out.rule()
        Lab.printMetrics(result.metrics, capital: capital)

        if result.liquidations > 0 { Out.warn("发生 \(result.liquidations) 次强平") }
        if result.fundingUnmodelled { Out.warn("未取到资金费率历史，永续成本被低估") }
        if let quality = result.dataQuality, !quality.usable {
            Out.warn("行情数据有问题：\(quality.reason)")
        } else if let quality = result.dataQuality, quality.gaps > 0 {
            Out.note("历史中缺失 \(quality.gaps) 根 K 线，跨越缺口的指标窗口比标称的长")
        }

        // The multi-window view the app shows, for the same strategy.
        Out.heading("分窗口")
        let report = try await BacktestRunner(feeSchedule: schedule).run(
            strategy: strategy, capital: capital)
        Out.row([("窗口", 8), ("日均", -10), ("总收益", -10), ("回撤", -9),
                 ("交易", -6), ("夏普", -7), ("买入持有", -10)])
        for window in BacktestWindow.allCases {
            guard let r = report.result(for: window) else {
                Out.row([(window.displayName, 8), ("数据不足", -10)]); continue
            }
            let m = r.metrics
            Out.row([
                (window.displayName, 8),
                (Out.tinted(m.dailyReturnPct, Out.signed(m.dailyReturnPct, decimals: 3)), -10),
                (Out.tinted(m.totalReturnPct, Out.signed(m.totalReturnPct)), -10),
                ("-" + PriceFormatter.percent(m.maxDrawdownPct, decimals: 1), -9),
                ("\(m.tradeCount)", -6),
                (PriceFormatter.ratio(m.sharpe), -7),
                (Out.signed(m.buyHoldReturnPct), -10),
            ])
        }
        Out.rule()
        Out.kv("稳健性", report.robustness.grade.displayName
               + "（\(report.robustness.observedTrades)/\(report.robustness.requiredTrades) 笔）")
        for note in report.robustness.notes { Out.note(note) }
        if let coverage = report.coverageNote { Out.warn(coverage) }
    }

    // MARK: optimize

    static func optimize(_ arguments: Arguments) async throws {
        guard let path = arguments.positionals.first else {
            throw LabError.usage("用法：maystock-lab optimize <策略>")
        }
        let manifest = try Lab.loadManifest(path)
        let strategy = try manifest.compile()
        let capital = arguments.double("capital", default: 30_000)
        let days = arguments.int("days", default: 365)
        let top = arguments.int("top", default: 10)
        let limit = arguments.int("limit", default: 20_000)
        let objective = Lab.objective(from: arguments)
        let schedule = Lab.feeSchedule(from: arguments)
        let grid = ParameterGrid(manifest: manifest,
                                 pointsPerAxis: arguments.int("points", default: 8))

        Out.heading("寻优 · \(strategy.name)")
        Out.kv("目标", objective.kind.displayName)
        Out.kv("约束", constraintSummary(objective))
        Out.kv("搜索空间", grid.isEmpty ? "（无可调参数）" : "\(grid.description) = \(grid.size) 组")
        Out.kv("费率", schedule.summary)

        let data = try await Lab.fetchMarketData(strategy: strategy, days: days)
        let candles = data.candles
        Lab.reportCoverage(data.coverage, bar: strategy.market.bar, days: days)
        let config = BacktestConfig(initialCapital: capital, feeSchedule: schedule,
                                    externalSeries: data.series)
        let optimiser = StrategyOptimizer(strategy: strategy, config: config, objective: objective)

        let progress = ProgressTicker()
        let result = optimiser.run(candles: candles, grid: grid, limit: limit) { done, total in
            progress.report(done: done, total: total)
        }
        progress.clear()

        Out.rule()
        Out.row([("#", 4), ("参数", 30), ("日均", -9), ("总收益", -10),
                 ("回撤", -8), ("交易", -6), ("夏普", -7), ("卡玛", -7)])
        for (rank, candidate) in result.candidates.prefix(top).enumerated() {
            let m = candidate.metrics
            Out.row([
                ("\(rank + 1)", 4),
                (candidate.parameterSummary, 30),
                (Out.tinted(m.dailyReturnPct, Out.signed(m.dailyReturnPct, decimals: 3)), -9),
                (Out.tinted(m.totalReturnPct, Out.signed(m.totalReturnPct)), -10),
                ("-" + PriceFormatter.percent(m.maxDrawdownPct, decimals: 1), -8),
                ("\(m.tradeCount)", -6),
                (PriceFormatter.ratio(m.sharpe), -7),
                (PriceFormatter.ratio(m.calmar), -7),
            ])
            if let rejection = candidate.rejection { Out.note("↑ 不满足：\(rejection)") }
        }

        Out.rule()
        Out.kv("已评估", "\(result.evaluated) 组，通过约束 \(result.passing.count) 组")
        let luck = result.luckThresholdSharpe
        if luck > 0 {
            Out.kv("运气基准", "无边际时 \(result.evaluated) 次尝试的期望最好夏普 ≈ "
                   + PriceFormatter.ratio(luck))
        }
        for warning in result.warnings { Out.warn(warning) }
        Out.note("寻优结果一律只是候选。用 walkforward 验证后再决定是否投入资金。")
    }

    static func constraintSummary(_ objective: OptimizationObjective) -> String {
        var parts = ["交易 ≥ \(objective.minTrades) 笔"]
        if let dd = objective.maxDrawdownPct { parts.append("回撤 ≤ \(PriceFormatter.percent(dd, decimals: 1))") }
        if let daily = objective.minDailyReturnPct {
            parts.append("日均 ≥ \(PriceFormatter.percent(daily, decimals: 2))")
        }
        if objective.mustBeatBuyHold { parts.append("须跑赢买入持有") }
        return parts.joined(separator: " · ")
    }

    // MARK: walk-forward

    static func walkForward(_ arguments: Arguments) async throws {
        guard let path = arguments.positionals.first else {
            throw LabError.usage("用法：maystock-lab walkforward <策略>")
        }
        let manifest = try Lab.loadManifest(path)
        let strategy = try manifest.compile()
        let capital = arguments.double("capital", default: 30_000)
        let days = arguments.int("days", default: 365)
        let folds = arguments.int("folds", default: 4)
        let inSample = arguments.double("in-sample", default: 0.7)
        let objective = Lab.objective(from: arguments)
        let schedule = Lab.feeSchedule(from: arguments)

        Out.heading("走向前验证 · \(strategy.name)")
        Out.kv("方案", "\(folds) 折 · 每折前 \(PriceFormatter.percent(inSample * 100))"
               + " 寻优，后 \(PriceFormatter.percent((1 - inSample) * 100)) 盲测")
        Out.kv("目标", objective.kind.displayName)

        let data = try await Lab.fetchMarketData(strategy: strategy, days: days)
        let candles = data.candles
        Lab.reportCoverage(data.coverage, bar: strategy.market.bar, days: days)
        let config = BacktestConfig(initialCapital: capital, feeSchedule: schedule,
                                    externalSeries: data.series)
        let analysis = WalkForwardAnalysis(
            strategy: strategy, config: config, objective: objective,
            folds: folds, inSampleFraction: inSample)

        let progress = ProgressTicker()
        let result = analysis.run(candles: candles,
                                  limit: arguments.int("limit", default: 5_000)) { done, total in
            progress.report(done: done, total: total)
        }
        progress.clear()

        Out.rule()
        Out.row([("折", 4), ("样本内参数", 26), ("样本内", -10), ("样本外", -10),
                 ("效率", -8), ("样本外回撤", -11), ("交易", -6)])
        for fold in result.folds {
            Out.row([
                ("\(fold.id + 1)", 4),
                (fold.parameterSummary, 26),
                (Out.tinted(fold.inSample.totalReturnPct, Out.signed(fold.inSample.totalReturnPct)), -10),
                (Out.tinted(fold.outOfSample.totalReturnPct, Out.signed(fold.outOfSample.totalReturnPct)), -10),
                (PriceFormatter.ratio(fold.efficiency), -8),
                ("-" + PriceFormatter.percent(fold.outOfSample.maxDrawdownPct, decimals: 1), -11),
                ("\(fold.outOfSample.tradeCount)", -6),
            ])
        }

        Out.rule()
        Out.heading("样本外拼接（这才是你能实际拿到的结果）")
        Lab.printMetrics(result.stitchedMetrics, capital: capital)
        Out.rule()
        Out.kv("效率比", PriceFormatter.ratio(result.efficiency) + "   （< 0.5 判为过拟合）")
        Out.kv("盈利折数", "\(result.profitableFolds)/\(result.folds.count)")
        Out.kv("累计尝试", "\(result.totalTrials) 组参数")
        for warning in result.warnings { Out.warn(warning) }

        let daily = result.stitchedMetrics.dailyReturnPct
        if daily >= 0.5 {
            Out.good("样本外日均 \(Out.signed(daily, decimals: 3))，达到 0.5% 目标")
        } else {
            Out.bad("样本外日均 \(Out.signed(daily, decimals: 3))，未达 0.5% 目标")
        }
        print("\n  结论：\(result.verdict)")
    }

    // MARK: portfolio

    static func portfolio(_ arguments: Arguments) async throws {
        guard arguments.positionals.count >= 2 else {
            throw LabError.usage("用法：maystock-lab portfolio <策略A> <策略B> [--weights 0.5,0.5]")
        }
        let capital = arguments.double("capital", default: 30_000)
        let days = arguments.int("days", default: 365)
        let schedule = Lab.feeSchedule(from: arguments)

        let strategies = try arguments.positionals.map { try Lab.loadManifest($0).compile() }
        var weights = arguments.string("weights")?
            .split(separator: ",").compactMap { Double($0) } ?? []
        if weights.count != strategies.count {
            weights = Array(repeating: 1.0 / Double(strategies.count), count: strategies.count)
        }

        Out.heading("组合回测")
        Out.kv("本金", "\(PriceFormatter.money(capital, decimals: 0)) USDT")
        Out.kv("费率", schedule.summary)

        var legs: [PortfolioLeg] = []
        for (index, strategy) in strategies.enumerated() {
            let data = try await Lab.fetchMarketData(strategy: strategy, days: days)
            let candles = data.candles
            var config = BacktestConfig(
                initialCapital: capital * weights[index], feeSchedule: schedule,
                externalSeries: data.series)
            if strategy.market.instType == .swap, let first = candles.first {
                config.fundingRates = (try? await OKXRESTClient().fundingRateHistory(
                    instId: strategy.market.instId, since: first.ts, limit: days * 3 + 10)) ?? []
            }
            let result = try BacktestEngine(strategy: strategy, config: config).run(candles: candles)
            legs.append(PortfolioLeg(
                strategyId: strategy.id, strategyName: strategy.name,
                instId: strategy.market.instId, weight: weights[index], result: result))
        }

        Out.rule()
        Out.row([("腿", 22), ("标的", 16), ("权重", -7), ("日均", -9),
                 ("总收益", -10), ("回撤", -8), ("交易", -6)])
        for leg in legs {
            let m = leg.result.metrics
            Out.row([
                (leg.strategyName, 22),
                (leg.instId, 16),
                (PriceFormatter.percent(leg.weight * 100), -7),
                (Out.tinted(m.dailyReturnPct, Out.signed(m.dailyReturnPct, decimals: 3)), -9),
                (Out.tinted(m.totalReturnPct, Out.signed(m.totalReturnPct)), -10),
                ("-" + PriceFormatter.percent(m.maxDrawdownPct, decimals: 1), -8),
                ("\(m.tradeCount)", -6),
            ])
        }

        let combined = PortfolioBacktest.combine(legs: legs, initialCapital: capital)
        Out.rule()
        Out.heading("组合合计")
        Lab.printMetrics(combined.metrics, capital: capital)
        Out.rule()
        Out.kv("分散化", "各腿加权回撤 \(PriceFormatter.percent(combined.undiversifiedDrawdownPct, decimals: 2))"
               + " → 组合 \(PriceFormatter.percent(combined.metrics.maxDrawdownPct, decimals: 2))"
               + "（改善 \(PriceFormatter.percent(combined.diversificationBenefitPct, decimals: 2))）")
        for (pair, correlation) in combined.correlations.sorted(by: { $0.key < $1.key }) {
            Out.kv("相关性", "\(pair.replacingOccurrences(of: "|", with: " ↔ ")) = "
                   + PriceFormatter.ratio(correlation)
                   + (correlation > 0.8 ? "   （过高，几乎没有分散效果）" : ""))
        }
        Out.kv("终值", "\(PriceFormatter.money(combined.finalEquity)) USDT")
    }

    // MARK: fees

    static func fees(_ arguments: Arguments) async throws {
        var schedule = Lab.feeSchedule(from: arguments)

        if arguments.has("sync") {
            let bridge = TradeBridge()
            guard bridge.resolveCLIPath() != nil else { throw TradeError.cliNotFound }
            guard bridge.hasCredentials() else { throw TradeError.notConfigured }
            let mode: TradingMode = arguments.has("live") ? .live : .demo
            for instType in InstrumentType.allCases {
                if let rates = try? await bridge.feeRates(instType: instType, mode: mode) {
                    schedule.apply(rates)
                    Out.good("同步 \(instType.displayName)：maker "
                             + "\(PriceFormatter.decimals(rates.makerBps, 3)) bps · taker "
                             + "\(PriceFormatter.decimals(rates.takerBps, 3)) bps")
                } else {
                    Out.warn("\(instType.displayName) 费率同步失败")
                }
            }
        }

        Out.heading("OKX 费率档位（当前：\(schedule.tier.displayName)"
                    + (schedule.syncedFromAccount ? "，已被账户实时费率覆盖" : "") + "）")
        Out.row([("档位", 10), ("现货 maker", -12), ("现货 taker", -12),
                 ("永续 maker", -12), ("永续 taker", -12), ("门槛", 2)])
        for tier in OKXFeeTier.allCases {
            let marker = tier == schedule.tier ? "▸ " : "  "
            Out.row([
                (marker + tier.displayName, 10),
                (PriceFormatter.decimals(tier.spotMakerBps, 3) + " bps", -12),
                (PriceFormatter.decimals(tier.spotTakerBps, 3) + " bps", -12),
                (PriceFormatter.decimals(tier.swapMakerBps, 3) + " bps", -12),
                (PriceFormatter.decimals(tier.swapTakerBps, 3) + " bps", -12),
                (tier.requirement, 2),
            ])
        }
        Out.rule()
        Out.kv("当前生效", schedule.summary)
        Out.kv("往返成本", "现货 \(PriceFormatter.percent(schedule.roundTripCostPct(for: .spot), decimals: 3))"
               + " · 永续 \(PriceFormatter.percent(schedule.roundTripCostPct(for: .swap), decimals: 3))")
        Out.note("档位表为公开资料整理，可能滞后于官方调整；--sync 会用本账户的真实费率覆盖它。")
        Out.note("每天来回一次现货，光成本就吃掉约 "
                 + PriceFormatter.percent(schedule.roundTripCostPct(for: .spot) * 30, decimals: 1)
                 + " 的月收益。")
    }

    // MARK: scaffolding

    static func newStrategy(_ arguments: Arguments) throws {
        guard let name = arguments.positionals.first else {
            throw LabError.usage("用法：maystock-lab new <名称> [--template trend]")
        }
        let template = arguments.string("template", default: "trend") ?? "trend"
        let instId = arguments.string("instId", default: "BTC-USDT")!
        let barRaw = arguments.string("bar", default: "1H")!
        guard let bar = BarInterval(rawValue: barRaw) else {
            throw LabError.usage("无效的 K 线周期：\(barRaw)（可选 \(BarInterval.allCases.map(\.rawValue).joined(separator: " ")))")
        }

        var manifest = try StrategyTemplates.make(template: template, name: name,
                                                  instId: instId, bar: bar)
        manifest.id = StrategyManifest.slug(from: name)
        _ = try manifest.compile()   // never scaffold something that won't run

        let directory = URL(fileURLWithPath: "Strategies")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(manifest.id + ".json")
        try manifest.encoded().write(to: url, options: .atomic)

        Out.good("已生成 \(url.path)")
        Out.note("回测：maystock-lab backtest \(manifest.id) --capital 30000")
        Out.note("寻优：maystock-lab optimize \(manifest.id) --objective calmar --max-dd 10")
        Out.note("验证：maystock-lab walkforward \(manifest.id) --folds 4")
        Out.note("语法与字段说明见 docs/STRATEGY-DEV.md")
    }

    // MARK: signals

    /// Probe every alternative data source and report what it actually returns.
    /// History depth, not availability, decides whether a signal can be
    /// validated — so measure it rather than trusting documentation.
    static func signals(_ arguments: Arguments) async throws {
        let ccy = arguments.string("ccy", default: "BTC")!
        let barRaw = arguments.string("bar", default: "1H")!
        guard let bar = BarInterval(rawValue: barRaw) else {
            throw LabError.usage("无效周期：\(barRaw)")
        }
        let instId = arguments.string("instId", default: ccy + "-USDT")!
        let market = StrategyMarket(instId: instId, instType: .spot, bar: bar)
        let provider = AlternativeDataProvider()

        Out.heading("另类数据源实测（\(ccy) · \(bar.rawValue)）")
        Out.row([("source", 18), ("名称", 18), ("来源", 22), ("点数", -8),
                 ("跨度(天)", -11), ("接口上限(天)", -15)])

        var failures: [(String, String)] = []
        for source in AlternativeSeriesSource.allCases {
            let spec = AlternativeSeriesSpec(source: source).resolved(against: market)
            var observations: [SeriesObservation] = []
            do {
                observations = try await provider.fetch(spec, bar: bar, days: 400)
            } catch {
                // Swallowing this would report "0 points" for a source that is
                // merely unreachable, which is a different problem entirely.
                failures.append((source.rawValue, String(describing: error)))
            }
            var span = 0.0
            if let lo = observations.map(\.ts).min(), let hi = observations.map(\.ts).max() {
                span = hi.timeIntervalSince(lo) / 86_400
            }
            let limit = source.historyLimitDays(bar: bar)
            Out.row([
                (source.rawValue, 18),
                (source.displayName, 18),
                (source.provider, 22),
                ("\(observations.count)", -8),
                (PriceFormatter.decimals(span, 0), -11),
                (limit.map(String.init) ?? "不限", -15),
            ])
        }
        Out.rule()
        for (name, reason) in failures { Out.bad("\(name) 拉取失败：\(reason)") }
        Out.note("在清单的 data 块里声明即可作为变量使用：")
        print(#"    "data": { "funding": { "source": "fundingRate" } },"#)
        print(#"    "signals": { "longEntry": "funding < -0.0001 and close > sma(close, 50)" }"#)
        Out.note("跨度短的源撑不起长窗口验证 —— backtest / walkforward 会明确警告覆盖不足。")
    }

    // MARK: ic

    /// Score a signal against forward returns across several horizons.
    static func informationCoefficient(_ arguments: Arguments) async throws {
        guard let raw = arguments.positionals.first,
              let source = AlternativeSeriesSource(rawValue: raw) else {
            let names = AlternativeSeriesSource.allCases.map(\.rawValue).joined(separator: " ")
            throw LabError.usage("用法：maystock-lab ic <source>\n可选：\(names)")
        }
        let ccy = arguments.string("ccy", default: "BTC")!
        let barRaw = arguments.string("bar", default: "4H")!
        guard let bar = BarInterval(rawValue: barRaw) else {
            throw LabError.usage("无效周期：\(barRaw)")
        }
        let days = arguments.int("days", default: 90)
        let instId = arguments.string("instId", default: ccy + "-USDT")!
        let horizons = (arguments.string("horizons") ?? "1,3,6,12")
            .split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 }

        let market = StrategyMarket(instId: instId, instType: .spot, bar: bar)
        let rest = OKXRESTClient()
        let bars = Int((Double(days) * 86_400 / bar.seconds).rounded(.up))
        let candles = try await rest.historyCandles(
            instId: instId, bar: bar, target: Swift.min(bars, BacktestRunner.maxBars))
        let spec = AlternativeSeriesSpec(source: source).resolved(against: market)
        let observations = try await AlternativeDataProvider(rest: rest)
            .fetch(spec, bar: bar, days: days)
        let rawSeries = SeriesAligner.align(
            observations, to: candles,
            timing: spec.isBarBased ? .bar(seconds: bar.seconds) : .instant,
            candleSeconds: bar.seconds)
        let transform = arguments.string("transform", default: "raw")!
        let aligned = try Lab.applyTransform(transform, to: rawSeries)
        let coverage = SeriesAligner.coverage(
            name: source.rawValue, spec: spec, observations: observations, aligned: rawSeries)

        Out.heading("信息系数 · \(source.displayName) → \(instId) 未来收益")
        Out.kv("数据", coverage.summary)
        Out.kv("K 线", "\(candles.count) 根 \(bar.rawValue)")
        Out.kv("变换", transform == "raw"
               ? "raw（原始水平值 —— 非平稳序列建议改用 roc:N 或 z:N）" : transform)
        if !coverage.isUsable {
            Out.warn("覆盖不足，下面的结论只对有数据的区间成立")
        }
        Out.rule()
        Out.row([("horizon", 9), ("样本", -7), ("有效样本", -10), ("Spearman", -10),
                 ("裸 t", -7), ("修正 t", -8), ("首尾分位差", -12), ("单调", -6)])
        var results: [SignalIC] = []
        for horizon in horizons {
            let ic = SignalAnalysis.informationCoefficient(
                signal: aligned, candles: candles, horizonBars: horizon)
            results.append(ic)
            Out.row([
                ("\(horizon) 根", 9),
                ("\(ic.observations)", -7),
                ("\(ic.effectiveObservations)", -10),
                (PriceFormatter.decimals(ic.spearman, 3), -10),
                (PriceFormatter.decimals(ic.tStatistic, 2), -7),
                (PriceFormatter.decimals(ic.adjustedTStatistic, 2), -8),
                (Out.tinted(ic.spread, PriceFormatter.decimals(ic.spread, 3) + "%"), -12),
                (ic.isMonotonic ? "是" : "否", -6),
            ])
        }

        Out.rule()
        let trials = arguments.int("trials", default: horizons.count)
        for (horizon, ic) in zip(horizons, results) {
            Out.kv("\(horizon) 根", SignalAnalysis.verdict(ic, trials: trials))
        }
        Out.kv("多重检验", "本次 \(trials) 个组合，门槛 |t| > "
               + PriceFormatter.decimals(SignalIC.multipleTestingThreshold(trials: trials), 2)
               + "（用 --trials N 传入你实际扫过的组合总数）")
        if let best = results.max(by: { abs($0.tStatistic) < abs($1.tStatistic) }),
           best.observations > 10 {
            Out.heading("分位收益（信号从低到高，\(best.horizonBars) 根前瞻）")
            for (index, value) in best.quintileReturns.enumerated() {
                let bar = String(repeating: value >= 0 ? "█" : "░",
                                 count: Swift.min(Int(abs(value) * 20), 40))
                Out.row([("Q\(index + 1)", 5),
                         (Out.tinted(value, PriceFormatter.decimals(value, 3) + "%"), -10),
                         (" " + bar, 2)])
            }
        }
        Out.rule()
        Out.note("重叠修正：h 根前瞻的相邻观测共享 h−1 根，有效样本约 n/h，裸 t 要除以 √h。"
                 + "跳过这一步是加密「信号研究」制造显著性的最常见方式。")
        Out.note("显著 ≠ 可交易：还要扣掉往返成本 "
                 + PriceFormatter.percent(OKXFeeSchedule().roundTripCostPct(for: .spot), decimals: 3)
                 + "，且需通过 walkforward 验证。")
    }

    // MARK: factors

    /// Cross-sectional three-factor study.
    ///
    /// Everything else in this tool times one instrument. This ranks a universe
    /// against itself, which is the setup Liu, Tsyvinski & Wu (JF 2022) found
    /// actually explains crypto returns — and the setup whose biases are
    /// easiest to hide, so they are printed whether you ask or not.
    static func factors(_ arguments: Arguments) async throws {
        let size = arguments.int("size", default: 40)
        let days = arguments.int("days", default: 365)
        let capital = arguments.double("capital", default: 30_000)
        let schedule = Lab.feeSchedule(from: arguments)

        Out.heading("横截面因子研究")
        Out.kv("宇宙", "OKX USDT 现货，按市值取前 \(size)")
        Out.kv("区间", "\(days) 天，日线")
        Out.kv("调仓", "每 \(arguments.int("rebalance", default: 7)) 根，"
               + "多空各取 \(PriceFormatter.percent(arguments.double("leg", default: 0.2) * 100)) 分位")
        Out.kv("动量", "回看 \(arguments.int("lookback", default: 28)) 根，"
               + "跳过最近 \(arguments.int("skip", default: 7)) 根")
        Out.kv("费率", schedule.summary)

        let builder = UniverseBuilder()
        let universe = try await builder.build(
            size: size, days: days, bar: .d1,
            onProgress: { message in
                FileHandle.standardError.write(Data("  \(message)\r".utf8))
            })
        FileHandle.standardError.write(Data((String(repeating: " ", count: 60) + "\r").utf8))

        Out.kv("实际宇宙", "\(universe.assets.count) 个币 · "
               + "共同交易日 \(universe.calendar.count) 天")
        guard universe.assets.count >= 10, universe.calendar.count > 60 else {
            throw LabError.usage("宇宙太小或历史太短，无法做横截面研究")
        }
        Out.note("成分：" + universe.assets.prefix(14).map(\.symbol).joined(separator: " ")
                 + (universe.assets.count > 14 ? " …" : ""))
        if !universe.biases.excludedPegged.isEmpty {
            Out.note("已剔除锚定资产（稳定币/黄金代币/包装币）："
                     + universe.biases.excludedPegged.joined(separator: " "))
        }

        let model = FactorModel(
            universe: universe,
            rebalanceBars: arguments.int("rebalance", default: 7),
            lookbackBars: arguments.int("lookback", default: 28),
            skipBars: arguments.int("skip", default: 7),
            legFraction: arguments.double("leg", default: 0.2),
            feeSchedule: schedule)

        Out.rule()
        Out.row([("因子", 20), ("多空均值", -11), ("t 值", -8), ("多空累计", -11),
                 ("仅做多", -11), ("市场", -10), ("换手", -8)])

        var results: [FactorBacktestResult] = []
        for factor in CrossSectionalFactor.allCases {
            let result = model.run(factor: factor, initialCapital: capital)
            results.append(result)
            guard !result.periods.isEmpty else { continue }
            Out.row([
                (factor.displayName, 20),
                (factor.isRankable
                 ? Out.tinted(result.meanLongShortReturn,
                              Out.signed(result.meanLongShortReturn, decimals: 3)) : "—", -11),
                (factor.isRankable
                 ? PriceFormatter.decimals(result.longShortTStatistic, 2) : "—", -8),
                (factor.isRankable
                 ? Out.tinted(result.longShortMetrics.totalReturnPct,
                              Out.signed(result.longShortMetrics.totalReturnPct)) : "—", -11),
                (Out.tinted(result.longOnlyMetrics.totalReturnPct,
                            Out.signed(result.longOnlyMetrics.totalReturnPct)), -11),
                (Out.tinted(result.marketMetrics.totalReturnPct,
                            Out.signed(result.marketMetrics.totalReturnPct)), -10),
                (factor.isRankable ? PriceFormatter.percent(result.turnover * 100) : "—", -8),
            ])
        }

        Out.rule()
        for result in results where result.factor.isRankable && !result.periods.isEmpty {
            Out.kv(result.factor.displayName, result.verdict)
        }
        if let sample = results.first(where: { !$0.periods.isEmpty }) {
            Out.kv("调仓次数", "\(sample.periods.count) 次")
            Out.kv("单次成本", PriceFormatter.percent(sample.costPerRebalancePct, decimals: 3)
                   + " × 换手率（只对换手的名字计费）")
            let threshold = SignalIC.multipleTestingThreshold(
                trials: CrossSectionalFactor.allCases.count - 1)
            Out.kv("多重检验", "3 个可排序因子 → 门槛 |t| > "
                   + PriceFormatter.decimals(threshold, 2))
        }

        Out.heading("已知偏差（横截面研究里最容易被藏起来的部分）")
        for note in (results.first?.biases.notes ?? []) { Out.warn(note) }
        Out.note("做空腿未计融券成本与可借券约束；现货做空在 OKX 需要杠杆账户，"
                 + "「仅做多」那一列才是现货可直接实现的口径。")
    }

    // MARK: oracle

    /// The ceiling nobody can reach, and how much chart "structure" is real.
    static func oracle(_ arguments: Arguments) async throws {
        let instId = arguments.string("instId", default: "BTC-USDT")!
        let barRaw = arguments.string("bar", default: "1D")!
        guard let bar = BarInterval(rawValue: barRaw) else {
            throw LabError.usage("无效周期：\(barRaw)")
        }
        let days = arguments.int("days", default: 1_400)
        let schedule = Lab.feeSchedule(from: arguments)
        let roundTrip = schedule.roundTripCostPct(for: .spot)
        let thresholds = (arguments.string("swings") ?? "3,5,10,20")
            .split(separator: ",").compactMap { Double($0) }.filter { $0 > 0 }

        let bars = Int((Double(days) * 86_400 / bar.seconds).rounded(.up))
        let candles = try await OKXRESTClient().historyCandles(
            instId: instId, bar: bar, target: Swift.min(bars, BacktestRunner.maxBars))
        guard candles.count > 30 else { throw LabError.usage("历史不足") }

        Out.heading("上帝视角上限 · \(instId) · \(bar.rawValue)")
        Out.kv("区间", "\(candles.first!.ts.formatted(date: .numeric, time: .omitted))"
               + " → \(candles.last!.ts.formatted(date: .numeric, time: .omitted))"
               + "（\(candles.count) 根）")
        Out.kv("成本", "往返 \(PriceFormatter.percent(roundTrip, decimals: 3))（每个波段都要付）")
        Out.rule()
        Out.row([("最小波段", 10), ("波段数", -8), ("完美多空", -14), ("完美只做多", -14),
                 ("买入持有", -12), ("完美日均", -11)])

        for threshold in thresholds {
            let result = ForesightAnalysis.perfectForesight(
                candles: candles, minimumSwingPct: threshold, roundTripCostPct: roundTrip)
            Out.row([
                (PriceFormatter.percent(threshold, decimals: 0), 10),
                ("\(result.swings.count)", -8),
                (Out.tinted(result.perfectReturnPct,
                            Out.signed(result.perfectReturnPct, decimals: 0)), -14),
                (Out.tinted(result.perfectLongOnlyReturnPct,
                            Out.signed(result.perfectLongOnlyReturnPct, decimals: 0)), -14),
                (Out.signed(result.buyHoldReturnPct, decimals: 0), -12),
                (Out.signed(result.perfectDailyPct, decimals: 3), -11),
            ])
        }
        Out.note("以上是**知道未来**才能拿到的数字。它不是目标，是任何策略都不可能越过的天花板。")

        // How much of the "structure" actually holds.
        Out.heading("前高前低到底挡不挡得住价格（无未来函数）")
        let spanDays = candles.last!.ts.timeIntervalSince(candles.first!.ts) / 86_400
        Out.row([("最小波段", 10), ("触碰", -7), ("挡住", -7), ("破", -6),
                 ("挡住率", -9), ("z 值", -8), ("押注期望", -11), ("年化边际", -11)])
        for threshold in thresholds {
            let level = ForesightAnalysis.levelReliability(
                candles: candles, minimumSwingPct: threshold,
                tolerancePct: arguments.double("tolerance", default: 0.5),
                targetPct: arguments.double("target", default: 2),
                roundTripCostPct: roundTrip)
            guard level.tests > 0 else { continue }
            Out.row([
                (PriceFormatter.percent(threshold, decimals: 0), 10),
                ("\(level.tests)", -7),
                ("\(level.held)", -7),
                ("\(level.broken)", -6),
                (PriceFormatter.percent(level.holdRate * 100, decimals: 1), -9),
                (PriceFormatter.decimals(level.zStatistic, 2), -8),
                (Out.tinted(level.expectancyPct,
                            Out.signed(level.expectancyPct, decimals: 2)), -11),
                (Out.tinted(level.annualEdgePct(overDays: spanDays),
                            Out.signed(level.annualEdgePct(overDays: spanDays), decimals: 1)), -11),
            ])
        }
        Out.rule()
        Out.note("「挡住」= 触碰后先反向走 "
                 + PriceFormatter.percent(arguments.double("target", default: 2), decimals: 0)
                 + "；「跌破/突破」= 先同向走同样幅度。50% 就是抛硬币。")
        Out.note("押注期望已扣除往返成本 "
                 + PriceFormatter.percent(roundTrip, decimals: 3)
                 + "；「年化边际」= 期望 × 每年出现次数，即全都做才拿得到的量。")
        Out.note("z 值是挡住率对「抛硬币」的检验：|z| > 2 才算不是运气。"
                 + "本次测了 \(thresholds.count) 组，多重检验门槛 |z| > "
                 + PriceFormatter.decimals(
                    SignalIC.multipleTestingThreshold(trials: thresholds.count), 2) + "。")
    }

    static func list() {
        Out.heading("内置策略")
        for preset in StrategyLibrary.presets {
            Out.row([(preset.id, 24), (preset.name, 22),
                     ("\(preset.market.instId) \(preset.market.bar.rawValue)", 20)])
        }
        let directory = URL(fileURLWithPath: "Strategies")
        let store = StrategyStore(directory: directory)
        let local = store.load()
        if !local.isEmpty {
            Out.heading("Strategies/")
            for manifest in local {
                Out.row([(manifest.id, 24), (manifest.name, 22),
                         ("\(manifest.market.instId) \(manifest.market.bar.rawValue)", 20)])
            }
        }
        let examples = StrategyStore(directory: directory.appendingPathComponent("examples")).load()
        if !examples.isEmpty {
            Out.heading("Strategies/examples/")
            for manifest in examples {
                Out.row([(manifest.id, 24), (manifest.name, 22),
                         ("\(manifest.market.instId) \(manifest.market.bar.rawValue)", 20)])
            }
        }
    }
}
