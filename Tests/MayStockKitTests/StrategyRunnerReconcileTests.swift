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

    /// When set, the next `accountSnapshot` never returns — modelling a
    /// subprocess whose continuation is lost. `releaseWedge()` frees it so the
    /// test does not leave a task suspended behind it.
    var wedgeNextAccountSnapshot = false
    private var wedged: CheckedContinuation<Void, Never>?

    func accountSnapshot(mode: TradingMode) async throws -> AccountSnapshot {
        if wedgeNextAccountSnapshot {
            wedgeNextAccountSnapshot = false
            await withCheckedContinuation { wedged = $0 }
        }
        return AccountSnapshot(balances: [], totalEquity: 1_000)
    }

    func releaseWedge() {
        wedged?.resume()
        wedged = nil
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
    var completedTicks: [Date] = []
    func runnerDidCompleteTick(at ts: Date) { completedTicks.append(ts) }
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

    @Test("整轮寻优在内核里跑完，只回来一次")
    func theSweepRunsInsideTheKernel() throws {
        let json = """
        {"schema":1,"id":"sweep-test","name":"Sweep",
         "market":{"instId":"BTC-USDT","instType":"SPOT","bar":"1H"},
         "params":[{"name":"fast","default":5,"min":3,"max":10},
                   {"name":"slow","default":20,"min":15,"max":30}],
         "signals":{"longEntry":"ema(close, fast) > ema(close, slow)",
                    "longExit":"ema(close, fast) < ema(close, slow)"},
         "sizing":{"mode":"equityPct","value":100}}
        """
        let manifest = try JSONDecoder().decode(
            StrategyManifest.self, from: Data(json.utf8))
        let strategy = try manifest.compile()

        var candles: [Candle] = []
        for i in 0..<900 {
            let base = 100 + sin(Double(i) * 0.15) * 12 + Double(i) * 0.02
            candles.append(Candle(
                ts: Date(timeIntervalSince1970: Double(i) * 3_600),
                open: base, high: base + 1, low: base - 1, close: base + 0.2,
                volume: 10, confirmed: true))
        }

        let result = StrategyOptimizer(
            strategy: strategy,
            config: BacktestConfig(initialCapital: 10_000),
            objective: OptimizationObjective(kind: .sharpe)
        ).run(candles: candles)

        // Every grid point comes back, and each carries the parameters it was
        // run with — the caller has to be able to reproduce a winner.
        #expect(result.evaluated == result.candidates.count)
        #expect(result.evaluated > 1)
        #expect(result.candidates.allSatisfy { $0.parameters["fast"] != nil })
        // And the overfitting assessment came back with it, rather than being
        // a second pass over data Swift had to keep.
        #expect(result.deflatedSharpe != nil || result.candidates.isEmpty)
    }

    @Test("寻优结果与逐个回测一致")
    func theSweepAgreesWithRunningEachBacktest() throws {
        // The sweep clones a compiled strategy and swaps its parameter map
        // rather than re-parsing the manifest. That is only sound if it lands
        // on exactly the same numbers.
        let json = """
        {"schema":1,"id":"parity","name":"Parity",
         "market":{"instId":"BTC-USDT","instType":"SPOT","bar":"1H"},
         "params":[{"name":"fast","default":5,"min":3,"max":6}],
         "signals":{"longEntry":"ema(close, fast) > sma(close, 20)",
                    "longExit":"ema(close, fast) < sma(close, 20)"},
         "sizing":{"mode":"equityPct","value":100}}
        """
        let manifest = try JSONDecoder().decode(
            StrategyManifest.self, from: Data(json.utf8))
        let strategy = try manifest.compile()

        var candles: [Candle] = []
        for i in 0..<600 {
            let base = 100 + sin(Double(i) * 0.2) * 8 + Double(i) * 0.01
            candles.append(Candle(
                ts: Date(timeIntervalSince1970: Double(i) * 3_600),
                open: base, high: base + 1, low: base - 1, close: base + 0.1,
                volume: 10, confirmed: true))
        }
        let config = BacktestConfig(initialCapital: 10_000)

        let swept = StrategyOptimizer(
            strategy: strategy, config: config,
            objective: OptimizationObjective(kind: .sharpe)
        ).run(candles: candles)

        for candidate in swept.candidates {
            let variant = try strategy.with(parameterValues: candidate.parameters)
            let direct = try BacktestEngine(strategy: variant, config: config)
                .run(candles: candles).metrics
            #expect(abs(direct.totalReturnPct - candidate.metrics.totalReturnPct) < 1e-9,
                    "fast=\(candidate.parameters["fast"] ?? -1)")
            #expect(direct.tradeCount == candidate.metrics.tradeCount)
        }
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

// MARK: - Backtest completeness

struct BacktestCompletenessTests {
    private func series(_ count: Int, skipping: Set<Int> = []) -> [Candle] {
        (0..<count).compactMap { i in
            guard !skipping.contains(i) else { return nil }
            let base = 100 + Double(i) * 0.05
            return Candle(
                ts: Date(timeIntervalSince1970: Double(i) * 3_600),
                open: base, high: base + 1, low: base - 1, close: base + 0.2,
                volume: 10, confirmed: true)
        }
    }

    private func strategy() throws -> CompiledStrategy {
        let json = """
        {"schema":1,"id":"quality","name":"Quality",
         "market":{"instId":"BTC-USDT","instType":"SPOT","bar":"1H"},
         "signals":{"longEntry":"close > sma(close, 10)",
                    "longExit":"close < sma(close, 10)"},
         "sizing":{"mode":"equityPct","value":100}}
        """
        return try JSONDecoder().decode(
            StrategyManifest.self, from: Data(json.utf8)).compile()
    }

    @Test("回测报告说明它跑在什么样的数据上")
    func aBacktestReportsTheHistoryItRanOver() throws {
        let clean = try BacktestEngine(strategy: strategy(), config: BacktestConfig())
            .run(candles: series(400))
        #expect(clean.dataQuality?.usable == true)
        #expect(clean.dataQuality?.gaps == 0)
    }

    @Test("历史里的缺口被数出来，而不是无声吞掉")
    func gapsAreCounted() throws {
        // A 60-bar lookback that spans a hole covers more than 60 bars of
        // market. The backtest cannot refuse retrospectively, so it says so.
        let holed = series(400, skipping: [100, 101, 102, 250])
        let result = try BacktestEngine(strategy: strategy(), config: BacktestConfig())
            .run(candles: holed)
        #expect(result.dataQuality?.gaps == 4)
    }

    @Test("历史全是洞时，报告直接判定不可用")
    func aSeriesFullOfHolesIsFlaggedUnusable() throws {
        let sparse = (0..<200).map { i -> Candle in
            let base = 100 + Double(i) * 0.05
            // One bar every three hours on an hourly strategy.
            return Candle(
                ts: Date(timeIntervalSince1970: Double(i) * 3 * 3_600),
                open: base, high: base + 1, low: base - 1, close: base + 0.2,
                volume: 10, confirmed: true)
        }
        let result = try BacktestEngine(strategy: strategy(), config: BacktestConfig())
            .run(candles: sparse)
        #expect(result.dataQuality?.usable == false)
        #expect(result.dataQuality?.reason.contains("缺失") == true)
    }
}

// MARK: - Build hygiene

struct KernelFreshnessTests {
    /// The staged static library must be newer than every kernel source file.
    ///
    /// SwiftPM cannot run cargo itself, so `Scripts/build-kernel.sh` stages the
    /// archive and `swift build` links whatever is there. Editing Rust and
    /// running `swift test` directly therefore tests the *previous* kernel —
    /// silently, and with symptoms that look like a logic bug: a field added in
    /// Rust simply decodes as nil.
    ///
    /// This has cost real debugging time twice. A loud failure naming the fix
    /// is worth more than the comment in the build script.
    @Test("暂存的内核库不比 Rust 源码旧")
    func theStagedKernelIsNotStale() throws {
        let fileManager = FileManager.default
        // Walk up from this file to the package root.
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1,
              !fileManager.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            root.deleteLastPathComponent()
        }
        let staged = root.appendingPathComponent(".build/kernel/libmaystock_kernel.a")
        let sources = root.appendingPathComponent("kernel/src")
        guard fileManager.fileExists(atPath: staged.path),
              let walker = fileManager.enumerator(at: sources,
                                                  includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }   // Not a checkout we can judge; say nothing.

        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
        }
        let libraryDate = modified(staged)
        var newest: (url: URL, date: Date)?
        for case let url as URL in walker where url.pathExtension == "rs" {
            let date = modified(url)
            if date > (newest?.date ?? .distantPast) { newest = (url, date) }
        }
        guard let newest else { return }

        #expect(
            libraryDate >= newest.date,
            """
            暂存的 libmaystock_kernel.a 比 \(newest.url.lastPathComponent) 旧，\
            这次测试跑的是上一版内核。先执行 Scripts/build-kernel.sh 再测。
            """)
    }
}

// MARK: - Diversification and validation protocol

struct DiversificationBridgeTests {
    @Test("三份同样的策略只算一注")
    func identicalStrategiesAreOneBet() throws {
        let series = (0..<50).map { sin(Double($0) * 0.3) * 0.01 }
        let report = try TradingKernel.diversification([
            (name: "a", returns: series),
            (name: "b", returns: series),
            (name: "c", returns: series),
        ])
        #expect(abs((report.effectiveBets ?? 0) - 1) < 1e-6)
        #expect(report.isConcentrated)
        #expect((report.highestPair?.correlation ?? 0) > 0.99)
    }

    @Test("互不相关的策略各算一注")
    func independentStrategiesCountSeparately() throws {
        let a = (0..<200).map { sin(Double($0) * 0.7) * 0.01 }
        let b = (0..<200).map { cos(Double($0) * 0.11) * 0.01 }
        let report = try TradingKernel.diversification([
            (name: "a", returns: a), (name: "b", returns: b),
        ])
        #expect((report.effectiveBets ?? 0) > 1.5)
        #expect(!report.isConcentrated)
    }

    @Test("不足两个策略时不作判断")
    func oneStrategyIsNotAJudgement() throws {
        let report = try TradingKernel.diversification([
            (name: "only", returns: Array(repeating: 0.01, count: 20)),
        ])
        #expect(report.pairs.isEmpty)
        #expect(report.isConcentrated == false)
    }
}

struct WalkForwardProtocolTests {
    private func strategy() throws -> CompiledStrategy {
        let json = """
        {"schema":1,"id":"wf","name":"WF",
         "market":{"instId":"BTC-USDT","instType":"SPOT","bar":"1H"},
         "params":[{"name":"len","default":10,"min":5,"max":20}],
         "signals":{"longEntry":"close > sma(close, len)",
                    "longExit":"close < sma(close, len)"},
         "sizing":{"mode":"equityPct","value":100}}
        """
        return try JSONDecoder().decode(
            StrategyManifest.self, from: Data(json.utf8)).compile()
    }

    private func candles(_ count: Int) -> [Candle] {
        (0..<count).map { i in
            let base = 100 + sin(Double(i) * 0.09) * 15 + Double(i) * 0.01
            return Candle(
                ts: Date(timeIntervalSince1970: Double(i) * 3_600),
                open: base, high: base + 1, low: base - 1, close: base + 0.2,
                volume: 10, confirmed: true)
        }
    }

    @Test("拟合窗口不碰测试期指标依赖的那些 bar")
    func theFitDoesNotTouchWhatTheTestDependsOn() throws {
        // The out-of-sample slice primes its indicators on the bars just before
        // the split. Fitting on those same bars is the textbook leak.
        let strategy = try strategy()
        let result = WalkForwardAnalysis(
            strategy: strategy, config: BacktestConfig(initialCapital: 10_000),
            folds: 3, inSampleFraction: 0.7, embargoFraction: 0.02
        ).run(candles: candles(3_000))

        #expect(!result.folds.isEmpty)
        for fold in result.folds {
            #expect(fold.purgedBars == strategy.warmupBars)
            #expect(fold.embargoedBars > 0)
            // The fitting window ends strictly before the test's first trade.
            #expect(fold.inSampleEnd < fold.outOfSampleStart)
        }
    }

    @Test("验证协议被写进报告，而不是靠默契")
    func theProtocolIsStated() throws {
        // A walk-forward whose purge and embargo are not written down cannot be
        // compared with another one — and the difference between them is the
        // difference between a real out-of-sample test and a delayed in-sample
        // one.
        let result = WalkForwardAnalysis(
            strategy: try strategy(), config: BacktestConfig(initialCapital: 10_000),
            folds: 3
        ).run(candles: candles(3_000))
        #expect(result.warnings.contains { $0.contains("purge") && $0.contains("embargo") })
    }
}

// MARK: - Higher-timeframe alignment

struct SeriesAlignmentTests {
    private func hourly(_ count: Int) -> [Candle] {
        (0..<count).map { i in
            Candle(ts: Date(timeIntervalSince1970: Double(i) * 3_600),
                   open: 1, high: 1, low: 1, close: 1, volume: 1, confirmed: true)
        }
    }

    @Test("同周期序列在本 bar 收盘时即可用")
    func sameIntervalIsUsableAtThisBarsClose() {
        // The other instrument's close for bar i is known at bar i's close,
        // which is exactly when the signal is evaluated.
        let observations = (0..<5).map {
            SeriesObservation(ts: Date(timeIntervalSince1970: Double($0) * 3_600),
                              value: Double($0))
        }
        let aligned = SeriesAligner.align(
            observations, to: hourly(5),
            timing: .bar(seconds: 3_600), candleSeconds: 3_600)
        #expect(aligned == [0, 1, 2, 3, 4])
    }

    @Test("日线过滤器要等它自己收盘，不能重绘")
    func aDailyFilterWaitsForItsOwnClose() {
        // A daily bar opening at 00:00 closes at 24:00. Matching on open time
        // would hand the 01:00 hourly bar a close with 23 hours still to run —
        // 23 hours of look-ahead.
        let daily = [
            SeriesObservation(ts: Date(timeIntervalSince1970: 0), value: 100),
            SeriesObservation(ts: Date(timeIntervalSince1970: 86_400), value: 200),
        ]
        let aligned = SeriesAligner.align(
            daily, to: hourly(30),
            timing: .bar(seconds: 86_400), candleSeconds: 3_600)

        // Nothing is known until the first daily bar has closed.
        #expect(aligned[0].isNaN)
        #expect(aligned[10].isNaN)
        // The hourly bar opening at 23:00 closes at 24:00 — the moment the
        // daily bar closes. That is the first bar allowed to see it.
        #expect(aligned[23] == 100)
        #expect(aligned[24] == 100)
        // And the second daily value only after another full day.
        #expect(aligned[29] == 100)
    }

    @Test("落在决策同一刻的时点数据算作还不知道")
    func anObservationLandingOnTheDecisionIsNotYetKnown() {
        // A funding settlement is not measured over a bar; it happens. One
        // stamped exactly at bar 0's close is simultaneous with the decision,
        // and assuming we held it at that instant is the optimistic reading.
        let settlement = [
            SeriesObservation(ts: Date(timeIntervalSince1970: 3_600), value: 0.0001),
        ]
        let aligned = SeriesAligner.align(
            settlement, to: hourly(4), timing: .instant, candleSeconds: 3_600)
        #expect(aligned[0].isNaN)
        #expect(aligned[1] == 0.0001)
    }

    @Test("同一刻收盘的同周期 bar 算作已知")
    func aBarClosingOnTheDecisionIsKnown() {
        // The other side of the same boundary: bar i's own close is available
        // when bar i closes. That is the execution model, not an assumption.
        let observations = [
            SeriesObservation(ts: Date(timeIntervalSince1970: 0), value: 42),
        ]
        let aligned = SeriesAligner.align(
            observations, to: hourly(2),
            timing: .bar(seconds: 3_600), candleSeconds: 3_600)
        #expect(aligned[0] == 42)
    }

    @Test("发布于本 bar 内的时点数据，本 bar 收盘时已知")
    func anObservationPublishedInsideTheBarIsKnownAtItsClose() {
        // The decision is taken at the bar's close, so anything stamped
        // strictly inside the bar is available to it.
        let observations = (0..<3).map {
            SeriesObservation(ts: Date(timeIntervalSince1970: Double($0) * 3_600),
                              value: Double($0))
        }
        #expect(SeriesAligner.align(
            observations, to: hourly(3), candleSeconds: 3_600) == [0, 1, 2])
    }
}

// MARK: - Trade resampling

struct ResampleBridgeTests {
    /// Alternating wins and losses: the observed drawdown is one trade deep,
    /// which is a benign ordering and the kind a backtest is lucky to draw.
    private var alternating: [Double] {
        (0..<40).map { $0 % 2 == 0 ? 0.05 : -0.04 }
    }

    @Test("重排后的回撤比回测报的那一个更深")
    func reorderingFindsAWorseDrawdown() throws {
        let report = try #require(try TradingKernel.resampleTrades(
            returns: alternating, iterations: 2_000, method: .shuffle, blockSize: 1))
        #expect(report.drawdownP95Pct > report.observedDrawdownPct)
        #expect(report.planningDrawdownPct >= report.observedDrawdownPct)
        #expect(report.observedIsOptimistic)
    }

    @Test("同一个种子给同一个答案")
    func theSameSeedGivesTheSameAnswer() throws {
        // A risk figure that changed on every run could not be argued with,
        // and one that cannot be argued with cannot be trusted.
        let a = try TradingKernel.resampleTrades(returns: alternating, seed: 7)
        let b = try TradingKernel.resampleTrades(returns: alternating, seed: 7)
        #expect(a == b)
    }

    @Test("交易太少时报空，而不是报一个自信的分位数")
    func tooFewTradesReportsNothing() throws {
        #expect(try TradingKernel.resampleTrades(returns: [0.01, -0.01, 0.02]) == nil)
    }

    @Test("重排不改变最终收益，只改变路径")
    func shufflingMovesThePathNotTheEndpoint() throws {
        let report = try #require(try TradingKernel.resampleTrades(
            returns: alternating, iterations: 300, method: .shuffle, blockSize: 1))
        #expect(abs(report.returnP5Pct - report.returnP95Pct) < 1e-6)
    }
}

// MARK: - Heartbeat

@MainActor
struct HeartbeatTests {
    private func store() -> HeartbeatStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return HeartbeatStore(directory: directory)
    }

    @Test("每次 tick 结束都上报心跳")
    func everyTickReportsAHeartbeat() async {
        let host = FakeHost()
        let runner = StrategyRunner(host: host)
        await runner.tick()
        await runner.tick()
        #expect(host.completedTicks.count == 2)
    }

    @Test("心跳落盘，重启后仍能回答「我没看着的时候它在跑吗」")
    func theHeartbeatSurvivesARestart() {
        let store = store()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        store.record(when)
        // A fresh instance reading the same directory — the restart case.
        #expect(HeartbeatStore(directory: store.fileURL.deletingLastPathComponent())
            .load() == when)
    }

    @Test("写得太密的心跳会被跳过")
    func writesAreThrottled() {
        // The tick is far more frequent than this needs, and every write is
        // disk I/O inside the trading loop.
        let store = store()
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        store.record(first)
        store.record(first.addingTimeInterval(5))
        #expect(store.load() == first)
        store.record(first.addingTimeInterval(HeartbeatStore.minimumInterval + 1))
        #expect(store.load() != first)
    }

    @Test("没有心跳文件时不谎报正常")
    func noHeartbeatIsNotAHealthyOne() {
        #expect(store().load() == nil)
    }

    @Test("单次 tick 永不返回，交易循环仍然继续")
    func aWedgedTickDoesNotKillTheLoop() async throws {
        // The failure this whole mechanism exists to catch, reproduced from the
        // inside. The loop used to `await` each tick, so one call that never
        // came back ended the engine for good — no error, no exit, just an app
        // that had stopped managing open positions. The loop now keeps its own
        // clock and walks away from a tick that overruns.
        let host = FakeHost()
        host.fake.wedgeNextAccountSnapshot = true

        let runner = StrategyRunner(host: host)
        runner.tickInterval = 0.05
        runner.tickStallTimeout = 0.3
        runner.start()
        defer {
            runner.stop()
            host.fake.releaseWedge()
        }

        // Well past the stall deadline: the first tick is still suspended
        // inside the venue and never will not be.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        #expect(!host.completedTicks.isEmpty,
                "a tick that never returns must not stop the loop trading")
        #expect(runner.isTicking == false,
                "the replacement tick owns the bookkeeping, and it finished")
    }

    @Test("被放弃的 tick 不上报心跳")
    func anAbandonedTickReportsNoHeartbeat() async throws {
        // Otherwise the dead man's switch reports "still alive" on the strength
        // of a tick that did no work — papering over the exact failure it is
        // there to surface.
        let host = FakeHost()
        host.fake.wedgeNextAccountSnapshot = true
        let runner = StrategyRunner(host: host)

        let wedged = Task { await runner.tick() }
        try await Task.sleep(nanoseconds: 200_000_000)
        wedged.cancel()
        host.fake.releaseWedge()
        await wedged.value

        #expect(host.completedTicks.isEmpty)
    }
}

// MARK: - App wiring

/// MayStock is an AppKit shell: it builds its hosting views by hand and never
/// calls `.environment(_:)` on any of them. A SwiftUI view that reads AppState
/// out of the environment therefore finds nothing there and traps the instant
/// it renders — which is exactly what took the whole app down on 2026-08-06 the
/// first time anyone opened the 持仓与成交 tab. Every other view in the app
/// takes `let appState: AppState`, which the compiler will not let you forget.
///
/// Checked against the source rather than at runtime because the defect is a
/// *missing* call: there is no object to interrogate, only a convention to hold.
@Suite("App wiring")
struct AppWiringTests {
    private func appSources() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // MayStockKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // package root
            .appendingPathComponent("Sources/MayStock")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        return files ?? []
    }

    /// Source with `//` comments stripped, so prose mentioning the API does not
    /// read as a call to it.
    private func code(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    @Test("没有人注入，就没有视图可以从 environment 里读 AppState")
    func noViewReadsAppStateFromAnEnvironmentNothingPopulates() throws {
        let sources = appSources()
        try #require(!sources.isEmpty, "the app sources must be reachable from the test")

        var injectors: [String] = []
        var readers: [String] = []
        for url in sources {
            let text = try code(of: url)
            if text.contains(".environment(") || text.contains(".environmentObject(") {
                injectors.append(url.lastPathComponent)
            }
            if text.contains("@Environment(AppState.self)") {
                readers.append(url.lastPathComponent)
            }
        }

        #expect(readers.isEmpty,
                "these read AppState from an environment nothing fills: \(readers)")
        // The other half of the invariant. If a future change starts injecting
        // AppState for real, reading it becomes legitimate and this whole check
        // should be deleted rather than worked around.
        #expect(injectors.isEmpty,
                "AppState is being injected now (\(injectors)) — revisit this check")
    }
}

// MARK: - Walk-forward efficiency

struct WalkForwardEfficiencyTests {
    private func fold(
        id: Int, inDays: Double, outDays: Double, inPct: Double, outPct: Double
    ) -> WalkForwardFold {
        let start = Date(timeIntervalSince1970: 0)
        // Metrics are derived, not settable, so the return is expressed the
        // way the engine would produce it: as an equity curve.
        func metrics(_ pct: Double, days: Double, from: Date) -> BacktestMetrics {
            BacktestMetrics(
                trades: [],
                equityCurve: [
                    EquityPoint(ts: from, equity: 10_000, price: 1),
                    EquityPoint(ts: from.addingTimeInterval(days * 86_400),
                                equity: 10_000 * (1 + pct / 100), price: 1),
                ],
                initialCapital: 10_000, bar: .h1, freeParameterCount: 1)
        }
        let inMetrics = metrics(inPct, days: inDays, from: start)
        let outMetrics = metrics(
            outPct, days: outDays, from: start.addingTimeInterval(inDays * 86_400))
        return WalkForwardFold(
            id: id,
            inSampleStart: start,
            inSampleEnd: start.addingTimeInterval(inDays * 86_400),
            outOfSampleStart: start.addingTimeInterval(inDays * 86_400),
            outOfSampleEnd: start.addingTimeInterval((inDays + outDays) * 86_400),
            parameters: [:], inSample: inMetrics, outOfSample: outMetrics,
            outOfSampleTrades: [], outOfSampleEquity: [])
    }

    private func result(_ folds: [WalkForwardFold]) -> WalkForwardResult {
        WalkForwardResult(
            folds: folds, stitchedEquity: [], stitchedMetrics: .empty,
            objective: OptimizationObjective(), totalTrials: 0, warnings: [])
    }

    @Test("效率比按窗口长度归一：不衰减就是 1.0")
    func noDecayScoresOne() {
        // In-sample is 70% of the fold and out-of-sample is what survives the
        // purge. Comparing raw totals compared a long window with a short one,
        // so a strategy that decayed not at all scored about 0.4 — and the 0.5
        // threshold then demanded that out-of-sample beat in-sample.
        let sameRate = fold(id: 0, inDays: 70, outDays: 30, inPct: 7, outPct: 3)
        #expect(abs((result([sameRate]).efficiency ?? 0) - 1.0) < 1e-9)
    }

    @Test("样本内没赚到钱时报空，而不是报满分")
    func aFlatFitHasNoRatioToReport() {
        // Returning 1.0 here let "the fit made no money" pass as "the fit held
        // up perfectly"; one search candidate scored 2.37 on exactly that.
        let flat = fold(id: 0, inDays: 70, outDays: 30, inPct: 0, outPct: 3)
        #expect(result([flat]).efficiency == nil)
        #expect(flat.efficiency == nil, "and the same holds per fold")
    }

    @Test("样本内亏损时也报空 —— 两个负数相除会得出漂亮的正数")
    func aLosingFitHasNoMeaningfulRatio() {
        // "in-sample -22%, out-of-sample -19%" once reported 1.21, which reads
        // as a pass and is the opposite of one.
        let losing = fold(id: 0, inDays: 70, outDays: 30, inPct: -22, outPct: -19)
        #expect(result([losing]).efficiency == nil)
    }

    @Test("真正的衰减会被如实报出来")
    func realDecayIsReported() {
        // Half the daily rate survives.
        let decayed = fold(id: 0, inDays: 70, outDays: 30, inPct: 14, outPct: 3)
        let efficiency = result([decayed]).efficiency ?? 0
        #expect(abs(efficiency - 0.5) < 1e-9)
    }
}

// MARK: - The robustness grade must judge everything it was given

struct BacktestWindowLadderTests {
    @Test("窗口阶梯里有「全样本」这一档")
    func theLadderReachesTheWholeSample() {
        // Without it the ladder stopped at one year, and the robustness grade —
        // which takes the LONGEST window present — silently judged the trailing
        // 365 days no matter how much history was requested. A 4H trend
        // strategy makes 8-12 trades a year, so that was a resample of about
        // ten trades from a single regime.
        let longest = BacktestWindow.allCases.max { $0.days < $1.days }
        #expect(longest == .full)
        #expect(BacktestWindow.full.coversEverything)
        #expect(BacktestWindow.d365.coversEverything == false)
    }

    @Test("全样本档的天数不会把取数算术撑爆")
    func theFullWindowDoesNotOverflowTheBarArithmetic() {
        // The caller multiplies days by seconds-per-day to size its fetch, so
        // this cannot be Int.max — `coversEverything` is what carries the
        // meaning, and the number just has to be large and finite.
        let bars = Double(BacktestWindow.full.days) * 86_400 / BarInterval.h4.seconds
        #expect(bars.isFinite)
        #expect(BacktestWindow.full.days > BacktestWindow.d365.days)
    }

    @Test("全样本档不是头条窗口")
    func theFullWindowIsNotAHeadline() {
        // The panel shows 1/7/30 day returns; "since inception" is a different
        // question and belongs in the robustness section, not the headline row.
        #expect(BacktestWindow.full.isHeadline == false)
        #expect(BacktestWindow.headline == [.d1, .d7, .d30])
    }
}

// MARK: - Silence must never read as a pass

struct ValidationHonestyTests {
    private func strategy(slow: Int) throws -> CompiledStrategy {
        let json = """
        {"schema":1,"id":"slow","name":"Slow",
         "market":{"instId":"BTC-USDT","instType":"SPOT","bar":"1D"},
         "params":[{"name":"slow","default":\(slow),"min":\(slow - 10),"max":\(slow + 10)}],
         "signals":{"longEntry":"close > sma(close, slow)",
                    "longExit":"close < sma(close, slow)"},
         "sizing":{"mode":"equityPct","value":100}}
        """
        return try JSONDecoder().decode(
            StrategyManifest.self, from: Data(json.utf8)).compile()
    }

    private func candles(_ count: Int) -> [Candle] {
        (0..<count).map { i in
            let base = 100 + sin(Double(i) * 0.05) * 20 + Double(i) * 0.02
            return Candle(ts: Date(timeIntervalSince1970: Double(i) * 86_400),
                          open: base, high: base + 1, low: base - 1, close: base + 0.2,
                          volume: 10, confirmed: true)
        }
    }

    @Test("装不下的走向前会说清为什么，而不是含糊地「数据不足」")
    func zeroFoldsExplainsItself() throws {
        // A long lookback simply cannot be walk-forward validated on short
        // history. Reporting that as "insufficient data" makes it look like a
        // data problem rather than a structural one — which is how a strategy
        // gets deployed having never been validated at all.
        let result = WalkForwardAnalysis(
            strategy: try strategy(slow: 365),
            config: BacktestConfig(initialCapital: 10_000), folds: 4
        ).run(candles: candles(600))

        #expect(result.folds.isEmpty)
        let explanation = result.warnings.joined()
        #expect(explanation.contains("预热"), "it must name the warm-up as the cause")
        #expect(explanation.contains("这不是通过"), "and refuse to be read as a pass")
    }

    @Test("历史够长时同一个策略是能验证的")
    func enoughHistoryLetsItRun() throws {
        // The counterpart: the message must be about this history, not a
        // permanent verdict on the strategy.
        let result = WalkForwardAnalysis(
            strategy: try strategy(slow: 30),
            config: BacktestConfig(initialCapital: 10_000), folds: 4
        ).run(candles: candles(1_200))
        #expect(!result.folds.isEmpty)
    }

    @Test("交易太少导致无法重采样时，报告要明说")
    func anAbsentResampleIsStated() throws {
        // Below ten trades the resample declines to run. It used to print
        // nothing, and a validation run seeing no warning concludes it passed.
        let sparse = BacktestMetrics.empty
        let result = BacktestResult(
            strategyId: "x", instId: "BTC-USDT", bar: .d1,
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 86_400 * 100),
            barCount: 100, initialCapital: 10_000, finalEquity: 10_500,
            trades: [], equityCurve: [], liquidations: 0, warmupBars: 10,
            fundingUnmodelled: false, metrics: sparse)
        let assessment = RobustnessAssessment.evaluate(
            results: [.full: result], bar: .d1, freeParameterCount: 1)
        #expect(assessment.notes.contains { $0.contains("这不是通过") })
    }
}
