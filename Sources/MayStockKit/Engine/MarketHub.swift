import Foundation
import Observation

/// Orchestrates market data for the whole watchlist.
///
/// Owns exactly two shared WebSocket connections:
///   - `/public`   → `tickers`, `books5`
///   - `/business` → `candle*`  (moved off `/public` by OKX on 2023-06-20)
/// plus a REST client for candle backfill, depth snapshots and metadata.
@Observable
@MainActor
public final class MarketHub {
    public private(set) var sessions: [String: InstrumentSession] = [:]
    public private(set) var publicState: OKXConnectionState = .idle
    public private(set) var businessState: OKXConnectionState = .idle

    /// Called on every ticker update — alert evaluation hooks in here.
    public var onTick: ((InstrumentSession, Ticker) -> Void)?

    private let rest: OKXRESTClient
    private let wsPublic: OKXWSClient
    private let wsBusiness: OKXWSClient
    private var depthPollTasks: [String: Task<Void, Never>] = [:]

    public init(
        rest: OKXRESTClient = OKXRESTClient(),
        publicURL: URL = OKXEndpoints.wsPublic,
        businessURL: URL = OKXEndpoints.wsBusiness
    ) {
        self.rest = rest
        self.wsPublic = OKXWSClient(url: publicURL)
        self.wsBusiness = OKXWSClient(url: businessURL)

        Task { [wsPublic, wsBusiness] in
            await wsPublic.setHandler { [weak self] event in
                Task { @MainActor in self?.handle(event, from: .publicSocket) }
            }
            await wsBusiness.setHandler { [weak self] event in
                Task { @MainActor in self?.handle(event, from: .businessSocket) }
            }
        }
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
        let session = InstrumentSession(instId: item.instId, bar: item.defaultBar)
        sessions[item.instId] = session

        Task { [wsPublic, wsBusiness] in
            await wsPublic.subscribe([
                OKXChannelArg(channel: "tickers", instId: item.instId),
                OKXChannelArg(channel: "books5", instId: item.instId),
            ])
            await wsBusiness.subscribe([
                OKXChannelArg(channel: item.defaultBar.wsChannel, instId: item.instId),
            ])
        }

        // REST warm-up: metadata, candle backfill, sparkline seed, first tick.
        //
        // The sparkline is seeded at *two* resolutions: 5m bars cover the full
        // 25h retention (so the 4H/24H line windows have real data the instant
        // the app launches) and 1m bars refine the most recent 5h.
        let bar = item.defaultBar
        Task { [rest] in
            async let metaTask = try? rest.instrumentMeta(instId: item.instId)
            async let candlesTask = try? rest.candles(instId: item.instId, bar: bar, target: 300)
            async let coarseSeedTask = try? rest.candles(instId: item.instId, bar: .m5, target: 300)
            async let fineSeedTask = try? rest.candles(instId: item.instId, bar: .m1, target: 300)
            async let tickerTask = try? rest.ticker(instId: item.instId)

            let (meta, candles, coarseSeed, fineSeed, ticker) =
                await (metaTask, candlesTask, coarseSeedTask, fineSeedTask, tickerTask)
            await MainActor.run {
                guard let session = self.sessions[item.instId] else { return }
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
        Task { [wsPublic, wsBusiness] in
            await wsPublic.unsubscribe([
                OKXChannelArg(channel: "tickers", instId: instId),
                OKXChannelArg(channel: "books5", instId: instId),
            ])
            await wsBusiness.unsubscribe([
                OKXChannelArg(channel: bar.wsChannel, instId: instId),
            ])
        }
    }

    // MARK: Bar switching

    public func switchBar(instId: String, to bar: BarInterval) {
        guard let session = sessions[instId], session.bar != bar else { return }
        let old = session.bar
        session.beginBarSwitch(to: bar)

        Task { [wsBusiness] in
            await wsBusiness.unsubscribe([OKXChannelArg(channel: old.wsChannel, instId: instId)])
            await wsBusiness.subscribe([OKXChannelArg(channel: bar.wsChannel, instId: instId)])
        }
        Task { [rest] in
            let candles = try? await rest.candles(instId: instId, bar: bar, target: 300)
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

    /// 400 levels is the deepest a single `books` call returns, and it is what
    /// makes a ±0.5% depth window show real structure instead of a spike.
    public func startDepthPolling(instId: String, depth: Int = 400, interval: TimeInterval = 2) {
        guard depthPollTasks[instId] == nil else { return }
        depthPollTasks[instId] = Task { [rest] in
            while !Task.isCancelled {
                if let book = try? await rest.books(instId: instId, depth: depth) {
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

    private enum Socket { case publicSocket, businessSocket }

    private func handle(_ event: OKXWSEvent, from socket: Socket) {
        switch event {
        case .state(let state):
            switch socket {
            case .publicSocket: publicState = state
            case .businessSocket: businessState = state
            }
            let combined: OKXConnectionState =
                (publicState == .connected && businessState == .connected) ? .connected
                : (publicState == .degraded || businessState == .degraded) ? .degraded
                : publicState
            for session in sessions.values { session.apply(connection: combined) }

        case .message(let message):
            switch message {
            case .ticker(let ticker):
                guard let session = sessions[ticker.instId] else { return }
                session.apply(ticker: ticker)
                onTick?(session, ticker)
            case .candles(let instId, let bar, let candles):
                guard let session = sessions[instId], session.bar == bar else { return }
                session.apply(candles: candles, reset: false)
            case .book(let book):
                sessions[book.instId]?.apply(book: book)
            case .error(let code, let message):
                Log.warn("OKX ws error \(code): \(message)")
            case .pong, .subscribed, .unsubscribed, .ignored:
                break
            }
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
