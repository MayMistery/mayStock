import Foundation
import CMayStockKernel

/// Swift face of the kernel's live data layer.
///
/// The kernel holds every real-time connection the checkup reads — OKX's
/// public market socket and read-only account socket, Deribit's option
/// surface, Binance's mark stream, Schwab's quote stream, and the REST reads
/// with no stream — and republishes one snapshot, under a sequence number,
/// whenever anything in it changes. This side only asks for that snapshot,
/// once a frame, and gets nothing back when nothing moved.
///
/// Thread-safe: the kernel serialises everything behind its own channel, and
/// `stop` is guarded here so a late `snapshot` after it is a no-op, not a use
/// of a freed handle.
public final class LiveKernel: @unchecked Sendable {

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

        public init(
            instId: String, followsHeldPosition: Bool, mode: TradingMode,
            okxProfile: String?, okxConfigPath: String?, schwabctlPath: String?,
            network: Bool = true, nowOverrideMs: Int64? = nil
        ) {
            self.instId = instId
            self.followsHeldPosition = followsHeldPosition
            self.mode = mode == .demo ? "demo" : "live"
            self.okxProfile = okxProfile
            self.okxConfigPath = okxConfigPath
            self.schwabctlPath = schwabctlPath
            self.network = network
            self.nowOverrideMs = nowOverrideMs
        }
    }

    private let handle: OpaquePointer
    private let lock = NSLock()
    private var stopped = false

    public init(config: Config) throws {
        let json = try encodeJSON(config)
        var error: UnsafeMutablePointer<CChar>?
        guard let started = ms_live_start(json, &error) else {
            throw KernelError.kernel(KernelStrategy.take(&error) ?? "实时层启动失败（未给出原因）")
        }
        handle = started
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
        let json = try encodeJSON(config)
        try withLiveHandle { handle, error in ms_live_configure(handle, json, error) }
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
