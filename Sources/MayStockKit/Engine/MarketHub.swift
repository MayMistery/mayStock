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
    private var sparklineSeedMinutes: Int = 1_440
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
        Task { [rest] in
            async let metaTask = try? rest.instrumentMeta(instId: item.instId)
            async let candlesTask = try? rest.candles(instId: item.instId, bar: item.defaultBar, target: 300)
            async let sparkTask = try? rest.candles(instId: item.instId, bar: .m1, target: 300)
            async let tickerTask = try? rest.ticker(instId: item.instId)

            let (meta, candles, sparkSeed, ticker) = await (metaTask, candlesTask, sparkTask, tickerTask)
            await MainActor.run {
                guard let session = self.sessions[item.instId] else { return }
                if let meta { session.apply(meta: meta) }
                if let candles { session.apply(candles: candles, reset: false) }
                if let sparkSeed { session.seedSparkline(from: sparkSeed) }
                if let ticker, session.ticker == nil { session.apply(ticker: ticker) }
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
        session.switchBar(bar)

        Task { [wsBusiness] in
            await wsBusiness.unsubscribe([OKXChannelArg(channel: old.wsChannel, instId: instId)])
            await wsBusiness.subscribe([OKXChannelArg(channel: bar.wsChannel, instId: instId)])
        }
        Task { [rest] in
            let candles = try? await rest.candles(instId: instId, bar: bar, target: 300)
            await MainActor.run {
                guard let candles, let session = self.sessions[instId], session.bar == bar else { return }
                session.apply(candles: candles, reset: false)
            }
        }
    }

    // MARK: Depth polling (only while a panel shows the depth chart)

    public func startDepthPolling(instId: String) {
        guard depthPollTasks[instId] == nil else { return }
        depthPollTasks[instId] = Task { [rest] in
            while !Task.isCancelled {
                if let book = try? await rest.books(instId: instId, depth: 50) {
                    await MainActor.run {
                        self.sessions[instId]?.apply(deepBook: book)
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
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
public enum Log {
    public static func warn(_ message: String) {
        FileHandle.standardError.write(Data("[maystock] \(message)\n".utf8))
    }
}
