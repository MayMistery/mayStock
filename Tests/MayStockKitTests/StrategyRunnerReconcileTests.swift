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
