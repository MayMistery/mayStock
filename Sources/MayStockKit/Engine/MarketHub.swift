import Foundation
import Observation

/// Orchestrates market data for the whole watchlist, across venues.
///
/// One feed and one one-off source per venue, looked up by the watch item's
/// venue. The hub knows nothing about how either works: OKX pushes over
/// WebSockets, Yahoo is polled, and both arrive here as `MarketFeedEvent`s
/// keyed by instrument id.
///
/// Sessions are keyed by instrument id alone, and the watchlist keeps ids
/// unique across venues. OKX writes the pair into the id (`BTC-USDT`) and a
/// US ticker never contains a dash, so the same id cannot mean two things —
/// and a session carries its venue, so every reader can still ask.
@Observable
@MainActor
public final class MarketHub {
    public private(set) var sessions: [String: InstrumentSession] = [:]
    /// Each venue's feed health, once its feed has reported anything.
    public private(set) var feedStates: [Venue: FeedState] = [:]

    /// Called on every ticker update — alert evaluation hooks in here.
    public var onTick: ((InstrumentSession, Ticker) -> Void)?

    private let feeds: [Venue: any MarketFeed]
    private let sources: [Venue: any MarketDataSource]
    private var depthPollTasks: [String: Task<Void, Never>] = [:]

    public init(feeds: [any MarketFeed], sources: [any MarketDataSource]) {
        self.feeds = Dictionary(uniqueKeysWithValues: feeds.map { ($0.venue, $0) })
        self.sources = Dictionary(uniqueKeysWithValues: sources.map { ($0.venue, $0) })
        for feed in feeds {
            let venue = feed.venue
            Task {
                await feed.setHandler { [weak self] event in
                    Task { @MainActor in self?.handle(event, from: venue) }
                }
            }
        }
    }

    /// The feeds and sources the app ships with, one pair per venue.
    public static func standard() -> MarketHub {
        let sources = MarketDataSources()
        return MarketHub(
            feeds: [OKXMarketFeed(), YahooMarketFeed(client: sources.yahoo)],
            sources: [sources.okx, sources.yahoo])
    }

    public func source(for venue: Venue) -> (any MarketDataSource)? {
        sources[venue]
    }

    public func feedState(for venue: Venue) -> FeedState {
        feedStates[venue] ?? .idle
    }

    /// Venues with at least one live session, in declaration order.
    public var activeVenues: [Venue] {
        Venue.allCases.filter { venue in sessions.values.contains { $0.venue == venue } }
    }

    // MARK: Watchlist lifecycle

    /// Reconcile subscriptions with the enabled watchlist.
    public func setWatchlist(_ items: [WatchItem]) {
        let wanted = items.filter(\.enabled)
        let wantedIds = Set(wanted.map(\.instId))
        let currentIds = Set(sessions.keys)

        for gone in currentIds.subtracting(wantedIds) {
            removeInstrument(gone)
        }
        for item in wanted where sessions[item.instId] == nil {
            addInstrument(item)
        }
    }

    public func session(for instId: String) -> InstrumentSession? {
        sessions[instId]
    }

    private func addInstrument(_ item: WatchItem) {
        guard let feed = feeds[item.venue], let source = sources[item.venue] else {
            // A watch item on a venue this hub was not built with. Said once,
            // loudly: the item stays in the list with no session, which the
            // markets page shows as "not subscribed".
            Log.warn("hub: \(item.instId) 属于 \(item.venue.displayName)，但没有该交易所的行情源")
            return
        }
        // A bar the venue's data cannot serve falls back to the venue's
        // finest, rather than a subscription that never answers.
        let bar = item.venue.supportedBars.contains(item.defaultBar)
            ? item.defaultBar : (item.venue.supportedBars.first ?? item.defaultBar)
        let session = InstrumentSession(instId: item.instId, venue: item.venue, bar: bar)
        sessions[item.instId] = session
        Task { await feed.subscribe(instId: item.instId, bar: bar) }

        // Warm-up: metadata, candle backfill, sparkline seed, first tick.
        //
        // The sparkline is seeded at *two* resolutions: coarse bars cover the
        // buffer's whole retention (so the long line windows have real data
        // the instant the app launches) and 1m bars refine the recent stretch.
        // A market with sessions keeps a week, so the coarse seed reaches back
        // five sessions rather than a day.
        let coarseTarget = item.venue.tradesContinuously ? 300 : 420
        let instId = item.instId
        Task {
            async let metaTask = try? source.instrumentMeta(instId: instId)
            async let candlesTask = try? source.candles(instId: instId, bar: bar, target: 300)
            async let coarseSeedTask = try? source.candles(instId: instId, bar: .m5, target: coarseTarget)
            async let fineSeedTask = try? source.candles(instId: instId, bar: .m1, target: 300)
            async let tickerTask = try? source.ticker(instId: instId)

            let (meta, candles, coarseSeed, fineSeed, ticker) =
                await (metaTask, candlesTask, coarseSeedTask, fineSeedTask, tickerTask)
            await MainActor.run {
                guard let session = self.sessions[instId] else { return }
                if let meta { session.apply(meta: meta) }
                if let coarseSeed { session.seedSparkline(from: coarseSeed) }
                if let fineSeed { session.seedSparkline(from: fineSeed) }
                if let ticker, session.ticker == nil { session.apply(ticker: ticker) }
                if let candles {
                    session.finishBackfill(candles, for: bar)
                } else {
                    session.failBackfill(for: bar)
                }
            }
        }
    }

    private func removeInstrument(_ instId: String) {
        guard let session = sessions.removeValue(forKey: instId) else { return }
        stopDepthPolling(instId: instId)
        let bar = session.bar
        guard let feed = feeds[session.venue] else { return }
        Task { await feed.unsubscribe(instId: instId, bar: bar) }
    }

    // MARK: Bar switching

    public func switchBar(instId: String, to bar: BarInterval) {
        guard let session = sessions[instId], session.bar != bar,
              session.venue.supportedBars.contains(bar),
              let feed = feeds[session.venue], let source = sources[session.venue] else { return }
        let old = session.bar
        session.beginBarSwitch(to: bar)

        Task { await feed.switchBar(instId: instId, from: old, to: bar) }
        Task {
            let candles = try? await source.candles(instId: instId, bar: bar, target: 300)
            await MainActor.run {
                guard let session = self.sessions[instId] else { return }
                if let candles, !candles.isEmpty {
                    session.finishBackfill(candles, for: bar)
                } else {
                    session.failBackfill(for: bar)
                }
            }
        }
    }

    // MARK: Depth polling (only while a panel shows the depth chart)

    /// 400 levels is the deepest a single OKX `books` call returns, and it is
    /// what makes a ±0.5% depth window show real structure instead of a spike.
    /// A venue without a book to poll is left alone.
    public func startDepthPolling(instId: String, depth: Int = 400, interval: TimeInterval = 2) {
        guard depthPollTasks[instId] == nil,
              let session = sessions[instId], session.venue.hasOrderBook,
              let source = sources[session.venue] else { return }
        depthPollTasks[instId] = Task {
            while !Task.isCancelled {
                if let book = try? await source.book(instId: instId, depth: depth) {
                    await MainActor.run {
                        self.sessions[instId]?.apply(deepBook: book)
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stopDepthPolling(instId: String) {
        depthPollTasks[instId]?.cancel()
        depthPollTasks[instId] = nil
    }

    // MARK: Event routing

    private func handle(_ event: MarketFeedEvent, from venue: Venue) {
        switch event {
        case .state(let state):
            feedStates[venue] = state
            for session in sessions.values where session.venue == venue {
                session.apply(connection: state)
            }
        case .ticker(let ticker):
            guard let session = sessions[ticker.instId], session.venue == venue else { return }
            session.apply(ticker: ticker)
            onTick?(session, ticker)
        case .candles(let instId, let bar, let candles):
            guard let session = sessions[instId], session.venue == venue, session.bar == bar else { return }
            session.apply(candles: candles, reset: false)
        case .book(let book):
            guard let session = sessions[book.instId], session.venue == venue else { return }
            session.apply(book: book)
        }
    }
}

/// Minimal logging shim that works on macOS and Linux.
///
/// Also appends to a file, and that is not belt-and-braces. A menu bar app is
/// launched by Finder or `open`, whose stderr goes nowhere anyone can read
/// afterwards — so every "we degraded and here is why" line this codebase
/// writes was, in production, addressed to no one. When a strategy flattened a
/// position on a multiplier it should never have had, there was nothing left to
/// reconstruct the decision from. A degradation notice that cannot be read
/// later is a comment, not observability.
public enum Log {
    /// Bounded so an unattended process cannot fill the disk over months.
    static let maxBytes = 4 << 20
    private static let queue = DispatchQueue(label: "com.maystock.log")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var destination: URL?

    /// Wire the file sink. Deliberately opt-in and off by default: defaulting
    /// it to the state directory meant the test suite — which builds runners
    /// against fake venues — appended its fixtures to the *live* engine log.
    /// Only a process that owns that directory may write to it, and only the
    /// app does.
    public static func useFile(in directory: URL) {
        lock.lock()
        destination = directory.appendingPathComponent("engine-log.txt")
        lock.unlock()
        // Marks the session boundary. Restarts are the context every other line
        // needs — a gap in the equity curve, a stale multiplier and a wake from
        // sleep are the same event, and nothing recorded which.
        warn("engine: 启动")
    }

    public static func warn(_ message: String) {
        let line = "[maystock] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        lock.lock()
        let fileURL = destination
        lock.unlock()
        guard let fileURL else { return }
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)"
        queue.async { append(stamped, to: fileURL) }
    }

    private static func append(_ line: String, to fileURL: URL) {
        let manager = FileManager.default
        let path = fileURL.path
        if let size = (try? manager.attributesOfItem(atPath: path)[.size]) as? Int,
           size > maxBytes {
            // Keep the tail: the lines nearest a failure are the ones wanted.
            if let data = try? Data(contentsOf: fileURL) {
                try? data.suffix(maxBytes / 2).write(to: fileURL, options: .atomic)
            }
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? manager.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
