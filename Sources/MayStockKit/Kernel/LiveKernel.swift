import Foundation
import CMayStockKernel

/// Swift face of the kernel's live data layer.
///
/// The kernel holds every real-time connection the app reads. The account
/// part — OKX's read-only private socket, the marks of what the account
/// holds, transfers, stops, the clock — runs for as long as the layer does,
/// and is published on its own (`account(since:)`) for every screen. The
/// checkup's market analytics — Deribit's option surface, Binance's mark
/// stream, Schwab's quote stream, the option books and the REST reads with
/// no stream — run while `Config.analytics` is on, and the whole snapshot
/// (`snapshot(since:)`) carries them. Both come back nil when nothing moved.
///
/// One config, owned here: the app sets the account it reads, the checkup
/// page switches its analytics on and off, and each changes only its own
/// part (`update`).
///
/// Thread-safe: the kernel serialises everything behind its own channel, and
/// `stop` is guarded here so a late `snapshot` after it is a no-op, not a use
/// of a freed handle.
public final class LiveKernel: @unchecked Sendable {

    /// How many of its own intervals a feed may miss before its age reads
    /// stale — the kernel's rule for its feeds, and the rule for every clock
    /// the app runs itself (the REST fallback, a venue it polls).
    public static let staleAfterIntervals = Double(ms_live_stale_after_intervals())
    /// The app's own clocks, as the kernel declares them (`Renewal`): each
    /// loop sleeps by the interval the kernel ages its readings by.
    public enum AppClock: String, CaseIterable, Sendable {
        /// The account over REST while the private socket is down.
        case restFallback
        /// A polled account (Schwab's) holding something priced, or cash alone.
        case polledPriced, polledCash
        /// A polled account's working orders.
        case accountRefresh

        public var interval: TimeInterval { TimeInterval(ms_live_renewal_ms(rawValue)) / 1000 }
    }

    /// How often the account is read over REST while the private
    /// socket is down: the interval the kernel ages those readings by.
    public static let restFallbackInterval = AppClock.restFallback.interval

    /// What the live layer watches.
    public struct Config: Encodable, Sendable, Equatable {
        public var instId: String
        public var followsHeldPosition: Bool
        /// `live` or `demo`.
        public var mode: String
        /// The `okx` CLI profile whose key signs the read-only account login.
        public var okxProfile: String?
        public var okxConfigPath: String?
        public var schwabctlPath: String?
        /// False for tests: nothing connects; frames arrive through `ingest`.
        public var network: Bool
        /// Offline only: a fixed clock, for reproducible time-to-expiry.
        public var nowOverrideMs: Int64?
        /// How many ranges the probability table cuts each automatic step
        /// into. The kernel declares which it offers
        /// (`Probability.gridChoices`); any other shows the automatic step.
        public var gridDivisor: Int
        /// Whether the checkup's market analytics run. The account part runs
        /// either way.
        public var analytics: Bool
        /// The market `instId` is in: `crypto` (an OKX perpetual) or
        /// `usEquity` (a US ticker, its options read from Schwab).
        public var reviewMarket: String
        /// The zone the layer writes times into its texts in, and what it is
        /// called (`DisplayTime`).
        public var displayZone: DisplayZone

        public struct DisplayZone: Encodable, Sendable, Equatable {
            public var identifier: String
            public var name: String

            /// The display zone in force now.
            public static var current: DisplayZone {
                DisplayZone(identifier: DisplayTime.identifier, name: DisplayTime.name)
            }
        }

        public init(
            instId: String, followsHeldPosition: Bool, mode: TradingMode,
            okxProfile: String?, okxConfigPath: String?, schwabctlPath: String?,
            network: Bool = true, nowOverrideMs: Int64? = nil, gridDivisor: Int = 1,
            analytics: Bool = true, reviewMarket: String = LiveSnapshot.Reviewable.crypto,
            displayZone: DisplayZone = .current
        ) {
            self.displayZone = displayZone
            self.reviewMarket = reviewMarket
            self.analytics = analytics
            self.instId = instId
            self.followsHeldPosition = followsHeldPosition
            self.mode = mode == .demo ? "demo" : "live"
            self.okxProfile = okxProfile
            self.okxConfigPath = okxConfigPath
            self.schwabctlPath = schwabctlPath
            self.network = network
            self.nowOverrideMs = nowOverrideMs
            self.gridDivisor = gridDivisor
        }
    }

    private let handle: OpaquePointer
    private let lock = NSLock()
    private var stopped = false
    /// The config the layer is running under; read and written under `lock`.
    private var running: Config

    /// The config the layer is running under.
    public var config: Config {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public init(config: Config) throws {
        let json = try encodeJSON(config)
        var error: UnsafeMutablePointer<CChar>?
        guard let started = ms_live_start(json, &error) else {
            throw KernelError.kernel(KernelStrategy.take(&error) ?? "实时层启动失败（未给出原因）")
        }
        handle = started
        running = config
    }

    deinit { stop() }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        ms_live_stop(handle)
    }

    public func configure(_ config: Config) throws {
        try update { $0 = config }
    }

    /// Change part of the config — what the caller owns — and keep the rest.
    /// Read, changed and sent under one lock, so two owners changing their
    /// own parts at once cannot undo each other. Nothing is sent when nothing
    /// changed.
    public func update(_ change: (inout Config) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw KernelError.kernel("实时层已停止") }
        var next = running
        change(&next)
        guard next != running else { return }
        let json = try encodeJSON(next)
        var error: UnsafeMutablePointer<CChar>?
        guard ms_live_configure(handle, json, &error) == 1 else {
            throw KernelError.kernel(KernelStrategy.take(&error) ?? "实时层调用失败（未给出原因）")
        }
        running = next
    }

    /// The latest account document if it is newer than `since`; nil when
    /// the account has not moved. Cheap enough to call every frame.
    public func account(since: UInt64) -> (seq: UInt64, json: Data)? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        var seq: UInt64 = 0
        guard let pointer = ms_live_account(handle, since, &seq) else { return nil }
        defer { ms_string_free(pointer) }
        return (seq, Data(bytes: pointer, count: strlen(pointer)))
    }

    /// Feed a recorded frame or a REST/CLI document down the live path.
    public func ingest(topic: String, payload: String) throws {
        try withLiveHandle { handle, error in ms_live_ingest(handle, topic, payload, error) }
    }

    /// The latest snapshot if it is newer than `since`; nil when nothing
    /// changed. Cheap enough to call every frame.
    public func snapshot(since: UInt64) -> (seq: UInt64, json: Data)? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        var seq: UInt64 = 0
        guard let pointer = ms_live_snapshot(handle, since, &seq) else { return nil }
        defer { ms_string_free(pointer) }
        return (seq, Data(bytes: pointer, count: strlen(pointer)))
    }

    private func withLiveHandle(
        _ call: (OpaquePointer, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw KernelError.kernel("实时层已停止") }
        var error: UnsafeMutablePointer<CChar>?
        guard call(handle, &error) == 1 else {
            throw KernelError.kernel(KernelStrategy.take(&error) ?? "实时层调用失败（未给出原因）")
        }
    }
}
