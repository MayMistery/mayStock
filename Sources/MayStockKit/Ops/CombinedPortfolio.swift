import Foundation

/// Every account added up, in dollars.
///
/// The per-venue pages each answer "what is this account worth, in its own
/// terms". Neither answers "what am I worth", and adding the two figures by
/// eye is wrong twice over: OKX's book quotes in USDT while its equity is
/// already dollars, and an account that failed to read contributes a blank
/// rather than a zero. This type does the addition once, and says out loud
/// which accounts it could not include.
///
/// The rule it enforces: **a total is only shown for what was actually read.**
/// A venue that errored, that has not been read yet, or that reported no
/// equity figure is named in `missing`, and its absence is visible next to
/// the number rather than folded silently into a smaller total.
public struct CombinedPortfolio: Sendable, Equatable {
    /// One account's contribution, already converted to dollars.
    public struct Share: Sendable, Equatable, Identifiable {
        public let venue: Venue
        /// The venue's own equity figure, in `nativeCurrency`.
        public let nativeEquity: Double?
        public let nativeCurrency: String
        /// `nativeEquity` in dollars, when it could be stated in dollars.
        public let usdEquity: Double?
        /// Why this account contributed nothing, in words. Nil when it did.
        public let absence: Absence?
        public let readAt: Date?

        public var id: Venue { venue }
        public var isIncluded: Bool { usdEquity != nil }

        public init(venue: Venue, nativeEquity: Double?, nativeCurrency: String,
                    usdEquity: Double?, absence: Absence?, readAt: Date?) {
            self.venue = venue
            self.nativeEquity = nativeEquity
            self.nativeCurrency = nativeCurrency
            self.usdEquity = usdEquity
            self.absence = absence
            self.readAt = readAt
        }
    }

    /// Why an account is not in the total. Each case is a different thing to
    /// do about it, which is why they are not one `String?`.
    public enum Absence: Sendable, Equatable {
        /// The account has not been read yet this session.
        case notRead
        /// The read failed; the venue's words.
        case failed(String)
        /// Read fine, but the venue reported no equity figure at all.
        case noEquityReported
        /// Read fine and reported equity, in a currency this cannot convert.
        case unconvertible(currency: String)

        public var text: String {
            switch self {
            case .notRead: return "尚未读取"
            case .failed(let why): return why
            case .noEquityReported: return "未报告权益"
            case .unconvertible(let ccy): return "\(ccy) 无法折算为 USD"
            }
        }
    }

    public let shares: [Share]

    public init(shares: [Share]) {
        self.shares = shares
    }

    /// Dollars across every account that could be read. Nil — not zero — when
    /// none could: an empty total and a total of nothing held look the same
    /// on screen, and only one of them is a fact about the money.
    public var totalUsd: Double? {
        let included = shares.compactMap(\.usdEquity)
        return included.isEmpty ? nil : included.reduce(0, +)
    }

    /// The accounts the total does not include, and why.
    public var missing: [Share] { shares.filter { !$0.isIncluded } }

    /// True when every account was read and valued, so `totalUsd` is the
    /// whole portfolio rather than a floor.
    public var isComplete: Bool { !shares.isEmpty && missing.isEmpty }

    /// The oldest reading the total rests on — the total is only as fresh as
    /// its stalest part.
    public var oldestReadAt: Date? {
        shares.filter(\.isIncluded).compactMap(\.readAt).min()
    }

    /// Each included account's share of the total, largest first. Empty when
    /// there is no total to take a share of.
    public var weights: [(share: Share, fraction: Double)] {
        guard let total = totalUsd, total > 0 else { return [] }
        return shares
            .filter(\.isIncluded)
            .map { ($0, ($0.usdEquity ?? 0) / total) }
            .sorted { $0.1 > $1.1 }
    }

    /// What to put next to the number so it is never read as more than it is.
    public var coverageNote: String {
        guard !missing.isEmpty else { return "" }
        return missing
            .map { "\($0.venue.displayName)未计入（\($0.absence?.text ?? "原因不明")）" }
            .joined(separator: "；")
    }

    // MARK: Building

    /// One account's reading, as the caller holds it.
    public struct Reading: Sendable {
        public let venue: Venue
        public let snapshot: AccountSnapshot?
        public let error: String?
        public let readAt: Date?

        public init(venue: Venue, snapshot: AccountSnapshot?, error: String?, readAt: Date?) {
            self.venue = venue
            self.snapshot = snapshot
            self.error = error
            self.readAt = readAt
        }
    }

    /// Add up what was read.
    ///
    /// Conversion is deliberately not a rate table: the only currency any
    /// venue here reports equity in is USD, and inventing a USDT→USD peg to
    /// paper over a venue that someday reports otherwise would put a made-up
    /// number in the one place that must not have one. Such a venue lands in
    /// `missing` as `.unconvertible` instead, which is a bug report rather
    /// than a silent rounding.
    public static func combine(_ readings: [Reading]) -> CombinedPortfolio {
        CombinedPortfolio(shares: readings.map { reading in
            let currency = reading.snapshot?.equityCurrency ?? reading.venue.quoteCurrency
            let native = reading.snapshot?.totalEquity
            let absence: Absence?
            var usd: Double?
            if let error = reading.error, reading.snapshot == nil {
                absence = .failed(error)
            } else if reading.snapshot == nil {
                absence = .notRead
            } else if native == nil {
                absence = .noEquityReported
            } else if currency == usdCode {
                usd = native
                absence = nil
            } else {
                absence = .unconvertible(currency: currency)
            }
            return Share(
                venue: reading.venue, nativeEquity: native, nativeCurrency: currency,
                usdEquity: usd, absence: absence, readAt: reading.readAt)
        })
    }

    private static let usdCode = AccountSnapshot.usdCode
}
