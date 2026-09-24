import Foundation

/// The live layer's snapshot, as the kernel publishes it.
///
/// Every number carries the venue's own timestamp (`…Ms`, epoch
/// milliseconds on the venue's clock), so the screen can say how old it is
/// rather than when it was fetched. `clock` is this machine's measured offset
/// from the venues' clock; `age(of:now:)` applies it.
///
/// Decoded as a whole, so a field the kernel stops sending (or renames) fails
/// the golden test that decodes a real snapshot, rather than quietly showing
/// a dash.
public struct LiveSnapshot: Decodable, Sendable, Equatable {
    public let seq: UInt64
    public let generatedMs: Int64
    public let clock: Clock?
    public let instrument: Instrument
    public let feeds: [Feed]
    public let events: [Event]
    public let spot: Spot?
    public let risk: Risk
    public let structure: [VenueStructure]
    public let gravity: Gravity
    public let probability: Probability
    public let macro: Macro

    public struct Clock: Decodable, Sendable, Equatable {
        /// Local minus venue, in milliseconds.
        public let offsetMs: Double
        /// The round trip the offset was measured over: half of it is the
        /// reading's error bar.
        public let roundTripMs: Double
        public let measuredMs: Int64
    }

    public struct Instrument: Decodable, Sendable, Equatable {
        public let instId: String
        public let base: String
        public let mode: String
    }

    public struct Feed: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        /// `connecting`, `live`, `degraded`, `refused` or `off`.
        public let state: String
        public let detail: String?
        public let sinceMs: Int64
        /// The last time the feed delivered data — a socket frame, or a poll
        /// that returned without error.
        public let lastFrameMs: Int64?
        /// Past this age the last frame reads as stale: a few of the feed's
        /// own intervals, declared by the kernel per feed.
        public let staleAfterMs: Double
        public let frames: UInt64
        public var isLive: Bool { state == "live" }
    }

    public struct Event: Decodable, Sendable, Equatable, Identifiable {
        public let id: UInt64
        public let ms: Int64
        public let message: String
    }

    public struct Spot: Decodable, Sendable, Equatable {
        public let value: Double
        public let ms: Int64
        public let source: String
    }

    /// A value and when the venue produced it.
    public struct Stamped: Decodable, Sendable, Equatable {
        public let value: Double
        public let ms: Int64
    }

    // MARK: Risk

    public struct Risk: Decodable, Sendable, Equatable {
        /// `okx.private` (the read-only account socket), `cli` (the fallback),
        /// or `none` — nothing read, in which case `note` says why and the
        /// screen must not claim the account is flat.
        public let source: String
        public let note: String?
        /// The account socket has been down long enough that the app should
        /// read positions through the CLI and hand them in.
        public let fallbackNeeded: Bool
        public let instId: String
        public let positionsMs: Int64?
        public let held: [String]
        public let position: Position?
        public let equity: Stamped?
        public let exposure: Exposure?
        public let liquidationOdds: [Odds]
        /// When pending stops were last read; nil until they have been, which
        /// is not the same as "there are none".
        public let stopsMs: Int64?
        /// The stops feed's stale age, for `stopsMs`.
        public let stopsStaleAfterMs: Double
        public let stopsError: String?

        /// Positions were actually read — the only state in which "flat" is a
        /// claim this screen may make.
        public var wasRead: Bool { source != "none" && positionsMs != nil }
    }

    public struct Position: Decodable, Sendable, Equatable {
        public let instId: String
        public let posSide: String
        public let contracts: Double
        public let baseQuantity: Double
        public let isShort: Bool
        public let averagePrice: Double?
        public let markPrice: Double?
        public let markMs: Int64?
        /// `okx.mark-price` (the live stream) or `position` (the last push).
        public let markSource: String
        public let unrealisedPnl: Double?
        public let liquidationPrice: Double?
        public let liquidationBufferPct: Double?
        public let margin: Double?
        public let maintenanceMargin: Double?
        public let marginRatio: Double?
        public let leverageSetting: Double?
        public let notionalUsd: Double?
        public let fundingFee: Double?
        public let protective: [Protective]
        public let updatedMs: Int64?
    }

    public struct Protective: Decodable, Sendable, Equatable, Identifiable {
        public let algoId: String
        public let stopPrice: Double?
        public let takeProfitPrice: Double?
        /// Contracts, for a standalone order.
        public let size: Double?
        /// Share of the position, for a position TP/SL.
        public let fraction: Double?
        /// `仓位止盈止损`, `条件单` or `OCO 条件单`.
        public let kind: String
        public var id: String { algoId }
    }

    public struct Exposure: Decodable, Sendable, Equatable {
        public let notional: Double
        public let equity: Double
        public let margin: Double
        public let effectiveLeverage: Double
        public let lossPerOnePercent: Double
        public let onePercentAsEquityPct: Double
        public let marginAsEquityPct: Double
    }

    public struct Odds: Decodable, Sendable, Equatable, Identifiable {
        public let hours: Double
        public let atHorizon: Double
        public let touching: Double
        /// Vol at the liquidation level on the curve used, in percent.
        public let iv: Double
        /// The expiry the horizon was read from, and the later one blended
        /// with it when the horizon falls between two.
        public let expiryMs: Int64
        public let farExpiryMs: Int64?
        /// `between`, `before-first` or `after-last`.
        public let placement: String
        public var id: Double { hours }
    }

    // MARK: Structure

    public struct VenueStructure: Decodable, Sendable, Equatable, Identifiable {
        public let venue: String
        public let symbol: String
        public let price: Stamped?
        public let mark: Stamped?
        public let fundingRate: Stamped?
        public let nextFundingMs: Int64?
        public let openInterest: OpenInterest?
        public let oiChange1h: Change?
        public let oiChange4h: Change?
        /// Five-minute buckets; `ms` is the bucket's start.
        public let topByPosition: Stamped?
        public let topByAccount: Stamped?
        public let allAccounts: Stamped?
        public let takerBuySell: Stamped?
        /// OKX only: taker buys over sells from the live trade stream.
        public let liveTaker: LiveTaker?
        public let historyError: String?
        public var id: String { venue }
    }

    public struct OpenInterest: Decodable, Sendable, Equatable {
        public let base: Double
        public let usd: Double?
        public let ms: Int64
    }

    public struct Change: Decodable, Sendable, Equatable {
        public let pct: Double
        /// The history bucket the change is measured from.
        public let referenceMs: Int64
        public let currentMs: Int64
    }

    public struct LiveTaker: Decodable, Sendable, Equatable {
        public let ratio: Double
        public let windowSeconds: Double
        public let trades: Int
        public let ms: Int64
    }

    // MARK: Gravity

    public struct Gravity: Decodable, Sendable, Equatable {
        public let bookMs: Int64?
        /// The option book feed's stale age, for `bookMs`.
        public let bookStaleAfterMs: Double
        public let venues: [VenueCoverage]
        public let expiries: [ExpiryRow]
        public let nearExpiryMs: Int64?
        public let nearStrikes: [StrikeRow]
    }

    public struct VenueCoverage: Decodable, Sendable, Equatable, Identifiable {
        public let venue: String
        public let ok: Bool
        public let error: String?
        public let oiBase: Double
        public let legs: Int
        public let fetchedMs: Int64?
        public var id: String { venue }
    }

    public struct ExpiryRow: Decodable, Sendable, Equatable, Identifiable {
        public let expiryMs: Int64
        public let hours: Double
        public let oiBase: Double
        public let notionalUsd: Double
        public let marketValueUsd: Double?
        public let maxPain: MaxPain?
        /// Percent.
        public let atmIv: Double?
        public let oneSigma: Double?
        /// Settlement at or beyond max pain, on its side of the forward.
        public let pBeyondMaxPain: Double?
        public let venueShares: [Share]
        public let skew: Skew?
        public let legs: Int
        public let smileMs: Int64?
        public var id: Int64 { expiryMs }
    }

    public struct MaxPain: Decodable, Sendable, Equatable {
        public let strike: Double
        public let distancePct: Double
        public let weak: Bool
        public let payoutUsd: Double
        public let payoutOneSigmaAwayUsd: Double?
    }

    public struct Share: Decodable, Sendable, Equatable, Identifiable {
        public let venue: String
        public let oiBase: Double
        public var id: String { venue }
    }

    public struct Skew: Decodable, Sendable, Equatable {
        public let points: Double
        public let noisy: Bool
    }

    public struct StrikeRow: Decodable, Sendable, Equatable, Identifiable {
        public let strike: Double
        public let callOi: Double
        public let putOi: Double
        public var id: Double { strike }
        public var net: Double { callOi - putOi }
    }

    // MARK: Probability

    public struct Probability: Decodable, Sendable, Equatable {
        public let smileVenue: String
        public let surfaceMs: Int64?
        public let indexMs: Int64?
        public let spot: Double?
        /// Ascending price edges; `columns[i].probabilities` has one more
        /// entry: below the first edge, each range, above the last.
        public let edges: [Double]
        public let spotBucket: Int?
        /// `exact` when every forward was carried from its quote time by the
        /// index; `approximate` when one was not.
        public let forwardAnchor: String?
        public let columns: [Column]
    }

    public struct Column: Decodable, Sendable, Equatable, Identifiable {
        public let expiryMs: Int64
        public let hours: Double
        public let forward: Double
        public let atmIv: Double?
        public let probabilities: [Double]
        /// Ranges whose raw probability came out negative and are shown as 0.
        public let clamped: [Int]
        public let maxPain: Double?
        public let maxPainBucket: Int?
        public let smileMs: Int64
        /// `SVI`, or `SSVI` when SVI's distribution failed the check.
        public let curve: String
        public let fitError: Double
        public let quotes: Int
        public var id: Int64 { expiryMs }
    }

    // MARK: Macro

    public struct Macro: Decodable, Sendable, Equatable {
        /// `schwab`, `yahoo` or `none`.
        public let source: String
        public let note: String?
        public let rows: [MacroRow]
    }

    public struct MacroRow: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let meaning: String
        public let price: Double?
        public let changePct: Double?
        public let ms: Int64?
        public let delayed: Bool
        public let source: String
    }

    // MARK: Ages

    /// How old a venue timestamp is now, in milliseconds, corrected for this
    /// machine's clock offset when it has been measured.
    public func age(of ms: Int64, now: Date = Date()) -> Double {
        Self.age(of: ms, offsetMs: clock?.offsetMs ?? 0, now: now)
    }

    /// The one age rule: local time, less the measured offset (local minus
    /// venue), less the venue's timestamp.
    public static func age(of ms: Int64, offsetMs: Double, now: Date) -> Double {
        now.timeIntervalSince1970 * 1000 - offsetMs - Double(ms)
    }

    public func feed(_ id: String) -> Feed? { feeds.first { $0.id == id } }
}
