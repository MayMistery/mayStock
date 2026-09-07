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

    @Test func spotBuyFeesInBaseCurrencyConvertToQuote() throws {
        let exchange = ExchangeFill(
            id: "t1", instId: "BTC-USDT", side: .buy, posSide: nil,
            price: 100, size: 1, fee: -0.001, feeCcy: "BTC",
            ordId: "o1", clOrdId: nil, ts: Date())
        let fill = try #require(StrategyFill(exchange: exchange, strategyId: "s", mode: .demo, venue: .okx))
        #expect(abs(fill.feeQuote - 0.1) < 1e-9, "0.001 BTC at 100 is 0.1 USDT")
    }
}

// MARK: - Realised-per-fill stamps

/// The realisation rule lives once, in `apply`; the stamp is its return value.
/// The guard here is therefore an invariant over whole fill sequences — the
/// stamps must sum to the position's realised P&L — rather than a list of
/// hand-picked cases that only re-prove yesterday's arithmetic.
@Suite("每笔成交的兑现盖章")
@MainActor
struct FillRealisationStampTests {
    private func fill(
        _ side: OrderSide, _ price: Double, _ quantity: Double,
        fee: Double = 0, instId: String = "BTC-USDT", id: String = UUID().uuidString
    ) -> StrategyFill {
        StrategyFill(id: id, strategyId: "s", instId: instId, side: side,
                     price: price, quantity: quantity, feeQuote: fee,
                     ts: Date(), clOrdId: nil, mode: .demo)
    }

    @Test("开仓单没有兑现，盖章为空")
    func openersCarryNoStamp() {
        let ledger = StrategyLedger(mode: .demo)
        ledger.record(fill(.buy, 100, 2, fee: 0.2))
        #expect(ledger.fills.first?.realisedQuote == nil)
        #expect(ledger.fills.first?.netRealisedQuote == nil)
    }

    @Test("平仓单盖毛额，净额扣掉本笔手续费")
    func closersAreStampedNetOfTheirOwnFee() {
        let ledger = StrategyLedger(mode: .demo)
        ledger.record(fill(.buy, 100, 4, fee: 0.4))
        ledger.record(fill(.sell, 150, 1, fee: 0.1))
        let closer = ledger.fills.last
        #expect(abs((closer?.realisedQuote ?? 0) - 50) < 1e-9)
        #expect(abs((closer?.netRealisedQuote ?? 0) - 49.9) < 1e-9,
                "净额只扣这一笔的手续费；开仓那笔的费用已经在开仓行显示过")
    }

    @Test("反手单只对平掉的那部分盖章")
    func aFlipStampsOnlyTheOverlap() {
        let ledger = StrategyLedger(mode: .demo)
        ledger.record(fill(.buy, 100, 1))
        ledger.record(fill(.sell, 120, 3))
        #expect(abs((ledger.fills.last?.realisedQuote ?? 0) - 20) < 1e-9,
                "平 1 开 2 空，只有平掉的 1 手算兑现")
    }

    /// The invariant, walked over a sequence that exercises every branch of
    /// `apply` — open, add, partial close, full close, flip — on a contract
    /// with a real multiplier. If a new branch ever realises money without
    /// returning it, or returns it without booking it, this sum breaks.
    @Test("全序列不变量：盖章之和等于持仓的已实现盈亏")
    func stampsSumToThePositionsRealisedPnL() {
        let ledger = StrategyLedger(mode: .demo)
        let inst = "ETH-USDT-SWAP"
        ledger.setContractSize(0.1, forInstId: inst)
        let sequence: [(OrderSide, Double, Double)] = [
            (.buy, 1_800, 10),   // open long
            (.buy, 1_900, 10),   // add
            (.sell, 1_950, 5),   // partial close
            (.sell, 1_700, 25),  // close the rest and flip short
            (.buy, 1_650, 12),   // cover past flat back to long
            (.sell, 1_640, 2),   // close again
        ]
        for (side, price, quantity) in sequence {
            ledger.record(fill(side, price, quantity, fee: 0.5, instId: inst))
        }
        let stamped = ledger.fills.compactMap(\.realisedQuote).reduce(0, +)
        let booked = ledger.position(for: "s")?.realisedPnL ?? 0
        #expect(abs(stamped - booked) < 1e-9,
                "盖章之和 \(stamped) 与账面已实现 \(booked) 不一致")
        #expect(ledger.fills.allSatisfy { $0.positionEffect != nil },
                "每笔入账的成交都必须带上开/加/平/反手判定")
        #expect(ledger.fills.map(\.positionEffect) ==
                [.open, .add, .close, .flip, .flip, .close],
                "效果序列要和 apply 的每个分支一一对上")
    }

    /// Walked off the declaration, not a hand-picked pair: any new effect case
    /// added to the enum fails here until it gets a label, and no two actions
    /// may collapse into the same word.
    @Test("操作标签覆盖整个效果×方向声明，且互不混淆")
    func actionLabelsCoverTheWholeDeclaration() {
        var seen: [String: String] = [:]
        for effect in PositionEffect.allCases {
            for side in [OrderSide.buy, .sell] {
                let labelled = StrategyFill(
                    id: "x", strategyId: "s", instId: "BTC-USDT", side: side,
                    price: 1, quantity: 1, feeQuote: 0, ts: Date(), clOrdId: nil,
                    mode: .demo, positionEffect: effect)
                let label = labelled.actionLabel
                #expect(!label.isEmpty)
                #expect(label != side.displayName,
                        "有效果判定时必须说开/平，不能退回买/卖")
                let key = "\(effect)-\(side)"
                #expect(!seen.values.contains(label), "\(key) 与 \(seen.first { $0.value == label }?.key ?? "") 共用了标签 \(label)")
                seen[key] = label
            }
        }
        let bare = StrategyFill(
            id: "x", strategyId: "s", instId: "BTC-USDT", side: .buy,
            price: 1, quantity: 1, feeQuote: 0, ts: Date(), clOrdId: nil, mode: .demo)
        #expect(bare.actionLabel == OrderSide.buy.displayName,
                "没重放过的旧记录退回买入/卖出，不硬猜")
    }

    @Test("重放恢复会给没有盖章的旧成交补章")
    func rebuildRestampsLegacyFills() {
        let ledger = StrategyLedger(mode: .demo)
        ledger.setContractSize(0.1, forInstId: "ETH-USDT-SWAP")
        ledger.record(fill(.buy, 1_800, 10, instId: "ETH-USDT-SWAP"))
        ledger.record(fill(.sell, 1_900, 10, instId: "ETH-USDT-SWAP"))
        let stampedBefore = ledger.fills.map { ($0.realisedQuote, $0.positionEffect) }

        // A ledger written before the stamps existed: same fills, no stamps.
        var stripped = ledger.fills
        for index in stripped.indices {
            stripped[index].realisedQuote = nil
            stripped[index].positionEffect = nil
        }
        ledger.replace(fills: stripped, positions: ledger.positions)

        ledger.rebuildPositions()
        let after = ledger.fills.map { ($0.realisedQuote, $0.positionEffect) }
        #expect(after.elementsEqual(stampedBefore, by: ==))
    }

    /// The load path, not just the explicit rebuild: a ledger written before
    /// the stamp existed gets its stamps the moment it is read back, using the
    /// multipliers the persisted positions already carry.
    @Test("加载旧账本时就地补章，乘数取自持久化仓位")
    func loadingALegacyLedgerRestampsWithPersistedMultipliers() {
        let inst = "ETH-USDT-SWAP"
        var position = StrategyPositionState(strategyId: "s", instId: inst)
        position.contractSize = 0.1
        let unstamped = [
            fill(.sell, 1_900, 10, instId: inst, id: "open"),
            fill(.buy, 1_800, 10, fee: 0.5, instId: inst, id: "close"),
        ]

        let ledger = StrategyLedger(mode: .demo)
        ledger.replace(fills: unstamped, positions: ["s": position])

        let closer = ledger.fills.first { $0.id == "close" }
        #expect(abs((closer?.realisedQuote ?? 0) - 100) < 1e-9,
                "空 10 张 @1900 平 @1800，面值 0.1：(1900-1800)×10×0.1 = 100")
        #expect(closer?.positionEffect == .close)
        let opener = ledger.fills.first { $0.id == "open" }
        #expect(opener?.realisedQuote == nil)
        #expect(opener?.positionEffect == .open)
    }

    /// A rebuild replays from blank states, so it can only know multipliers
    /// from the lookup table — which used to start empty after a restart,
    /// making "load, then rebuild" silently re-book every swap at multiplier 1
    /// and drop the contract size from the rebuilt position.
    @Test("加载后立刻重建不会丢乘数")
    func rebuildingRightAfterLoadKeepsTheMultiplier() {
        let inst = "ETH-USDT-SWAP"
        var position = StrategyPositionState(strategyId: "s", instId: inst)
        position.contractSize = 0.1
        let history = [
            fill(.sell, 1_900, 10, instId: inst, id: "open"),
            fill(.buy, 1_800, 10, instId: inst, id: "close"),
        ]

        let ledger = StrategyLedger(mode: .demo)
        ledger.replace(fills: history, positions: ["s": position])
        ledger.rebuildPositions()

        #expect(ledger.position(for: "s")?.contractSize == 0.1,
                "重建后的仓位必须还记得面值")
        #expect(abs((ledger.position(for: "s")?.realisedPnL ?? 0) - 100) < 1e-9,
                "没有回种 contractSizes 的话这里会按乘数 1 重算成 1000")
    }

    @Test("旧账本文件没有这个字段也能解码")
    func legacyLedgerFilesDecodeWithoutTheField() throws {
        let json = """
        {"id":"f1","strategyId":"s","instId":"BTC-USDT","side":"buy","price":100,
         "quantity":1,"feeQuote":0.1,"ts":"2026-08-01T00:00:00Z","mode":"demo"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StrategyFill.self, from: Data(json.utf8))
        #expect(decoded.realisedQuote == nil)
        #expect(decoded.positionEffect == nil)
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
        ], knownStrategyIds: ["ema-trend"], venue: .okx)

        #expect(added == 1)
        #expect(ledger.position(for: "ema-trend")?.quantity == 1,
                "manual and foreign orders must not land in a strategy's book")
    }

    @Test func ingestIsIdempotent() {
        let ledger = StrategyLedger(mode: .demo)
        let tag = OrderTag.make(strategyId: "ema-trend")
        let fills = [exchangeFill(id: "1", side: .buy, price: 100, size: 1, clOrdId: tag)]
        ledger.ingest(fills, knownStrategyIds: ["ema-trend"], venue: .okx)
        ledger.ingest(fills, knownStrategyIds: ["ema-trend"], venue: .okx)
        #expect(ledger.fills.count == 1)
        #expect(ledger.position(for: "ema-trend")?.quantity == 1)
    }

    @Test func positionsRebuildFromTheFillHistory() {
        let ledger = StrategyLedger(mode: .demo)
        let tag = OrderTag.make(strategyId: "ema-trend")
        ledger.ingest([
            exchangeFill(id: "1", side: .buy, price: 100, size: 2, clOrdId: tag),
            exchangeFill(id: "2", side: .sell, price: 120, size: 1, clOrdId: tag),
        ], knownStrategyIds: ["ema-trend"], venue: .okx)
        let before = ledger.position(for: "ema-trend")

        ledger.rebuildPositions()
        #expect(ledger.position(for: "ema-trend")?.quantity == before?.quantity)
        #expect(ledger.position(for: "ema-trend")?.realisedPnL == before?.realisedPnL)
    }

    /// Funding is not derived from fills, so a replay cannot re-derive it —
    /// and the bill ids that make booking idempotent survive the rebuild, so
    /// dropping it here would delete a real cost that could never come back.
    @Test func rebuildingKeepsFundingItCannotReplay() {
        let ledger = StrategyLedger(mode: .demo)
        let tag = OrderTag.make(strategyId: "ema-trend")
        ledger.ingest([exchangeFill(id: "1", side: .buy, price: 100, size: 2, clOrdId: tag)],
                      knownStrategyIds: ["ema-trend"], venue: .okx)
        ledger.recordFunding(
            FundingPayment(id: "bill-1", instId: "BTC-USDT", amount: -31.19,
                           ccy: "USDT", ts: Date(timeIntervalSince1970: 1_000)),
            strategyId: "ema-trend")

        ledger.rebuildPositions()

        #expect(ledger.position(for: "ema-trend")?.fundingPaid == -31.19)
        #expect(ledger.recordedFundingIds.contains("bill-1"))
    }

    @Test func reconciliationSurfacesUnattributedHoldings() {
        let ledger = StrategyLedger(mode: .demo)
        let tag = OrderTag.make(strategyId: "ema-trend")
        ledger.ingest([exchangeFill(id: "1", side: .buy, price: 100, size: 1, clOrdId: tag)],
                      knownStrategyIds: ["ema-trend"], venue: .okx)

        // The exchange holds 3 BTC; only 1 came from a strategy.
        let rows = ledger.reconcile(
            spotBalances: [AccountBalance(ccy: "BTC", available: 3, total: 3)],
            derivativePositions: [])
        let row = try? #require(rows.first { $0.instId == "BTC-USDT" })
        #expect(row?.unattributed == 2)
        #expect(row?.isMaterial == true)
    }

    @Test func matchingBooksReportNoDiscrepancy() {
        let ledger = StrategyLedger(mode: .demo)
        let tag = OrderTag.make(strategyId: "ema-trend")
        ledger.ingest([exchangeFill(id: "1", side: .buy, price: 100, size: 2, clOrdId: tag)],
                      knownStrategyIds: ["ema-trend"], venue: .okx)
        let rows = ledger.reconcile(
            spotBalances: [AccountBalance(ccy: "BTC", available: 2, total: 2)],
            derivativePositions: [])
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
                      knownStrategyIds: ["ema-trend"], venue: .okx)

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
    /// its spot symbol's panel. That grouping is built on the venue's
    /// `currencies(of:)`, so a swap and its spot pair must report the same
    /// base and quote.
    ///
    /// This was a real defect: the hybrid portfolio's `BTC-USDT-SWAP` shorts
    /// were invisible on the `BTC-USDT` panel, which read "当前空仓" while the
    /// account was short 11.65 contracts.
    @Test func aSwapAndItsSpotPairShareAnUnderlying() {
        let spot = Venue.okx.currencies(of: "BTC-USDT")
        let swap = Venue.okx.currencies(of: "BTC-USDT-SWAP")
        #expect(spot.base == swap.base)
        #expect(spot.quote == swap.quote)
        #expect(spot.base == "BTC" && spot.quote == "USDT")
    }

    @Test func differentAssetsDoNotCollide() {
        let btc = Venue.okx.currencies(of: "BTC-USDT-SWAP")
        let eth = Venue.okx.currencies(of: "ETH-USDT-SWAP")
        #expect(btc.base != eth.base)
    }

    @Test func degenerateInstrumentIdsAreSafe() {
        #expect(Venue.okx.currencies(of: "BTC").base == "BTC")
        #expect(Venue.okx.currencies(of: "BTC").quote == "USDT")
        #expect(Venue.okx.currencies(of: "").base == "")
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
    /// book — a ledger written before the field existed loads without one.
    @Test func learningTheContractSizeCorrectsExistingPositions() {
        let ledger = StrategyLedger(mode: .demo)
        var stale = StrategyPositionState(strategyId: "s", instId: "BTC-USDT-SWAP")
        stale.quantity = -1
        stale.averagePrice = 64_000
        ledger.replace(fills: [], positions: ["s": stale])
        #expect(ledger.position(for: "s")?.multiplier == 1)

        ledger.setContractSize(0.01, forInstId: "BTC-USDT-SWAP")
        let corrected = ledger.position(for: "s")
        #expect(corrected?.multiplier == 0.01)
        #expect(abs((corrected?.unrealisedPnL(mark: 63_900) ?? 0) - 1) < 1e-9)
    }

    @Test func aNonsenseContractSizeIsIgnored() {
        let ledger = StrategyLedger(mode: .demo)
        ledger.setContractSize(0.01, forInstId: "BTC-USDT-SWAP")
        ledger.record(StrategyFill(
            id: "1", strategyId: "s", instId: "BTC-USDT-SWAP", side: .sell,
            price: 64_000, quantity: 1, feeQuote: 0,
            ts: Date(), clOrdId: nil, mode: .demo))
        ledger.setContractSize(0, forInstId: "BTC-USDT-SWAP")
        ledger.setContractSize(-5, forInstId: "BTC-USDT-SWAP")
        #expect(ledger.position(for: "s")?.multiplier == 0.01, "never scale by zero")
    }

    /// The realised stamp is cumulative and taken once, so a multiplier
    /// learned afterwards cannot repair it. A fill that cannot be scaled
    /// waits instead of being booked at 1.
    @Test("面值未知的衍生品成交不入账，知道之后按真面值补记")
    func aFillIsNotBookedUntilItsContractSizeIsKnown() {
        let ledger = StrategyLedger(mode: .demo)
        let call = "BTC-USD-261225-100000-C"
        let tag = OrderTag.make(strategyId: "s")
        func fill(_ id: String, _ side: OrderSide, _ price: Double) -> ExchangeFill {
            ExchangeFill(
                id: id, instId: call, side: side, posSide: nil, price: price, size: 2,
                fee: 0, feeCcy: "BTC", ordId: "o" + id, clOrdId: tag,
                ts: Date(timeIntervalSince1970: 1_000), priceUsd: nil, indexPrice: 80_000)
        }
        let listing = [fill("open", .buy, 0.0375), fill("close", .sell, 0.037)]

        // A fresh ledger reading the exchange's history has never held this
        // contract, so nobody has told it one contract is 0.01 BTC.
        #expect(ledger.ingest(listing, knownStrategyIds: ["s"], venue: .okx) == 0)
        #expect(ledger.fills.isEmpty)
        #expect(ledger.position(for: "s") == nil)

        // The caller looked the size up; both fills book at once, correctly.
        #expect(ledger.ingest(listing, knownStrategyIds: ["s"], venue: .okx,
                              contractSizes: [call: 0.01]) == 2)
        let position = try? #require(ledger.position(for: "s"))
        #expect(position?.isFlat == true)
        // (0.037 − 0.0375) × 80,000 × 2 contracts × 0.01 BTC = −0.80.
        #expect(abs((position?.realisedPnL ?? 0) + 0.80) < 1e-6,
                "realised=\(position?.realisedPnL ?? 0)")
    }

    @Test("现货不需要谁来教面值")
    func spotNeedsNoMultiplier() {
        let ledger = StrategyLedger(mode: .demo)
        ledger.record(StrategyFill(
            id: "1", strategyId: "s", instId: "BTC-USDT", side: .buy,
            price: 64_000, quantity: 0.5, feeQuote: 0, ts: Date(), clOrdId: nil, mode: .demo))
        #expect(ledger.position(for: "s")?.quantity == 0.5)
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

// MARK: - Funding

@Suite("资金费入账")
@MainActor
struct LedgerFundingTests {
    private func payment(_ id: String, _ amount: Double) -> FundingPayment {
        FundingPayment(
            id: id, instId: "ETH-USDT-SWAP", amount: amount, ccy: "USDT",
            ts: Date(timeIntervalSince1970: 1_770_000_000))
    }

    private func ledgerHoldingAPosition() -> StrategyLedger {
        let ledger = StrategyLedger(mode: .demo)
        // One ETH-USDT-SWAP contract is 0.1 ETH; a ledger that has not been
        // told refuses the fill rather than booking it at 1.
        ledger.setContractSize(0.1, forInstId: "ETH-USDT-SWAP")
        ledger.record(StrategyFill(
            id: "f1", strategyId: "eth-short", instId: "ETH-USDT-SWAP", side: .sell,
            price: 1_919.58, quantity: 40, feeQuote: 0,
            ts: Date(timeIntervalSince1970: 1_770_000_000), clOrdId: nil, mode: .demo))
        return ledger
    }

    @Test func theSameBillIsOnlyBookedOnce() {
        let ledger = ledgerHoldingAPosition()
        #expect(ledger.recordFunding(payment("b1", -32.24), strategyId: "eth-short"))
        #expect(!ledger.recordFunding(payment("b1", -32.24), strategyId: "eth-short"))
        #expect(ledger.position(for: "eth-short")?.fundingPaid == -32.24)
    }

    /// The bug this exists to prevent, and it cost real accuracy: the dedup set
    /// lived only in memory while the exchange kept serving the same bills for
    /// days, so every relaunch re-booked the whole visible history. The demo
    /// book read BTC +36.37 / ETH -77.90 against real bills of +2.73 / -31.19 —
    /// a carry cost inflated 13× and 2.5×, with nothing erroring. Idempotency
    /// that does not survive a restart is not idempotency.
    @Test func bookedBillsSurviveARestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StrategyLedgerStore(directory: directory, mode: .demo)

        let before = ledgerHoldingAPosition()
        before.recordFunding(payment("b1", -0.76), strategyId: "eth-short")
        before.recordFunding(payment("b2", -0.28), strategyId: "eth-short")
        before.recordFunding(payment("b3", -32.24), strategyId: "eth-short")
        try store.save(
            fills: before.fills, positions: before.positions,
            fundingIds: before.recordedFundingIds)

        // Relaunch, then poll again: the exchange still lists all three bills.
        let payload = store.load()
        let after = StrategyLedger(mode: .demo)
        after.replace(
            fills: payload.fills, positions: payload.positions, fundingIds: payload.fundingIds)
        for bill in [("b1", -0.76), ("b2", -0.28), ("b3", -32.24)] {
            #expect(!after.recordFunding(payment(bill.0, bill.1), strategyId: "eth-short"))
        }
        #expect(abs((after.position(for: "eth-short")?.fundingPaid ?? 0) - -33.28) < 1e-9)
    }

    /// A ledger written before the field existed decodes to an empty set. That
    /// is honest — we genuinely do not know what it booked — so the first poll
    /// after upgrading may still double-count once. It cannot recur.
    @Test func aLedgerWithoutTheFieldStillLoads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StrategyLedgerStore(directory: directory, mode: .demo)
        try Data(#"{"fills":[],"positions":{}}"#.utf8).write(to: store.fileURL)
        #expect(store.load().fundingIds.isEmpty)
    }
}

// MARK: - Options in the book

/// An option is quoted in its settlement coin per unit of underlying, and so
/// is its fee; the book keeps quote currency. Everything below is about that
/// conversion being done once, at the fill, at the index the exchange stamped.
@Suite("期权入账")
@MainActor
struct LedgerOptionTests {
    private let call = "BTC-USD-260926-80000-C"
    private let put = "BTC-USD-260926-80000-P"

    private func exchangeFill(
        id: String = "opt-1", instId: String? = nil, side: OrderSide = .buy,
        price: Double = 0.02, size: Double = 5, fee: Double = -0.0001,
        priceUsd: Double? = nil, indexPrice: Double? = 80_000, clOrdId: String? = nil
    ) -> ExchangeFill {
        ExchangeFill(
            id: id, instId: instId ?? call, side: side, posSide: nil,
            price: price, size: size, fee: fee, feeCcy: "BTC",
            ordId: "o", clOrdId: clOrdId, ts: Date(timeIntervalSince1970: 1_000),
            priceUsd: priceUsd, indexPrice: indexPrice)
    }

    @Test("权利金和手续费按成交时的指数价换算成计价币")
    func premiumAndFeeConvertAtTheFillIndex() throws {
        let fill = try #require(StrategyFill(exchange: exchangeFill(), strategyId: "s", mode: .demo, venue: .okx))
        // 0.02 BTC per unit at an 80,000 index is 1,600 USD per unit.
        #expect(abs(fill.price - 1_600) < 1e-9)
        // A 0.0001 BTC fee is 8 USD.
        #expect(abs(fill.feeQuote - 8) < 1e-9)
        #expect(fill.quantity == 5)
    }

    @Test("交易所给了美元价就用美元价")
    func theExchangesUsdPriceWins() throws {
        let fill = try #require(StrategyFill(
            exchange: exchangeFill(priceUsd: 1_650), strategyId: "s", mode: .demo, venue: .okx))
        #expect(abs(fill.price - 1_650) < 1e-9)
    }

    @Test("没有指数价就不入账，而不是猜一个")
    func noIndexMeansNoBooking() {
        #expect(StrategyFill(
            exchange: exchangeFill(indexPrice: nil), strategyId: "s", mode: .demo, venue: .okx) == nil)
        // The caller's own reading fills the gap.
        let converted = StrategyFill(
            exchange: exchangeFill(indexPrice: nil), strategyId: "s", mode: .demo,
            venue: .okx, indexPrice: 90_000)
        #expect(abs((converted?.price ?? 0) - 1_800) < 1e-9)
    }

    @Test("ingest 用调用方的指数价补齐，补不齐的留到下轮")
    func ingestUsesTheCallersIndexAndLeavesTheRest() {
        let ledger = StrategyLedger(mode: .demo)
        let tag = OrderTag.make(strategyId: "s")
        let fills = [exchangeFill(id: "a", indexPrice: nil, clOrdId: tag)]
        ledger.setContractSize(0.01, forInstId: call)
        #expect(ledger.ingest(fills, knownStrategyIds: ["s"], venue: .okx) == 0, "nothing to convert with")
        #expect(ledger.fills.isEmpty)
        #expect(ledger.ingest(fills, knownStrategyIds: ["s"], venue: .okx, indexPrices: ["BTC-USD": 80_000]) == 1)
        #expect(abs((ledger.position(for: "s")?.averagePrice ?? 0) - 1_600) < 1e-9)
    }

    @Test("空仓时可以换到新合约，持仓时不能")
    func aFlatBookRollsToANewContractAndAnOpenOneDoesNot() {
        let ledger = StrategyLedger(mode: .demo)
        ledger.setContractSize(0.01, forInstId: call)
        ledger.setContractSize(0.01, forInstId: put)
        let tag = OrderTag.make(strategyId: "s")
        ledger.ingest([exchangeFill(id: "open-call", clOrdId: tag)], knownStrategyIds: ["s"], venue: .okx)
        #expect(ledger.position(for: "s")?.instId == call)

        // A fill on another contract while this one is held is left out and
        // retried later: the arithmetic of one book cannot span two contracts.
        ledger.ingest([exchangeFill(id: "stray", instId: put, clOrdId: tag)], knownStrategyIds: ["s"], venue: .okx)
        #expect(ledger.position(for: "s")?.instId == call)
        #expect(ledger.position(for: "s")?.quantity == 5)
        #expect(ledger.fills.count == 1)

        // Close the call; the book is flat and the put may now be booked.
        ledger.ingest([exchangeFill(id: "close-call", side: .sell, price: 0.03, clOrdId: tag)],
                      knownStrategyIds: ["s"], venue: .okx)
        #expect(ledger.position(for: "s")?.isFlat == true)
        ledger.ingest([exchangeFill(id: "stray", instId: put, clOrdId: tag)], knownStrategyIds: ["s"], venue: .okx)
        let rolled = ledger.position(for: "s")
        #expect(rolled?.instId == put)
        #expect(rolled?.quantity == 5)
        #expect(rolled?.contractSize == 0.01, "the new contract's multiplier, not the old one's")
    }

    @Test("看跌期权的多头是看空观点")
    func aLongPutReadsAsAShortView() {
        var state = StrategyPositionState(strategyId: "s", instId: put)
        state.contractSize = 0.01
        state.apply(StrategyFill(
            id: "1", strategyId: "s", instId: put, side: .buy, price: 1_600, quantity: 5,
            feeQuote: 0, ts: Date(), clOrdId: nil, mode: .demo))
        #expect(state.direction == .long, "the book is long the contract")
        #expect(state.signalDirection == .short, "and short the market")
        // 5 contracts × 0.01 = 0.05 units, signed by the view.
        #expect(abs(state.kernelHeldBase + 0.05) < 1e-12)

        var callState = StrategyPositionState(strategyId: "s", instId: call)
        callState.contractSize = 0.01
        callState.apply(StrategyFill(
            id: "1", strategyId: "s", instId: call, side: .buy, price: 1_600, quantity: 5,
            feeQuote: 0, ts: Date(), clOrdId: nil, mode: .demo))
        #expect(callState.signalDirection == .long)
        #expect(abs(callState.kernelHeldBase - 0.05) < 1e-12)
        #expect(StrategyPositionState(strategyId: "s", instId: call).kernelHeldBase == 0)
    }

    @Test("期权盈亏按权利金差 × 张数 × 面值")
    func optionPnLScalesByTheContractMultiplier() {
        var state = StrategyPositionState(strategyId: "s", instId: call)
        state.contractSize = 0.01
        state.apply(StrategyFill(
            id: "1", strategyId: "s", instId: call, side: .buy, price: 1_600, quantity: 5,
            feeQuote: 8, ts: Date(), clOrdId: nil, mode: .demo))
        // Premium up 400 per unit on 0.05 units = 20, less the 8 fee.
        #expect(abs(state.unrealisedPnL(mark: 2_000) - 20) < 1e-9)
        #expect(abs(state.netPnL(mark: 2_000) - 12) < 1e-9)
        // Exposure is the premium's current value, not the notional it controls.
        #expect(abs(state.exposure(mark: 2_000) - 100) < 1e-9)
    }
}
