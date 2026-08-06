import Foundation
import CMayStockKernel

/// Swift face of the Rust trading kernel.
///
/// Everything deterministic — indicators, the strategy DSL, the backtest
/// engine, sizing and the live signal decision — lives in `kernel/` and is
/// reached through here. Swift keeps what it is genuinely better at: the
/// exchange connection, the UI, persistence, and async orchestration.
///
/// The split earns its keep in one specific place. The backtester and the live
/// runner used to be two Swift functions required to agree by convention; now
/// they are one compiled Rust function called from both sides, so "the backtest
/// runs what live trading runs" is a fact about the binary rather than a
/// promise in a comment.
public enum TradingKernel {

    /// Kernel ABI version, from the linked library rather than a Swift constant
    /// — a stale `.a` next to a fresh app shows up here.
    public static var version: String {
        guard let pointer = ms_kernel_version() else { return "unknown" }
        return String(cString: pointer)
    }

    /// Evaluate one DSL expression over candles. Warm-up positions come back as
    /// `Double.nan`, matching the kernel's "NaN means unknown" convention.
    public static func evaluate(
        _ expression: String, params: [String: Double] = [:], candles: [Candle],
        externalSeries: [String: [Double]] = [:]
    ) throws -> [Double] {
        let paramsJSON = try encodeJSON(params)
        let externalJSON = externalSeries.isEmpty ? nil : try encodeJSON(externalSeries)
        return try withKernelCandles(candles) { buffer, count in
            let json = try callReturningString { error in
                ms_evaluate_expression(expression, paramsJSON, buffer, count, externalJSON, error)
            }
            let decoded = try JSONDecoder().decode([Double?].self, from: Data(json.utf8))
            return decoded.map { $0 ?? .nan }
        }
    }
}

// MARK: - Errors

public enum KernelError: Error, CustomStringConvertible, Sendable {
    /// The kernel rejected the input; the message is the kernel's own, already
    /// localised, so it can be shown to the user unchanged.
    case kernel(String)
    case encoding(String)

    public var description: String {
        switch self {
        case .kernel(let message): return message
        case .encoding(let message): return "内核数据编码失败：\(message)"
        }
    }
}

// MARK: - Compiled strategy handle

/// A manifest compiled by the kernel.
///
/// Holds an opaque Rust allocation, so it is a `final class` with a `deinit`
/// rather than a struct: copying a struct would double-free the handle.
public final class KernelStrategy: @unchecked Sendable {
    private let handle: OpaquePointer

    /// Compile a strategy manifest.
    ///
    /// `knownSeries` names any externally supplied (non-OHLCV) series the
    /// manifest may reference, so a strategy reading `funding_rate` compiles
    /// instead of being rejected as an unknown identifier.
    public init(manifestJSON: String, knownSeries: [String] = []) throws {
        let seriesJSON = knownSeries.isEmpty ? nil : try encodeJSON(knownSeries)
        var error: UnsafeMutablePointer<CChar>?
        guard let handle = ms_strategy_compile(manifestJSON, seriesJSON, &error) else {
            throw KernelError.kernel(Self.take(&error) ?? "策略编译失败（内核未给出原因）")
        }
        self.handle = handle
    }

    public convenience init(manifest: Data, knownSeries: [String] = []) throws {
        guard let text = String(data: manifest, encoding: .utf8) else {
            throw KernelError.encoding("清单不是有效的 UTF-8")
        }
        try self.init(manifestJSON: text, knownSeries: knownSeries)
    }

    deinit {
        ms_strategy_free(handle)
    }

    /// Bars of history needed before this strategy's signals mean anything.
    public var warmupBars: Int {
        Int(ms_strategy_warmup_bars(handle))
    }

    /// True when the strategy holds a scaled position rather than switching in
    /// and out.
    public var isContinuous: Bool {
        ms_strategy_is_continuous(handle) == 1
    }

    public func describe() throws -> KernelStrategyInfo {
        let json = try callReturningString { error in
            ms_strategy_describe(self.handle, error)
        }
        return try JSONDecoder().decode(KernelStrategyInfo.self, from: Data(json.utf8))
    }

    // MARK: Live decision

    /// Decide the target position for the latest confirmed bar.
    ///
    /// This is the same code path the backtester takes on every bar; see the
    /// note on `TradingKernel`.
    /// Ask the kernel for a complete order plan.
    ///
    /// The account figures are inputs because sizing, the rebalance threshold
    /// and the daily-loss breaker all live in the kernel now. Swift's job is
    /// to submit `baseDelta` — it no longer decides how big anything should be.
    public func decide(
        candles: [Candle],
        current: TradeDirection?,
        barsHeld: Int = 0,
        externalSeries: [String: [Double]] = [:],
        account: KernelAccountState = KernelAccountState()
    ) throws -> KernelDecision {
        let externalJSON = externalSeries.isEmpty ? nil : try encodeJSON(externalSeries)
        return try withKernelCandles(candles) { buffer, count in
            let json = try callReturningString { error in
                ms_strategy_decide(
                    self.handle, buffer, count,
                    Int32(current.kernelCode), Int64(max(barsHeld, 0)), externalJSON,
                    account.equity, account.heldBase, account.dayStartEquity,
                    account.leverageCap ?? -1,
                    Int64(account.barsSinceExit ?? -1), account.haltedToday,
                    account.entryPrice, error)
            }
            return try JSONDecoder().decode(KernelDecision.self, from: Data(json.utf8))
        }
    }

    // MARK: Backtest

    public func backtest(
        candles: [Candle], config: KernelBacktestConfig = KernelBacktestConfig()
    ) throws -> KernelBacktestResult {
        let configJSON = try encodeJSON(config)
        return try withKernelCandles(candles) { buffer, count in
            let json = try callReturningString { error in
                ms_backtest_run(self.handle, buffer, count, configJSON, error)
            }
            return try JSONDecoder().decode(KernelBacktestResult.self, from: Data(json.utf8))
        }
    }

    fileprivate static func take(_ error: inout UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer = error else { return nil }
        defer {
            ms_string_free(pointer)
            error = nil
        }
        return String(cString: pointer)
    }
}

// MARK: - Bridging helpers

/// Copy Swift candles into the kernel's `#[repr(C)]` layout and hand the buffer
/// over for the duration of one call.
///
/// The buffer is stack-scoped: the kernel never retains it, and every entry
/// point takes the candles as a borrowed slice.
private func withKernelCandles<T>(
    _ candles: [Candle], _ body: (UnsafePointer<MSCandle>?, Int) throws -> T
) rethrows -> T {
    var buffer = [MSCandle]()
    buffer.reserveCapacity(candles.count)
    for candle in candles {
        buffer.append(MSCandle(
            ts_ms: Int64((candle.ts.timeIntervalSince1970 * 1000).rounded()),
            open: candle.open,
            high: candle.high,
            low: candle.low,
            close: candle.close,
            volume: candle.volume,
            confirmed: candle.confirmed ? 1 : 0))
    }
    return try buffer.withUnsafeBufferPointer { pointer in
        try body(pointer.baseAddress, buffer.count)
    }
}

/// Run a kernel call that returns an owned string, converting a null result
/// into the error the kernel wrote out.
private func callReturningString(
    _ call: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> UnsafeMutablePointer<CChar>?
) throws -> String {
    var error: UnsafeMutablePointer<CChar>?
    guard let result = call(&error) else {
        throw KernelError.kernel(KernelStrategy.take(&error) ?? "内核调用失败（未给出原因）")
    }
    defer { ms_string_free(result) }
    return String(cString: result)
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    do {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw KernelError.encoding("结果不是有效的 UTF-8")
        }
        return text
    } catch let error as KernelError {
        throw error
    } catch {
        throw KernelError.encoding(String(describing: error))
    }
}

extension Optional where Wrapped == TradeDirection {
    /// The kernel's direction encoding: 1 long, −1 short, 0 flat.
    var kernelCode: Int {
        switch self {
        case .some(.long): return 1
        case .some(.short): return -1
        case .none: return 0
        }
    }
}

extension TradeDirection {
    public static func fromKernelCode(_ code: Int32) -> TradeDirection? {
        switch code {
        case 1: return .long
        case -1: return .short
        default: return nil
        }
    }
}

// MARK: - Metrics over an arbitrary curve

extension TradingKernel {
    /// Performance statistics for an equity curve the kernel did not produce.
    ///
    /// The portfolio backtester and the factor tools combine several
    /// strategies' curves and then need the same numbers a single-strategy run
    /// reports. Routing them here keeps one Sharpe, one drawdown and one
    /// expectancy in the codebase.
    public static func metrics(
        trades: [BacktestTrade],
        equityCurve: [EquityPoint],
        initialCapital: Double,
        bar: BarInterval,
        freeParameterCount: Int
    ) throws -> KernelMetrics {
        let request = MetricsRequest(
            equityCurve: equityCurve.map {
                MetricsRequest.Point(
                    ts: Int64(($0.ts.timeIntervalSince1970 * 1000).rounded()),
                    equity: $0.equity, price: $0.price)
            },
            trades: trades.map(MetricsRequest.Trade.init(swift:)),
            initialCapital: initialCapital,
            bar: bar.rawValue,
            freeParameterCount: freeParameterCount)
        let json = try callReturningString { error in
            ms_metrics_compute(try? encodeJSON(request), error)
        }
        return try JSONDecoder().decode(KernelMetrics.self, from: Data(json.utf8))
    }

    /// What slippage this account is actually paying.
    ///
    /// Every fill is scored against the open of the bar it landed in, because
    /// that is precisely what the backtester models — so the number that comes
    /// back is directly comparable to the manifest's `slippageBps` rather than
    /// merely adjacent to it.
    public static func calibrateSlippage(
        fills: [StrategyFill], candles: [Candle], assumedBps: Double
    ) throws -> KernelSlippageReport {
        let request = SlippageRequest(
            fills: fills.map {
                SlippageRequest.Fill(
                    ts_ms: Int64(($0.ts.timeIntervalSince1970 * 1000).rounded()),
                    price: $0.price, side: $0.side == .buy ? 1 : -1)
            },
            candles: candles.map(SlippageRequest.Bar.init(swift:)),
            assumedBps: assumedBps)
        let json = try callReturningString { error in
            ms_calibrate_slippage(try? encodeJSON(request), error)
        }
        return try JSONDecoder().decode(KernelSlippageReport.self, from: Data(json.utf8))
    }

    /// How far live equity has drifted from the backtest that justified it.
    public static func compareEquity(
        live: [(ts: Date, equity: Double)], backtest: [(ts: Date, equity: Double)]
    ) throws -> KernelEquityComparison {
        func samples(_ points: [(ts: Date, equity: Double)]) -> [EquityRequest.Sample] {
            points.map {
                EquityRequest.Sample(
                    ts_ms: Int64(($0.ts.timeIntervalSince1970 * 1000).rounded()),
                    equity: $0.equity)
            }
        }
        let request = EquityRequest(live: samples(live), backtest: samples(backtest))
        let json = try callReturningString { error in
            ms_compare_equity(try? encodeJSON(request), error)
        }
        return try JSONDecoder().decode(KernelEquityComparison.self, from: Data(json.utf8))
    }
}

/// Wire shape for `ms_calibrate_slippage`.
///
/// Candles travel as JSON here rather than through the zero-copy buffer the
/// hot paths use: this runs once when a report is opened, and matching the
/// kernel's own field names keeps the request a plain struct on both sides.
private struct SlippageRequest: Encodable {
    struct Fill: Encodable {
        let ts_ms: Int64
        let price: Double
        let side: Int
    }
    struct Bar: Encodable {
        let ts_ms: Int64
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let volume: Double
        let confirmed: UInt8

        init(swift candle: Candle) {
            ts_ms = Int64((candle.ts.timeIntervalSince1970 * 1000).rounded())
            open = candle.open
            high = candle.high
            low = candle.low
            close = candle.close
            volume = candle.volume
            confirmed = candle.confirmed ? 1 : 0
        }
    }
    let fills: [Fill]
    let candles: [Bar]
    let assumedBps: Double
}

/// Wire shape for `ms_compare_equity`.
private struct EquityRequest: Encodable {
    struct Sample: Encodable {
        let ts_ms: Int64
        let equity: Double
    }
    let live: [Sample]
    let backtest: [Sample]
}

/// Wire shape for `ms_metrics_compute`. Mirrors the kernel's own `Trade` and
/// `EquityPoint` field names so it decodes without a translation layer there.
private struct MetricsRequest: Encodable {
    struct Point: Encodable {
        let ts: Int64
        let equity: Double
        let price: Double
    }

    struct Trade: Encodable {
        let id: Int
        let direction: TradeDirection
        let entryTs: Int64
        let exitTs: Int64
        let entryPrice: Double
        let exitPrice: Double
        let quantity: Double
        let notional: Double
        let grossPnL: Double
        let fees: Double
        let funding: Double
        let netPnL: Double
        let returnPct: Double
        let bars: Int
        let exitReason: String

        init(swift t: BacktestTrade) {
            id = t.id
            direction = t.direction
            entryTs = Int64((t.entryTime.timeIntervalSince1970 * 1000).rounded())
            exitTs = Int64((t.exitTime.timeIntervalSince1970 * 1000).rounded())
            entryPrice = t.entryPrice
            exitPrice = t.exitPrice
            quantity = t.quantity
            notional = t.notional
            grossPnL = t.grossPnL
            fees = t.fees
            funding = t.funding
            netPnL = t.netPnL
            returnPct = t.returnPct
            bars = t.bars
            exitReason = t.exitReason.rawValue
        }
    }

    let equityCurve: [Point]
    let trades: [Trade]
    let initialCapital: Double
    let bar: String
    let freeParameterCount: Int
}

extension KernelMetrics {
    /// An all-zero metric set, used when the kernel refuses a malformed curve.
    static func zeroed(freeParameterCount: Int) -> KernelMetrics {
        let json = """
        {"totalReturnPct":0,"absolutePnL":0,"cagr":0,"spanDays":0,
         "maxDrawdownPct":0,"maxDrawdownAbsolute":0,"maxDrawdownBars":0,
         "annualisedVolatilityPct":0,"sharpe":0,"sortino":0,"calmar":0,
         "tradeCount":0,"winRate":0,"profitFactor":null,"expectancyPct":0,
         "payoffRatio":null,"averageHoldBars":0,"maxConsecutiveLosses":0,
         "largestWinPct":0,"largestLossPct":0,"feesPaid":0,"fundingPaid":0,
         "exposurePct":0,"buyHoldReturnPct":0,
         "freeParameterCount":\(Swift.max(freeParameterCount, 1))}
        """
        // Decoding a constant we wrote ourselves cannot fail.
        return try! JSONDecoder().decode(KernelMetrics.self, from: Data(json.utf8))
    }
}
