import Foundation

/// One reading of an account: what it is worth, what it holds, when each was
/// true, and where it came from.
///
/// Every surface that shows an account — the panel, the overview, the
/// trading loop's equity and exposure — reads the venue's one current
/// reading rather than asking the exchange on a clock of its own. Equity and
/// positions carry their own stamps because they are not always read
/// together: a reading that refreshed one and not the other must not let the
/// stale half borrow the fresh half's age, which is how a five-minute-old
/// position table came to be labelled "20 秒前" (2026-10-08).
public struct AccountReading: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        /// The venue's account stream, valued at the mark as it streams.
        case stream
        /// The stream is down and the account is read through REST in its
        /// place, on the fallback's slower clock.
        case fallback
        /// A venue with no stream, read on a clock.
        case polled

        public var displayName: String {
            switch self {
            case .stream: return "实时推送"
            case .fallback: return "推送中断 · REST 兜底"
            case .polled: return "定时读取"
            }
        }
    }

    public let snapshot: AccountSnapshot
    /// When `snapshot`'s equity was true, on this machine's clock.
    public let equityAt: Date
    /// Every contract position the venue holds — perpetuals, options,
    /// futures, margin; nil when they could not be read, which is not the
    /// same as none. What the account's contract risk is measured from.
    public let positions: [ExchangePosition]?
    /// Holdings filed as positions without being contracts — shares. Listed
    /// beside the contracts on every screen, but valued through the
    /// balances, so the risk measure never counts them twice.
    public let shareHoldings: [ExchangePosition]
    public let positionsError: String?
    /// When the list of positions was last confirmed, on this machine's
    /// clock. Each position carries the time of its own mark (`markAt`).
    public let positionsAt: Date?
    public let source: Source

    public init(
        snapshot: AccountSnapshot, equityAt: Date, positions: [ExchangePosition]?,
        shareHoldings: [ExchangePosition] = [],
        positionsError: String? = nil, positionsAt: Date?, source: Source
    ) {
        self.snapshot = snapshot
        self.equityAt = equityAt
        self.positions = positions
        self.shareHoldings = shareHoldings
        self.positionsError = positionsError
        self.positionsAt = positionsAt
        self.source = source
    }

    /// Why there is no reading to give.
    public struct Unavailable: Error, CustomStringConvertible, Sendable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    /// Whether anything the account holds is priced by a market — a
    /// contract, a share, a coin other than `quoteCurrency` — and so moves
    /// between two readings with no trade or transfer. Positions that could
    /// not be read count as held: not knowing is a reason to look again
    /// sooner, not later.
    public func holdsPriced(quoteCurrency: String) -> Bool {
        (positions.map { !$0.isEmpty } ?? true) || !shareHoldings.isEmpty
            || snapshot.balances.contains { $0.ccy != quoteCurrency && $0.total != 0 }
    }

    /// How long a venue with no stream lets this reading stand before it
    /// reads the account again: as long as the figure can stay unchanged.
    /// Cash moves only with a trade or a transfer, and a minute is soon
    /// enough to see either. Anything priced moves with its market, and the
    /// venue's own app revalues it as it moves; ten seconds keeps such an
    /// account inside the fifteen a streamed one is allowed before it reads
    /// stale. Every reading is the venue's own valuation — nothing here
    /// re-values a holding between readings, which would be a second copy of
    /// the venue's rule, free to drift from it.
    public func pollInterval(quoteCurrency: String) -> TimeInterval {
        holdsPriced(quoteCurrency: quoteCurrency) ? Self.pricedPollInterval : Self.cashPollInterval
    }

    public static let pricedPollInterval: TimeInterval = 10
    public static let cashPollInterval: TimeInterval = 60

    /// Read the account one part after another — the snapshot, then the
    /// contracts, then the shares: `ExchangeVenue.accountReading`'s default.
    /// Not public, so nothing outside can step around a venue's own
    /// single-document read.
    static func piecewise(
        from venue: any ExchangeVenue, mode: TradingMode, source: Source
    ) async throws -> AccountReading {
        let snapshot = try await venue.accountSnapshot(mode: mode)
        let equityAt = Date()
        do {
            let positions = try await venue.allPositions(mode: mode)
            let shares = try await venue.shareHoldings(mode: mode)
            return AccountReading(
                snapshot: snapshot, equityAt: equityAt, positions: positions, shareHoldings: shares,
                positionsAt: Date(), source: source)
        } catch {
            return AccountReading(
                snapshot: snapshot, equityAt: equityAt, positions: nil,
                positionsError: String(describing: error), positionsAt: nil, source: source)
        }
    }
}

/// Money moved into or out of an account — the one shape both venues' are
/// kept in, so a period's result takes them out by one rule
/// (`AccountEquityCurve.change`).
public struct AccountTransfer: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        /// Moved in or out by the owner: left out of a period's result.
        case principal
        /// Earned and booked as a movement (OKX's auto earn): part of it.
        case income
        /// Not named by the venue's rule: left out like principal, and said.
        case unrecognised
    }

    public let id: String
    public let at: Date
    public let ccy: String
    /// Positive in, negative out.
    public let amount: Double
    public let kind: Kind
    /// The venue's own word for it (OKX `subType`, Schwab `type`).
    public let venueType: String?

    public init(id: String, at: Date, ccy: String, amount: Double, kind: Kind, venueType: String?) {
        self.id = id
        self.at = at
        self.ccy = ccy
        self.amount = amount
        self.kind = kind
        self.venueType = venueType
    }

    /// Whether a period's result leaves this out.
    public var isLeftOut: Bool { kind != .income }
}

/// A venue's transfers over a lookback, as last read.
public struct AccountTransferListing: Sendable, Equatable {
    public var items: [AccountTransfer]
    /// False when the listing stopped before the lookback's start.
    public var complete: Bool
    public var readAt: Date

    public init(items: [AccountTransfer], complete: Bool, readAt: Date) {
        self.items = items
        self.complete = complete
        self.readAt = readAt
    }
}
