import Foundation

/// The account as the kernel's live layer values it, right now.
///
/// One document for every screen. Positions and balances come from OKX's
/// read-only private socket (pushed every two seconds and on every event), and
/// each position is valued at the mark of its instrument the moment that mark
/// streams — by the same contract-terms rule the close ticket prices a close
/// with — so the floating profit, the equity built on it and the notional move
/// with the price the way the exchange's own app does, not once per poll.
///
/// It replaces three readings that each kept their own clock: the trading
/// loop's equity sample (every 60 s), the account refresh behind the panel and
/// the overview (every 300 s), and the checkup page's socket. On the live
/// account (2026-10-08, a 21.5 ETH long) those clocks alone put the panel's
/// floating profit $52 off the phone on average over ten minutes, and up to
/// $173 — see `docs/KERNEL.md` §1.0.2.
///
/// Every `…Ms` is on the venue's clock; `date(ms:)` puts one on this
/// machine's, by the offset the kernel measured.
public struct LiveAccount: Decodable, Sendable, Equatable {
    /// `live` or `demo`.
    public let mode: String
    /// `okx.private` (the socket), `cli` (the fallback), or `none` — nothing
    /// read, which is not the same as nothing held.
    public let source: String
    public let note: String?
    /// The socket has been down long enough that the app should read the
    /// account through the CLI and hand it in.
    public let fallbackNeeded: Bool
    /// When positions were last read; nil until they have been.
    public let positionsMs: Int64?
    /// Past this age the list of positions is too old to be the account's
    /// reading and the app reads it over REST instead: the private socket's
    /// grace before the CLI fallback starts, plus one fallback read.
    public let positionsStaleAfterMs: Double
    public let equity: Equity?
    public let balances: [Balance]
    public let positions: [Holding]
    public let transfers: Transfers
    public let orders: Orders
    public let clock: LiveSnapshot.Clock?
    /// The feeds the account is read through.
    public let feeds: [LiveSnapshot.Feed]
    public let events: [LiveSnapshot.Event]

    public struct Equity: Decodable, Sendable, Equatable {
        /// Dollars, now: cash and margin as last pushed, plus every
        /// position's floating profit at the mark just streamed.
        public let usd: Double
        /// The venue's own total as last pushed (`totalEq`).
        public let pushedUsd: Double
        public let pushedMs: Int64
        /// The oldest mark the floating part was taken at; nil when no
        /// position was valued at a streamed mark.
        public let markedMs: Int64?
        /// Past these ages `markedMs` and `pushedMs` read stale: the marks'
        /// stream, and whatever renews the push — the socket, or the CLI
        /// fallback while that is the source.
        public let markedStaleAfterMs: Double
        public let pushedStaleAfterMs: Double?
        /// Currencies whose floating profit stands as last pushed.
        public let unmarked: [String]
    }

    /// One currency of the trading account, valued now.
    public struct Balance: Decodable, Sendable, Equatable {
        public let ccy: String
        /// Cash plus margin plus floating profit (`eq`).
        public let equity: Double
        public let equityUsd: Double?
        public let available: Double?

        public var accountBalance: AccountBalance {
            AccountBalance(ccy: ccy, available: available ?? 0, total: equity, valuationUsd: equityUsd)
        }
    }

    public struct Mark: Decodable, Sendable, Equatable {
        public let price: Double
        public let ms: Int64?
        /// `okx.mark-price` (the stream) or `position` (the venue's push).
        public let source: String
        /// The stale age of whatever renews the mark; nil for a document
        /// read on the app's own clock.
        public let staleAfterMs: Double?
    }

    /// One position, as the account holds it. Also the shape of every OKX
    /// position document the kernel reads (`KernelAccount.positions`), so a
    /// REST read and the stream map through one function.
    public struct Holding: Decodable, Sendable, Equatable {
        public let key: String
        public let instId: String
        public let instType: String
        public let posSide: String
        public let marginMode: String?
        /// Signed: short legs negative.
        public let contracts: Double
        public let averagePrice: Double?
        /// The mark the figures below were taken at.
        public let mark: Mark?
        /// In `settlementCurrency`, at `mark`.
        public let unrealisedPnl: Double?
        /// The venue's return on the position, a fraction (`uplRatio`).
        public let unrealisedRatio: Double?
        public let notionalUsd: Double?
        /// Valued at the streamed mark rather than the venue's last push.
        public let remarked: Bool
        /// Why the venue's pushed figures stand, when they do and the stream
        /// had something newer to offer.
        public let note: String?
        public let pushedUnrealisedPnl: Double?
        public let leverage: Double?
        public let liquidationPrice: Double?
        public let margin: Double?
        public let maintenanceMargin: Double?
        /// The venue's health ratio (`mgnRatio`): 1.0 is liquidation.
        public let marginRatio: Double?
        public let fundingFee: Double?
        public let settlementCurrency: String?
        public let usdRate: Double?
        public let updatedMs: Int64?
    }

    public struct Transfers: Decodable, Sendable, Equatable {
        /// Every transfer bill of the trading account over the last week,
        /// newest first: money moved in (positive) or out (negative), each
        /// with what it is to a period's result.
        public let items: [Transfer]
        /// False when the listing stopped before the week's start.
        public let complete: Bool
        public let readMs: Int64?
        public let error: String?
        public let staleAfterMs: Double
    }

    /// Every order working on the account, read whole and again the moment
    /// an order push says something changed.
    public struct Orders: Decodable, Sendable, Equatable {
        /// Nil until the listing has been read — not the same as none armed.
        let items: [WorkingOrderRow]?
        public let unavailable: [String]
        public let readMs: Int64?
        public let error: String?
        public let staleAfterMs: Double

        /// Whether the listing has been read at all.
        public var wasRead: Bool { items != nil }

        /// The orders as the rest of the app knows them; nil until read.
        public var listing: OpenOrderListing? {
            items.map { OpenOrderListing(orders: $0.compactMap(\.order), unavailable: unavailable) }
        }
    }

    public struct Transfer: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let ms: Int64
        public let ccy: String
        public let amount: Double
        public let subType: String?
        /// The kernel's reading of `subType` (`trade::reads::transfer_kind`).
        public let kind: Kind

        public enum Kind: String, Decodable, Sendable, Equatable {
            /// Moved in or out by the owner: left out of a period's result.
            case principal
            /// Earned, and booked as a transfer (auto earn): part of it.
            case income
            /// Not named by the rule: left out like principal, and said.
            case unrecognised
        }

        /// Whether a period's result leaves this out.
        public var isLeftOut: Bool { kind != .income }
    }

    /// The transfers in the shape every venue's are kept in; nil until read.
    public var transferListing: AccountTransferListing? {
        guard let readMs = transfers.readMs else { return nil }
        let items = transfers.items.map { transfer in
            AccountTransfer(
                id: transfer.id, at: date(ms: transfer.ms), ccy: transfer.ccy, amount: transfer.amount,
                kind: AccountTransfer.Kind(rawValue: transfer.kind.rawValue) ?? .unrecognised,
                venueType: transfer.subType)
        }
        return AccountTransferListing(items: items, complete: transfers.complete, readAt: date(ms: readMs))
    }

    /// Positions were actually read — the one state in which "flat" may be
    /// said.
    public var wasRead: Bool { source != "none" && positionsMs != nil }

    /// When the equity is as of, and the age past which that reads stale:
    /// the oldest mark its floating part was taken at, aged by the marks'
    /// stream — unless the account push under it has itself gone stale, in
    /// which case the push's own time, aged by whatever renews the push, so
    /// a live mark cannot make an account whose cash and positions stopped
    /// arriving look current. Both ages are the kernel's (`Renewal`); a push
    /// it cannot age reads stale at once.
    public func equityAsOf(now: Date = Date()) -> (ms: Int64, staleAfterMs: Double)? {
        guard let equity else { return nil }
        let pushStale = equity.pushedStaleAfterMs ?? 0
        let pushAge = now.timeIntervalSince(date(ms: equity.pushedMs)) * 1000
        if let marked = equity.markedMs, pushAge <= pushStale {
            return (marked, equity.markedStaleAfterMs)
        }
        return (equity.pushedMs, pushStale)
    }

    /// A venue time on this machine's clock.
    public func date(ms: Int64) -> Date {
        LiveAccount.date(ms: ms, offsetMs: clock?.offsetMs)
    }

    public static func date(ms: Int64, offsetMs: Double?) -> Date {
        Date(timeIntervalSince1970: (Double(ms) + (offsetMs ?? 0)) / 1000)
    }

    /// The account as a reading the rest of the app understands: the
    /// equity in dollars (`totalEq`, valued now) and every currency line.
    public var snapshot: AccountSnapshot? {
        guard let equity else { return nil }
        return AccountSnapshot(
            balances: balances.map(\.accountBalance), totalEquity: equity.usd,
            equityCurrency: AccountSnapshot.usdCode)
    }

    /// Every position, valued now.
    public var exchangePositions: [ExchangePosition] {
        positions.map { $0.exchangePosition(offsetMs: clock?.offsetMs) }
    }
}

extension LiveAccount.Holding {
    /// The app's position, from the kernel's. The one mapping, for the stream
    /// and for a REST read alike.
    public func exchangePosition(offsetMs: Double?) -> ExchangePosition {
        ExchangePosition(
            instId: instId,
            posSide: PositionSide(rawValue: posSide) ?? .net,
            quantity: contracts,
            averagePrice: averagePrice ?? 0,
            markPrice: mark?.price,
            unrealisedPnL: unrealisedPnl ?? 0,
            leverage: leverage,
            liquidationPrice: liquidationPrice,
            notionalUsd: notionalUsd,
            instType: instType,
            margin: margin,
            maintenanceMargin: maintenanceMargin,
            marginRatio: marginRatio,
            settlementCurrency: settlementCurrency,
            usdRate: usdRate,
            marginMode: marginMode.flatMap(MarginMode.init(rawValue:)),
            unrealisedRatio: unrealisedRatio,
            markAt: mark?.ms.map { LiveAccount.date(ms: $0, offsetMs: offsetMs) },
            isValuedLive: remarked,
            valuationNote: note)
    }
}

// MARK: - The feed

/// The live account, kept current for the whole app.
///
/// It asks the kernel for the account document a few times a second — a lock
/// and nothing else when the account has not moved — and hands every new one
/// to `onChange`. Two duties come with being the account's one reader: the
/// kernel's account events (a socket lost, a fallback taken, terms that would
/// not load) go to the engine log once each, and while the private socket is
/// down the account is read through the `okx` CLI and handed to the kernel,
/// so the figures keep coming — from a slower source, said as such.
@Observable
@MainActor
public final class LiveAccountFeed {
    /// The latest document; nil until the first.
    public private(set) var account: LiveAccount?
    /// The last CLI read that failed, while the fallback is running.
    public private(set) var fallbackError: String?
    /// Every new document, for the books that show it.
    @ObservationIgnored public var onChange: ((LiveAccount) -> Void)?

    /// How often the document is asked for. Marks stream every 200 ms while
    /// they move; a quarter second is as current as a screen needs, and an
    /// unchanged document costs a lock.
    public static let pollInterval: TimeInterval = 0.25
    /// While the account socket is down, the CLI is read this often — the
    /// kernel's interval, the one it ages those readings by.
    public static let fallbackInterval = LiveKernel.cliFallbackInterval

    @ObservationIgnored private let kernel: LiveKernel
    @ObservationIgnored private let venue: () -> (any ExchangeVenue)?
    @ObservationIgnored private let mode: () -> TradingMode?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var fallback: Task<Void, Never>?
    @ObservationIgnored private var seq: UInt64 = 0
    @ObservationIgnored private var loggedEventId: UInt64 = 0

    public init(kernel: LiveKernel, venue: @escaping () -> (any ExchangeVenue)?, mode: @escaping () -> TradingMode?) {
        self.kernel = kernel
        self.venue = venue
        self.mode = mode
    }

    public func start() {
        pump?.cancel()
        let interval = UInt64(Self.pollInterval * 1_000_000_000)
        pump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pull()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    public func stop() {
        pump?.cancel()
        pump = nil
        fallback?.cancel()
        fallback = nil
    }

    /// Take the document if it changed. Exposed so tests can step it.
    @discardableResult
    public func pull() -> Bool {
        guard let (next, json) = kernel.account(since: seq) else { return false }
        seq = next
        do {
            let decoded = try JSONDecoder().decode(LiveAccount.self, from: json)
            account = decoded
            log(decoded.events)
            followFallback(needed: decoded.fallbackNeeded)
            onChange?(decoded)
            return true
        } catch {
            // The kernel and the app disagree about the document's shape — a
            // build defect, not a market condition. Logged, never skipped
            // silently; the last good document stays.
            Log.warn("account: 实时账户文档无法解码：\(error)")
            return false
        }
    }

    /// The kernel's event lines go to the engine log once each, so a
    /// degraded reading can be reconstructed afterwards.
    private func log(_ events: [LiveSnapshot.Event]) {
        for event in events where event.id > loggedEventId {
            Log.warn("live: \(event.message)")
            loggedEventId = event.id
        }
    }

    private func followFallback(needed: Bool) {
        if needed, fallback == nil {
            Log.warn("account: 账户推送不可用，改由 okx CLI 每 \(Int(Self.fallbackInterval)) 秒读取一次")
            let interval = UInt64(Self.fallbackInterval * 1_000_000_000)
            fallback = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await self?.readThroughCLI()
                    try? await Task.sleep(nanoseconds: interval)
                }
            }
        } else if !needed, let task = fallback {
            task.cancel()
            fallback = nil
            fallbackError = nil
            Log.warn("account: 账户推送恢复，停止 CLI 读取")
        }
    }

    private func readThroughCLI() async {
        guard let venue = venue(), let mode = mode() else { return }
        do {
            let documents = try await venue.accountDocuments(mode: mode)
            try kernel.ingest(topic: "cli.positions", payload: documents.positions)
            try kernel.ingest(topic: "cli.account", payload: documents.balance)
            fallbackError = nil
            pull()
        } catch {
            let message = (error as? TradeError)?.description ?? String(describing: error)
            fallbackError = message
            Log.warn("account: CLI 读取账户失败：\(message)")
        }
    }
}
