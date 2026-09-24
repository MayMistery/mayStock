import Foundation

// MARK: - What is being closed

/// A holding someone asked to close or protect, by hand.
///
/// Names the holding rather than carrying it. Whatever screen the button sat
/// on showed a reading that may be seconds or minutes old — a checkup
/// snapshot, a ledger row, a balance — and a close sized from it is a close
/// sized from the past. The ticket reads the holding from the exchange itself
/// when it opens and again just before anything is sent.
public struct CloseTicketRequest: Sendable, Hashable, Identifiable {
    public enum Holding: Sendable, Hashable {
        /// A position on `instId` — a perpetual, an option, shares. `isLong`
        /// picks the leg: a long/short account can hold both on one
        /// instrument, and closing the wrong one opens exposure instead.
        case position(isLong: Bool)
        /// A coin held outright, sold into its spot market `instId`.
        case coin(String)

        /// "多头持仓", "空头持仓", "ETH 余额".
        public var description: String {
            switch self {
            case .position(let isLong): return isLong ? "多头持仓" : "空头持仓"
            case .coin(let coin): return "\(coin) 余额"
            }
        }
    }

    public let venue: Venue
    public let mode: TradingMode
    /// The market the closing order trades on.
    public let instId: String
    /// The family the exchange files the holding under. Nil for one this app
    /// does not trade — a delivery future, a margin loan — which the ticket
    /// still opens, to say so rather than to hide the button.
    public let instType: InstrumentType?
    /// How the exchange spelled the family, for saying which one it was.
    public let filedAs: String
    public let holding: Holding

    public var id: String { "\(venue.rawValue)|\(mode.rawValue)|\(instId)|\(holding)" }

    public init(
        venue: Venue, mode: TradingMode, instId: String,
        instType: InstrumentType?, filedAs: String, holding: Holding
    ) {
        self.venue = venue
        self.mode = mode
        self.instId = instId
        self.instType = instType
        self.filedAs = filedAs
        self.holding = holding
    }

    /// A position the exchange reported.
    public static func position(
        _ position: ExchangePosition, venue: Venue, mode: TradingMode
    ) -> CloseTicketRequest {
        CloseTicketRequest(
            venue: venue, mode: mode, instId: position.instId,
            instType: venue.family(ofPositionFiledAs: position.instType),
            filedAs: position.instType, holding: .position(isLong: position.quantity > 0))
    }

    /// A holding known by its id and direction: a strategy's book entry, the
    /// checkup's perpetual. The family comes from the id here, which is safe
    /// for the families those can hold — the runner only opens perpetuals,
    /// options, spot and shares, and the checkup follows perpetuals — and the
    /// exchange's own filing replaces it once the ticket reads the position.
    public static func held(
        instId: String, isLong: Bool, venue: Venue, mode: TradingMode
    ) -> CloseTicketRequest {
        let family = venue.instrumentType(of: instId)
        if family == .spot, let coin = CloseTicketRequest.coin(
            venue.currencies(of: instId).base, venue: venue, mode: mode) {
            return coin
        }
        return CloseTicketRequest(
            venue: venue, mode: mode, instId: instId, instType: family,
            filedAs: family.rawValue, holding: .position(isLong: isLong))
    }

    /// A coin balance, sold into its USDT market. Nil for the quote coin
    /// itself, which has nothing to be sold into.
    public static func coin(_ coin: String, venue: Venue, mode: TradingMode) -> CloseTicketRequest? {
        guard venue == .okx, let market = SettlementFunding.spotMarket(for: coin) else { return nil }
        return CloseTicketRequest(
            venue: venue, mode: mode, instId: market, instType: .spot,
            filedAs: InstrumentType.spot.rawValue, holding: .coin(coin.uppercased()))
    }
}

extension Venue {
    /// The family a position belongs to, from the exchange's own filing of it.
    ///
    /// Never from the id: `instrumentType(of:)` reads a delivery future such
    /// as `BTC-USD-250926` as spot, and an order sent to the spot book to
    /// close a future is an order for something else.
    public func family(ofPositionFiledAs instType: String) -> InstrumentType? {
        switch self {
        case .okx:
            switch instType.uppercased() {
            case InstrumentType.swap.rawValue: return .swap
            case InstrumentType.option.rawValue: return .option
            case InstrumentType.spot.rawValue: return .spot
            default: return nil
            }
        case .schwab:
            return SchwabAPI.equityAssetTypes.contains(instType.uppercased()) ? .stock : nil
        }
    }
}
