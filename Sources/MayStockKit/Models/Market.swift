import Foundation

// MARK: - Bar interval

/// Candlestick intervals MayStock draws. Every one exists on OKX v5; a venue
/// with sessions may serve fewer — see `Venue.supportedBars`.
public enum BarInterval: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case m1 = "1m"
    case m5 = "5m"
    case m15 = "15m"
    case h1 = "1H"
    case h4 = "4H"
    case d1 = "1D"
    case w1 = "1W"

    public var id: String { rawValue }

    /// OKX WebSocket channel name. Candle channels live on the **business**
    /// endpoint since 2023-06-20 — not `/public`.
    public var wsChannel: String { "candle" + rawValue }

    /// REST `bar` query value.
    public var restBar: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .m1: return 60
        case .m5: return 300
        case .m15: return 900
        case .h1: return 3_600
        case .h4: return 14_400
        case .d1: return 86_400
        case .w1: return 604_800
        }
    }
}

// MARK: - Ticker

/// What a ticker's change is measured from — what "up 1.2%" is up from.
public enum ChangeBasis: String, Sendable, Codable, Equatable {
    /// Against the price 24 hours ago: a market that never closes has no
    /// session to measure a day from.
    case rolling24h
    /// Against the previous session's close: what a stock's daily change
    /// means everywhere it is quoted.
    case previousClose

    /// The period the high, low and volume cover: "24h" or "今日".
    public var periodLabel: String {
        switch self {
        case .rolling24h: return "24h"
        case .previousClose: return "今日"
        }
    }

    /// What the change chip is relative to, for a tooltip.
    public var changeLabel: String {
        switch self {
        case .rolling24h: return "较 24h 前"
        case .previousClose: return "较昨收"
        }
    }
}

/// Where a market with sessions is in its day. Nil on a market that never
/// closes.
public enum MarketPhase: String, Sendable, Codable, Equatable, CaseIterable {
    case preMarket, regular, afterHours, closed

    public var displayName: String {
        switch self {
        case .preMarket: return "盘前"
        case .regular: return "交易中"
        case .afterHours: return "盘后"
        case .closed: return "休市"
        }
    }

    /// Prints are arriving: any session, regular or extended.
    public var isTrading: Bool { self != .closed }
}

/// Latest market snapshot for one instrument.
///
/// One shape for every venue. `reference`, `high`, `low` and `volume` cover
/// the period `basis` names — the trailing day on OKX, the current session
/// on a stock exchange — so a page reads the label off the basis instead of
/// assuming "24h".
public struct Ticker: Sendable, Equatable {
    public let instId: String
    public let last: Double
    public let bid: Double?
    public let ask: Double?
    /// The price `change` is measured from; see `basis`.
    public let reference: Double
    /// The period's opening print, where the venue reports one.
    public let open: Double?
    public let high: Double
    public let low: Double
    /// In base units — coins, shares.
    public let volume: Double
    public let basis: ChangeBasis
    /// Session phase on a market that has sessions; nil on a continuous one.
    public let phase: MarketPhase?
    public let ts: Date

    public init(
        instId: String, last: Double, bid: Double?, ask: Double?,
        reference: Double, open: Double? = nil, high: Double, low: Double, volume: Double,
        basis: ChangeBasis, phase: MarketPhase? = nil, ts: Date
    ) {
        self.instId = instId
        self.last = last
        self.bid = bid
        self.ask = ask
        self.reference = reference
        self.open = open
        self.high = high
        self.low = low
        self.volume = volume
        self.basis = basis
        self.phase = phase
        self.ts = ts
    }

    public var change: Double { last - reference }

    /// Change in percent against `reference`, e.g. `1.24` for +1.24%.
    public var changePct: Double {
        guard reference > 0 else { return 0 }
        return (last - reference) / reference * 100
    }

    public var spread: Double? {
        guard let bid, let ask else { return nil }
        return ask - bid
    }
}

// MARK: - Candle

/// One OHLCV candle. Identity is the bar-open timestamp — never a random UUID,
/// so SwiftUI diffing and merge-by-key both stay cheap and correct.
public struct Candle: Sendable, Equatable, Identifiable {
    public let ts: Date
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    public let volume: Double // base currency
    public let confirmed: Bool

    public var id: Date { ts }
    public var isBullish: Bool { close >= open }

    public init(ts: Date, open: Double, high: Double, low: Double, close: Double, volume: Double, confirmed: Bool) {
        self.ts = ts
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.confirmed = confirmed
    }
}

extension Array where Element == Candle {
    /// Merge incoming candles (REST backfill or WS push) into a sorted-by-ts
    /// array, replacing rows with equal `ts` (in-progress bar refreshes) and
    /// appending new ones. Keeps at most `cap` most-recent rows.
    public mutating func mergeCandles(_ incoming: [Candle], cap: Int = 500) {
        guard !incoming.isEmpty else { return }
        var byTs = Dictionary(uniqueKeysWithValues: self.map { ($0.ts, $0) })
        for c in incoming { byTs[c.ts] = c }
        var merged = byTs.values.sorted { $0.ts < $1.ts }
        if merged.count > cap { merged.removeFirst(merged.count - cap) }
        self = merged
    }
}

// MARK: - Order book

public struct BookLevel: Sendable, Equatable {
    public let price: Double
    public let size: Double
    public init(price: Double, size: Double) {
        self.price = price
        self.size = size
    }
}

/// Order book snapshot. `bids` sorted descending, `asks` ascending by price.
public struct OrderBook: Sendable, Equatable {
    public let instId: String
    public let bids: [BookLevel]
    public let asks: [BookLevel]
    public let ts: Date

    public init(instId: String, bids: [BookLevel], asks: [BookLevel], ts: Date) {
        self.instId = instId
        self.bids = bids.sorted { $0.price > $1.price }
        self.asks = asks.sorted { $0.price < $1.price }
        self.ts = ts
    }

    public var bestBid: Double? { bids.first?.price }
    public var bestAsk: Double? { asks.first?.price }

    public var mid: Double? {
        guard let bestBid, let bestAsk else { return nil }
        return (bestBid + bestAsk) / 2
    }

    public var spread: Double? {
        guard let bestBid, let bestAsk else { return nil }
        return bestAsk - bestBid
    }

    /// Spread in basis points of mid — the scale-free way to compare books.
    public var spreadBps: Double? {
        guard let spread, let mid, mid > 0 else { return nil }
        return spread / mid * 10_000
    }

    /// Cumulative depth suitable for a depth chart.
    /// Bid side is returned in descending-price order (walking away from mid).
    public var cumulativeBids: [BookLevel] {
        var running = 0.0
        return bids.map { level in
            running += level.size
            return BookLevel(price: level.price, size: running)
        }
    }

    public var cumulativeAsks: [BookLevel] {
        var running = 0.0
        return asks.map { level in
            running += level.size
            return BookLevel(price: level.price, size: running)
        }
    }

    /// Cumulative depth clipped to a symmetric price window around mid, plus
    /// the aggregates a depth chart needs to label itself.
    ///
    /// `pct` is the half-window as a percentage of mid (0.25 → ±0.25%); `nil`
    /// means "as deep as the book goes". The window is symmetric and never
    /// wider than the *shallower* side, so both curves always reach the edge
    /// instead of one of them stopping in mid-air.
    public func profile(withinPct pct: Double?) -> DepthProfile? {
        guard let mid, mid > 0 else { return nil }
        let bids = cumulativeBids, asks = cumulativeAsks
        guard let deepestBid = bids.last?.price, let deepestAsk = asks.last?.price else { return nil }

        let reach = Swift.min(mid - deepestBid, deepestAsk - mid)
        guard reach > 0 else { return nil }
        let requested = pct.map { mid * $0 / 100 }
        let span = Swift.max(Swift.min(requested ?? reach, reach), mid * 1e-6)

        let lo = mid - span, hi = mid + span
        // Keep one level past the edge so the step function reaches it, then
        // pin that level's price to the edge itself.
        func clip(_ levels: [BookLevel], inside: (Double) -> Bool, edge: Double) -> [BookLevel] {
            var kept: [BookLevel] = []
            for level in levels {
                if inside(level.price) {
                    kept.append(level)
                } else {
                    kept.append(BookLevel(price: edge, size: level.size))
                    break
                }
            }
            if kept.isEmpty, let first = levels.first {
                kept = [BookLevel(price: edge, size: first.size)]
            }
            return kept
        }
        let clippedBids = clip(bids, inside: { $0 >= lo }, edge: lo)
        let clippedAsks = clip(asks, inside: { $0 <= hi }, edge: hi)

        let bidTotal = clippedBids.last?.size ?? 0
        let askTotal = clippedAsks.last?.size ?? 0
        return DepthProfile(
            mid: mid, lo: lo, hi: hi,
            bids: clippedBids, asks: clippedAsks,
            maxCumulative: Swift.max(bidTotal, askTotal, .leastNonzeroMagnitude),
            bidTotal: bidTotal, askTotal: askTotal,
            spanPct: span / mid * 100,
            clampedToBook: requested.map { $0 > reach } ?? false,
            ts: ts)
    }
}

/// Cumulative depth around mid, windowed for display.
public struct DepthProfile: Sendable, Equatable {
    public let mid: Double
    /// Window edges in price terms.
    public let lo: Double
    public let hi: Double
    /// Cumulative levels walking away from mid (bids descending, asks ascending).
    public let bids: [BookLevel]
    public let asks: [BookLevel]
    public let maxCumulative: Double
    public let bidTotal: Double
    public let askTotal: Double
    /// Half-window actually drawn, in percent of mid.
    public let spanPct: Double
    /// The book ran out before the requested window — the view narrowed it.
    public let clampedToBook: Bool
    public let ts: Date

    public init(
        mid: Double, lo: Double, hi: Double,
        bids: [BookLevel], asks: [BookLevel],
        maxCumulative: Double, bidTotal: Double, askTotal: Double,
        spanPct: Double, clampedToBook: Bool, ts: Date
    ) {
        self.mid = mid
        self.lo = lo
        self.hi = hi
        self.bids = bids
        self.asks = asks
        self.maxCumulative = maxCumulative
        self.bidTotal = bidTotal
        self.askTotal = askTotal
        self.spanPct = spanPct
        self.clampedToBook = clampedToBook
        self.ts = ts
    }

    /// −1 (all asks) … 0 (balanced) … +1 (all bids), inside the window.
    public var imbalance: Double {
        let total = bidTotal + askTotal
        guard total > 0 else { return 0 }
        return (bidTotal - askTotal) / total
    }
}

// MARK: - Options

/// Call or put. The raw values match the kernel's `OptionKind`, which is
/// where the direction arithmetic lives — Swift only names and displays it.
public enum OptionKind: String, Codable, Sendable, CaseIterable, Equatable {
    case call, put

    public var displayName: String { self == .call ? "看涨" : "看跌" }
}

/// One listed option contract, as the exchange describes it.
public struct OptionContract: Sendable, Equatable, Identifiable {
    public let instId: String
    /// The index it settles against, e.g. `BTC-USD`.
    public let underlying: String
    public let kind: OptionKind
    public let strike: Double
    public let expiry: Date
    /// Underlying units one contract covers: OKX's `ctVal × ctMult`, 0.01 BTC
    /// for a BTC option.
    public let contractValue: Double
    public let tickSize: Double
    public let lotSize: Double
    public let minSize: Double
    /// The coin premiums and fees are paid in.
    public let settleCurrency: String

    public var id: String { instId }

    public init(
        instId: String, underlying: String, kind: OptionKind, strike: Double, expiry: Date,
        contractValue: Double, tickSize: Double, lotSize: Double, minSize: Double,
        settleCurrency: String
    ) {
        self.instId = instId
        self.underlying = underlying
        self.kind = kind
        self.strike = strike
        self.expiry = expiry
        self.contractValue = contractValue
        self.tickSize = tickSize
        self.lotSize = lotSize
        self.minSize = minSize
        self.settleCurrency = settleCurrency
    }

    /// The same contract in the shape the order path already understands.
    public var meta: InstrumentMeta {
        InstrumentMeta(
            instId: instId, tickSize: tickSize, lotSize: lotSize, minSize: minSize,
            contractValue: contractValue)
    }
}

/// One option's market, all at once: the book in the settlement coin per unit
/// of underlying (how OKX quotes it), the mark in the same unit, and the
/// index that converts either into the quote currency the book keeps.
public struct OptionQuote: Sendable, Equatable {
    public let instId: String
    public let bid: Double?
    public let ask: Double?
    public let mark: Double?
    public let indexPrice: Double
    public let ts: Date

    public init(instId: String, bid: Double?, ask: Double?, mark: Double?, indexPrice: Double, ts: Date) {
        self.instId = instId
        self.bid = bid
        self.ask = ask
        self.mark = mark
        self.indexPrice = indexPrice
        self.ts = ts
    }

    /// The mark in quote currency per unit of underlying — what the ledger
    /// books a premium at.
    public var markQuote: Double? { mark.map { $0 * indexPrice } }
}

// MARK: - Instrument metadata

/// Static exchange metadata for an instrument (from `GET /api/v5/public/instruments`).
public struct InstrumentMeta: Sendable, Equatable {
    public let instId: String
    public let tickSize: Double // e.g. 0.1 for BTC-USDT
    public let lotSize: Double
    public let minSize: Double
    /// Base units per contract: OKX's `ctVal × ctMult`. Order sizes on
    /// derivatives are counted in contracts, not coins — 1 BTC-USDT-SWAP
    /// contract is 0.01 BTC, and so is one BTC option, where `ctVal` is 1 and
    /// the multiplier carries the 0.01. Nil for spot.
    public let contractValue: Double?

    public init(
        instId: String, tickSize: Double, lotSize: Double,
        minSize: Double, contractValue: Double? = nil
    ) {
        self.instId = instId
        self.tickSize = tickSize
        self.lotSize = lotSize
        self.minSize = minSize
        self.contractValue = contractValue
    }

    /// The units one contract covers, from the two fields OKX splits it
    /// across. `ctMult` is 1 on every perpetual and 0.01 on a BTC option;
    /// reading `ctVal` alone would size an option order a hundredfold.
    public static func contractValue(ctVal: Double?, ctMult: Double?) -> Double? {
        guard let ctVal, ctVal > 0 else { return nil }
        let multiplier = (ctMult ?? 1) > 0 ? (ctMult ?? 1) : 1
        return ctVal * multiplier
    }

    /// Convert a base-currency quantity into the units the exchange expects,
    /// rounded down to a whole lot. Returns 0 when the result is below `minSize`.
    public func exchangeSize(forBaseQuantity quantity: Double) -> Double {
        let raw = quantity / (contractValue ?? 1)
        let step = lotSize > 0 ? lotSize : 0
        let rounded = step > 0 ? (raw / step).rounded(.down) * step : raw
        guard rounded >= minSize, rounded > 0 else { return 0 }
        // Trim binary noise so "0.30000000000000004" never reaches the CLI.
        return (rounded * 1e10).rounded() / 1e10
    }

    /// Inverse of `exchangeSize` — what an order of `size` represents in coins.
    public func baseQuantity(forExchangeSize size: Double) -> Double {
        size * (contractValue ?? 1)
    }

    /// Number of fraction digits implied by the tick size (0.1 → 1).
    public var priceDecimals: Int {
        guard tickSize > 0, tickSize < 1 else { return 0 }
        // Robust against binary representation: count digits in decimal string.
        let s = String(format: "%.10f", tickSize)
        guard let dot = s.firstIndex(of: ".") else { return 0 }
        let frac = s[s.index(after: dot)...]
        var digits = 0, seen = 0
        for ch in frac {
            seen += 1
            if ch != "0" { digits = seen }
        }
        return digits
    }
}
