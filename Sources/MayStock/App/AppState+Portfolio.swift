import Foundation
import MayStockKit

/// Portfolio arithmetic every surface shares. One definition of "this
/// strategy's return", so the panel, the overview and the studio can never
/// disagree about it.
extension AppState {
    /// Latest known price for an instrument: the runner's poll, else a live
    /// watchlist session.
    func mark(for instId: String) -> Double? {
        runner.mark(for: instId) ?? hub.session(for: instId)?.ticker?.last
    }

    func netPnL(for strategyId: String) -> Double {
        guard let position = ledger.position(for: strategyId) else { return 0 }
        return position.netPnL(mark: mark(for: position.instId))
    }

    func returnPct(for strategyId: String) -> Double? {
        guard let allocation = store.config.strategy.allocation(for: strategyId),
              allocation.capital > 0,
              let position = ledger.position(for: strategyId),
              position.fillCount > 0 else { return nil }
        return position.returnPct(mark: mark(for: position.instId), capital: allocation.capital)
    }

    var portfolioNetPnL: Double {
        store.config.strategy.allocations.reduce(0) { $0 + netPnL(for: $1.strategyId) }
    }

    var portfolioReturnPct: Double? {
        let allocated = store.config.strategy.allocatedCapital
        guard allocated > 0 else { return nil }
        return portfolioNetPnL / allocated * 100
    }

    /// Every open position on the active account, largest first.
    var openPositions: [StrategyPositionState] {
        ledger.positions.values
            .filter { !$0.isFlat }
            .sorted { abs($0.exposure(mark: mark(for: $0.instId))) > abs($1.exposure(mark: mark(for: $1.instId))) }
    }

    /// Ledger against exchange, material differences only.
    var reconciliationIssues: [LedgerReconciliation] {
        ledger.reconcile(spotBalances: accountBalances, swapPositions: exchangePositions)
            .filter(\.isMaterial)
    }

    /// The most recent fills across every strategy on the active account.
    func recentFills(limit: Int) -> [StrategyFill] {
        Array(ledger.fills.suffix(limit).reversed())
    }

    /// "BTC-USDT-SWAP" and "BTC-USDT" are both BTC against USDT.
    static func underlying(_ instId: String) -> String {
        let (base, quote) = StrategyLedger.currencies(of: instId)
        return "\(base)-\(quote)"
    }

    /// The reasons the engine is currently refusing new exposure, worst first.
    /// A silent loop outranks a tripped breaker: one is a decision, the other is
    /// a position nobody is managing.
    var engineNotices: [(kind: EngineNoticeKind, text: String)] {
        var notices: [(EngineNoticeKind, String)] = []
        if let heartbeat = heartbeatWarning { notices.append((.heartbeat, heartbeat)) }
        if store.config.strategy.emergencyStop {
            notices.append((.emergencyStop, "急停已触发：所有策略停止，解除后才能重新开始交易。"))
        }
        if let over = runner.overCommitted { notices.append((.overCommitted, over)) }
        if let tripped = runner.protectionTripped { notices.append((.protection, tripped)) }
        if store.config.strategy.isOverAllocated {
            let portfolio = store.config.strategy
            let multiple = portfolio.allocatedCapital / max(portfolio.totalCapital, 1)
            notices.append((.overAllocated,
                "策略预算合计 \(PriceFormatter.money(portfolio.allocatedCapital, decimals: 0)) 超出本金 "
                + "\(PriceFormatter.money(portfolio.totalCapital, decimals: 0))：下单按各自预算定量，"
                + "全部满仓会下到本金的 \(PriceFormatter.decimals(multiple, 1)) 倍。改本金即可按比例缩回。"))
        }
        return notices
    }

    enum EngineNoticeKind { case heartbeat, emergencyStop, overCommitted, protection, overAllocated }
}
