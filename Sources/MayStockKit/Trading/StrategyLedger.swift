import Foundation
import Observation

// MARK: - Records

public struct StrategyFill: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let strategyId: String
    public let instId: String
    public let side: OrderSide
    public let price: Double
    /// Base units, always positive; `side` carries the direction.
    public let quantity: Double
    /// Fee as a positive cost in the quote currency.
    public let feeQuote: Double
    public let ts: Date
    public let clOrdId: String?
    public let mode: TradingMode

    public init(
        id: String, strategyId: String, instId: String, side: OrderSide,
        price: Double, quantity: Double, feeQuote: Double,
        ts: Date, clOrdId: String?, mode: TradingMode
    ) {
        self.id = id
        self.strategyId = strategyId
        self.instId = instId
        self.side = side
        self.price = price
        self.quantity = quantity
        self.feeQuote = feeQuote
        self.ts = ts
        self.clOrdId = clOrdId
        self.mode = mode
    }

    /// Convert an exchange fill, normalising the fee into quote currency.
    /// OKX charges spot buy fees in the base currency and reports them negative.
    public init(exchange fill: ExchangeFill, strategyId: String, mode: TradingMode) {
        let (base, _) = StrategyLedger.currencies(of: fill.instId)
        let feeMagnitude = abs(fill.fee)
        let inQuote = fill.feeCcy == base ? feeMagnitude * fill.price : feeMagnitude
        self.init(
            id: fill.id, strategyId: strategyId, instId: fill.instId, side: fill.side,
            price: fill.price, quantity: abs(fill.size), feeQuote: inQuote,
            ts: fill.ts, clOrdId: fill.clOrdId, mode: mode)
    }

    /// Signed base quantity: positive for buys, negative for sells.
    public var signedQuantity: Double { quantity * side.sign }
    public var notional: Double { price * quantity }
}

/// Running book for one strategy on one instrument, using average cost.
public struct StrategyPositionState: Codable, Sendable, Equatable, Identifiable {
    public var strategyId: String
    public var instId: String
    /// Signed: positive long, negative short, zero flat.
    public var quantity: Double
    public var averagePrice: Double
    public var realisedPnL: Double
    public var feesPaid: Double
    public var fillCount: Int
    public var firstFillAt: Date?
    public var lastFillAt: Date?
    /// Base units per contract (`ctVal`). Swap sizes are counted in contracts,
    /// not coins — one BTC-USDT-SWAP contract is 0.01 BTC — so every P&L and
    /// exposure figure has to scale by it. Optional so ledgers written before
    /// this existed still decode; nil means "spot, one-for-one".
    public var contractSize: Double?

    /// Contracts → coins. 1 for spot and for any position whose size the
    /// exchange already reports in base units.
    public var multiplier: Double {
        guard let contractSize, contractSize > 0 else { return 1 }
        return contractSize
    }

    /// Position size in coins rather than contracts, for display.
    public var baseQuantity: Double { quantity * multiplier }

    public var id: String { strategyId + "@" + instId }
    public var isFlat: Bool { abs(quantity) < 1e-12 }
    public var direction: TradeDirection? {
        isFlat ? nil : (quantity > 0 ? .long : .short)
    }

    public init(strategyId: String, instId: String) {
        self.strategyId = strategyId
        self.instId = instId
        self.quantity = 0
        self.averagePrice = 0
        self.realisedPnL = 0
        self.feesPaid = 0
        self.fillCount = 0
    }

    public func unrealisedPnL(mark: Double?) -> Double {
        guard let mark, !isFlat else { return 0 }
        return (mark - averagePrice) * quantity * multiplier
    }

    /// Absolute exposure in quote currency at the given mark.
    public func exposure(mark: Double?) -> Double {
        let price = mark ?? averagePrice
        return abs(quantity) * price * multiplier
    }

    /// Realised plus unrealised, net of fees already paid.
    public func netPnL(mark: Double?) -> Double {
        realisedPnL + unrealisedPnL(mark: mark) - feesPaid
    }

    /// Return on the capital allocated to this strategy.
    public func returnPct(mark: Double?, capital: Double) -> Double? {
        guard capital > 0 else { return nil }
        return netPnL(mark: mark) / capital * 100
    }

    /// Apply one fill using average-cost accounting, handling the case where a
    /// fill closes the position and opens the opposite side in one go.
    public mutating func apply(_ fill: StrategyFill) {
        let delta = fill.signedQuantity
        defer {
            feesPaid += fill.feeQuote
            fillCount += 1
            if firstFillAt == nil { firstFillAt = fill.ts }
            lastFillAt = fill.ts
        }

        if isFlat {
            quantity = delta
            averagePrice = fill.price
            return
        }
        if (quantity > 0) == (delta > 0) {
            // Adding to the same side: weighted-average the cost basis.
            let total = abs(quantity) + abs(delta)
            averagePrice = (averagePrice * abs(quantity) + fill.price * abs(delta)) / total
            quantity += delta
            return
        }
        // Opposing fill: realise on the overlap, then flip if it overshoots.
        let closing = Swift.min(abs(quantity), abs(delta))
        realisedPnL += (fill.price - averagePrice) * closing * multiplier * (quantity > 0 ? 1 : -1)
        let remainder = abs(delta) - closing
        quantity += delta
        if remainder > 1e-12 {
            averagePrice = fill.price
        } else if abs(quantity) < 1e-12 {
            quantity = 0
            averagePrice = 0
        }
    }
}

/// Ledger position versus what the exchange actually holds.
public struct LedgerReconciliation: Sendable, Equatable, Identifiable {
    public let instId: String
    public let ledgerQuantity: Double
    public let exchangeQuantity: Double

    public var id: String { instId }
    /// Holdings the ledger cannot explain: manual orders, other bots, or coins
    /// that were already there. Shown, never silently absorbed.
    public var unattributed: Double { exchangeQuantity - ledgerQuantity }

    public var isMaterial: Bool {
        let scale = Swift.max(abs(exchangeQuantity), abs(ledgerQuantity))
        guard scale > 0 else { return false }
        return abs(unattributed) / scale > 0.01 && abs(unattributed) > 1e-8
    }
}

// MARK: - Ledger

/// Per-strategy book of record, rebuilt from exchange fills.
///
/// The exchange knows one balance; this knows which strategy earned which part
/// of it. Every fill is attributed through the `clOrdId` tag written by
/// `OrderTag`, so the book survives restarts and can be rebuilt from scratch by
/// replaying `okx spot fills`.
///
/// Demo and live keep separate ledgers — mixing simulated fills into live P&L
/// would make both numbers meaningless.
@Observable
@MainActor
public final class StrategyLedger {
    public private(set) var fills: [StrategyFill] = []
    public private(set) var positions: [String: StrategyPositionState] = [:]
    /// Base units per contract, per instrument, learned from exchange metadata.
    private var contractSizes: [String: Double] = [:]
    public let mode: TradingMode

    /// Called whenever the book changes, so the app can persist it.
    public var onChanged: (() -> Void)?

    /// Cap on retained fills; positions are cumulative so old rows are only
    /// history, not state.
    public static let maxFills = 5_000

    public init(mode: TradingMode) {
        self.mode = mode
    }

    // MARK: Queries

    public func position(for strategyId: String) -> StrategyPositionState? {
        positions[strategyId]
    }

    public func fills(for strategyId: String, limit: Int = 200) -> [StrategyFill] {
        fills.filter { $0.strategyId == strategyId }.suffix(limit).reversed()
    }

    public var activePositions: [StrategyPositionState] {
        positions.values.filter { !$0.isFlat }.sorted { $0.instId < $1.instId }
    }

    /// Ledger exposure per instrument, for reconciliation and the panel strip.
    public func quantity(forInstId instId: String) -> Double {
        positions.values.filter { $0.instId == instId }.reduce(0) { $0 + $1.quantity }
    }

    // MARK: Mutation

    /// Teach the ledger what one contract of `instId` is worth in coins.
    ///
    /// Called from the runner once instrument metadata is known. It updates
    /// positions already on the book, so a ledger loaded from disk before this
    /// field existed starts reporting correct P&L on the next tick rather than
    /// needing to be rebuilt.
    public func setContractSize(_ size: Double, forInstId instId: String) {
        guard size > 0 else { return }
        contractSizes[instId] = size
        var changed = false
        for (key, var state) in positions where state.instId == instId {
            if state.contractSize != size {
                state.contractSize = size
                positions[key] = state
                changed = true
            }
        }
        if changed { onChanged?() }
    }

    public func record(_ fill: StrategyFill) {
        guard !fills.contains(where: { $0.id == fill.id }) else { return }
        fills.append(fill)
        if fills.count > Self.maxFills { fills.removeFirst(fills.count - Self.maxFills) }
        var state = positions[fill.strategyId] ?? StrategyPositionState(
            strategyId: fill.strategyId, instId: fill.instId)
        state.contractSize = contractSizes[fill.instId] ?? state.contractSize
        state.apply(fill)
        positions[fill.strategyId] = state
        onChanged?()
    }

    /// Attribute exchange fills to strategies and fold in anything new.
    /// Fills without a MayStock tag belong to somebody else and are skipped —
    /// they surface later as unattributed exposure in reconciliation.
    @discardableResult
    public func ingest(_ exchangeFills: [ExchangeFill], knownStrategyIds: [String]) -> Int {
        let existing = Set(fills.map(\.id))
        var added = 0
        for fill in exchangeFills.sorted(by: { $0.ts < $1.ts }) {
            guard !existing.contains(fill.id),
                  let strategyId = OrderTag.resolveStrategy(fill.clOrdId, among: knownStrategyIds)
            else { continue }
            record(StrategyFill(exchange: fill, strategyId: strategyId, mode: mode))
            added += 1
        }
        return added
    }

    /// Forget one strategy's book — used when a strategy is removed from the
    /// portfolio. Its historical fills stay, so the audit trail is intact.
    public func clearPosition(strategyId: String) {
        positions[strategyId] = nil
        onChanged?()
    }

    public func replace(fills newFills: [StrategyFill], positions newPositions: [String: StrategyPositionState]) {
        fills = newFills
        positions = newPositions
    }

    /// Rebuild every position by replaying the stored fills — the recovery path
    /// when a position looks wrong.
    public func rebuildPositions() {
        var rebuilt: [String: StrategyPositionState] = [:]
        for fill in fills.sorted(by: { $0.ts < $1.ts }) {
            var state = rebuilt[fill.strategyId] ?? StrategyPositionState(
                strategyId: fill.strategyId, instId: fill.instId)
            state.contractSize = contractSizes[fill.instId] ?? state.contractSize
            state.apply(fill)
            rebuilt[fill.strategyId] = state
        }
        positions = rebuilt
        onChanged?()
    }

    // MARK: Reconciliation

    /// Compare the book against the exchange, per instrument.
    public func reconcile(
        spotBalances: [AccountBalance], swapPositions: [ExchangePosition]
    ) -> [LedgerReconciliation] {
        var ledgerByInst: [String: Double] = [:]
        for state in positions.values where !state.isFlat {
            ledgerByInst[state.instId, default: 0] += state.quantity
        }

        var exchangeByInst: [String: Double] = [:]
        for position in swapPositions {
            exchangeByInst[position.instId, default: 0] += position.quantity
        }
        // Spot exposure is the base-currency balance of each traded pair.
        for instId in ledgerByInst.keys where !instId.hasSuffix("-SWAP") {
            let (base, _) = Self.currencies(of: instId)
            if let balance = spotBalances.first(where: { $0.ccy == base }) {
                exchangeByInst[instId] = balance.total
            }
        }

        let instruments = Set(ledgerByInst.keys).union(exchangeByInst.keys)
        return instruments.sorted().map { instId in
            LedgerReconciliation(
                instId: instId,
                ledgerQuantity: ledgerByInst[instId] ?? 0,
                exchangeQuantity: exchangeByInst[instId] ?? 0)
        }
    }

    /// "BTC-USDT-SWAP" → ("BTC", "USDT")
    public nonisolated static func currencies(of instId: String) -> (base: String, quote: String) {
        let parts = instId.split(separator: "-").map(String.init)
        return (parts.first ?? instId, parts.count > 1 ? parts[1] : "USDT")
    }
}

// MARK: - Persistence

/// JSON-backed storage for a ledger, one file per trading mode.
public struct StrategyLedgerStore: Sendable {
    public let fileURL: URL

    public init(directory: URL, mode: TradingMode) {
        self.fileURL = directory.appendingPathComponent("ledger-\(mode.rawValue).json")
    }

    private struct Payload: Codable {
        var fills: [StrategyFill]
        var positions: [String: StrategyPositionState]
    }

    public func load() -> (fills: [StrategyFill], positions: [String: StrategyPositionState]) {
        guard let data = try? Data(contentsOf: fileURL) else { return ([], [:]) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return ([], [:]) }
        return (payload.fills, payload.positions)
    }

    public func save(fills: [StrategyFill], positions: [String: StrategyPositionState]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Payload(fills: fills, positions: positions))
        try data.write(to: fileURL, options: .atomic)
    }
}
