import Foundation

// MARK: - The exchange's ledger

/// One line of the exchange's own ledger: a balance change it booked, with
/// what it says the change was.
public struct ExchangeBill: Sendable, Equatable, Identifiable {
    /// The exchange's bill id, which is what makes merging two listings safe.
    public let id: String
    public let ts: Date
    /// OKX's bill type: 1 transfer, 2 trade, 3 delivery, 5 liquidation,
    /// 6 margin transfer, 7 interest, 8 funding fee, 9 ADL…
    public let type: Int
    public let subType: Int?
    public let instId: String?
    public let ccy: String
    /// Profit the exchange attributes to the bill: a close's P&L, a funding
    /// settlement. Zero on everything else.
    public let pnl: Double
    /// Negative when charged.
    public let fee: Double
    /// Negative when charged.
    public let interest: Double
    public let balanceChange: Double
    public let positionBalanceChange: Double

    public init(
        id: String, ts: Date, type: Int, subType: Int?, instId: String?, ccy: String,
        pnl: Double, fee: Double, interest: Double, balanceChange: Double, positionBalanceChange: Double
    ) {
        self.id = id
        self.ts = ts
        self.type = type
        self.subType = subType
        self.instId = instId
        self.ccy = ccy
        self.pnl = pnl
        self.fee = fee
        self.interest = interest
        self.balanceChange = balanceChange
        self.positionBalanceChange = positionBalanceChange
    }

    /// What the bill made or cost the account.
    ///
    /// Summed from what the exchange labels as profit and as charges, not from
    /// the balance change: a transfer in, a margin top-up or a coin conversion
    /// moves the balance without making or losing anything, and carries no
    /// P&L, fee or interest — so it contributes nothing here without anyone
    /// having to keep a list of which types to skip.
    public var result: Double { pnl + fee + interest }

    public var isFunding: Bool { type == 8 }
}

/// A listing of bills, newest first, and whether it reached the end.
public struct ExchangeBillListing: Sendable, Equatable {
    public var bills: [ExchangeBill]
    /// True when the listing returned fewer bills than it was allowed to, so
    /// there is nothing older to fetch within the endpoint's reach.
    public var exhausted: Bool
    public var fetchedAt: Date

    public init(bills: [ExchangeBill], exhausted: Bool, fetchedAt: Date = Date()) {
        self.bills = bills
        self.exhausted = exhausted
        self.fetchedAt = fetchedAt
    }

    public var oldestBillAt: Date? { bills.map(\.ts).min() }
}

// MARK: - Realised P&L over a window

/// What the exchange's own bills say the account made or paid over a window.
///
/// This is the period figure the exchange can vouch for. Its API publishes no
/// period P&L and no equity history — the "today" figures on the OKX app are
/// computed on OKX's servers and never leave them — so a window's *realised*
/// result is summed here from the bills the exchange filed in it: closed
/// trades' P&L, fees, funding, interest, liquidation penalties. Unrealised
/// P&L is not a window figure at all; it is reported beside this, at the
/// current mark, from the positions the exchange holds.
public struct BilledPnL: Sendable, Equatable {
    public let window: EquityWindow
    public let anchor: Date
    /// P&L on bills that are not funding: closes, deliveries, liquidations.
    public let closedTradePnL: Double
    public let funding: Double
    public let fees: Double
    public let interest: Double
    public let billCount: Int
    /// False when the listing ran out inside the window, so the sum is only
    /// what the bills that were fetched add up to.
    public let coversWindow: Bool

    public init(
        window: EquityWindow, anchor: Date, closedTradePnL: Double, funding: Double,
        fees: Double, interest: Double, billCount: Int, coversWindow: Bool
    ) {
        self.window = window
        self.anchor = anchor
        self.closedTradePnL = closedTradePnL
        self.funding = funding
        self.fees = fees
        self.interest = interest
        self.billCount = billCount
        self.coversWindow = coversWindow
    }

    public var total: Double { closedTradePnL + funding + fees + interest }

    public static func over(
        _ window: EquityWindow, listing: ExchangeBillListing, now: Date = Date()
    ) -> BilledPnL {
        let anchor = window.anchor(now: now)
        var closed = 0.0, funding = 0.0, fees = 0.0, interest = 0.0, count = 0
        for bill in listing.bills where bill.ts >= anchor {
            count += 1
            if bill.isFunding { funding += bill.pnl } else { closed += bill.pnl }
            fees += bill.fee
            interest += bill.interest
        }
        // The window is covered when the listing has nothing older to give,
        // or reaches back past the anchor.
        let covers = listing.exhausted || (listing.oldestBillAt.map { $0 <= anchor } ?? false)
        return BilledPnL(
            window: window, anchor: anchor, closedTradePnL: closed, funding: funding,
            fees: fees, interest: interest, billCount: count, coversWindow: covers)
    }
}
