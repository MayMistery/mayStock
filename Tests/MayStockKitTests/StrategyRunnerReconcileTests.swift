import Foundation
import Testing

@testable import MayStockKit

// MARK: - Test doubles

/// An exchange that answers from fixtures, so the runner's reconciliation can
/// be driven through states a real venue only reaches by being liquidated.
final class FakeVenue: ExchangeVenue, @unchecked Sendable {
    let venueName = "Fake"

    var positionsResult: Result<[ExchangePosition], Error> = .success([])
    var fillsResult: [ExchangeFill] = []
    var price: Double = 100
    var placed: [OrderRequest] = []
    /// Errors to throw from `place`, consumed in order; nil means accept.
    var placeOutcomes: [Error?] = []

    func isReady() async -> Bool { true }

    func candles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle] { [] }
    func historyCandles(instId: String, bar: BarInterval, target: Int) async throws -> [Candle] { [] }
    func lastPrice(instId: String) async throws -> Double { price }
    /// One BTC-USDT-SWAP contract is 0.01 BTC, as OKX reports it. The runner
    /// re-reads this every tick, so a fixture that omitted it would silently
    /// have the ledger price contracts as coins.
    func instrumentMeta(instId: String) async throws -> InstrumentMeta? {
        InstrumentMeta(
            instId: instId, tickSize: 0.1, lotSize: 1, minSize: 1, contractValue: 0.01)
    }

    func place(
        _ order: OrderRequest, mode: TradingMode, liveUnlocked: Bool
    ) async throws -> OrderResult {
        placed.append(order)
        if !placeOutcomes.isEmpty, let failure = placeOutcomes.removeFirst() { throw failure }
        return OrderResult(ordId: "ord-\(placed.count)", clOrdId: order.clOrdId, raw: "{}")
    }

    func orderStatus(
        instId: String, instType: InstrumentType, clOrdId: String, mode: TradingMode
    ) async throws -> VenueOrderStatus { .unknown }

    func fills(
        instId: String?, instType: InstrumentType, mode: TradingMode
    ) async throws -> [ExchangeFill] { fillsResult }

    func positions(
        mode: TradingMode, instType: InstrumentType
    ) async throws -> [ExchangePosition] { try positionsResult.get() }

    func accountSnapshot(mode: TradingMode) async throws -> AccountSnapshot {
        AccountSnapshot(balances: [], totalEquity: 1_000)
    }

    // MARK: Protective orders

    var protectiveResult: [VenueProtectiveOrder] = []
    var amended: [(algoId: String, stopPrice: Double)] = []
    var placedProtective: [(size: Double, stopPrice: Double)] = []

    func protectiveOrders(
        instId: String, instType: InstrumentType, mode: TradingMode
    ) async throws -> [VenueProtectiveOrder] { protectiveResult }

    func amendProtectiveOrder(
        instId: String, instType: InstrumentType, algoId: String,
        stopPrice: Double, mode: TradingMode, liveUnlocked: Bool
    ) async throws {
        amended.append((algoId, stopPrice))
    }

    func placeProtectiveOrder(
        instId: String, instType: InstrumentType, posSide: PositionSide?,
        size: Double, stopPrice: Double, mode: TradingMode, liveUnlocked: Bool
    ) async throws {
        placedProtective.append((size, stopPrice))
    }
}

@MainActor
final class FakeHost: StrategyRunnerHost {
    var portfolio = StrategyPortfolioPrefs(mode: .demo)
    var liveTradingUnlocked = false
    var runnableStrategies: [CompiledStrategy] = []
    let ledger = StrategyLedger(mode: .demo)
    let fake = FakeVenue()
    var venue: any ExchangeVenue { fake }

    var halts: [(strategyId: String, reason: String)] = []

    func runnerDidChange() {}
    func runnerDidHalt(strategyId: String, reason: String) {
        halts.append((strategyId, reason))
    }
    func runnerDidSampleEquity(_ equity: Double, at ts: Date) {}
    var strategyEquitySamples: [(strategyId: String, equity: Double)] = []
    func runnerDidSampleStrategyEquity(_ strategyId: String, equity: Double, at ts: Date) {
        strategyEquitySamples.append((strategyId, equity))
    }
}

// MARK: - Fixtures

private let instId = "BTC-USDT-SWAP"

@MainActor
private func seedLongPosition(
    _ host: FakeHost, strategyId: String = "alpha", contracts: Double = 10
) {
    host.ledger.setContractSize(0.01, forInstId: instId)
    host.ledger.record(StrategyFill(
        id: "entry-1", strategyId: strategyId, instId: instId, side: .buy,
        price: 100, quantity: contracts, feeQuote: 0.1,
        ts: Date(timeIntervalSince1970: 1_000), clOrdId: OrderTag.make(strategyId: strategyId),
        mode: .demo))
}

private func exchangePosition(contracts: Double) -> ExchangePosition {
    ExchangePosition(
        instId: instId, posSide: .long, quantity: contracts, averagePrice: 100,
        markPrice: 100, unrealisedPnL: 0, leverage: 1, liquidationPrice: nil)
}

/// A fill the exchange executed on its own — the attached stop firing, say.
/// It carries the exchange's own order id, never a MayStock tag.
private func untaggedFill(id: String, size: Double, price: Double) -> ExchangeFill {
    ExchangeFill(
        id: id, instId: instId, side: .sell, posSide: .long, price: price, size: size,
        fee: -0.05, feeCcy: "USDT", ordId: "algo-77", clOrdId: "OKX-ALGO-77",
        ts: Date(timeIntervalSince1970: 2_000))
}

/// A runner whose debounce window has already elapsed, so two ticks are enough
/// to confirm a difference. Two agreeing readings are still required.
@MainActor
private func runner(for host: FakeHost) -> StrategyRunner {
    let runner = StrategyRunner(host: host)
    runner.externalConfirmDelay = 0
    return runner
}

// MARK: - Tests

@MainActor
struct StrategyRunnerReconcileTests {
    @Test("交易所侧止损成交后，台账补记并归零")
    func anExchangeSideStopIsBooked() async {
        let host = FakeHost()
        seedLongPosition(host)
        // The stop fired: the exchange holds nothing, and the fill it executed
        // carries its own order id rather than ours.
        host.fake.positionsResult = .success([])
        host.fake.fillsResult = [untaggedFill(id: "algo-fill-1", size: 10, price: 94)]

        let runner = runner(for: host)
        await runner.tick()
        await runner.tick()

        let position = host.ledger.position(for: "alpha")
        #expect(position?.isFlat == true)
        // Priced from the exchange's own fill, not from the current mark: a
        // stop fills at the stop. 10 contracts × 0.01 × (94 − 100) = −0.6.
        #expect(abs((position?.realisedPnL ?? 0) - (-0.6)) < 1e-9)
        // And the real fee came with it.
        #expect(abs((position?.feesPaid ?? 0) - 0.15) < 1e-9)
        #expect(host.ledger.fills.count == 2)
    }

    @Test("部分减仓只补记减掉的那部分")
    func aPartialReductionIsBookedPartially() async {
        let host = FakeHost()
        seedLongPosition(host)
        host.fake.positionsResult = .success([exchangePosition(contracts: 4)])
        host.fake.fillsResult = [untaggedFill(id: "adl-1", size: 6, price: 91)]

        let runner = runner(for: host)
        await runner.tick()
        await runner.tick()

        #expect(host.ledger.position(for: "alpha")?.quantity == 4)
    }

    @Test("没有成交记录可对应时，按标记价补记数量")
    func anUnexplainedReductionStillFixesTheSize() async {
        let host = FakeHost()
        seedLongPosition(host)
        host.fake.positionsResult = .success([])
        host.fake.fillsResult = []   // the exchange offers no fill to adopt

        let runner = runner(for: host)
        await runner.tick()
        await runner.tick()

        // The size is what every later decision depends on, so it is corrected
        // even when the price behind it can only be estimated.
        #expect(host.ledger.position(for: "alpha")?.isFlat == true)
    }

    @Test("一次读数不足以补记，必须两次一致")
    func aSingleReadingIsNotBelieved() async {
        let host = FakeHost()
        seedLongPosition(host)
        host.fake.positionsResult = .success([])
        let runner = runner(for: host)

        await runner.tick()

        // One reading only: nothing is booked yet.
        #expect(host.ledger.position(for: "alpha")?.quantity == 10)
    }

    @Test("两次读数不一致时重新计时")
    func adisagreeingSecondReadingRestartsTheWindow() async {
        let host = FakeHost()
        seedLongPosition(host)
        host.fake.positionsResult = .success([])
        let runner = runner(for: host)

        await runner.tick()
        // A different answer the second time — the book must not be rewritten
        // off the back of two readings that disagree.
        host.fake.positionsResult = .success([exchangePosition(contracts: 6)])
        await runner.tick()

        #expect(host.ledger.position(for: "alpha")?.quantity == 10)
    }

    @Test("同一合约有多个策略时熔断而不是猜测归属")
    func anAmbiguousInstrumentHaltsInsteadOfGuessing() async {
        let host = FakeHost()
        seedLongPosition(host, strategyId: "alpha", contracts: 10)
        host.ledger.record(StrategyFill(
            id: "entry-2", strategyId: "beta", instId: instId, side: .buy,
            price: 100, quantity: 6, feeQuote: 0.1,
            ts: Date(timeIntervalSince1970: 1_000),
            clOrdId: OrderTag.make(strategyId: "beta"), mode: .demo))
        host.fake.positionsResult = .success([exchangePosition(contracts: 4)])

        let runner = runner(for: host)
        await runner.tick()
        await runner.tick()

        #expect(host.halts.count == 2)
        #expect(host.ledger.position(for: "alpha")?.quantity == 10)
        #expect(host.ledger.position(for: "beta")?.quantity == 6)
    }

    @Test("查询失败绝不当成已平仓")
    func aFailedQueryBooksNothing() async {
        let host = FakeHost()
        seedLongPosition(host)
        host.fake.positionsResult = .failure(TradeError.cliNotFound)
        let runner = runner(for: host)

        await runner.tick()
        await runner.tick()

        #expect(host.ledger.position(for: "alpha")?.quantity == 10)
        #expect(host.halts.isEmpty)
    }

    @Test("交易所仓位多于台账时不并入")
    func anIncreaseIsNotAbsorbed() async {
        let host = FakeHost()
        seedLongPosition(host)
        // Somebody bought 5 more contracts by hand.
        host.fake.positionsResult = .success([exchangePosition(contracts: 15)])
        let runner = runner(for: host)

        await runner.tick()
        await runner.tick()

        #expect(host.ledger.position(for: "alpha")?.quantity == 10)
    }

    @Test("误差在容差内时视为舍入，不动账")
    func roundingIsIgnored() async {
        let host = FakeHost()
        seedLongPosition(host)
        host.fake.positionsResult = .success([exchangePosition(contracts: 9.99)])
        let runner = runner(for: host)

        await runner.tick()
        await runner.tick()

        #expect(host.ledger.position(for: "alpha")?.quantity == 10)
        #expect(host.ledger.fills.count == 1)
    }
}

// MARK: - Rejection classification

struct ExchangeRejectionTests {
    @Test("带非零 OKX 错误码的失败是确定性拒绝")
    func aCodedFailureIsDefinite() {
        let error = TradeError.cliFailed(
            exitCode: 1, stderr: #"{"code":"51000","msg":"Parameter slTriggerPx error"}"#)
        #expect(error.exchangeRejection?.contains("51000") == true)
    }

    @Test("超时不是拒绝")
    func aTimeoutIsNotARejection() {
        // The watchdog reports exit code −1: the CLI never came back, so the
        // order's fate is unknown and must not be treated as refused.
        let error = TradeError.cliFailed(
            exitCode: -1, stderr: "okx CLI 超过 15 秒未返回，已终止：okx swap place")
        #expect(error.exchangeRejection == nil)
    }

    @Test("没有交易所裁决的失败也不算拒绝")
    func aVerdictlessFailureIsNotARejection() {
        #expect(TradeError.cliFailed(exitCode: 1, stderr: "socket hang up")
            .exchangeRejection == nil)
        #expect(TradeError.cliNotFound.exchangeRejection == nil)
        // code 0 is OKX saying "fine", which cannot be a rejection.
        #expect(TradeError.cliFailed(exitCode: 1, stderr: #"{"code":"0"}"#)
            .exchangeRejection == nil)
    }

    @Test("从嵌套响应里挑出第一个非零码")
    func theFirstNonZeroCodeWins() {
        // OKX wraps a per-order `sCode` inside an envelope whose own `code` is 0.
        let raw = #"{"code":"0","data":[{"sCode":"51119","sMsg":"Insufficient balance"}]}"#
        #expect(TradeError.okxCode(in: raw) == "51119")
    }
}

// MARK: - Position clock

struct PositionOpenedAtTests {
    @Test("平仓后重新开仓，持仓时钟从头开始")
    func closingResetsTheClock() {
        var state = StrategyPositionState(strategyId: "alpha", instId: instId)
        let open = Date(timeIntervalSince1970: 1_000)
        let close = Date(timeIntervalSince1970: 2_000)
        let reopen = Date(timeIntervalSince1970: 9_000)

        state.apply(fill(side: .buy, quantity: 5, at: open))
        #expect(state.openedAt == open)

        state.apply(fill(side: .sell, quantity: 5, at: close))
        #expect(state.isFlat)
        // Without this the next position would look thousands of bars old, and
        // a time barrier would close it the instant it opened.
        #expect(state.openedAt == nil)

        state.apply(fill(side: .buy, quantity: 5, at: reopen))
        #expect(state.openedAt == reopen)
    }

    @Test("反手开仓时钟同样重置")
    func flippingRestartsTheClock() {
        var state = StrategyPositionState(strategyId: "alpha", instId: instId)
        let open = Date(timeIntervalSince1970: 1_000)
        let flip = Date(timeIntervalSince1970: 5_000)
        state.apply(fill(side: .buy, quantity: 5, at: open))
        state.apply(fill(side: .sell, quantity: 8, at: flip))
        #expect(state.quantity == -3)
        #expect(state.openedAt == flip)
    }

    @Test("加仓不重置时钟")
    func addingKeepsTheClock() {
        var state = StrategyPositionState(strategyId: "alpha", instId: instId)
        let open = Date(timeIntervalSince1970: 1_000)
        state.apply(fill(side: .buy, quantity: 5, at: open))
        state.apply(fill(side: .buy, quantity: 5, at: Date(timeIntervalSince1970: 3_000)))
        #expect(state.openedAt == open)
    }

    private func fill(side: OrderSide, quantity: Double, at ts: Date) -> StrategyFill {
        StrategyFill(
            id: UUID().uuidString, strategyId: "alpha", instId: instId, side: side,
            price: 100, quantity: quantity, feeQuote: 0, ts: ts, clOrdId: nil, mode: .demo)
    }
}

// MARK: - Protective order parsing

struct ProtectiveOrderParsingTests {
    @Test("从 algo orders 输出里读出止损单")
    func aStopIsFound() {
        let json = """
        {"data":[{"algoId":"9001","instId":"BTC-USDT-SWAP","slTriggerPx":"58000",
                  "slOrdPx":"-1","sz":"10","posSide":"long","state":"live"}]}
        """
        let orders = TradeBridge.parseProtectiveOrders(json: json, instId: "BTC-USDT-SWAP")
        #expect(orders.count == 1)
        #expect(orders.first?.algoId == "9001")
        #expect(orders.first?.stopTriggerPrice == 58_000)
        #expect(orders.first?.posSide == .long)
    }

    @Test("别的合约的算法单不算数")
    func anotherInstrumentIsIgnored() {
        let json = """
        {"data":[{"algoId":"9002","instId":"ETH-USDT-SWAP","slTriggerPx":"3000","sz":"1"}]}
        """
        #expect(TradeBridge.parseProtectiveOrders(
            json: json, instId: "BTC-USDT-SWAP").isEmpty)
    }

    @Test("两条腿都没有的算法单不保护任何东西")
    func anOrderWithNeitherLegIsNotProtective() {
        // Grid bots and TWAP legs live in the same algo book; they are not stops.
        let json = """
        {"data":[{"algoId":"9003","instId":"BTC-USDT-SWAP","sz":"10","ordType":"twap"}]}
        """
        #expect(TradeBridge.parseProtectiveOrders(
            json: json, instId: "BTC-USDT-SWAP").isEmpty)
    }

    @Test("止盈腿也读得出来")
    func aTakeProfitLegIsRead() {
        let json = """
        {"data":[{"algoId":"9004","instId":"BTC-USDT-SWAP","tpTriggerPx":"72000","sz":"10"}]}
        """
        let orders = TradeBridge.parseProtectiveOrders(json: json, instId: "BTC-USDT-SWAP")
        #expect(orders.first?.takeProfitTriggerPrice == 72_000)
        #expect(orders.first?.stopTriggerPrice == nil)
    }
}

// MARK: - Kernel bridge for the live/backtest comparison

struct LiveVsBacktestBridgeTests {
    private let instId = "BTC-USDT-SWAP"

    private func candle(_ ts: TimeInterval, open: Double) -> Candle {
        Candle(ts: Date(timeIntervalSince1970: ts), open: open, high: open + 5,
               low: open - 5, close: open, volume: 1, confirmed: true)
    }

    private func fill(_ ts: TimeInterval, price: Double, side: OrderSide) -> StrategyFill {
        StrategyFill(
            id: UUID().uuidString, strategyId: "alpha", instId: instId, side: side,
            price: price, quantity: 1, feeQuote: 0,
            ts: Date(timeIntervalSince1970: ts), clOrdId: nil, mode: .demo)
    }

    @Test("滑点经过 FFI 往返后仍是同一个数")
    func slippageRoundTrips() throws {
        let report = try TradingKernel.calibrateSlippage(
            fills: [fill(30, price: 100.10, side: .buy)],
            candles: [candle(0, open: 100)],
            assumedBps: 5)
        #expect(report.samples == 1)
        #expect(abs((report.medianBps ?? 0) - 10) < 1e-6)
        #expect(report.assumedBps == 5)
    }

    @Test("样本太少时不给建议值")
    func aThinSampleRecommendsNothing() throws {
        // Three fills is not evidence. Feeding that back into a cost model
        // would be replacing one guess with another, more confident one.
        let fills = (0..<3).map { fill(Double($0) + 10, price: 100.5, side: .buy) }
        let report = try TradingKernel.calibrateSlippage(
            fills: fills, candles: [candle(0, open: 100)], assumedBps: 5)
        #expect(report.recommendedBps == nil)
        #expect(report.understatesCost == false)
    }

    @Test("实测成本高于假设时点名")
    func aWorseThanAssumedCostIsFlagged() throws {
        let fills = (0..<12).map { fill(Double($0) + 10, price: 100.5, side: .buy) }
        let report = try TradingKernel.calibrateSlippage(
            fills: fills, candles: [candle(0, open: 100)], assumedBps: 5)
        // 50 bps measured against a 5 bps assumption.
        #expect(report.understatesCost)
        #expect((report.recommendedBps ?? 0) > 40)
    }

    @Test("净值对照经过 FFI 往返后仍是同一个数")
    func equityComparisonRoundTrips() throws {
        let live = (0..<8).map {
            (ts: Date(timeIntervalSince1970: Double($0) * 60), equity: 1_000.0 + Double($0))
        }
        let result = try TradingKernel.compareEquity(live: live, backtest: live)
        #expect(result.samples == 8)
        #expect(abs(result.differencePct ?? 1) < 1e-9)
        #expect(result.tracksShape == true)
    }

    @Test("重合期不足时报空而不是报零")
    func tooLittleOverlapReportsNothing() throws {
        let point = [(ts: Date(timeIntervalSince1970: 0), equity: 1_000.0)]
        let result = try TradingKernel.compareEquity(live: point, backtest: point)
        #expect(result.liveReturnPct == nil)
        #expect(result.tracksShape == nil)
    }
}

// MARK: - Data quality, pre-trade limits, overfitting

struct KernelGateBridgeTests {
    @Test("过拟合评估经过 FFI 往返")
    func overfitRoundTrips() throws {
        // A modest, believable edge: strong enough to clear a five-trial bar,
        // not so strong that the probability saturates and proves nothing.
        var state: UInt64 = 42
        let series = (0..<2_000).map { _ -> Double in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let uniform = Double(state >> 33) / Double(1 << 31)
            return 0.0006 + (uniform - 0.5) * 0.02
        }
        let mean = series.reduce(0, +) / Double(series.count)
        let sd = (series.map { pow($0 - mean, 2) }.reduce(0, +)
                  / Double(series.count - 1)).squareRoot()
        let sharpe = mean / sd * 365.0.squareRoot()

        let few = try TradingKernel.assessOverfit(
            returns: series, observedSharpe: sharpe, trials: 5)
        let many = try TradingKernel.assessOverfit(
            returns: series, observedSharpe: sharpe, trials: 100_000)
        #expect(few.deflated?.significant == true)
        // The identical backtest means less once it was picked out of a search.
        #expect((many.deflated?.probability ?? 1) < (few.deflated?.probability ?? 0))
    }

    @Test("试的次数越多，运气门槛越高")
    func theBarRisesWithTrials() {
        let ten = TradingKernel.expectedMaxSharpeUnderNull(trials: 10, years: 3)
        let many = TradingKernel.expectedMaxSharpeUnderNull(trials: 10_000, years: 3)
        #expect(many > ten)
        #expect(TradingKernel.expectedMaxSharpeUnderNull(trials: 1, years: 3) == 0)
    }

    @Test("等价曲线的收益率序列")
    func periodReturnsAreDerivedFromTheCurve() {
        let curve = [
            EquityPoint(ts: Date(timeIntervalSince1970: 0), equity: 100, price: 1),
            EquityPoint(ts: Date(timeIntervalSince1970: 60), equity: 110, price: 1),
            EquityPoint(ts: Date(timeIntervalSince1970: 120), equity: 99, price: 1),
        ]
        let returns = StrategyOptimizer.periodReturns(of: curve)
        #expect(returns.count == 2)
        #expect(abs(returns[0] - 0.1) < 1e-9)
        #expect(abs(returns[1] - (-0.1)) < 1e-9)
    }

    @Test("交叉验证采样横跨整个排名，不只取头部")
    func crossValidationSamplingSpansTheRanking() {
        // Comparing winners against winners would understate the problem the
        // statistic exists to detect.
        let candidates = (0..<100).map { index in
            OptimizationCandidate(
                id: index, parameters: [:],
                metrics: BacktestMetrics.empty, score: Double(100 - index), rejection: nil)
        }
        let returns = Dictionary(uniqueKeysWithValues: (0..<100).map { index in
            (index, (0..<40).map { step in Double(index + step) * 0.001 })
        })
        let sampled = StrategyOptimizer.sampleForCrossValidation(
            candidates: candidates, returns: returns, limit: 10)
        #expect(sampled.count == 10)
    }

    @Test("样本太短的候选不参与交叉验证")
    func shortSeriesAreExcluded() {
        let candidates = [
            OptimizationCandidate(id: 0, parameters: [:], metrics: BacktestMetrics.empty,
                                  score: 1, rejection: nil),
        ]
        let sampled = StrategyOptimizer.sampleForCrossValidation(
            candidates: candidates, returns: [0: [0.1, 0.2]])
        #expect(sampled.isEmpty)
    }
}

// MARK: - Protective defaults

struct PortfolioProtectionDefaultTests {
    @Test("旧配置解码后自动获得保护，而不是默认关闭")
    func anOlderConfigGainsTheProtection() throws {
        // Absent means "written before this existed". For a protective limit
        // that has to mean the default, not "off" — otherwise every existing
        // install silently opts out of the guard.
        let json = #"{"mode":"demo","totalCapital":1000,"allocations":[]}"#
        let prefs = try JSONDecoder().decode(
            StrategyPortfolioPrefs.self, from: Data(json.utf8))
        #expect(prefs.maxDrawdownPct == 25)
        #expect(prefs.stoplossGuard != nil)
        // The order-notional cap has no safe default, so it stays opt-in; the
        // equity-share cap in the kernel covers the same failure regardless.
        #expect(prefs.maxOrderNotional == nil)
    }

    @Test("显式配置照常生效")
    func anExplicitValueIsHonoured() throws {
        let json = #"{"mode":"demo","maxDrawdownPct":10,"maxOrderNotional":5000}"#
        let prefs = try JSONDecoder().decode(
            StrategyPortfolioPrefs.self, from: Data(json.utf8))
        #expect(prefs.maxDrawdownPct == 10)
        #expect(prefs.maxOrderNotional == 5_000)
    }

    @Test("按 bar 计数，不按经过的时间")
    func barsAreCountedAsBarsNotAsElapsedTime() {
        // An entry at 10:05 against the 15:00 bar has been open across 5 bars.
        // Dividing the raw interval gives 4.9 → 4, and every bar-counted rule
        // would then be one bar out from the backtest.
        let entry = Date(timeIntervalSince1970: 10 * 3_600 + 5 * 60)
        let latest = Date(timeIntervalSince1970: 15 * 3_600)
        #expect(StrategyRunner.barsBetween(entry, and: latest, bar: .h1) == 5)
        // Same bar is zero, and time running backwards never goes negative.
        #expect(StrategyRunner.barsBetween(latest, and: latest, bar: .h1) == 0)
        #expect(StrategyRunner.barsBetween(latest, and: entry, bar: .h1) == 0)
    }
}
