import Foundation

// MARK: - Live feed

/// OKX's live market data: two shared WebSockets, one per endpoint family.
///
///   - `/public`   → `tickers`, `books5`
///   - `/business` → `candle*`  (moved off `/public` by OKX on 2023-06-20)
///
/// The feed's health is the pair's: connected only when both sockets are,
/// degraded when either is reconnecting.
public actor OKXMarketFeed: MarketFeed {
    public nonisolated let venue = Venue.okx
    private let wsPublic: OKXWSClient
    private let wsBusiness: OKXWSClient
    private var publicState: OKXConnectionState = .idle
    private var businessState: OKXConnectionState = .idle
    private var handler: (@Sendable (MarketFeedEvent) -> Void)?

    public init(publicURL: URL = OKXEndpoints.wsPublic, businessURL: URL = OKXEndpoints.wsBusiness) {
        wsPublic = OKXWSClient(url: publicURL)
        wsBusiness = OKXWSClient(url: businessURL)
    }

    public func setHandler(_ handler: @escaping @Sendable (MarketFeedEvent) -> Void) async {
        self.handler = handler
        await wsPublic.setHandler { [weak self] event in
            Task { await self?.forward(event, from: .publicSocket) }
        }
        await wsBusiness.setHandler { [weak self] event in
            Task { await self?.forward(event, from: .businessSocket) }
        }
    }

    public func subscribe(instId: String, bar: BarInterval) async {
        await wsPublic.subscribe([
            OKXChannelArg(channel: "tickers", instId: instId),
            OKXChannelArg(channel: "books5", instId: instId),
        ])
        await wsBusiness.subscribe([OKXChannelArg(channel: bar.wsChannel, instId: instId)])
    }

    public func unsubscribe(instId: String, bar: BarInterval) async {
        await wsPublic.unsubscribe([
            OKXChannelArg(channel: "tickers", instId: instId),
            OKXChannelArg(channel: "books5", instId: instId),
        ])
        await wsBusiness.unsubscribe([OKXChannelArg(channel: bar.wsChannel, instId: instId)])
    }

    public func switchBar(instId: String, from old: BarInterval, to new: BarInterval) async {
        await wsBusiness.unsubscribe([OKXChannelArg(channel: old.wsChannel, instId: instId)])
        await wsBusiness.subscribe([OKXChannelArg(channel: new.wsChannel, instId: instId)])
    }

    // MARK: Event routing

    private enum Socket { case publicSocket, businessSocket }

    private func forward(_ event: OKXWSEvent, from socket: Socket) {
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
            handler?(.state(FeedState(rawValue: combined.rawValue) ?? .idle))
        case .message(let message):
            switch message {
            case .ticker(let ticker):
                handler?(.ticker(ticker))
            case .candles(let instId, let bar, let candles):
                handler?(.candles(instId: instId, bar: bar, candles: candles))
            case .book(let book):
                handler?(.book(book))
            case .error(let code, let message):
                Log.warn("OKX ws error \(code): \(message)")
            case .pong, .subscribed, .unsubscribed, .ignored:
                break
            }
        }
    }
}

// MARK: - One-off reads

extension OKXRESTClient: MarketDataSource {
    public var venue: Venue { .okx }

    public func book(instId: String, depth: Int) async throws -> OrderBook? {
        try await books(instId: instId, depth: depth)
    }

    /// OKX has no search; an exact instrument id either lists or it does not.
    public func search(_ query: String) async throws -> [InstrumentMatch] {
        let instId = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard !instId.isEmpty, let meta = try await instrumentMeta(instId: instId) else { return [] }
        let type = Venue.okx.instrumentType(of: meta.instId)
        return [InstrumentMatch(instId: meta.instId, name: meta.instId, exchange: "OKX", instType: type)]
    }
}
