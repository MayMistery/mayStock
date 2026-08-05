import Foundation

/// Ready-made strategies shipped with the app.
///
/// They exist for two reasons: somebody opening the studio for the first time
/// has something real to backtest, and anyone writing their own manifest has a
/// correct example of every field to copy from. All of them are classic,
/// published low-frequency ideas — none is tuned to recent data, which is
/// exactly why their robustness badges are worth reading.
public enum StrategyLibrary {

    public static var presets: [StrategyManifest] {
        [emaTrend, rsiReversion, donchianBreakout, bollingerReversion, dualMomentum]
    }

    /// Compiled presets, silently dropping any that fail validation — the test
    /// suite asserts none ever do.
    public static var compiledPresets: [CompiledStrategy] {
        presets.compactMap { try? $0.compile() }
    }

    // MARK: Trend following

    public static let emaTrend = StrategyManifest(
        id: "ema-trend",
        name: "EMA 双均线趋势",
        author: "MayStock",
        notes: "经典趋势跟随：快慢 EMA 金叉入场、死叉离场，且只在长期均线之上做多。",
        market: StrategyMarket(instId: "BTC-USDT", instType: .spot, bar: .h1),
        params: StrategyParameterSet([
            StrategyParameter(name: "fast", value: 12, minimum: 2, maximum: 100, label: "快线周期"),
            StrategyParameter(name: "slow", value: 26, minimum: 5, maximum: 400, label: "慢线周期"),
            StrategyParameter(name: "trend", value: 200, minimum: 20, maximum: 500, label: "趋势过滤"),
        ]),
        signals: StrategySignals(
            longEntry: "ema(close, fast) crosses_above ema(close, slow) and close > sma(close, trend)",
            longExit: "ema(close, fast) crosses_below ema(close, slow)"),
        sizing: StrategySizing(mode: .equityPct, value: 100),
        risk: StrategyRisk(stopLossPct: 4, cooldownBars: 1))

    /// Turtle-style channel breakout, the only preset that also goes short.
    public static let donchianBreakout = StrategyManifest(
        id: "donchian-breakout",
        name: "唐奇安通道突破",
        author: "MayStock",
        notes: "突破 N 根高点做多、跌破 N 根低点做空，ATR 止损，2× 杠杆。通道取上一根，避免拿当根自己比自己。",
        market: StrategyMarket(instId: "BTC-USDT-SWAP", instType: .swap, bar: .h4),
        params: StrategyParameterSet([
            StrategyParameter(name: "entryLen", value: 20, minimum: 5, maximum: 200, label: "入场通道"),
            StrategyParameter(name: "exitLen", value: 10, minimum: 3, maximum: 100, label: "离场通道"),
        ]),
        signals: StrategySignals(
            longEntry: "close > ref(highest(high, entryLen), 1)",
            longExit: "close < ref(lowest(low, exitLen), 1)",
            shortEntry: "close < ref(lowest(low, entryLen), 1)",
            shortExit: "close > ref(highest(high, exitLen), 1)"),
        sizing: StrategySizing(mode: .riskPerTrade, value: 1),
        risk: StrategyRisk(atrStop: ATRStop(period: 14, mult: 2.5), leverage: 2, maxDailyLossPct: 5))

    /// Absolute momentum with a trend filter, on daily bars.
    public static let dualMomentum = StrategyManifest(
        id: "dual-momentum",
        name: "双动量轮动",
        author: "MayStock",
        notes: "N 日涨幅超过阈值且站上长期均线才持有，动量转负即离场；日线级别，换手极低。",
        market: StrategyMarket(instId: "BTC-USDT", instType: .spot, bar: .d1),
        params: StrategyParameterSet([
            StrategyParameter(name: "lookback", value: 30, minimum: 5, maximum: 250, label: "动量窗口"),
            StrategyParameter(name: "threshold", value: 5, minimum: 0, maximum: 100, label: "动量阈值 %"),
            StrategyParameter(name: "trend", value: 100, minimum: 20, maximum: 400, label: "趋势过滤"),
        ]),
        signals: StrategySignals(
            longEntry: "roc(close, lookback) > threshold and close > sma(close, trend)",
            longExit: "roc(close, lookback) < 0 or close < sma(close, trend)"),
        sizing: StrategySizing(mode: .equityPct, value: 100),
        risk: StrategyRisk(trailingStopPct: 12))

    // MARK: Mean reversion

    public static let rsiReversion = StrategyManifest(
        id: "rsi-reversion",
        name: "RSI 均值回归",
        author: "MayStock",
        notes: "超卖回升时买入、回到中性区离场；仍以长期均线做方向过滤，不在下跌趋势里接刀。",
        market: StrategyMarket(instId: "BTC-USDT", instType: .spot, bar: .h1),
        params: StrategyParameterSet([
            StrategyParameter(name: "period", value: 14, minimum: 2, maximum: 100, label: "RSI 周期"),
            StrategyParameter(name: "oversold", value: 30, minimum: 5, maximum: 50, label: "超卖线"),
            StrategyParameter(name: "overbought", value: 60, minimum: 50, maximum: 95, label: "离场线"),
            StrategyParameter(name: "trend", value: 200, minimum: 20, maximum: 500, label: "趋势过滤"),
        ]),
        signals: StrategySignals(
            longEntry: "rsi(close, period) crosses_above oversold and close > sma(close, trend)",
            longExit: "rsi(close, period) > overbought or close < sma(close, trend)"),
        sizing: StrategySizing(mode: .equityPct, value: 100),
        risk: StrategyRisk(stopLossPct: 3, takeProfitPct: 6, minHoldBars: 1))

    public static let bollingerReversion = StrategyManifest(
        id: "bollinger-reversion",
        name: "布林带回归",
        author: "MayStock",
        notes: "价格自下轨回升时买入，回到中轨止盈 —— 震荡市有效，单边下跌靠止损兜底。",
        market: StrategyMarket(instId: "ETH-USDT", instType: .spot, bar: .h4),
        params: StrategyParameterSet([
            StrategyParameter(name: "period", value: 20, minimum: 5, maximum: 200, label: "均线周期"),
            StrategyParameter(name: "mult", value: 2, minimum: 0.5, maximum: 4, label: "带宽倍数", step: 0.1),
        ]),
        signals: StrategySignals(
            longEntry: "close crosses_above bb_lower(close, period, mult)",
            longExit: "close crosses_above sma(close, period)"),
        sizing: StrategySizing(mode: .equityPct, value: 100),
        risk: StrategyRisk(stopLossPct: 5, cooldownBars: 1))
}
