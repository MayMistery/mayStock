import Foundation
import Testing
@testable import MayStockKit

// MARK: - Order tagging

@Suite("Order tagging")
struct OrderTagTests {
    @Test func clientOrderIdsSatisfyExchangeConstraints() {
        for id in ["ema-trend", "策略-一", "a", String(repeating: "x", count: 200)] {
            let tag = OrderTag.make(strategyId: id)
            #expect(tag.count <= 32, "OKX allows at most 32 characters")
            #expect(tag.allSatisfy { $0.isLetter || $0.isNumber }, "alphanumeric only")
            #expect(tag.first?.isLetter == true, "must start with a letter")
        }
    }

    @Test func tagsRoundTripToTheirStrategy() {
        let tag = OrderTag.make(strategyId: "donchian-breakout")
        #expect(OrderTag.belongs(tag, to: "donchian-breakout"))
        #expect(!OrderTag.belongs(tag, to: "ema-trend"))
        #expect(OrderTag.resolveStrategy(tag, among: ["ema-trend", "donchian-breakout"])
                == "donchian-breakout")
    }

    @Test func foreignOrdersAreNotClaimed() {
        #expect(OrderTag.strategyHash(of: "someBotOrder123") == nil)
        #expect(OrderTag.strategyHash(of: nil ?? "") == nil)
        #expect(OrderTag.resolveStrategy("manualBuy", among: ["ema-trend"]) == nil)
        #expect(OrderTag.resolveStrategy(nil, among: ["ema-trend"]) == nil)
    }

    @Test func hashingIsStableAcrossCalls() {
        #expect(OrderTag.hash(strategyId: "ema-trend") == OrderTag.hash(strategyId: "ema-trend"))
        #expect(OrderTag.hash(strategyId: "ema-trend") != OrderTag.hash(strategyId: "ema-trend-2"))
    }

    @Test func builtInPresetsDoNotCollide() {
        let ids = StrategyLibrary.presets.map(\.id)
        #expect(OrderTag.collisions(among: ids).isEmpty)
    }

    @Test func sequentialTagsDifferWithinTheSameMillisecond() {
        let now = Date()
        let first = OrderTag.make(strategyId: "s", at: now, nonce: 1)
        let second = OrderTag.make(strategyId: "s", at: now, nonce: 2)
        #expect(first != second)
    }
}

// MARK: - Position accounting

@Suite("Strategy position accounting")
struct StrategyPositionTests {
    private func fill(_ side: OrderSide, _ price: Double, _ quantity: Double,
                      fee: Double = 0, id: String = UUID().uuidString) -> StrategyFill {
        StrategyFill(id: id, strategyId: "s", instId: "BTC-USDT", side: side,
                     price: price, quantity: quantity, feeQuote: fee,
                     ts: Date(), clOrdId: nil, mode: .demo)
    }

    @Test func averageCostIsWeightedBySize() {
        var state = StrategyPositionState(strategyId: "s", instId: "BTC-USDT")
        state.apply(fill(.buy, 100, 1))
        state.apply(fill(.buy, 200, 3))
        #expect(state.quantity == 4)
        #expect(abs(state.averagePrice - 175) < 1e-9)   // (100 + 600) / 4
    }

    @Test func partialClosesRealiseProportionally() {
        var state = StrategyPositionState(strategyId: "s", instId: "BTC-USDT")
        state.apply(fill(.buy, 100, 4))
        state.apply(fill(.sell, 150, 1))
        #expect(state.quantity == 3)
        #expect(abs(state.realisedPnL - 50) < 1e-9)
        #expect(state.averagePrice == 100, "cost basis survives a partial exit")
    }

    @Test func flippingLongToShortRebasesTheAveragePrice() {
        var state = StrategyPositionState(strategyId: "s", instId: "BTC-USDT")
        state.apply(fill(.buy, 100, 1))
        state.apply(fill(.sell, 120, 3))     // close 1, open 2 short at 120
        #expect(abs(state.quantity - -2) < 1e-9)
        #expect(state.averagePrice == 120)
        #expect(abs(state.realisedPnL - 20) < 1e-9)
    }

    @Test func shortsRealiseProfitWhenCoveredLower() {
        var state = StrategyPositionState(strategyId: "s", instId: "BTC-USDT")
        state.apply(fill(.sell, 100, 2))
        state.apply(fill(.buy, 80, 2))
        #expect(state.isFlat)
        #expect(abs(state.realisedPnL - 40) < 1e-9)
        #expect(state.averagePrice == 0, "a flat book carries no cost basis")
    }

    @Test func unrealisedFollowsTheMark() {
        var state = StrategyPositionState(strategyId: "s", instId: "BTC-USDT")
        state.apply(fill(.buy, 100, 2, fee: 1))
        #expect(abs(state.unrealisedPnL(mark: 110) - 20) < 1e-9)
        #expect(abs(state.netPnL(mark: 110) - 19) < 1e-9, "fees come out of net P&L")
        #expect(abs((state.returnPct(mark: 110, capital: 190) ?? 0) - 10) < 1e-9)
        #expect(state.returnPct(mark: 110, capital: 0) == nil)
    }

    @Test func spotBuyFeesInBaseCurrencyConvertToQuote() {
        let exchange = ExchangeFill(
            id: "t1", instId: "BTC-USDT", side: .buy, posSide: nil,
            price: 100, size: 1, fee: -0.001, feeCcy: "BTC",
            ordId: "o1", clOrdId: nil, ts: Date())
        let fill = StrategyFill(exchange: exchange, strategyId: "s", mode: .demo)
        #expect(abs(fill.feeQuote - 0.1) < 1e-9, "0.001 BTC at 100 is 0.1 USDT")
    }
}

// MARK: - Ledger

@Suite("Strategy ledger")
@MainActor
struct StrategyLedgerTests {
    private func exchangeFill(
        id: String, side: OrderSide, price: Double, size: Double, clOrdId: String?
    ) -> ExchangeFill {
        ExchangeFill(id: id, instId: "BTC-USDT", side: side, posSide: nil,
                     price: price, size: size, fee: -0.1, feeCcy: "USDT",
                     ordId: "o" + id, clOrdId: clOrdId, ts: Date())
    }

    @Test func onlyTaggedFillsAreAttributed() {
        let ledger = StrategyLedger(mode: .demo)
        let mine = OrderTag.make(strategyId: "ema-trend")
        let added = ledger.ingest([
            exchangeFill(id: "1", side: .buy, price: 100, size: 1, clOrdId: mine),
            exchangeFill(id: "2", side: .buy, price: 100, size: 5, clOrdId: "someoneElse"),
            exchangeFill(id: "3", side: .buy, price: 100, size: 2, clOrdId: nil),
        ], knownStrategyIds: ["ema-trend"])

        #expect(added == 1)
        #expect(ledger.position(for: "ema-trend")?.quantity == 1,
                "manual and foreign orders must not land in a strategy's book")
    }

    @Test func ingestIsIdempotent() {
        let ledger = StrategyLedger(mode: .demo)
        let tag = OrderTag.make(strategyId: "ema-trend")
        let fills = [exchangeFill(id: "1", side: .buy, price: 100, size: 1, clOrdId: tag)]
        ledger.ingest(fills, knownStrategyIds: ["ema-trend"])
        ledger.ingest(fills, knownStrategyIds: ["ema-trend"])
        #expect(ledger.fills.count == 1)
        #expect(ledger.position(for: "ema-trend")?.quantity == 1)
    }

    @Test func positionsRebuildFromTheFillHistory() {
        let ledger = StrategyLedger(mode: .demo)
        let tag = OrderTag.make(strategyId: "ema-trend")
        ledger.ingest([
            exchangeFill(id: "1", side: .buy, price: 100, size: 2, clOrdId: tag),
            exchangeFill(id: "2", side: .sell, price: 120, size: 1, clOrdId: tag),
        ], knownStrategyIds: ["ema-trend"])
        let before = ledger.position(for: "ema-trend")

        ledger.rebuildPositions()
        #expect(ledger.position(for: "ema-trend")?.quantity == before?.quantity)
        #expect(ledger.position(for: "ema-trend")?.realisedPnL == before?.realisedPnL)
    }

    @Test func reconciliationSurfacesUnattributedHoldings() {
        let ledger = StrategyLedger(mode: .demo)
        let tag = OrderTag.make(strategyId: "ema-trend")
        ledger.ingest([exchangeFill(id: "1", side: .buy, price: 100, size: 1, clOrdId: tag)],
                      knownStrategyIds: ["ema-trend"])

        // The exchange holds 3 BTC; only 1 came from a strategy.
        let rows = ledger.reconcile(
            spotBalances: [AccountBalance(ccy: "BTC", available: 3, total: 3)],
            swapPositions: [])
        let row = try? #require(rows.first { $0.instId == "BTC-USDT" })
        #expect(row?.unattributed == 2)
        #expect(row?.isMaterial == true)
    }

    @Test func matchingBooksReportNoDiscrepancy() {
        let ledger = StrategyLedger(mode: .demo)
        let tag = OrderTag.make(strategyId: "ema-trend")
        ledger.ingest([exchangeFill(id: "1", side: .buy, price: 100, size: 2, clOrdId: tag)],
                      knownStrategyIds: ["ema-trend"])
        let rows = ledger.reconcile(
            spotBalances: [AccountBalance(ccy: "BTC", available: 2, total: 2)],
            swapPositions: [])
        #expect(rows.allSatisfy { !$0.isMaterial })
    }

    @Test func persistenceRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maystock-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ledger = StrategyLedger(mode: .demo)
        let tag = OrderTag.make(strategyId: "ema-trend")
        ledger.ingest([exchangeFill(id: "1", side: .buy, price: 100, size: 1, clOrdId: tag)],
                      knownStrategyIds: ["ema-trend"])

        let store = StrategyLedgerStore(directory: dir, mode: .demo)
        try store.save(fills: ledger.fills, positions: ledger.positions)
        let loaded = store.load()
        #expect(loaded.fills.count == 1)
        #expect(loaded.positions["ema-trend"]?.quantity == 1)
    }

    @Test func demoAndLiveKeepSeparateFiles() {
        let dir = FileManager.default.temporaryDirectory
        let demo = StrategyLedgerStore(directory: dir, mode: .demo)
        let live = StrategyLedgerStore(directory: dir, mode: .live)
        #expect(demo.fileURL != live.fileURL)
    }
}

// MARK: - Portfolio allocation

@Suite("Portfolio allocation")
struct PortfolioAllocationTests {
    @Test func allocationsCannotExceedTotalCapital() {
        var portfolio = StrategyPortfolioPrefs(totalCapital: 1_000)
        portfolio.setCapital(700, for: "a")
        portfolio.setCapital(900, for: "b")   // only 300 left
        #expect(portfolio.allocation(for: "b")?.capital == 300)
        #expect(portfolio.allocatedCapital == 1_000)
        #expect(portfolio.unallocatedCapital == 0)
    }

    @Test func headroomExcludesTheStrategysOwnBudget() {
        var portfolio = StrategyPortfolioPrefs(totalCapital: 1_000)
        portfolio.setCapital(400, for: "a")
        portfolio.setCapital(200, for: "b")
        #expect(portfolio.capitalHeadroom(for: "a") == 800, "a may grow into everything b left")
    }

    @Test func negativeAllocationsClampToZero() {
        var portfolio = StrategyPortfolioPrefs(totalCapital: 1_000)
        portfolio.setCapital(-50, for: "a")
        #expect(portfolio.allocation(for: "a")?.capital == 0)
    }

    @Test func evenDistributionSplitsTheWholePortfolio() {
        var portfolio = StrategyPortfolioPrefs(totalCapital: 900)
        portfolio.distributeEvenly(across: ["a", "b", "c"])
        #expect(portfolio.allocatedCapital == 900)
        #expect(portfolio.allocation(for: "b")?.capital == 300)
    }

    @Test func startingClearsAPreviousHaltReason() {
        var portfolio = StrategyPortfolioPrefs(totalCapital: 100)
        portfolio.setCapital(100, for: "a")
        portfolio.allocations[0].haltReason = "日内亏损熔断"
        portfolio.setRunning(true, for: "a")
        #expect(portfolio.allocation(for: "a")?.haltReason == nil)
        #expect(portfolio.runningCount == 1)
    }
}

@Suite("Instrument underlying")
struct InstrumentUnderlyingTests {
    /// The panel groups positions by underlying so a perpetual leg shows up on
    /// its spot symbol's panel. That grouping is built on `currencies(of:)`, so
    /// a swap and its spot pair must report the same base and quote.
    ///
    /// This was a real defect: the hybrid portfolio's `BTC-USDT-SWAP` shorts
    /// were invisible on the `BTC-USDT` panel, which read "当前空仓" while the
    /// account was short 11.65 contracts.
    @Test func aSwapAndItsSpotPairShareAnUnderlying() {
        let spot = StrategyLedger.currencies(of: "BTC-USDT")
        let swap = StrategyLedger.currencies(of: "BTC-USDT-SWAP")
        #expect(spot.base == swap.base)
        #expect(spot.quote == swap.quote)
        #expect(spot.base == "BTC" && spot.quote == "USDT")
    }

    @Test func differentAssetsDoNotCollide() {
        let btc = StrategyLedger.currencies(of: "BTC-USDT-SWAP")
        let eth = StrategyLedger.currencies(of: "ETH-USDT-SWAP")
        #expect(btc.base != eth.base)
    }

    @Test func degenerateInstrumentIdsAreSafe() {
        #expect(StrategyLedger.currencies(of: "BTC").base == "BTC")
        #expect(StrategyLedger.currencies(of: "BTC").quote == "USDT")
        #expect(StrategyLedger.currencies(of: "").base == "")
    }
}

@Suite("Perpetual contract sizing")
@MainActor
struct PerpetualContractSizingTests {
    private func shortPosition(instId: String, contracts: Double, at price: Double,
                               contractSize: Double) -> StrategyPositionState {
        var state = StrategyPositionState(strategyId: "s", instId: instId)
        state.contractSize = contractSize
        state.apply(StrategyFill(
            id: "1", strategyId: "s", instId: instId, side: .sell,
            price: price, quantity: contracts, feeQuote: 0,
            ts: Date(), clOrdId: nil, mode: .demo))
        return state
    }

    /// One BTC-USDT-SWAP contract is 0.01 BTC. A 100 USDT adverse move on a
    /// single contract is a 1 USDT loss, not 100.
    ///
    /// This was a live defect: the book held 11.65 BTC contracts and would have
    /// reported P&L 100× too large, while the exchange showed +27 USDT.
    @Test func oneBtcContractIsAHundredthOfACoin() {
        let state = shortPosition(instId: "BTC-USDT-SWAP", contracts: 1,
                                  at: 64_000, contractSize: 0.01)
        // Short: price falling 100 is a gain of 100 × 1 × 0.01 = 1.
        #expect(abs(state.unrealisedPnL(mark: 63_900) - 1) < 1e-9)
        #expect(abs(state.unrealisedPnL(mark: 64_100) + 1) < 1e-9)
        #expect(abs(state.baseQuantity + 0.01) < 1e-12)
    }

    @Test func ethContractsScaleByATenth() {
        let state = shortPosition(instId: "ETH-USDT-SWAP", contracts: 40.04,
                                  at: 1_919.58, contractSize: 0.1)
        // 4.004 ETH short; a 10 USDT drop is a 40.04 USDT gain.
        #expect(abs(state.baseQuantity + 4.004) < 1e-9)
        #expect(abs(state.unrealisedPnL(mark: 1_909.58) - 40.04) < 1e-6)
    }

    @Test func spotIsUnscaled() {
        var state = StrategyPositionState(strategyId: "s", instId: "BTC-USDT")
        state.apply(StrategyFill(
            id: "1", strategyId: "s", instId: "BTC-USDT", side: .buy,
            price: 64_000, quantity: 0.5, feeQuote: 0,
            ts: Date(), clOrdId: nil, mode: .demo))
        #expect(state.multiplier == 1)
        #expect(abs(state.baseQuantity - 0.5) < 1e-12)
        #expect(abs(state.unrealisedPnL(mark: 64_100) - 50) < 1e-9)
    }

    /// Ledgers written before `contractSize` existed decode with it absent.
    /// They must behave as spot (multiplier 1) rather than crashing or
    /// silently zeroing the position.
    @Test func anOlderLedgerDecodesAsUnscaled() throws {
        let json = """
        {"strategyId":"s","instId":"BTC-USDT-SWAP","quantity":-11.65,
         "averagePrice":64769.39,"realisedPnL":0,"feesPaid":3.77,"fillCount":5}
        """
        let state = try JSONDecoder().decode(
            StrategyPositionState.self, from: Data(json.utf8))
        #expect(state.multiplier == 1)
        #expect(state.contractSize == nil)
    }

    /// Teaching the ledger a contract size must fix positions already on the
    /// book — a restart loads a ledger that predates the knowledge.
    @Test func learningTheContractSizeCorrectsExistingPositions() {
        let ledger = StrategyLedger(mode: .demo)
        ledger.record(StrategyFill(
            id: "1", strategyId: "s", instId: "BTC-USDT-SWAP", side: .sell,
            price: 64_000, quantity: 1, feeQuote: 0,
            ts: Date(), clOrdId: nil, mode: .demo))
        #expect(ledger.position(for: "s")?.multiplier == 1)

        ledger.setContractSize(0.01, forInstId: "BTC-USDT-SWAP")
        let corrected = ledger.position(for: "s")
        #expect(corrected?.multiplier == 0.01)
        #expect(abs((corrected?.unrealisedPnL(mark: 63_900) ?? 0) - 1) < 1e-9)
    }

    @Test func aNonsenseContractSizeIsIgnored() {
        let ledger = StrategyLedger(mode: .demo)
        ledger.record(StrategyFill(
            id: "1", strategyId: "s", instId: "BTC-USDT-SWAP", side: .sell,
            price: 64_000, quantity: 1, feeQuote: 0,
            ts: Date(), clOrdId: nil, mode: .demo))
        ledger.setContractSize(0, forInstId: "BTC-USDT-SWAP")
        ledger.setContractSize(-5, forInstId: "BTC-USDT-SWAP")
        #expect(ledger.position(for: "s")?.multiplier == 1, "never scale by zero")
    }
}

@Suite("Position sizing units")
@MainActor
struct PositionSizingUnitTests {
    /// `submit(baseDelta:)` is denominated in coins and converts to contracts
    /// itself, so every caller must hand it coins.
    ///
    /// The flatten and daily-loss paths passed `position.quantity`, which is
    /// contracts. On the live book of 11.65 BTC-USDT-SWAP contracts that would
    /// have submitted a sell for 11.65 *BTC* — a hundred times the position —
    /// and an emergency stop is exactly when that must not happen.
    @Test func flatteningUsesCoinsNotContracts() {
        var state = StrategyPositionState(strategyId: "s", instId: "BTC-USDT-SWAP")
        state.contractSize = 0.01
        state.apply(StrategyFill(
            id: "1", strategyId: "s", instId: "BTC-USDT-SWAP", side: .sell,
            price: 64_769, quantity: 11.65, feeQuote: 0,
            ts: Date(), clOrdId: nil, mode: .demo))

        #expect(state.quantity == -11.65, "the ledger counts contracts")
        #expect(abs(state.baseQuantity + 0.1165) < 1e-12, "orders are placed in coins")
        // The distinction is a factor of 100 — the difference between closing
        // a position and opening a much larger opposite one.
        #expect(abs(state.quantity / state.baseQuantity) == 100)
    }

    /// A round trip through the instrument's own conversion must return the
    /// contract count the exchange reported.
    @Test func coinsRoundTripBackToContracts() {
        let meta = InstrumentMeta(
            instId: "BTC-USDT-SWAP", tickSize: 0.1, lotSize: 0.01,
            minSize: 0.01, contractValue: 0.01)
        var state = StrategyPositionState(strategyId: "s", instId: "BTC-USDT-SWAP")
        state.contractSize = 0.01
        state.apply(StrategyFill(
            id: "1", strategyId: "s", instId: "BTC-USDT-SWAP", side: .sell,
            price: 64_769, quantity: 11.65, feeQuote: 0,
            ts: Date(), clOrdId: nil, mode: .demo))

        let contracts = meta.exchangeSize(forBaseQuantity: abs(state.baseQuantity))
        #expect(abs(contracts - 11.65) < 1e-9)
    }

    @Test func spotNeedsNoConversion() {
        var state = StrategyPositionState(strategyId: "s", instId: "BTC-USDT")
        state.apply(StrategyFill(
            id: "1", strategyId: "s", instId: "BTC-USDT", side: .buy,
            price: 64_769, quantity: 0.25, feeQuote: 0,
            ts: Date(), clOrdId: nil, mode: .demo))
        #expect(state.quantity == state.baseQuantity)
    }
}
