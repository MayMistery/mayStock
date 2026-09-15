import Foundation
import MayStockKit

/// Portfolio arithmetic every surface shares. One definition of "this
/// strategy's return", so the panel, the overview and the studio can never
/// disagree about it.
extension AppState {
    /// Latest known price for an instrument: any runner's poll, else a live
    /// watchlist session.
    func mark(for instId: String) -> Double? {
        for runner in runners {
            if let mark = runner.mark(for: instId) { return mark }
        }
        return hub.session(for: instId)?.ticker?.last
    }

    func netPnL(for strategyId: String) -> Double {
        guard let position = ledger(forStrategy: strategyId)?.position(for: strategyId) else { return 0 }
        return position.netPnL(mark: mark(for: position.instId))
    }

    func returnPct(for strategyId: String) -> Double? {
        guard let allocation = store.config.strategy.allocation(for: strategyId),
              allocation.capital > 0,
              let position = ledger(forStrategy: strategyId)?.position(for: strategyId),
              position.fillCount > 0 else { return nil }
        return position.returnPct(mark: mark(for: position.instId), capital: allocation.capital)
    }

    /// Net P&L of every strategy budgeted on a venue, in its currency.
    func portfolioNetPnL(on venue: Venue) -> Double {
        store.config.strategy.allocations(on: venue).reduce(0) { $0 + netPnL(for: $1.strategyId) }
    }

    func portfolioReturnPct(on venue: Venue) -> Double? {
        let allocated = store.config.strategy.allocatedCapital(on: venue)
        guard allocated > 0 else { return nil }
        return portfolioNetPnL(on: venue) / allocated * 100
    }

    /// Every open position on the active account of every venue, largest
    /// first within a venue. Each carries its venue, so a row is never
    /// mistaken for the other exchange's.
    var openPositions: [StrategyPositionState] {
        Venue.allCases.flatMap { openPositions(on: $0) }
    }

    func openPositions(on venue: Venue) -> [StrategyPositionState] {
        ledger(for: venue).positions.values
            .filter { !$0.isFlat }
            .sorted { abs($0.exposure(mark: mark(for: $0.instId))) > abs($1.exposure(mark: mark(for: $1.instId))) }
    }

    /// Ledger against exchange, material differences only — on instruments
    /// the book holds something in. A position the book has never heard of
    /// is not a difference to reconcile; it is somebody else's holding, and
    /// `externalPositions` lists it as one.
    func reconciliationIssues(on venue: Venue) -> [LedgerReconciliation] {
        let books = books(for: venue)
        return ledger(for: venue)
            .reconcile(spotBalances: books.accountBalances, derivativePositions: books.exchangePositions)
            .filter { $0.isMaterial && !$0.isExternal }
    }

    /// Positions the exchange holds on instruments no strategy's book has a
    /// position in: opened by hand, by another program, or before this
    /// install existed. Shown as holdings — they are the account's price
    /// risk whoever opened them — and counted in exposure by the runner.
    func externalPositions(on venue: Venue) -> [ExchangePosition] {
        let held = Set(ledger(for: venue).positions.values.filter { !$0.isFlat }.map(\.instId))
        return books(for: venue).exchangePositions
            .filter { $0.quantity != 0 && !held.contains($0.instId) }
            .sorted { abs($0.notionalUsd ?? 0) > abs($1.notionalUsd ?? 0) }
    }

    /// Who placed an order the exchange holds: one of our strategies, named
    /// through its order tag, or somebody else.
    func orderSource(_ order: ExchangeOpenOrder) -> String {
        if let id = OrderTag.resolveStrategy(order.clOrdId, among: strategies.map(\.id)) {
            return strategy(id: id)?.name ?? id
        }
        return "外部"
    }

    /// The most recent fills across every strategy, newest first — on one
    /// venue, or across all of them.
    func recentFills(limit: Int, on venue: Venue? = nil) -> [StrategyFill] {
        let venues = venue.map { [$0] } ?? Venue.allCases
        return venues.flatMap { ledger(for: $0).fills.suffix(limit) }
            .sorted { $0.ts > $1.ts }
            .prefix(limit)
            .map { $0 }
    }

    /// The asset an instrument is exposure to, whatever family it is, on the
    /// venue it trades.
    static func underlying(_ instId: String, venue: Venue) -> String {
        // "BTC-USDT-SWAP", "BTC-USDT" and "BTC-USD-260926-80000-C" are all
        // BTC exposure. Grouped by base currency: an option settles against
        // the USD index while the watchlist tracks the USDT pair, and
        // splitting the two would hide a BTC option on the BTC panel. The
        // venue is part of the key so a ticker on one exchange never merges
        // with a coin of the same letters on another.
        "\(venue.rawValue):\(venue.currencies(of: instId).base)"
    }

    /// Set when a venue's engine should be trading and demonstrably is not.
    ///
    /// A process that is alive but has stopped doing its job is the failure
    /// mode that goes unnoticed: nothing errors, the panel keeps showing the
    /// last numbers it had, and the account simply stops being managed.
    func heartbeatWarning(for venue: Venue) -> String? {
        guard store.config.strategy.allocations(on: venue).contains(where: \.running),
              !store.config.strategy.emergencyStop,
              let silence = books(for: venue).heartbeatSilence,
              silence > StrategyRunner.heartbeatTimeout else { return nil }
        let minutes = Int(silence / 60)
        return "\(venue.displayName)交易循环已 \(minutes) 分钟没有完成一次轮询，仓位当前无人管理"
    }

    /// The reasons the engines are currently refusing new exposure, worst
    /// first. A silent loop outranks a tripped breaker: one is a decision, the
    /// other is a position nobody is managing.
    var engineNotices: [(kind: EngineNoticeKind, text: String)] {
        var notices: [(EngineNoticeKind, String)] = []
        for venue in Venue.allCases {
            if let heartbeat = heartbeatWarning(for: venue) { notices.append((.heartbeat, heartbeat)) }
        }
        if store.config.strategy.emergencyStop {
            notices.append((.emergencyStop, "急停已触发：所有策略停止，解除后才能重新开始交易。"))
        }
        for venue in Venue.allCases {
            let runner = runner(for: venue)
            if let over = runner.overCommitted { notices.append((.overCommitted, "\(venue.displayName)：" + over)) }
            if let tripped = runner.protectionTripped { notices.append((.protection, "\(venue.displayName)：" + tripped)) }
        }
        let portfolio = store.config.strategy
        for venue in portfolio.overAllocatedVenues {
            let allocated = portfolio.allocatedCapital(on: venue)
            let total = portfolio.totalCapital(for: venue)
            let multiple = allocated / max(total, 1)
            notices.append((.overAllocated,
                "\(venue.displayName)策略预算合计 \(PriceFormatter.money(allocated, decimals: 0)) 超出本金 "
                + "\(PriceFormatter.money(total, decimals: 0)) \(venue.quoteCurrency)：下单按各自预算定量，"
                + "全部满仓会下到本金的 \(PriceFormatter.decimals(multiple, 1)) 倍。改本金即可按比例缩回。"))
        }
        return notices
    }

    enum EngineNoticeKind { case heartbeat, emergencyStop, overCommitted, protection, overAllocated }
}
