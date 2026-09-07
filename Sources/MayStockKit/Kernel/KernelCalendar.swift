import Foundation
import CMayStockKernel

/// A market's calendar, as the kernel keeps it.
///
/// Every conversion between bars and time on the Swift side — how many bars a
/// window of days holds, which trading day a timestamp belongs to, when a bar
/// closes, how many bars a position has been held — asks here, and here asks
/// the kernel. There is deliberately no Swift arithmetic of the form
/// `days × 86 400 / barSeconds`: that formula is the one that counted a stock
/// position as eighteen bars old overnight and reset the daily breaker at
/// midnight UTC, and a second copy of the right answer would only drift from
/// the kernel's.
public struct KernelCalendar: Sendable, Equatable {
    /// The manifest's market block, which is all the kernel needs.
    private let marketJSON: String

    public init(market: StrategyMarket) {
        // Encoding our own value type cannot fail; if it ever did the kernel
        // would refuse the JSON below, loudly.
        marketJSON = (try? String(data: JSONEncoder().encode(market), encoding: .utf8) ?? "") ?? ""
    }

    /// Bars in a year on this market, for annualising anything.
    public var barsPerYear: Double {
        query { error in ms_calendar_bars_per_year(marketJSON, error) }
    }

    /// The trading day `date` belongs to, as a day index. Two instants with the
    /// same key are the same day for the daily-loss breaker.
    public func sessionKey(_ date: Date) -> Int {
        Int(query { error in ms_calendar_session_key(marketJSON, Self.millis(date), error) })
    }

    /// Close of the bar opening at `open` — when a decision on it is taken.
    public func barClose(_ open: Date) -> Date {
        Self.date(query { error in ms_calendar_bar_close(marketJSON, Self.millis(open), error) })
    }

    /// Open of the bar after the one opening at `open`.
    public func nextOpen(after open: Date) -> Date {
        Self.date(query { error in ms_calendar_next_open(marketJSON, Self.millis(open), error) })
    }

    /// Bar opens the calendar expects strictly after `from` and up to `to`.
    ///
    /// This is "bars between two instants": the count of bars a position
    /// opened at `from` has been held by the bar at `to`, or the bars a
    /// cooldown has waited.
    public func expectedBars(from: Date, to: Date) -> Int {
        Int(query { error in
            ms_calendar_opens_between(marketJSON, Self.millis(from), Self.millis(to), error)
        })
    }

    public func isOpen(at date: Date) -> Bool {
        query { error in ms_calendar_is_open(marketJSON, Self.millis(date), error) } == 1
    }

    /// Bars the calendar expects over the trailing `days` calendar days ending
    /// at `now` — how many bars to fetch for a window of that length.
    public func barCount(days: Int, endingAt now: Date = Date()) -> Int {
        expectedBars(from: now.addingTimeInterval(-Double(days) * 86_400), to: now)
    }

    // MARK: Plumbing

    /// Run one calendar query. A kernel error here means the market JSON the
    /// Swift side encoded is not one the kernel understands — a build-time
    /// mismatch between the two enums, which the test suite walks every
    /// declared combination to rule out. Trading on a fabricated calendar
    /// figure would be worse than stopping, so this stops.
    private func query<T>(
        _ call: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var error: UnsafeMutablePointer<CChar>?
        let value = call(&error)
        if let error {
            let message = String(cString: error)
            ms_string_free(error)
            preconditionFailure("kernel calendar refused \(marketJSON): \(message)")
        }
        return value
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}

// MARK: - Instrument policy

/// What an instrument type allows, as the kernel defines it.
///
/// Swift reads this rather than keeping a table of its own: the kernel is the
/// side that compiles manifests and sizes positions, so if the two disagreed
/// about whether a stock may be shorted the disagreement would surface as a
/// live order the backtest never modelled.
public struct KernelInstrumentPolicy: Decodable, Sendable, Equatable {
    public let instType: InstrumentType
    public let allowsShort: Bool
    public let allowsLeverage: Bool
    public let maxLeverage: Double
    /// Sized in contracts rather than in the base unit, so the exchange has
    /// to be asked what one contract is worth.
    public let tradesInContracts: Bool
    public let marginRegime: String
    public let defaultMaintenanceMarginRate: Double?
    /// Cost model the kernel assumes when neither the manifest nor the fee
    /// schedule states one. Nil means the type has no defensible default.
    public let defaultFees: FeeModel?

    /// One kernel round trip per type, once.
    public static func policy(for instType: InstrumentType) -> KernelInstrumentPolicy {
        policies[instType]!
    }

    /// Every type's policy, read from the kernel at first use. Missing an
    /// entry means the Swift enum names a type the kernel does not — the
    /// vocabulary test catches that before this could.
    private static let policies: [InstrumentType: KernelInstrumentPolicy] = {
        var out: [InstrumentType: KernelInstrumentPolicy] = [:]
        for instType in InstrumentType.allCases {
            var error: UnsafeMutablePointer<CChar>?
            guard let json = ms_instrument_policy(instType.rawValue, &error) else {
                let message = error.map { pointer -> String in
                    defer { ms_string_free(pointer) }
                    return String(cString: pointer)
                } ?? "unknown"
                preconditionFailure("kernel has no policy for \(instType.rawValue): \(message)")
            }
            defer { ms_string_free(json) }
            do {
                out[instType] = try JSONDecoder().decode(
                    KernelInstrumentPolicy.self, from: Data(String(cString: json).utf8))
            } catch {
                preconditionFailure("kernel policy for \(instType.rawValue) did not decode: \(error)")
            }
        }
        return out
    }()
}
