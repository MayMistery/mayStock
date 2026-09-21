import Foundation
import CMayStockKernel

// MARK: - Fill identity and merge

/// What a fill did to the leg it names, as the kernel reads it off the venue's
/// own record. Coarser than `PositionEffect` on purpose: telling an opener
/// from an add needs a position book, and a fill read straight off the venue
/// has none.
public enum KernelLegEffect: String, Decodable, Sendable {
    case increase, decrease

    /// Crossed with the leg, this is the 开/平 half of a Chinese action label.
    public var verb: String { self == .increase ? "开" : "平" }
}

/// Which of the two books a merged row came from.
public enum KernelFillSource: String, Decodable, Sendable {
    case ledger, venue
}

/// One execution as one book recorded it — the shape the kernel's identity
/// rule reads. Deliberately not `StrategyFill` or `ExchangeFill`: those carry
/// prices, fees and currencies the rule has no use for, and shipping them
/// across the FFI to have them handed back would be pure cost.
public struct KernelFillRecord: Encodable, Sendable, Equatable {
    public let id: String
    public let instId: String
    public let tradeId: String?
    public let billId: String?
    public let tsMs: Int64
    public let side: String?
    public let leg: String?

    public init(
        id: String, instId: String, tradeId: String? = nil, billId: String? = nil,
        ts: Date, side: OrderSide? = nil, leg: PositionSide? = nil
    ) {
        self.id = id
        self.instId = instId
        self.tradeId = tradeId
        self.billId = billId
        self.tsMs = Int64((ts.timeIntervalSince1970 * 1000).rounded())
        self.side = side?.rawValue
        self.leg = leg?.rawValue
    }
}

/// One surviving row of the union, pointing back at the record it came from.
public struct KernelMergedFill: Decodable, Sendable, Equatable {
    public let source: KernelFillSource
    /// Index into whichever book `source` names, as it was passed in.
    public let index: Int
    public let id: String
    public let legEffect: KernelLegEffect?
}

public struct KernelFillMerge: Decodable, Sendable, Equatable {
    /// Newest first.
    public let rows: [KernelMergedFill]
    /// Venue rows the ledger already had. Zero on an account that has been
    /// trading is the symptom that attribution is failing, so it is a number
    /// worth showing rather than a detail of the merge.
    public let matched: Int

    public init(rows: [KernelMergedFill], matched: Int) {
        self.rows = rows
        self.matched = matched
    }
}

// MARK: - The row a page shows

/// One line of 「最近成交」, from whichever book knows about it.
///
/// A row can come from either side and the two know different things about
/// the same execution: the ledger knows which strategy it belongs to and what
/// it realised; the venue knows the price, the size, the fee and what the
/// exchange says it realised — but only the ledger knows the strategy. When
/// both have it the ledger's copy wins, which is what the kernel's merge
/// decides; when only the venue has it, the row says so rather than
/// attributing it to a strategy that never placed it.
public struct FillRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let ts: Date
    public let venue: Venue
    public let instId: String
    public let side: OrderSide
    public let price: Double
    public let quantity: Double
    /// Fee as a positive cost, in the instrument's quote currency where the
    /// source could put it there.
    public let feeQuote: Double
    /// The strategy this fill belongs to, or nil for one this app did not
    /// place — a hand trade, another program, or a fill from before the book
    /// existed. Nil is shown as 外部, never guessed at.
    public let strategyId: String?
    /// 开/加/平/反手 crossed with 多/空, where the source could tell. The
    /// ledger's `PositionEffect` is the better answer and is used when it is
    /// there; the venue's own record only supports grew/shrank.
    public let action: String
    /// What this fill banked, in the book's quote currency, or nil when
    /// nothing about it is known to have realised anything.
    public let realisedQuote: Double?
    /// True when the row came from the venue's listing rather than the book.
    public let isExternal: Bool

    public init(
        id: String, ts: Date, venue: Venue, instId: String, side: OrderSide,
        price: Double, quantity: Double, feeQuote: Double, strategyId: String?,
        action: String, realisedQuote: Double?, isExternal: Bool
    ) {
        self.id = id
        self.ts = ts
        self.venue = venue
        self.instId = instId
        self.side = side
        self.price = price
        self.quantity = quantity
        self.feeQuote = feeQuote
        self.strategyId = strategyId
        self.action = action
        self.realisedQuote = realisedQuote
        self.isExternal = isExternal
    }

    /// Net of this fill's own fee, the way the ledger reports a realised
    /// figure. The venue's `fillPnl` is gross of nothing — OKX charges the fee
    /// separately — so the fee comes off here for both sources, which is the
    /// one subtraction that makes the two comparable.
    public var netRealisedQuote: Double? { realisedQuote.map { $0 - feeQuote } }
}

extension TradingKernel {
    /// Every key each fill record carries, strongest first — one key set per
    /// record, in the order given.
    ///
    /// Swift asks rather than spelling the keys itself. An OKX trade id is
    /// only an identity once qualified by its instrument (an option's is a
    /// per-instrument counter: the two live option fills are numbered 32 and
    /// 50 on different contracts), and a rule written on both sides of the FFI
    /// is a rule that will eventually be written two different ways.
    public static func fillKeys(_ records: [KernelFillRecord]) throws -> [[String]] {
        guard !records.isEmpty else { return [] }
        let json = try callReturningString { error in
            ms_fill_keys(try? encodeJSON(records), error)
        }
        return try JSONDecoder().decode([[String]].self, from: Data(json.utf8))
    }

    /// Union the app's ledger with the venue's own fill history, newest first.
    ///
    /// Neither book is complete: the venue knows every execution but only for
    /// a rolling window (OKX returned 2.98 days), and the ledger keeps its own
    /// forever but only ever saw the fills it could attribute. The union is
    /// what 「最近成交」 shows; `matched` says how much of the venue's window
    /// the ledger had actually booked.
    public static func mergeFills(
        ledger: [KernelFillRecord], venue: [KernelFillRecord]
    ) throws -> KernelFillMerge {
        guard !ledger.isEmpty || !venue.isEmpty else {
            return KernelFillMerge(rows: [], matched: 0)
        }
        let request = FillMergeRequest(ledger: ledger, venue: venue)
        let json = try callReturningString { error in
            ms_fill_merge(try? encodeJSON(request), error)
        }
        return try JSONDecoder().decode(KernelFillMerge.self, from: Data(json.utf8))
    }

    private struct FillMergeRequest: Encodable {
        let ledger: [KernelFillRecord]
        let venue: [KernelFillRecord]
    }

    /// What a position in `instId` settles in — the currency its P&L, margin
    /// and premium are paid in, which on OKX is not the currency the book runs
    /// on for an inverse swap or an option.
    ///
    /// Asked of the kernel because a total that adds figures across
    /// instruments is only as honest as this answer, and the kernel is the
    /// side that sizes positions against it.
    public static func settlementCurrency(venue: Venue, instId: String) -> String {
        (try? callReturningString { error in
            ms_settlement_currency(venue.rawValue, instId, error)
        }) ?? venue.quoteCurrency
    }
}

// MARK: - Building the rows

extension FillRow {
    /// A row from the book: the strategy is known, the effect is known, and
    /// the realised figure is the ledger's own arithmetic.
    public init(_ fill: StrategyFill) {
        self.init(
            id: fill.id, ts: fill.ts, venue: fill.venue, instId: fill.instId,
            side: fill.side, price: fill.price, quantity: fill.quantity,
            feeQuote: fill.feeQuote, strategyId: fill.strategyId,
            action: fill.actionLabel, realisedQuote: fill.realisedQuote,
            isExternal: false)
    }

    /// A row from the venue's listing: an execution this app did not book.
    ///
    /// Its 操作 comes from the kernel's `legEffect` — grew or shrank the leg
    /// the side names — and the label is 开/平 rather than the ledger's finer
    /// 开/加/平/反手 because that is exactly the granularity the venue's own
    /// record carries: OKX files an opener and an add under one sub-type and
    /// words it 开多/开空, a closer as 平多/平空. Calling an add 加多 here
    /// would be this app inventing a distinction the fill cannot support.
    ///
    /// 多/空 comes from the *leg*, never from the side: a sell that closes a
    /// long is 平多, and reading the side there would print 平空 — the
    /// exchange's own word for the opposite trade. This is the same reason the
    /// ledger keeps a `PositionEffect` at all.
    ///
    /// Price, fee and realised P&L all come through `FillMoney`, the one place
    /// a fill's money is converted into quote currency. An option fill arrives
    /// in its settlement coin — the two live ones are priced in ETH with the
    /// venue's own dollar reading alongside — and putting that figure in the
    /// same column as a USDT perpetual's would be adding two currencies
    /// together, which is what the whole settlement-currency rule forbids.
    ///
    /// Nil when the money cannot be converted: an option fill with no index
    /// price is *left out* rather than shown at a guessed rate. Its 净益 would
    /// be the only thing wrong with it, but a row is one thing, and half a row
    /// is not honest either.
    public init?(_ fill: ExchangeFill, venue: Venue, legEffect: KernelLegEffect?) {
        guard let money = FillMoney(fill, venue: venue) else { return nil }
        let action = legEffect.map { effect in
            effect.verb + (fill.posSide == .short ? "空" : "多")
        } ?? fill.side.displayName
        self.init(
            id: fill.id, ts: fill.ts, venue: venue, instId: fill.instId,
            side: fill.side, price: money.price, quantity: abs(fill.size),
            feeQuote: money.feeQuote, strategyId: nil,
            action: action,
            // `FillMoney` has already turned an opener's stamped-zero into nil
            // and converted a coin figure into quote currency, so this is
            // simply "what the venue says this fill banked", or nothing.
            realisedQuote: money.realisedQuote,
            isExternal: true)
    }
}

extension TradingKernel {
    /// The ledger's fills unioned with the venue's own listing, newest first —
    /// what 「最近成交」 shows.
    ///
    /// Neither book is sufficient alone, and the union is decided by the
    /// kernel rather than by a `Set` here: the two books name the same
    /// execution by different fields, and which of two records is *the same
    /// fill* is a rule, not a lookup. The ledger's copy wins wherever both
    /// have it — it is the side that attributed the fill and computed what it
    /// realised — so a row this app placed keeps its strategy name and its
    /// 开/平 label, and only genuinely foreign executions come back as 外部.
    public static func fillRows(
        ledger: [StrategyFill], venue: [ExchangeFill], on venueName: Venue
    ) -> [FillRow] {
        let merged = (try? mergeFills(
            ledger: ledger.map(\.kernelRecord),
            venue: venue.map(\.kernelRecord))) ?? KernelFillMerge(rows: [], matched: 0)
        var rows: [FillRow] = []
        rows.reserveCapacity(merged.rows.count)
        for row in merged.rows {
            switch row.source {
            case .ledger:
                rows.append(FillRow(ledger[row.index]))
            case .venue:
                if let converted = FillRow(venue[row.index], venue: venueName, legEffect: row.legEffect) {
                    rows.append(converted)
                } else {
                    // An option fill the venue neither stamped an index on nor
                    // the caller could price. Dropping it is the honest choice —
                    // a guessed rate would put a fabricated number in the P&L
                    // column — but a row that vanishes without a word is how a
                    // screen starts lying, so it is said out loud.
                    Log.warn("fills: \(venue[row.index].instId) 的成交 \(venue[row.index].id) "
                             + "没有可用的指数价，最近成交里不显示")
                }
            }
        }
        return rows
    }
}

/// The executions a book already holds, keyed the kernel's way.
///
/// Not a `Set<String>` of identities. A record carries *several* names — the
/// exchange stamps both a trade counter and a bill id on the same execution —
/// and two records of one fill are the same execution when **any** name they
/// both carry agrees. A set of single identities answers a different and wrong
/// question: whether this build has already booked it *under the same name*,
/// which turns false the moment either side starts reading a field it did not
/// read before. That is exactly the failure this exists to prevent — a
/// re-listing of a week of fills the ledger had already booked, counted twice.
///
/// The kernel is asked in one batch per listing, never one row at a time.
public struct KernelIdentities: Sendable {
    private var keys: Set<String>

    public init() { keys = [] }

    /// Index the given records' keys.
    public static func of(_ records: [KernelFillRecord]) -> KernelIdentities {
        KernelIdentities(keys: Self.keySets(records).flatMap { $0 })
    }

    /// For each record, whether this book has **not** seen it.
    ///
    /// When the rule cannot be asked, every row reads as already seen — the
    /// direction that loses a fill rather than double-counting one. A row the
    /// rule refused is retried on the next tick; a doubled position never
    /// un-doubles, so the conservative answer is the safe one.
    public func unbooked(_ records: [KernelFillRecord]) -> [Bool] {
        Self.keySets(records).map { set in !set.contains { keys.contains($0) } }
    }

    /// Whether this book has seen one execution.
    public func holds(_ record: KernelFillRecord) -> Bool {
        !(unbooked([record]).first ?? false)
    }

    /// Index records the book is about to keep.
    public mutating func insert(_ records: [KernelFillRecord]) {
        keys.formUnion(Self.keySets(records).flatMap { $0 })
    }

    /// One kernel round trip for the whole batch; a kernel failure is an empty
    /// key set, which the callers above read conservatively.
    private static func keySets(_ records: [KernelFillRecord]) -> [[String]] {
        guard !records.isEmpty,
              let sets = try? TradingKernel.fillKeys(records) else { return [] }
        return sets
    }

    private init(keys: [String]) { self.keys = Set(keys) }
}
