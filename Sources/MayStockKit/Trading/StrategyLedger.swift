import Foundation
import Observation

// MARK: - What a fill did

/// What one fill did to the position it landed on. Side alone cannot say: for
/// a short book a sell *opens* and a buy *closes*, and a table labelled
/// 买入/卖出 reads exactly backwards from what the money did.
public enum PositionEffect: String, Codable, Sendable, CaseIterable {
    /// Started a position from flat.
    case open
    /// Grew the existing side.
    case add
    /// Reduced or fully closed the existing side.
    case close
    /// Closed the whole side and opened the opposite one in the same fill.
    case flip
}

// MARK: - What a fill's money is denominated in

/// One fill's price, fee and realised P&L, all three expressed in the venue's
/// quote currency.
///
/// The conversion is here and only here. A fill arrives in whatever the venue
/// stamps on it — a spot pair in its quote coin, a perpetual in the book's
/// currency, an option in the settlement coin per unit of underlying — and
/// every figure derived from it (a booked P&L, a 净益 column, a reconciliation
/// total) is only comparable across instruments once they are all in one
/// currency. Writing this arithmetic at each call site is how a screen ends up
/// adding an ETH premium to a USDT one, which is the mistake
/// `Venue.settlementCurrency` exists to make impossible.
///
/// Nil when a fill cannot be converted — it settles in a coin and no rate to
/// the book's currency is available — because there is no honest number to book
/// and a guess would be worse than the wait.
public struct FillMoney: Sendable, Equatable {
    /// Per unit of underlying, in quote currency.
    public let price: Double
    /// The fill's fee as a **cost** in quote currency: positive when charged,
    /// negative when the venue paid a maker rebate.
    ///
    /// The sign is carried, not flattened. OKX files a charge negative and a
    /// rebate positive — stated on `ExchangeFill.fee`, modelled in
    /// `OKXFeeSchedule` ("a genuine rebate stays negative"), and preserved on
    /// the exchange side of the reconciliation by `row.fees -= bill.fee`.
    /// Taking the magnitude here booked a rebate as if it were a charge, so
    /// the two sides of that reconciliation disagreed by twice the rebate and
    /// the book read low by the same amount.
    public let feeQuote: Double
    /// What the venue says this fill realised, in quote currency. Nil when it
    /// says nothing, or naught — an opener is stamped zero and realises no
    /// money, and a dash in the P&L column reads more honestly than "+0".
    public let realisedQuote: Double?

    /// What decides whether anything needs converting is whether the
    /// instrument **settles in its own base coin** — the kernel's settlement
    /// currency compared against the pair's base, not against the book's.
    ///
    /// Measured on the live account (2026-09-21): two expired ETH options
    /// settled with `pnl` of −0.0013 and −0.0444 and `ccy: ETH` — OKX stamps an
    /// option's realised P&L in the settlement coin, so a figure copied
    /// straight into a USDT column is out by the index, about 2,600×. An
    /// inverse swap (`BTC-USD-SWAP`) settles BTC the same way.
    ///
    /// Comparing against the book's currency instead looks equivalent and is
    /// not: `BTC-USDC` settles USDC, which differs from a USDT book but is not
    /// a coin — there is no index to convert it by, so every such fill would be
    /// refused and never booked at all. The two stablecoins are treated as the
    /// same money here, which is the approximation this app already makes
    /// everywhere; a base-coin settlement is the case that genuinely needs a
    /// rate, and it is the only one taken down that path.
    public init?(_ fill: ExchangeFill, venue: Venue, indexPrice: Double? = nil) {
        let (base, _) = venue.currencies(of: fill.instId)
        let settles = venue.settlementCurrency(of: fill.instId)
        // Cost, sign carried: a charge arrives negative, a rebate positive.
        let feeCost = -fill.fee

        guard settles == base else {
            // Settled in the quote leg — USDT, USDC, USD — which the book reads
            // as its own money. Price and P&L are already in it; only a spot
            // buy's fee arrives in the base coin, priced by the fill.
            price = fill.price
            feeQuote = fill.feeCcy == base ? feeCost * fill.price : feeCost
            realisedQuote = fill.pnl.flatMap(Self.nonZero)
            return
        }

        // Settled in a coin: the fee and the realised P&L are in that coin, and
        // converting needs its rate against the book's currency — the index the
        // exchange stamped on the fill, or the caller's current reading.
        guard let rate = fill.indexPrice ?? indexPrice, rate > 0 else { return nil }
        feeQuote = fill.feeCcy == settles ? feeCost * rate : feeCost
        realisedQuote = fill.pnl.flatMap(Self.nonZero).map { $0 * rate }
        // The *price* is a separate question from the money, and only an option
        // answers it differently: OKX quotes a premium in the settlement coin
        // per unit of underlying, and stamps its own dollar reading beside it.
        // An inverse swap settles in the coin too but is quoted in dollars
        // already — multiplying that by the index would be out by the index.
        if venue.instrumentType(of: fill.instId) == .option {
            price = fill.priceUsd.map { $0 > 0 ? $0 : fill.price * rate } ?? fill.price * rate
        } else {
            price = fill.price
        }
    }

    private static func nonZero(_ value: Double) -> Double? { value == 0 ? nil : value }
}

// MARK: - Records

public struct StrategyFill: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let strategyId: String
    public let instId: String
    /// Where the fill happened. Decides how `instId` is read and what
    /// currency `feeQuote` is in. Records written before the field existed
    /// are OKX's, the only venue there was.
    public let venue: Venue
    public let side: OrderSide
    public let price: Double
    /// Base units, always positive; `side` carries the direction.
    public let quantity: Double
    /// Fee as a cost in the quote currency — negative when the venue paid a
    /// maker rebate. See `FillMoney.feeQuote` for why the sign is carried.
    public let feeQuote: Double
    public let ts: Date
    public let clOrdId: String?
    public let mode: TradingMode
    /// Gross P&L this fill crystallised by closing (part of) a position, in
    /// quote currency. Nil when the fill closed nothing — an opener realises
    /// nothing, however profitable it later turns out to be.
    ///
    /// Stamped by the ledger from `StrategyPositionState.apply`, which is the
    /// only place the realisation rule lives; fills recorded before the field
    /// existed stay nil until a rebuild replays them.
    public var realisedQuote: Double?
    /// What this fill did to the position — opened, added, closed or flipped.
    /// Stamped alongside `realisedQuote` from the same `apply` call; nil only
    /// on records that predate the field and have not been replayed yet.
    public var positionEffect: PositionEffect?

    public init(
        id: String, strategyId: String, instId: String, side: OrderSide,
        price: Double, quantity: Double, feeQuote: Double,
        ts: Date, clOrdId: String?, mode: TradingMode,
        realisedQuote: Double? = nil, positionEffect: PositionEffect? = nil,
        venue: Venue = .okx
    ) {
        self.id = id
        self.strategyId = strategyId
        self.instId = instId
        self.venue = venue
        self.side = side
        self.price = price
        self.quantity = quantity
        self.feeQuote = feeQuote
        self.ts = ts
        self.clOrdId = clOrdId
        self.mode = mode
        self.realisedQuote = realisedQuote
        self.positionEffect = positionEffect
    }

    /// Convert an exchange fill, normalising price and fee into quote currency.
    ///
    /// OKX charges spot buy fees in the base currency and reports them
    /// negative. An option is quoted in its settlement coin per unit of
    /// underlying, and so is its fee, so both convert at the index the exchange
    /// stamped on the fill — or at `indexPrice`, the caller's current reading,
    /// when the fill carries none. Without either there is no honest number to
    /// book, so the conversion fails rather than guess; the caller leaves the
    /// fill unrecorded and tries again next tick.
    public init?(
        exchange fill: ExchangeFill, strategyId: String, mode: TradingMode, venue: Venue,
        indexPrice: Double? = nil
    ) {
        guard let money = FillMoney(fill, venue: venue, indexPrice: indexPrice) else { return nil }
        self.init(
            id: fill.id, strategyId: strategyId, instId: fill.instId, side: fill.side,
            price: money.price, quantity: abs(fill.size), feeQuote: money.feeQuote,
            ts: fill.ts, clOrdId: fill.clOrdId, mode: mode, venue: venue)
    }

    private enum CodingKeys: String, CodingKey {
        case id, strategyId, instId, venue, side, price, quantity, feeQuote, ts, clOrdId, mode
        case realisedQuote, positionEffect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        strategyId = try c.decode(String.self, forKey: .strategyId)
        instId = try c.decode(String.self, forKey: .instId)
        venue = try c.decodeIfPresent(Venue.self, forKey: .venue) ?? .okx
        side = try c.decode(OrderSide.self, forKey: .side)
        price = try c.decode(Double.self, forKey: .price)
        quantity = try c.decode(Double.self, forKey: .quantity)
        feeQuote = try c.decode(Double.self, forKey: .feeQuote)
        ts = try c.decode(Date.self, forKey: .ts)
        clOrdId = try c.decodeIfPresent(String.self, forKey: .clOrdId)
        mode = try c.decode(TradingMode.self, forKey: .mode)
        realisedQuote = try c.decodeIfPresent(Double.self, forKey: .realisedQuote)
        positionEffect = try c.decodeIfPresent(PositionEffect.self, forKey: .positionEffect)
    }

    /// Signed base quantity: positive for buys, negative for sells.
    public var signedQuantity: Double { quantity * side.sign }
    public var notional: Double { price * quantity }
    /// What this fill banked after its own fee, or nil for a fill that closed
    /// nothing. The fee is this fill's alone — the opener's fee was already
    /// shown against the opener.
    public var netRealisedQuote: Double? { realisedQuote.map { $0 - feeQuote } }

    /// This fill as the kernel's identity rule reads it.
    ///
    /// A ledger row stores one id, whatever the venue gave it: an ingested
    /// fill keeps its exchange trade id (the field the rule qualifies by
    /// instrument), a shadow or synthetic fill keeps the id it was made with.
    /// It goes in the record's `id` slot only — the kernel turns both a trade
    /// id and a synthesised id into the same `trade:inst|id` key, so claiming
    /// `tradeId` for a row that is not really a venue trade would be lying
    /// about the key's provenance for no change in the key itself.
    public var kernelRecord: KernelFillRecord {
        KernelFillRecord(id: id, instId: instId, ts: ts, side: side, leg: nil)
    }

    /// The action in position terms — 开/加/平/反手 crossed with 多/空 — which
    /// is what the fill *did*, where the raw side is only what was sent. Falls
    /// back to the side for records that have never been replayed.
    public var actionLabel: String {
        guard let effect = positionEffect else { return side.displayName }
        switch (effect, side) {
        case (.open, .buy): return "开多"
        case (.open, .sell): return "开空"
        case (.add, .buy): return "加多"
        case (.add, .sell): return "加空"
        case (.close, .buy): return "平空"
        case (.close, .sell): return "平多"
        case (.flip, .buy): return "反手多"
        case (.flip, .sell): return "反手空"
        }
    }
}

/// Running book for one strategy on one instrument, using average cost.
public struct StrategyPositionState: Codable, Sendable, Equatable, Identifiable {
    public var strategyId: String
    public var instId: String
    /// Where the position is held. Records written before the field existed
    /// are OKX's, the only venue there was.
    public var venue: Venue
    /// Signed: positive long, negative short, zero flat.
    public var quantity: Double
    public var averagePrice: Double
    public var realisedPnL: Double
    public var feesPaid: Double
    public var fillCount: Int
    /// When the position *currently* held was opened, or nil while flat.
    ///
    /// Scoped to the open position, not to the strategy's history, because
    /// every rule that reads it — the minimum hold, the time barrier — asks
    /// "how long has *this* trade been on". An earlier version set it on the
    /// first fill ever and never cleared it, which made every position look
    /// arbitrarily old.
    public var openedAt: Date?
    public var lastFillAt: Date?
    /// Funding settled on this position, signed: negative when we paid.
    ///
    /// Kept apart from `realisedPnL` so the two can be told apart on screen —
    /// a strategy losing money purely to funding is a different diagnosis from
    /// one losing it on entries — but it is real money and `netPnL` includes it.
    public var fundingPaid: Double?

    /// Base units per contract (`ctVal`). Swap sizes are counted in contracts,
    /// not coins — one BTC-USDT-SWAP contract is 0.01 BTC — so every P&L and
    /// exposure figure has to scale by it. Optional so ledgers written before
    /// this existed still decode; nil means "spot, one-for-one".
    public var contractSize: Double?

    /// Whether the multiplier below is a fact or a guess.
    ///
    /// Spot is one-for-one by definition; a swap's only source is the exchange.
    /// Nothing may book P&L off a guess — see `StrategyRunner.contractSize`.
    public var contractSizeIsKnown: Bool {
        if let contractSize, contractSize > 0 { return true }
        return venue.instrumentType(of: instId).impliedContractSize != nil
    }

    /// Contracts → coins. 1 for spot and for any position whose size the
    /// exchange already reports in base units.
    ///
    /// Still 1 for a swap we have never been told about, because arithmetic
    /// needs a number — which is exactly why `contractSizeIsKnown` exists and
    /// why the writers refuse to persist a fabricated one.
    public var multiplier: Double {
        if let contractSize, contractSize > 0 { return contractSize }
        return venue.instrumentType(of: instId).impliedContractSize ?? 1
    }

    /// Position size in coins rather than contracts, for display.
    public var baseQuantity: Double { quantity * multiplier }

    public var id: String { strategyId + "@" + instId }
    public var isFlat: Bool { abs(quantity) < 1e-12 }
    public var direction: TradeDirection? {
        isFlat ? nil : (quantity > 0 ? .long : .short)
    }

    /// The call/put leg when this position is an option, else nil.
    public var optionKind: OptionKind? { venue.optionKind(of: instId) }

    /// The market view the position expresses, which is what the kernel's
    /// `current` direction means. A long in spot or a perpetual is long; a
    /// long *put* is a bearish view and reads as short, a short put as long.
    public var signalDirection: TradeDirection? {
        guard let direction else { return nil }
        guard let optionKind else { return direction }
        let bullish = (optionKind == .call) == (direction == .long)
        return bullish ? .long : .short
    }

    /// Units of underlying, signed by `signalDirection` — the quantity the
    /// kernel reasons about. Zero when flat.
    public var kernelHeldBase: Double {
        guard let signalDirection else { return 0 }
        return abs(baseQuantity) * signalDirection.sign
    }

    private enum CodingKeys: String, CodingKey {
        case strategyId, instId, venue, quantity, averagePrice, realisedPnL, feesPaid
        case fillCount, lastFillAt, contractSize, fundingPaid
        // Written under the old name before it was scoped to the current
        // position, so ledgers already on disk keep decoding.
        case openedAt = "firstFillAt"
    }

    public init(strategyId: String, instId: String, venue: Venue = .okx) {
        self.strategyId = strategyId
        self.instId = instId
        self.venue = venue
        self.quantity = 0
        self.averagePrice = 0
        self.realisedPnL = 0
        self.feesPaid = 0
        self.fillCount = 0
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strategyId = try c.decode(String.self, forKey: .strategyId)
        instId = try c.decode(String.self, forKey: .instId)
        venue = try c.decodeIfPresent(Venue.self, forKey: .venue) ?? .okx
        quantity = try c.decode(Double.self, forKey: .quantity)
        averagePrice = try c.decode(Double.self, forKey: .averagePrice)
        realisedPnL = try c.decode(Double.self, forKey: .realisedPnL)
        feesPaid = try c.decode(Double.self, forKey: .feesPaid)
        fillCount = try c.decode(Int.self, forKey: .fillCount)
        openedAt = try c.decodeIfPresent(Date.self, forKey: .openedAt)
        lastFillAt = try c.decodeIfPresent(Date.self, forKey: .lastFillAt)
        contractSize = try c.decodeIfPresent(Double.self, forKey: .contractSize)
        fundingPaid = try c.decodeIfPresent(Double.self, forKey: .fundingPaid)
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

    /// Realised plus unrealised, net of fees and funding.
    public func netPnL(mark: Double?) -> Double {
        realisedPnL + unrealisedPnL(mark: mark) - feesPaid + (fundingPaid ?? 0)
    }

    /// Return on the capital allocated to this strategy.
    public func returnPct(mark: Double?, capital: Double) -> Double? {
        guard capital > 0 else { return nil }
        return netPnL(mark: mark) / capital * 100
    }

    /// Apply one fill using average-cost accounting, handling the case where a
    /// fill closes the position and opens the opposite side in one go.
    ///
    /// Returns what the fill did to the position and the gross P&L it
    /// crystallised (nil when it closed nothing). Returned rather than
    /// recomputed by callers so the rule exists exactly once; the ledger
    /// stamps both onto the stored fill.
    @discardableResult
    public mutating func apply(
        _ fill: StrategyFill
    ) -> (effect: PositionEffect, realisedQuote: Double?) {
        let delta = fill.signedQuantity
        defer {
            feesPaid += fill.feeQuote
            fillCount += 1
            lastFillAt = fill.ts
        }

        if isFlat {
            quantity = delta
            averagePrice = fill.price
            openedAt = fill.ts
            return (.open, nil)
        }
        if (quantity > 0) == (delta > 0) {
            // Adding to the same side: weighted-average the cost basis.
            let total = abs(quantity) + abs(delta)
            averagePrice = (averagePrice * abs(quantity) + fill.price * abs(delta)) / total
            quantity += delta
            return (.add, nil)
        }
        // Opposing fill: realise on the overlap, then flip if it overshoots.
        let closing = Swift.min(abs(quantity), abs(delta))
        let realised = (fill.price - averagePrice) * closing * multiplier * (quantity > 0 ? 1 : -1)
        realisedPnL += realised
        let remainder = abs(delta) - closing
        quantity += delta
        if remainder > 1e-12 {
            // Overshot into the opposite side: that is a new position, and its
            // clock starts here.
            averagePrice = fill.price
            openedAt = fill.ts
            return (.flip, realised)
        }
        if abs(quantity) < 1e-12 {
            quantity = 0
            averagePrice = 0
            openedAt = nil
        }
        return (.close, realised)
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

    /// Held on the exchange with no strategy claiming any of it: opened by
    /// hand, by another program, or before this book existed. Not a mismatch
    /// — there is nothing here for the book to be wrong about — but real
    /// exposure, so it is listed as a holding rather than raised as an alarm.
    public var isExternal: Bool { ledgerQuantity == 0 && exchangeQuantity != 0 }

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
    /// Oldest first, always. Every append comes from `record`, which is fed by
    /// `ingest` in timestamp order or by the runner as fills land, so this is
    /// append-ordered by construction — and callers rely on it: 「最近成交」
    /// takes `suffix(limit)` as the newest rows, which is only the newest rows
    /// if the array is chronological. Asserted in the tests rather than left
    /// as a comment nobody can check.
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

    /// The venue this book is kept for. Fills say where they happened on
    /// their own; this is what names the file and labels the page.
    public let venue: Venue

    public init(mode: TradingMode, venue: Venue = .okx) {
        self.mode = mode
        self.venue = venue
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

    /// One fill is a hundred rows a tick, and the rule crosses the FFI, so the
    /// index is kept rather than rebuilt: `record` adds to it, `replace`
    /// re-derives it from the book it was handed. Rebuilding it per fill would
    /// be a kernel round trip per row and a quadratic replay.
    private var identityIndex = KernelIdentities()

    /// Every execution already accounted for on this book, keyed the kernel's
    /// way, so a caller adopting fills the exchange executed on its own can
    /// tell which ones are genuinely new.
    ///
    /// The keys are the kernel's, not the exchange's raw ids, and that is what
    /// makes the answer independent of which build wrote the row. The exchange
    /// names one execution both `4294122652` (its trade counter) and
    /// `3931253135398440960` (its bill id); a book written before this app
    /// read bill ids carries only the first, and today's listing of the same
    /// fill carries both. Compared by name they are two fills; compared by
    /// overlap they are one, which is what they are.
    public var bookedIdentities: KernelIdentities { identityIndex }

    /// Funding settlements already booked, by the exchange's bill id.
    ///
    /// Persisted with the rest of the book, and that is not a detail. Fills are
    /// deduplicated against `bookedIdentities`, which is *derived* from the fills
    /// on disk and so survives a restart for free. This set had no such backing
    /// — it lived only in memory — while the exchange keeps serving the same
    /// bills for days. Every relaunch therefore re-booked every settlement still
    /// in the listing, and `fundingPaid` grew by a full history each time. The
    /// account showed BTC +36.37 and ETH -77.90 against real bills of +2.73 and
    /// -31.19: a carry cost inflated 13× and 2.5×, silently, with nothing
    /// erroring. Idempotency that does not outlive the process is not
    /// idempotency, it is a comment.
    public private(set) var recordedFundingIds: Set<String> = []

    /// Book a funding settlement against a strategy.
    ///
    /// Idempotent on the exchange's bill id, because this is called from a
    /// polling loop that will see the same settlement on every tick until it
    /// ages out of the listing.
    @discardableResult
    public func recordFunding(_ payment: FundingPayment, strategyId: String) -> Bool {
        guard !recordedFundingIds.contains(payment.id),
              var state = positions[strategyId] else { return false }
        recordedFundingIds.insert(payment.id)
        state.fundingPaid = (state.fundingPaid ?? 0) + payment.amount
        positions[strategyId] = state
        onChanged?()
        return true
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

    /// Book one fill against its strategy's position.
    ///
    /// The identity guard is here, per fill, and it is checked against the
    /// index *as it stands now* — not against a verdict computed earlier for a
    /// whole batch. That distinction is the whole guard: two records of one
    /// execution inside a single listing would both pass a batch verdict taken
    /// before either was booked, and the position would count the fill twice.
    /// A batch pre-filter may still run ahead of this (see `ingest`) to keep
    /// already-booked rows from logging, but it can only ever skip work — it
    /// cannot be what makes the booking safe.
    ///
    /// The cost is one kernel round trip per fill that is actually new, which
    /// is nearly always none: a listing the book has already seen is filtered
    /// out upstream and never reaches here.
    public func record(_ fill: StrategyFill) {
        guard !bookedIdentities.holds(fill.kernelRecord) else { return }
        var state = positions[fill.strategyId] ?? StrategyPositionState(
            strategyId: fill.strategyId, instId: fill.instId, venue: fill.venue)
        if state.instId != fill.instId {
            // A strategy holds one instrument at a time. A *flat* book may move
            // to a new one — an option strategy rolls from one expiry to the
            // next — and the position follows it. A book that still holds the
            // old instrument cannot absorb a fill on another without the
            // arithmetic becoming nonsense, so the fill is left unrecorded and
            // said so; it is retried on the next ingest, by which time the
            // closing fill it was ordered after has normally arrived.
            guard state.isFlat else {
                Log.warn("ledger: \(fill.strategyId) 仍持有 \(state.instId)，"
                         + "收到 \(fill.instId) 的成交 \(fill.id) 暂不入账，下轮重试")
                return
            }
            state.instId = fill.instId
            state.contractSize = nil
        }
        state.contractSize = contractSizes[fill.instId] ?? state.contractSize
        // Never book against a guessed multiplier.
        //
        // A position's *unrealised* P&L is recomputed from its state, so a
        // multiplier learned late still fixes it — which is why teaching the
        // ledger a contract size updates positions already on the book. The
        // realised stamp is not like that: `apply` scales it once, appends it
        // to a cumulative total, and nothing later can take it back. A BTC
        // option booked at 1 instead of 0.01 realises a hundred times its
        // true P&L, permanently, and that is exactly what a fresh ledger
        // reading the exchange's fill history did — it had never held the
        // contract, so nobody had told it what one is worth. So the fill
        // waits for the answer instead of being booked on a guess; the
        // listing is re-read every tick, and the caller teaches the size it
        // looked up.
        guard state.contractSizeIsKnown else {
            Log.warn("ledger: \(fill.instId) 的合约面值未知，成交 \(fill.id) 暂不入账，"
                     + "等交易所元数据到达后重试")
            return
        }
        var stamped = fill
        (stamped.positionEffect, stamped.realisedQuote) = state.apply(fill)
        fills.append(stamped)
        identityIndex.insert([stamped.kernelRecord])
        // The index is not pruned with the rows. It answers "has this
        // execution been booked", and the positions it protects are
        // cumulative, so dropping a key that aged out of the row cap would let
        // a fill still inside the exchange's window be replayed onto a
        // position that already counted it. The two are bounded differently on
        // purpose: rows are history and capped at `maxFills`, keys are the
        // double-counting guard. The guard is only as long-lived as the rows,
        // though — `replace` re-derives it from the book it loads, so a
        // restart starts with the keys of whatever the file still holds.
        if fills.count > Self.maxFills { fills.removeFirst(fills.count - Self.maxFills) }
        positions[fill.strategyId] = state
        onChanged?()
    }

    /// Attribute exchange fills to strategies and fold in anything new.
    /// Fills without a MayStock tag belong to somebody else and are skipped —
    /// they surface later as unattributed exposure in reconciliation.
    ///
    /// `indexPrices`, keyed by underlying (`BTC-USD`), converts option fills
    /// the exchange did not stamp with an index of their own. A fill that can
    /// be converted by neither is left for the next ingest and logged, not
    /// booked at a guess.
    ///
    /// `contractSizes`, keyed by instrument, is what one contract is worth in
    /// base units. Same rule, same reason: a derivative fill whose multiplier
    /// nobody has supplied is left for the next ingest rather than booked at
    /// 1 — see `record`.
    @discardableResult
    public func ingest(
        _ exchangeFills: [ExchangeFill], knownStrategyIds: [String], venue: Venue,
        indexPrices: [String: Double] = [:], contractSizes: [String: Double] = [:]
    ) -> Int {
        for (instId, size) in contractSizes { setContractSize(size, forInstId: instId) }
        // What is new, the tag, and the index price all resolve before a fill
        // is offered to the position — one batch identity call for the whole
        // listing rather than one per fill, and so that a fill already on the
        // book is dropped *before* anything is logged about it. A duplicate
        // that has nothing to say about its own conversion would otherwise
        // warn on every tick for as long as the exchange kept listing it.
        let candidates: [(fill: ExchangeFill, strategyId: String)] = exchangeFills
            .sorted(by: { $0.ts < $1.ts })
            .compactMap { fill in
                OrderTag.resolveStrategy(fill.clOrdId, among: knownStrategyIds)
                    .map { (fill, $0) }
            }
        let unbooked = bookedIdentities.unbooked(candidates.map(\.fill.kernelRecord))
        var added = 0
        for ((fill, strategyId), isNew) in zip(candidates, unbooked) where isNew {
            let index = venue.optionUnderlying(of: fill.instId).flatMap { indexPrices[$0] }
            guard let booked = StrategyFill(
                exchange: fill, strategyId: strategyId, mode: mode, venue: venue,
                indexPrice: index) else {
                Log.warn("ledger: 成交 \(fill.id)（\(fill.instId)）以 "
                         + "\(venue.settlementCurrency(of: fill.instId)) 结算，"
                         + "没有可用的汇率换算成 \(venue.quoteCurrency)，本轮未入账，下轮重试")
                continue
            }
            // `record` re-checks identity against the live index. The batch
            // verdict above only spared us the work and the log noise for rows
            // already on the book; it cannot stand in for the per-fill guard,
            // because two records of one execution in this same listing would
            // both have been called new by it.
            let before = fills.count
            record(booked)
            if fills.count > before { added += 1 }
        }
        return added
    }

    /// Forget one strategy's book — used when a strategy is removed from the
    /// portfolio. Its historical fills stay, so the audit trail is intact.
    public func clearPosition(strategyId: String) {
        positions[strategyId] = nil
        onChanged?()
    }

    public func replace(
        fills newFills: [StrategyFill],
        positions newPositions: [String: StrategyPositionState],
        fundingIds: Set<String> = []
    ) {
        fills = newFills
        positions = newPositions
        recordedFundingIds = fundingIds
        // Re-derived from the book just loaded, never carried over: an index
        // that survived a `replace` would describe a book this one replaced.
        identityIndex = KernelIdentities.of(newFills.map(\.kernelRecord))
        // A loaded ledger already knows its multipliers — the positions carry
        // them — but the lookup table starts empty, and until instrument
        // metadata arrived a swap fill would book P&L at multiplier 1. Learn
        // back what the file already says instead of waiting to be retaught.
        for state in newPositions.values {
            if let size = state.contractSize, size > 0 { contractSizes[state.instId] = size }
        }
        // Fills persisted before the stamps existed show up here without an
        // effect (every fill gets one, unlike the realised amount, which is
        // legitimately nil on openers); give them both by the same replay a
        // rebuild uses.
        if fills.contains(where: { $0.positionEffect == nil }), let replayed = replay() {
            restamp(from: replayed.stamps)
        }
    }

    /// Replay the stored fills chronologically through `apply` — the one place
    /// the accounting rule lives — yielding the rebuilt positions and each
    /// fill's stamps, aligned to `fills` by index.
    ///
    /// Stamps come back as an array rather than a dictionary keyed by fill id,
    /// because a fill id is not unique: OKX numbers trades *per instrument*, so
    /// a roll from one option contract to the next can hand two fills the same
    /// id, and the second would overwrite the first's stamps — relabelling a
    /// closing fill worth real money as an opener worth nothing. `restamp`
    /// walks the same array, so an index is exact and needs no rule at all.
    ///
    /// Nil when the history cannot be replayed honestly. `record` refuses to
    /// book a derivative fill at a guessed multiplier — a BTC option booked at
    /// 1 instead of 0.01 realises a hundred times its true P&L — and a replay
    /// that quietly did what `record` refuses would write exactly that number
    /// to disk on the next launch.
    private func replay() -> (
        positions: [String: StrategyPositionState],
        stamps: [(effect: PositionEffect, realisedQuote: Double?)?]
    )? {
        var rebuilt: [String: StrategyPositionState] = [:]
        var stamps = [(effect: PositionEffect, realisedQuote: Double?)?](
            repeating: nil, count: fills.count)
        // Chronological, but carrying each fill's place in the stored array so
        // the stamps can be handed back in that order.
        for index in fills.indices.sorted(by: { fills[$0].ts < fills[$1].ts }) {
            let fill = fills[index]
            var state = rebuilt[fill.strategyId] ?? StrategyPositionState(
                strategyId: fill.strategyId, instId: fill.instId, venue: fill.venue)
            // A strategy that rolled from one contract to the next has fills on
            // both. The position follows it from flat, exactly as `record`
            // moves it; without this the whole history is applied to the first
            // instrument ever traded, and priced by its multiplier.
            if state.instId != fill.instId {
                guard state.isFlat else {
                    Log.warn("ledger: \(fill.strategyId) 的历史里 \(state.instId) 未平就出现了 "
                             + "\(fill.instId) 的成交，无法重放，保持现有仓位")
                    return nil
                }
                state.instId = fill.instId
                state.contractSize = nil
            }
            state.contractSize = contractSizes[fill.instId] ?? state.contractSize
            guard state.contractSizeIsKnown else {
                Log.warn("ledger: \(fill.instId) 的合约面值未知，无法重放这段历史"
                         + "（按 1 计会把已实现盈亏放大到面值的倒数倍），保持现状")
                return nil
            }
            stamps[index] = state.apply(fill)
            rebuilt[fill.strategyId] = state
        }
        return (rebuilt, stamps)
    }

    private func restamp(from stamps: [(effect: PositionEffect, realisedQuote: Double?)?]) {
        guard stamps.count == fills.count else { return }
        for index in fills.indices {
            guard let stamp = stamps[index] else { continue }
            fills[index].positionEffect = stamp.effect
            fills[index].realisedQuote = stamp.realisedQuote
        }
    }

    /// Rebuild every position by replaying the stored fills — the recovery path
    /// when a position looks wrong.
    ///
    /// Funding is carried across rather than replayed: it is not derived from
    /// fills, it is settled money booked against `recordedFundingIds`, and
    /// those ids survive the rebuild. Dropping it here would have deleted a
    /// real cost while leaving the ids that stop it ever being booked again.
    ///
    /// A history the replay cannot price is left exactly as it is: a rebuild
    /// that cannot be done honestly is worse than no rebuild, because the
    /// numbers it writes look like a repair.
    @discardableResult
    public func rebuildPositions() -> Bool {
        guard let replayed = replay() else { return false }
        var rebuilt = replayed.positions
        // The replay also restamps each fill, so fills recorded before the
        // stamps existed pick them up on the same pass.
        restamp(from: replayed.stamps)
        for (key, funding) in positions.compactMapValues(\.fundingPaid) {
            rebuilt[key]?.fundingPaid = funding
        }
        positions = rebuilt
        onChanged?()
        return true
    }

    // MARK: Reconciliation

    /// Compare the book against the exchange, per instrument.
    ///
    /// `derivativePositions` is every per-instrument position the exchange
    /// reports — perpetuals and options alike; spot exposure is read from the
    /// coin balance of each traded pair.
    public func reconcile(
        spotBalances: [AccountBalance], derivativePositions: [ExchangePosition]
    ) -> [LedgerReconciliation] {
        var ledgerByInst: [String: Double] = [:]
        var venueByInst: [String: Venue] = [:]
        for state in positions.values where !state.isFlat {
            ledgerByInst[state.instId, default: 0] += state.quantity
            venueByInst[state.instId] = state.venue
        }

        var exchangeByInst: [String: Double] = [:]
        for position in derivativePositions {
            exchangeByInst[position.instId, default: 0] += position.quantity
        }
        // Anything held as a balance rather than a contract — spot coins,
        // shares — is read off the base-currency line of the account.
        for (instId, venue) in venueByInst where !venue.instrumentType(of: instId).isDerivative {
            let (base, _) = venue.currencies(of: instId)
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

}

// MARK: - Persistence

/// JSON-backed storage for a ledger, one file per venue and trading mode.
public struct StrategyLedgerStore: Sendable {
    public let fileURL: URL

    public init(directory: URL, mode: TradingMode, venue: Venue = .okx) {
        self.fileURL = directory.appendingPathComponent("ledger\(venue.stateFileInfix)-\(mode.rawValue).json")
    }

    private struct Payload: Codable {
        var fills: [StrategyFill]
        var positions: [String: StrategyPositionState]
        /// Bill ids of funding already booked. Sorted on the way out so the
        /// file does not churn between saves for no reason.
        var fundingIds: [String]?
    }

    public typealias Snapshot = (
        fills: [StrategyFill],
        positions: [String: StrategyPositionState],
        fundingIds: Set<String>)

    public func load() -> Snapshot {
        guard let data = try? Data(contentsOf: fileURL) else { return ([], [:], []) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return ([], [:], []) }
        return (payload.fills, payload.positions, Set(payload.fundingIds ?? []))
    }

    public func save(
        fills: [StrategyFill],
        positions: [String: StrategyPositionState],
        fundingIds: Set<String> = []
    ) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Payload(
            fills: fills, positions: positions, fundingIds: fundingIds.sorted()))
        try data.write(to: fileURL, options: .atomic)
    }
}
