import Foundation

/// History shared by backtests that run together.
///
/// "Run all backtests" starts one report per strategy at once, and since the
/// full sample became the whole history, strategies on one instrument and
/// interval each asked for the same hundreds of pages. Here the first request
/// downloads and every other one with the same instrument, interval and venue
/// waits on that download — progress included — or reuses it for a few
/// minutes after. A request for fewer bars is served from a longer download;
/// one for more starts its own.
///
/// Memory only, and only for backtests: the trading runner never reads it.
/// It has to know its feed is live, and a cache is exactly what would hide a
/// dead one.
actor BacktestHistoryMemo {
    static let shared = BacktestHistoryMemo()

    /// How long a finished download may be reused: one batch of reports, not
    /// a session — "today's backtest" means today's bars.
    static let lifetime: TimeInterval = 600

    private struct Key: Hashable {
        let venue: Venue
        let instId: String
        let bar: BarInterval
    }

    private struct Entry {
        let target: Int
        let started: Date
        let download: Task<[Candle], Error>
        var watchers: [@Sendable (Int) -> Void]
    }

    private var entries: [Key: Entry] = [:]

    /// The newest `target` candles, from a download already running or just
    /// finished when one covers them, otherwise from `fetch`.
    func candles(
        venue: Venue, instId: String, bar: BarInterval, target: Int,
        progress: (@Sendable (Int) -> Void)?,
        fetch: @escaping @Sendable (_ progress: @escaping @Sendable (Int) -> Void) async throws -> [Candle]
    ) async throws -> [Candle] {
        let key = Key(venue: venue, instId: instId, bar: bar)
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.started) < Self.lifetime }

        if var entry = entries[key], entry.target >= target {
            if let progress { entry.watchers.append(progress) }
            entries[key] = entry
            Log.warn("backtest: \(venue.rawValue) \(instId) \(bar.rawValue) 的历史与同批回测共用一次下载")
            return Array(try await entry.download.value.suffix(target))
        }

        let download = Task { [weak self] in
            try await fetch { loaded in
                Task { await self?.report(key, loaded: loaded) }
            }
        }
        entries[key] = Entry(target: target, started: now, download: download, watchers: progress.map { [$0] } ?? [])
        do {
            return try await download.value
        } catch {
            // A failed download is not reused: the next report asks afresh.
            if entries[key]?.started == now { entries[key] = nil }
            throw error
        }
    }

    private func report(_ key: Key, loaded: Int) {
        entries[key]?.watchers.forEach { $0(loaded) }
    }
}
