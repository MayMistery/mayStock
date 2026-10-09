import Foundation

/// Where an instrument trades.
///
/// The venue decides three things nothing else may guess: the calendar its
/// bars follow (the kernel owns that, see `KernelCalendar`), the currency its
/// book settles in, and how an instrument id is spelled. OKX writes the
/// instrument family into the id — `BTC-USDT-SWAP` — and quotes everything in
/// USDT; Schwab names a stock by its ticker and quotes in dollars. Every
/// place that used to split an id on `-` and read the second piece as the
/// quote currency was assuming OKX, and would have read `AAPL` as a coin
/// quoted in USDT.
public enum Venue: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case okx
    case schwab

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .okx: return "OKX"
        case .schwab: return "嘉信"
        }
    }

    /// What the book on this venue settles in — budgets, P&L and equity are
    /// all denominated in it.
    public var quoteCurrency: String {
        switch self {
        case .okx: return "USDT"
        case .schwab: return "USD"
        }
    }

    /// What a **position** in `instId` settles in — the currency its P&L,
    /// margin and premium are paid in, which is not the same as the currency
    /// the instrument is quoted in.
    ///
    /// `quoteCurrency` answers "what does this venue's *book* run on"; this
    /// answers "what is *this instrument's* money", and a total that adds
    /// figures across instruments must ask the second question. The rule
    /// itself lives in the kernel (`Venue::settlement_currency`, with the
    /// measurement that justifies it) because the kernel is the side that
    /// sizes positions against the answer, and a rule spelled on both sides
    /// of the FFI is a rule that will eventually be spelled two ways.
    public func settlementCurrency(of instId: String) -> String {
        TradingKernel.settlementCurrency(venue: self, instId: instId)
    }

    /// The instrument types this venue trades.
    public var instrumentTypes: [InstrumentType] {
        switch self {
        case .okx: return [.spot, .swap, .option]
        case .schwab: return [.stock]
        }
    }

    public func trades(_ instType: InstrumentType) -> Bool {
        instrumentTypes.contains(instType)
    }

    /// The families this venue's account holds that the app reads — what a
    /// position on it can be, and so what the close ticket handles. Wider
    /// than `instrumentTypes`, what a strategy may trade: an option on
    /// Schwab is bought by hand and closed from the app, but no strategy
    /// trades one.
    public var accountFamilies: [InstrumentType] {
        switch self {
        case .okx: return [.spot, .swap, .option]
        case .schwab: return [.stock, .option]
        }
    }

    /// The spelling this venue's instruments are kept under, from however
    /// one arrived — typed in the watchlist, imported in a manifest. Upper
    /// case everywhere; on Schwab a share class takes the slash Schwab itself
    /// uses (`BRK/B`), whether it came as `BRK.B`, `BRK-B` or `brk/b`. Schwab
    /// answers `BRK.B` with an error and Yahoo serves only `BRK-B`
    /// (`schwabctl quotes` and Yahoo's chart endpoint, 2026-10-09), so one
    /// spelling is kept and each source is asked in its own
    /// (`YahooWire.yahooSymbol`).
    public func canonicalInstId(_ raw: String) -> String {
        let upper = raw.trimmingCharacters(in: .whitespaces).uppercased()
        switch self {
        case .okx: return upper
        case .schwab: return ShareClass(upper).map { "\($0.root)/\($0.share)" } ?? upper
        }
    }

    /// The instrument family an id names on this venue.
    ///
    /// OKX encodes it in the id itself, and this is the only place allowed to
    /// know how. The spelling `instId.hasSuffix("-SWAP")` used to be copied
    /// into a dozen call sites, which is fine right up until one of them needs
    /// to grow a case and eleven others quietly keep the old answer.
    public func instrumentType(of instId: String) -> InstrumentType {
        switch self {
        case .okx:
            if instId.hasSuffix("-" + InstrumentType.swap.rawValue) { return .swap }
            if optionKind(of: instId) != nil { return .option }
            return .spot
        case .schwab:
            // An OCC symbol is a contract; every other id is a share.
            return USOptionContract(instId) != nil ? .option : .stock
        }
    }

    /// The call/put leg an option id names: OKX spells a call
    /// `BTC-USD-260908-70000-C`, Schwab `MU    261120C01040000` (the OCC
    /// symbol, read by the kernel). Nil for any id that is not an option.
    public func optionKind(of instId: String) -> OptionKind? {
        guard self == .okx else { return USOptionContract(instId)?.kind }
        let parts = instId.split(separator: "-")
        guard parts.count == 5,
              parts[2].count == 6, parts[2].allSatisfy(\.isNumber),
              Double(parts[3]) != nil else { return nil }
        switch parts[4] {
        case "C": return .call
        case "P": return .put
        default: return nil
        }
    }

    /// What an option settles against: `BTC-USD-260908-70000-C` → `BTC-USD`
    /// on OKX, `MU    261120C01040000` → `MU` on Schwab.
    public func optionUnderlying(of instId: String) -> String? {
        guard self == .okx else { return USOptionContract(instId)?.underlying }
        guard optionKind(of: instId) != nil else { return nil }
        return instId.split(separator: "-").prefix(2).joined(separator: "-")
    }

    /// Where the live layer is handed this venue's account reading — nil for
    /// a venue whose account the layer reads itself (OKX's private socket).
    public var liveAccountTopic: String? {
        switch self {
        case .okx: return nil
        case .schwab: return SchwabVenue.accountTopic
        }
    }

    /// Where the live layer is handed this venue's working orders — nil for
    /// a venue whose orders the layer reads itself.
    public var liveOrdersTopic: String? {
        switch self {
        case .okx: return nil
        case .schwab: return SchwabVenue.ordersTopic
        }
    }

    /// "BTC-USDT-SWAP" → ("BTC", "USDT") on OKX; "AAPL" → ("AAPL", "USD") on
    /// Schwab, where the quote is the venue's currency rather than part of
    /// the id.
    public func currencies(of instId: String) -> (base: String, quote: String) {
        switch self {
        case .okx:
            let parts = instId.split(separator: "-").map(String.init)
            return (parts.first ?? instId, parts.count > 1 ? parts[1] : quoteCurrency)
        case .schwab:
            return (instId, quoteCurrency)
        }
    }

    /// The id that prices `base` in the venue's quote currency — what a
    /// balance in `base` is marked against.
    public func spotInstId(base: String) -> String {
        switch self {
        case .okx: return "\(base)-\(quoteCurrency)"
        case .schwab: return base
        }
    }

    /// The perpetual that shares an underlying with `instId`. Only OKX has
    /// perpetuals; on any other venue the id passes through unchanged so a
    /// caller asking for funding on a stock gets a name the venue will refuse
    /// rather than an invented one.
    public func perpetual(for instId: String) -> String {
        switch self {
        case .okx:
            return instrumentType(of: instId) == .swap
                ? instId : instId + "-" + InstrumentType.swap.rawValue
        case .schwab:
            return instId
        }
    }

    /// How a bar interval annualises on this venue — the kernel's calendar,
    /// asked through one market so the number cannot be derived twice.
    public func barsPerYear(bar: BarInterval) -> Double {
        KernelCalendar(market: StrategyMarket(
            instId: "", instType: instrumentTypes[0], bar: bar, venue: self)).barsPerYear
    }

    // MARK: Market data

    /// Whether the venue trades around the clock or in sessions. The kernel's
    /// calendar is the authority on *when*; this is the one Swift-side flag
    /// that decides how a day of prices is framed, and the vocabulary test
    /// checks it against the kernel's calendar for every venue.
    public var tradesContinuously: Bool {
        switch self {
        case .okx: return true
        case .schwab: return false
        }
    }

    /// The clock the venue's day runs on: where its daily bar opens, what
    /// "today" means for its book, which session a closed market still
    /// shows. OKX opens all three at 00:00 UTC+8 — its 1D bar, its App's day
    /// and the account's — and a US day is New York's, so "today" on one
    /// never means half of yesterday on the other.
    ///
    /// A rule, not a display: every time shown is written in
    /// `DisplayTime.zone`. A bar of a day or longer is named for this day
    /// (`ChartMath.labelZone`).
    public var dayZone: TimeZone {
        switch self {
        case .okx: return TimeZone(identifier: "Asia/Singapore")!
        case .schwab: return TimeZone(identifier: "America/New_York")!
        }
    }

    /// Whether the venue's public data carries an order book worth drawing.
    public var hasOrderBook: Bool {
        switch self {
        case .okx: return true
        case .schwab: return false
        }
    }

    /// The candle intervals the venue's data source serves. There is no
    /// four-hour bar on a six-and-a-half-hour session.
    public var supportedBars: [BarInterval] {
        switch self {
        case .okx: return BarInterval.allCases
        case .schwab: return BarInterval.allCases.filter { $0 != .h4 }
        }
    }

    /// Where the venue's prices come from, for the footer and the settings.
    public var marketDataSourceName: String {
        switch self {
        case .okx: return "OKX 公共行情"
        case .schwab: return "嘉信官方行情（未登录时 Yahoo Finance）"
        }
    }

    /// How this venue's files are named in the state directory. OKX keeps
    /// the bare names the app has always written — `ledger-demo.json` — so
    /// a book recorded before there was a second venue stays readable; every
    /// other venue is spelled into the name.
    public var stateFileInfix: String {
        self == .okx ? "" : "-" + rawValue
    }

    /// Whether the venue keeps a bill ledger the app reads: what a window
    /// realised, shown as the breakdown of the window's result. OKX does;
    /// Schwab's transactions are read for fills alone.
    public var publishesBills: Bool { self == .okx }

    /// The capital a fresh portfolio starts with on this venue, in its
    /// quote currency. Only a starting point for the settings page.
    public var defaultPortfolioCapital: Double {
        switch self {
        case .okx: return 1_000
        case .schwab: return 10_000
        }
    }

    /// The short name a watchlist row shows for an id: OKX pairs shed their
    /// quote (`BTC-USDT` → `BTC`) and mark perpetuals; a ticker is its own
    /// name.
    public func shortLabel(for instId: String) -> String {
        switch self {
        case .okx:
            let base = currencies(of: instId).base
            return instrumentType(of: instId) == .swap ? base + "⚡︎" : base
        case .schwab:
            return instId
        }
    }
}

/// A US share class — a root of one to five letters and a one-letter class —
/// however its separator is written: Schwab's slash, Yahoo's hyphen, the dot
/// people type. Nil for anything else, including a pair like `BTC-USD`.
struct ShareClass {
    let root: String
    let share: String

    init?(_ symbol: String) {
        let parts = symbol.split(omittingEmptySubsequences: false, whereSeparator: { "./-".contains($0) })
        guard parts.count == 2, (1...5).contains(parts[0].count), parts[1].count == 1,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isLetter } }) else { return nil }
        root = String(parts[0])
        share = String(parts[1])
    }
}

