import Foundation
import MayStockKit

/// Starting points for `maystock-lab new`.
///
/// Every template declares `min`/`max` on its parameters — without a range the
/// optimiser has nothing to search, so a scaffold that omitted them would be a
/// dead end the moment you tried to tune it.
enum StrategyTemplates {

    static let names = ["trend", "reversion", "breakout", "grid"]

    static func make(
        template: String, name: String, instId: String, bar: BarInterval
    ) throws -> StrategyManifest {
        let instType: InstrumentType = instId.hasSuffix("-SWAP") ? .swap : .spot
        let market = StrategyMarket(instId: instId, instType: instType, bar: bar)

        switch template {
        case "trend":
            return StrategyManifest(
                id: StrategyManifest.slug(from: name),
                name: name,
                notes: "趋势跟随脚手架：快慢均线交叉入场，长期均线做方向过滤。"
                    + "先跑 walkforward 再谈参数好坏。",
                market: market,
                params: StrategyParameterSet([
                    StrategyParameter(name: "fast", value: 12, minimum: 4, maximum: 60, label: "快线周期"),
                    StrategyParameter(name: "slow", value: 26, minimum: 10, maximum: 200, label: "慢线周期"),
                    StrategyParameter(name: "trend", value: 200, minimum: 50, maximum: 300, label: "趋势过滤"),
                ]),
                signals: StrategySignals(
                    longEntry: "ema(close, fast) crosses_above ema(close, slow) and close > sma(close, trend)",
                    longExit: "ema(close, fast) crosses_below ema(close, slow)"),
                sizing: StrategySizing(mode: .equityPct, value: 100),
                risk: StrategyRisk(stopLossPct: 4, cooldownBars: 1))

        case "reversion":
            return StrategyManifest(
                id: StrategyManifest.slug(from: name),
                name: name,
                notes: "均值回归脚手架：超卖回升买入，回到中性离场，趋势过滤避免接下跌的刀。",
                market: market,
                params: StrategyParameterSet([
                    StrategyParameter(name: "period", value: 14, minimum: 4, maximum: 40, label: "RSI 周期"),
                    StrategyParameter(name: "oversold", value: 30, minimum: 10, maximum: 45, label: "超卖线"),
                    StrategyParameter(name: "exitLevel", value: 60, minimum: 50, maximum: 85, label: "离场线"),
                    StrategyParameter(name: "trend", value: 200, minimum: 50, maximum: 300, label: "趋势过滤"),
                ]),
                signals: StrategySignals(
                    longEntry: "rsi(close, period) crosses_above oversold and close > sma(close, trend)",
                    longExit: "rsi(close, period) > exitLevel or close < sma(close, trend)"),
                sizing: StrategySizing(mode: .equityPct, value: 100),
                risk: StrategyRisk(stopLossPct: 3, takeProfitPct: 6, minHoldBars: 1))

        case "breakout":
            return StrategyManifest(
                id: StrategyManifest.slug(from: name),
                name: name,
                notes: "通道突破脚手架：突破前 N 根高点入场，跌破 M 根低点离场。"
                    + "通道一律取上一根（ref(...,1)），否则等于拿当根自己比自己。",
                market: market,
                params: StrategyParameterSet([
                    StrategyParameter(name: "entryLen", value: 20, minimum: 8, maximum: 120, label: "入场通道"),
                    StrategyParameter(name: "exitLen", value: 10, minimum: 4, maximum: 60, label: "离场通道"),
                    StrategyParameter(name: "atrMult", value: 2.5, minimum: 1, maximum: 5,
                                      label: "ATR 止损倍数", step: 0.5),
                ]),
                signals: StrategySignals(
                    longEntry: "close > ref(highest(high, entryLen), 1)",
                    longExit: "close < ref(lowest(low, exitLen), 1)"),
                sizing: StrategySizing(mode: .equityPct, value: 100),
                risk: StrategyRisk(atrStop: ATRStop(period: 14, mult: 2.5), maxDailyLossPct: 5))

        case "grid":
            return StrategyManifest(
                id: StrategyManifest.slug(from: name),
                name: name,
                notes: "区间低吸脚手架：跌破布林下轨买入、回中轨止盈 —— 震荡市有效，"
                    + "单边下跌靠止损兜底。注意：真正的网格请用 OKX 原生 `okx bot grid`，"
                    + "本引擎是单仓位模型，不做多层挂单。",
                market: market,
                params: StrategyParameterSet([
                    StrategyParameter(name: "period", value: 20, minimum: 10, maximum: 80, label: "均线周期"),
                    StrategyParameter(name: "mult", value: 2, minimum: 1, maximum: 3.5,
                                      label: "带宽倍数", step: 0.25),
                ]),
                signals: StrategySignals(
                    longEntry: "close crosses_above bb_lower(close, period, mult)",
                    longExit: "close crosses_above sma(close, period)"),
                sizing: StrategySizing(mode: .equityPct, value: 100),
                risk: StrategyRisk(stopLossPct: 5, cooldownBars: 1))

        default:
            throw LabError.usage("未知模板：\(template)（可选 \(names.joined(separator: " ")))")
        }
    }
}
